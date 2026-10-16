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

// Route resolution: pure, no I/O.

// Resolves a model id (bare, cross-region or ARN) for `bedrock-runtime`. An unknown id
// is not an error: it is sent as given and AWS answers, so new models work at once.
isolated function resolveRuntimeRoute(string model, string region, ApiFamily api) returns Route|error {
    if isArn(model) {
        return resolveRuntimeArn(model, region, api);
    }
    [string, string?] [bareId, geoPrefix] = normalizeModelId(model);
    return {
        api,
        bareModelId: bareId,
        geoPrefix,
        // The geo prefix is stripped for lookup and put back on the wire.
        // https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html
        effectiveModelId: applyGeoPrefix(bareId, geoPrefix),
        region,
        partition: partitionForRegion(region)
    };
}

// The ARN's region and partition win over the caller's.
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
                api,
            bareModelId: bareId,
            geoPrefix,
            effectiveModelId: applyGeoPrefix(bareId, geoPrefix),
            region: arnRegion,
            partition: arn.partition
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
        api,
        bareModelId: arnStr,
        geoPrefix: (),
        effectiveModelId: arnStr,
        region: arnRegion,
        partition: arn.partition
    };
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
