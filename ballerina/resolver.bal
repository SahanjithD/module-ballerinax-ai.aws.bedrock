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

// Route resolution: pure, no I/O. The provider class fixes the endpoint, so a model
// never ends up on an endpoint the caller did not choose.

// Resolves a model id (bare, cross-region or ARN) for `bedrock-runtime`. An unknown id
// is not an error: it is sent as given and AWS answers, so new models work at once.
isolated function resolveRuntimeRoute(string model, string region, ApiFamily api) returns Route|error {
    if isArn(model) {
        return resolveRuntimeArn(model, region, api);
    }
    [string, string?] [bareId, geoPrefix] = normalizeModelId(model);
    return {
        endpoint: RUNTIME,
        api,
        bareModelId: bareId,
        geoPrefix,
        // The geo prefix is stripped for lookup and put back on the wire.
        // https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html
        effectiveModelId: applyGeoPrefix(bareId, geoPrefix),
        region,
        partition: partitionForRegion(region),
        mantleEntry: ()
    };
}

// Resolves a model id for `bedrock-mantle`. Stricter: the request path is per-model data,
// so an id not in `MANTLE_CAPABLE` is refused by name.
// https://docs.aws.amazon.com/bedrock/latest/userguide/bedrock-mantle.html
isolated function resolveMantleRoute(string model, string region) returns Route|error {
    // ARNs name bedrock-runtime resources; none exist on Mantle.
    if isArn(model) {
        return error(string `'${model}' is an ARN, which the bedrock-mantle endpoint does not accept: ` +
            string `provisioned models, inference profiles and custom-model deployments are ` +
            string `bedrock-runtime resources. Pass a bare Mantle model id, or use the matching ` +
            string `Runtime*ModelProvider.`);
    }

    [string, string?] [bareId, geoPrefix] = normalizeModelId(model);
    if geoPrefix is string {
        // Refused rather than stripped: the caller asked for cross-region inference,
        // which Mantle does not have.
        // https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
        return error(string `'${model}' carries the cross-region inference prefix '${geoPrefix}.', ` +
            string `which the bedrock-mantle endpoint does not support — cross-region inference is ` +
            string `available on bedrock-runtime only. Pass the bare id '${bareId}' for Mantle, or use ` +
            string `the matching Runtime*ModelProvider to keep the prefix.`);
    }

    [string, MantleEntry] [canonicalId, entry] = check mantleEntryForBare(bareId);
    // The model decides the API; the Mantle classes take no API argument. `apis` stays
    // a list because some models serve more than one.
    ApiFamily resolvedApi = entry.apis[0];

    return {
        endpoint: MANTLE,
        api: resolvedApi,
        bareModelId: canonicalId,
        geoPrefix: (),
        // Some models have a different id on each endpoint.
        effectiveModelId: entry?.modelId ?: canonicalId,
        region,
        partition: partitionForRegion(region),
        mantleEntry: entry
    };
}

// ARN routing for bedrock-runtime. The ARN's region and partition win over the caller's.
isolated function resolveRuntimeArn(string arnStr, string region, ApiFamily api) returns Route|error {
    ParsedArn arn = check parseArn(arnStr);

    if arn.'service != "bedrock" {
        return error(string `not a Bedrock ARN: service segment is '${arn.'service}', expected 'bedrock'`);
    }

    // Global ARNs leave the region empty; use the caller's then.
    string arnRegion = arn.region == "" ? region : arn.region;

    // A bare id inside; resolve it as one.
    if arn.resourceType == "foundation-model" {
        [string, string?] [bareId, geoPrefix] = normalizeModelId(arn.resourceId);
        return {
            endpoint: RUNTIME,
            api,
            bareModelId: bareId,
            geoPrefix,
            effectiveModelId: applyGeoPrefix(bareId, geoPrefix),
            region: arnRegion,
            partition: arn.partition,
            mantleEntry: ()
        };
    }

    // A custom model is used through its deployment or provisioned-throughput ARN.
    if arn.resourceType == "custom-model" {
        return error(string `'custom-model/' ARN is a model artifact, not a deployment; ` +
            string `pass the 'custom-model-deployment/' (on-demand) or 'provisioned-model/' ARN instead`);
    }

    // Not supported: imported weights have no default chat template, so the request
    // format cannot be known.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/invoke-imported-model.html
    if arn.resourceType == "imported-model" {
        return error(string `'imported-model/' ARNs are not supported: AWS applies no default chat ` +
            string `template to imported weights, so this module cannot build a request body for them. ` +
            string `Use a foundation-model, inference-profile, or provisioned-model ARN instead`);
    }

    // Any other ARN (provisioned model, inference profile, deployment) is sent as is.
    return {
        endpoint: RUNTIME,
        api,
        bareModelId: arnStr,
        geoPrefix: (),
        effectiveModelId: arnStr,
        region: arnRegion,
        partition: arn.partition,
        mantleEntry: ()
    };
}

// Looks up a bare id in `MANTLE_CAPABLE`.
isolated function mantleEntryForBare(string bareId) returns [string, MantleEntry]|error {
    MantleEntry? entry = MANTLE_CAPABLE[bareId];
    if entry is MantleEntry {
        return [bareId, entry];
    }
    // Also accept the Mantle-side id, which is what the Mantle model card shows.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
    foreach [string, MantleEntry] [key, candidate] in MANTLE_CAPABLE.entries() {
        if candidate?.modelId == bareId {
            return [key, candidate];
        }
    }
    return error(string `model '${bareId}' is not available on bedrock-mantle (no known request ` +
        string `path). Use the matching Runtime*ModelProvider, or upgrade the module if AWS ` +
        string `has since added it to bedrock-mantle`);
}

// Splits a cross-region geo prefix off: [bareId, geoPrefix?].
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

isolated function applyGeoPrefix(string bareId, string? geoPrefix) returns string
    => geoPrefix is string ? string `${geoPrefix}.${bareId}` : bareId;

// The partition for a region; ARNs carry their own.
isolated function partitionForRegion(string region) returns string {
    if region.startsWith("us-gov-") {
        return "aws-us-gov";
    }
    if region.startsWith("cn-") {
        return "aws-cn";
    }
    // The isolated and EU Sovereign partitions each have their own DNS suffix.
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
