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

// resolveRoute — the §5.1 ladder. Pure: no I/O, no state, fully table-testable
// without AWS credentials (design §5.1, §13.1). All construction-time routing
// decisions are made here.

// Resolves a model id (bare, CRIS-prefixed, ARN, or `mantle/|converse/|invoke/`
// prefixed) to a fully-specified `Route` (design §5.1). Returns an `error` for
// the cases AWS cannot diagnose for us (design principle 7): `custom-model/`
// ARNs, `imported-model/` ARNs missing `modelSchema`, and `apiFamily = MANTLE`
// on a model absent from `MANTLE_CAPABLE`.
isolated function resolveRoute(string model, string region, RouteConfig config = {}) returns Route|error {
    // ---- step 1: explicit override (prefix and/or config.apiFamily) ----
    // AUTO (the config default) means "no forced family" — run the ladder (amendment).
    [ApiFamily?, string] [prefixFamily, work] = stripRoutePrefix(model);
    ApiFamily? configFamily = config.apiFamily == AUTO ? () : config.apiFamily;
    ApiFamily? explicitFamily = configFamily ?: prefixFamily;

    // ---- step 2: ARN dispatch (region + partition are authoritative — §5.2) ----
    if isArn(work) {
        return resolveArn(work, config, explicitFamily);
    }

    // ---- bare / CRIS-prefixed id: normalize then walk steps 3-6 ----
    string effRegion = region;
    string partition = partitionForRegion(region);
    return resolveBareId(work, effRegion, partition, config, explicitFamily);
}

// Splits an optional `mantle/|converse/|invoke/` route prefix off the model
// string (design §5.1 step 1). Returns the implied family (if any) and the
// remaining id.
isolated function stripRoutePrefix(string model) returns [ApiFamily?, string] {
    if model.startsWith("mantle/") {
        return [MANTLE, model.substring("mantle/".length())];
    }
    if model.startsWith("converse/") {
        return [CONVERSE, model.substring("converse/".length())];
    }
    if model.startsWith("invoke/") {
        return [INVOKE, model.substring("invoke/".length())];
    }
    return [(), model];
}

// ARN dispatch — the resource-type token gives the family before any call
// (design §5.1 step 2, §5.2). The ARN's region/partition override `config.region`.
isolated function resolveArn(string arnStr, RouteConfig config, ApiFamily? explicitFamily) returns Route|error {
    ParsedArn arn = check parseArn(arnStr);

    // `foundation-model/` carries a bare, globally-addressable id — strip to it
    // and fall through to the allowlists (design §5.1 step 2).
    if arn.resourceType == "foundation-model" {
        return resolveBareId(arn.resourceId, arn.region, arn.partition, config, explicitFamily);
    }

    // `custom-model/` is an artifact, not a deployment — AWS's prose directs
    // users to the deployment/Provisioned-Throughput ARN (design §5.2). Policy
    // choice, recorded so a reviewer can overrule it.
    if arn.resourceType == "custom-model" {
        return error(string `'custom-model/' ARN is a model artifact, not a deployment; ` +
            string `pass the 'custom-model-deployment/' (on-demand) or 'provisioned-model/' ARN instead`);
    }

    // Every remaining opaque ARN keeps its family through the sink (design §5.1
    // step 6). Default family by resource type; an explicit override outranks it.
    ApiFamily defaultFamily = arn.resourceType == "imported-model" ? INVOKE : CONVERSE;
    ApiFamily family = explicitFamily ?: defaultFamily;

    // `imported-model/` says nothing about the body schema (design §5.4): AWS
    // applies no default chat template, so INVOKE needs `modelSchema`.
    if family == INVOKE && arn.resourceType == "imported-model" && config.modelSchema is () {
        return error(string `'imported-model/' ARN requires 'modelSchema' — AWS applies no default ` +
            string `chat template for imported weights, so the request body cannot be built without it`);
    }

    MantleEntry? mantleEntry = ();
    if family == MANTLE {
        // An opaque ARN is not a bare id, so it cannot be in MANTLE_CAPABLE
        // unless the user supplied a routeOverride keyed by the ARN string.
        mantleEntry = check mantleEntryFor(arnStr, config);
    }

    return {
        family,
        bareModelId: arnStr,
        geoPrefix: (),
        effectiveModelId: arnStr, // opaque ARNs go on the wire verbatim (URL-encoded in endpoint.bal)
        region: arn.region,
        partition: arn.partition,
        mantleEntry
    };
}

// Bare/CRIS-prefixed id: normalize (strip geo prefix, keep it) then walk ladder
// steps 3-6 (design §5.1, §5.3).
isolated function resolveBareId(string id, string region, string partition, RouteConfig config,
        ApiFamily? explicitFamily) returns Route|error {
    [string, string?] [bareId, geoPrefix] = normalizeModelId(id);

    // step 1 (explicit): outranks the tables.
    if explicitFamily is ApiFamily {
        return buildBareRoute(explicitFamily, bareId, geoPrefix, region, partition, config);
    }

    // step 3: routeOverrides.
    map<ApiFamily|MantleEntry>? overrides = config.routeOverrides;
    if overrides is map<ApiFamily|MantleEntry> {
        ApiFamily|MantleEntry? ov = overrides[bareId];
        if ov is MantleEntry {
            return mantleRoute(bareId, geoPrefix, region, partition, ov);
        }
        if ov is ApiFamily {
            return buildBareRoute(ov, bareId, geoPrefix, region, partition, config);
        }
    }

    // step 4: MANTLE_DEFAULT (positive allowlist) — checked BEFORE Converse so an
    // unknown model can never reach Mantle by elimination (design principle 2).
    if MANTLE_DEFAULT.indexOf(bareId) is int {
        return mantleRoute(bareId, geoPrefix, region, partition, check mantleEntryForBare(bareId));
    }

    // step 5: CONVERSE_MODELS positive allowlist. step 6 sink: everything else
    // → CONVERSE (never Mantle). Both land on the same family.
    return buildBareRoute(CONVERSE, bareId, geoPrefix, region, partition, config);
}

// Builds a CONVERSE/INVOKE/MANTLE route from a resolved family + bare id.
isolated function buildBareRoute(ApiFamily family, string bareId, string? geoPrefix, string region,
        string partition, RouteConfig config) returns Route|error {
    if family == MANTLE {
        return mantleRoute(bareId, geoPrefix, region, partition, check mantleEntryForBare(bareId));
    }
    // CONVERSE/INVOKE take the CRIS-prefixed id on the wire (design §5.3).
    return {
        family,
        bareModelId: bareId,
        geoPrefix,
        effectiveModelId: applyGeoPrefix(bareId, geoPrefix),
        region,
        partition,
        mantleEntry: ()
    };
}

// Builds a MANTLE route. Mantle takes the BARE id on the wire (design §5.3).
isolated function mantleRoute(string bareId, string? geoPrefix, string region, string partition,
        MantleEntry entry) returns Route {
    return {
        family: MANTLE,
        bareModelId: bareId,
        geoPrefix,
        effectiveModelId: bareId,
        region,
        partition,
        mantleEntry: entry
    };
}

// MANTLE_CAPABLE lookup for a bare id (design §7.3). Capability ≠ membership: a
// model the user forced onto Mantle must have a path/auth/codec entry.
isolated function mantleEntryForBare(string bareId) returns MantleEntry|error {
    MantleEntry? entry = MANTLE_CAPABLE[bareId];
    if entry is () {
        return error(string `model '${bareId}' is not available on Mantle ` +
            string `(no path/auth/codec entry); supply 'routeOverrides' if AWS has since added it`);
    }
    return entry;
}

// MANTLE_CAPABLE lookup that also consults `routeOverrides` (for keys — e.g. ARN
// strings — not present in the static table).
isolated function mantleEntryFor(string key, RouteConfig config) returns MantleEntry|error {
    map<ApiFamily|MantleEntry>? overrides = config.routeOverrides;
    if overrides is map<ApiFamily|MantleEntry> {
        ApiFamily|MantleEntry? ov = overrides[key];
        if ov is MantleEntry {
            return ov;
        }
    }
    return mantleEntryForBare(key);
}

// Strips a CRIS geo prefix for lookup, keeping it for per-family re-application
// (design §5.3). Returns [bareId, geoPrefix?].
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

// Re-applies a CRIS geo prefix to a bare id (Converse/Invoke wire form — §5.3).
isolated function applyGeoPrefix(string bareId, string? geoPrefix) returns string
    => geoPrefix is string ? string `${geoPrefix}.${bareId}` : bareId;

// Partition inferred from a region string (design §9.2). ARNs carry their own
// partition; bare-id routes derive it here.
isolated function partitionForRegion(string region) returns string {
    if region.startsWith("us-gov-") {
        return "aws-us-gov";
    }
    if region.startsWith("cn-") {
        return "aws-cn";
    }
    return "aws";
}
