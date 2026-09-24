// Copyright (c) 2026 WSO2 LLC. (http://www.wso2.com).
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Route resolution. Pure: no I/O, no state, fully table-testable without AWS
// credentials. All construction-time routing decisions are made here.
//
// There is no longer a single `resolveRoute` with a preference ladder. The provider
// CLASS fixes the endpoint, so resolution splits in two and each half is small
// enough to read at a glance. Nothing here can send a model to an endpoint the
// caller did not name — the old `AUTO` failure mode, where a bare id silently
// resolved to `bedrock-mantle` and then 403'd on a separate IAM namespace, is
// unrepresentable.

// Resolves a model id for the `bedrock-runtime` endpoint. The id may be bare,
// CRIS-prefixed, or an ARN. Returns an `error` only for the cases AWS cannot
// diagnose for us: `custom-model/` and `imported-model/` ARNs.
//
// Unknown ids are NOT an error. Converse is model-agnostic, so an id this module has
// never heard of goes on the wire as-is and AWS answers for it — which is what keeps
// a model AWS ships tomorrow usable today.
isolated function resolveRuntimeRoute(string model, string region, ApiShape shape) returns Route|error {
    if isArn(model) {
        return resolveRuntimeArn(model, region, shape);
    }
    [string, string?] [bareId, geoPrefix] = normalizeModelId(model);
    return {
        endpoint: RUNTIME,
        shape,
        bareModelId: bareId,
        geoPrefix,
        // Cross-region inference is a `bedrock-runtime` concept: the geo prefix is
        // stripped for table lookup and re-applied on the wire.
        // https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html
        effectiveModelId: applyGeoPrefix(bareId, geoPrefix),
        region,
        partition: partitionForRegion(region),
        mantleEntry: ()
    };
}

// Resolves a model id for the `bedrock-mantle` endpoint.
//
// Stricter than the runtime side by necessity: a Mantle request path is per-model
// table data (`/v1` vs `/openai/v1` vs `/anthropic/v1` on the same host) and is not
// derivable from an id, so an id absent from `MANTLE_CAPABLE` has no URL to build and
// is refused by name rather than guessed at.
// https://docs.aws.amazon.com/bedrock/latest/userguide/bedrock-mantle.html
isolated function resolveMantleRoute(string model, string region, MantleApi? shape = ()) returns Route|error {
    // An ARN names a `bedrock-runtime` resource — a provisioned model, an inference
    // profile, a custom-model deployment. None of those exist on Mantle, and an ARN
    // is not a key into `MANTLE_CAPABLE`, so there is nothing to look up.
    if isArn(model) {
        return error(string `'${model}' is an ARN, which the bedrock-mantle endpoint does not accept: ` +
            string `provisioned models, inference profiles and custom-model deployments are ` +
            string `bedrock-runtime resources. Pass a bare Mantle model id, or use the matching ` +
            string `BedrockRuntime*ModelProvider.`);
    }

    [string, string?] [bareId, geoPrefix] = normalizeModelId(model);
    if geoPrefix is string {
        // Guard, not a silent strip: a caller who passed `us.` asked for cross-region
        // inference, and Mantle has none. Dropping the prefix would quietly give them
        // in-region single-endpoint routing under the name they used to request the
        // opposite.
        // https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
        return error(string `'${model}' carries the cross-region inference prefix '${geoPrefix}.', ` +
            string `which the bedrock-mantle endpoint does not support — cross-region inference is ` +
            string `available on bedrock-runtime only. Pass the bare id '${bareId}' for Mantle, or use ` +
            string `the matching BedrockRuntime*ModelProvider to keep the prefix.`);
    }

    MantleEntry entry = check mantleEntryForBare(bareId);
    // `api` SELECTS among the shapes this model serves; unset takes the first. A
    // model published on two shapes (gpt-oss serves Responses and Chat Completions
    // on `/v1`) is reachable on either.
    ApiShape resolvedShape = entry.shapes[0];
    if shape is MantleApi {
        if entry.shapes.indexOf(shape) is () {
            return error(string `model '${bareId}' is not served as ${shape} on bedrock-mantle. ` +
                string `It is served as ${string:'join(" or ", ...entry.shapes)}; drop the 'api' ` +
                string `argument to use ${entry.shapes[0]}.`);
        }
        resolvedShape = shape;
    }

    return {
        endpoint: MANTLE,
        shape: resolvedShape,
        bareModelId: bareId,
        geoPrefix: (),
        // A model may be published under different ids per endpoint (see
        // `MantleEntry.modelId`); the entry wins when it says so.
        effectiveModelId: entry?.modelId ?: bareId,
        region,
        partition: partitionForRegion(region),
        mantleEntry: entry
    };
}

// ARN dispatch for the runtime endpoint — the resource-type token settles the case
// before any call. The ARN's region and partition override the caller's.
isolated function resolveRuntimeArn(string arnStr, string region, ApiShape shape) returns Route|error {
    ParsedArn arn = check parseArn(arnStr);

    if arn.'service != "bedrock" {
        return error(string `not a Bedrock ARN: service segment is '${arn.'service}', expected 'bedrock'`);
    }

    // The ARN's region is authoritative — but it is legitimately EMPTY on global ARNs
    // such as `arn:aws:bedrock::123:foundation-model/anthropic.claude-v2`. Copying ""
    // through would build the host `bedrock-runtime..amazonaws.com` and surface as an
    // opaque DNS failure, so fall back to the caller's region.
    string arnRegion = arn.region == "" ? region : arn.region;

    // `foundation-model/` carries a bare, globally-addressable id — strip to it and
    // resolve as an ordinary bare id.
    if arn.resourceType == "foundation-model" {
        [string, string?] [bareId, geoPrefix] = normalizeModelId(arn.resourceId);
        return {
            endpoint: RUNTIME,
            shape,
            bareModelId: bareId,
            geoPrefix,
            effectiveModelId: applyGeoPrefix(bareId, geoPrefix),
            region: arnRegion,
            partition: arn.partition,
            mantleEntry: ()
        };
    }

    // `custom-model/` is an artifact, not a deployment — AWS's prose directs users to
    // the deployment/Provisioned-Throughput ARN. Policy choice, recorded so a reviewer
    // can overrule it.
    if arn.resourceType == "custom-model" {
        return error(string `'custom-model/' ARN is a model artifact, not a deployment; ` +
            string `pass the 'custom-model-deployment/' (on-demand) or 'provisioned-model/' ARN instead`);
    }

    // `imported-model/` (Custom Model Import) is out of scope. AWS applies no default
    // chat template to imported weights, so the request body cannot be built without
    // the caller naming the wire dialect.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/invoke-imported-model.html
    if arn.resourceType == "imported-model" {
        return error(string `'imported-model/' ARNs are not supported: AWS applies no default chat ` +
            string `template to imported weights, so this module cannot build a request body for them. ` +
            string `Use a foundation-model, inference-profile, or provisioned-model ARN instead`);
    }

    // Every remaining opaque ARN (provisioned-model, inference-profile,
    // application-inference-profile, custom-model-deployment) goes on the wire
    // verbatim, URL-encoded in endpoint.bal.
    return {
        endpoint: RUNTIME,
        shape,
        bareModelId: arnStr,
        geoPrefix: (),
        effectiveModelId: arnStr,
        region: arnRegion,
        partition: arn.partition,
        mantleEntry: ()
    };
}

// `MANTLE_CAPABLE` lookup for a bare id. A Mantle path is not derivable from a model
// id, so a model AWS has added since our last release cannot be reached on Mantle
// until the table ships it.
isolated function mantleEntryForBare(string bareId) returns MantleEntry|error {
    MantleEntry? entry = MANTLE_CAPABLE[bareId];
    if entry is () {
        return error(string `model '${bareId}' is not available on bedrock-mantle (no known request ` +
            string `path). Use the matching BedrockRuntime*ModelProvider, or upgrade the module if AWS ` +
            string `has since added it to bedrock-mantle`);
    }
    return entry;
}

// Strips a CRIS geo prefix for lookup, keeping it for re-application on the wire.
// Returns [bareId, geoPrefix?].
isolated function normalizeModelId(string id) returns [string, string?] {
    int? dot = id.indexOf(".");
    if dot is int {
        string maybePrefix = id.substring(0, dot);
        if CRIS_PREFIXES.indexOf(maybePrefix) is int {
            return [id.substring(dot + 1), maybePrefix];
        }
    }
    return [id, ()];
}

// Re-applies a CRIS geo prefix to a bare id (the `bedrock-runtime` wire form).
isolated function applyGeoPrefix(string bareId, string? geoPrefix) returns string
    => geoPrefix is string ? string `${geoPrefix}.${bareId}` : bareId;

// Partition inferred from a region string. ARNs carry their own partition; bare-id
// routes derive it here.
isolated function partitionForRegion(string region) returns string {
    if region.startsWith("us-gov-") {
        return "aws-us-gov";
    }
    if region.startsWith("cn-") {
        return "aws-cn";
    }
    // The isolated and EU Sovereign partitions. Bedrock carries a service entry in all
    // four in the SDK endpoint metadata, and each has its own DNS suffix
    // (`c2s.ic.gov`, `sc2s.sgov.gov`, `csp.hci.ic.gov`, `amazonaws.eu`). Reporting them
    // as `aws` let them past the Mantle host-shape guard, which would then build a
    // `bedrock-mantle` host for a partition that serves none.
    // `us-isob-`/`us-isof-` do not match the `us-iso-` prefix, so order is irrelevant.
    if region.startsWith("us-iso-") {
        return "aws-iso";
    }
    if region.startsWith("us-isob-") {
        return "aws-iso-b";
    }
    if region.startsWith("us-isof-") {
        return "aws-iso-f";
    }
    if region.startsWith("eusc-") {
        return "aws-eusc";
    }
    return "aws";
}
