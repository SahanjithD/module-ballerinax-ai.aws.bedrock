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

import ballerinax/aws;

// Endpoint construction: host, path, partition and signing name, once at construction.
// The model id is single-encoded in the wire path; the transport encodes it again for
// the SigV4 canonical URI.

// Every `bedrock-runtime` path signs as `bedrock`, the OpenAI and Anthropic paths too.
// https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html
const SIGNING_BEDROCK = "bedrock";
// "SigV4 signature with service name `bedrock-mantle`".
// https://docs.aws.amazon.com/bedrock/latest/userguide/count-tokens.html
const SIGNING_BEDROCK_MANTLE = "bedrock-mantle";

// Mantle's hosts use the partition's dualstack suffix (`api.aws` and others), which
// `aws:resolveEndpoint` picks.
// https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
const RUNTIME_ENDPOINT_PREFIX = "bedrock-runtime";
const MANTLE_ENDPOINT_PREFIX = "bedrock-mantle";

// Knowledge-base hosts. Both still sign as `bedrock` (botocore `signingName`).
const AGENT_ENDPOINT_PREFIX = "bedrock-agent";
const AGENT_RUNTIME_ENDPOINT_PREFIX = "bedrock-agent-runtime";

// Uses the route's region, so an ARN's region wins.
isolated function resolveServiceUrl(Route route, aws:EndpointConfig? endpointConfig) returns string|error {
    boolean mantle = route.endpoint == MANTLE;
    string serviceName = mantle ? MANTLE_ENDPOINT_PREFIX : RUNTIME_ENDPOINT_PREFIX;
    // Mantle is only on the dualstack host; the plain one does not resolve.
    return resolveServiceUrlCore(serviceName, route.region, endpointConfig, mantle);
}

// Every host this module dials is built here, so the dualstack check lives here.
isolated function resolveServiceUrlCore(string serviceName, string region,
        aws:EndpointConfig? endpointConfig, boolean forceDualstack) returns string|error {
    aws:EndpointConfig config = endpointConfig ?: {};
    string? custom = config?.customEndpoint;
    if custom is string {
        // Used as given, for every service this client calls, like `AWS_ENDPOINT_URL`.
        // https://docs.aws.amazon.com/sdkref/latest/guide/feature-ss-endpoints.html
        return trimTrailingSlash(custom);
    }
    check guardDualstack(serviceName, region, config.dualstack);
    return trimTrailingSlash(aws:resolveEndpoint(serviceName, region,
            {fips: config.fips, dualstack: forceDualstack || config.dualstack}));
}

// Only `bedrock-mantle` has a dualstack host. `aws:resolveEndpoint` would still build
// one for the others, which then fails as a confusing connection error.
// https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
isolated function guardDualstack(string serviceName, string region, boolean dualstack) returns error? {
    if !dualstack || serviceName == MANTLE_ENDPOINT_PREFIX {
        return;
    }
    return error(string `'dualstack' is not available on '${serviceName}': AWS publishes a dualstack ` +
        string `('.api.aws') host for 'bedrock-mantle' only, so '${serviceName}.${region}.api.aws' does ` +
        string `not resolve and every request would fail as a connection error. Drop 'dualstack' ` +
        string `(the standard host is reached over IPv4), use a Mantle*ModelProvider if you ` +
        string `need the dualstack endpoint family, or set 'customEndpoint' to dial a specific origin.`);
}

isolated function trimTrailingSlash(string url) returns string
    => url.endsWith("/") ? url.substring(0, url.length() - 1) : url;

// Bedrock is not offered in the China partition. The resolver would still build a
// host there, which fails only on the first call.
// https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints-region-availability.html
isolated function guardBedrockPartition(string partition, string region) returns error? {
    if partition == "aws-cn" {
        return error(string `Amazon Bedrock is not available in the AWS China partition ` +
            string `(region '${region}'): no Bedrock endpoint of any API family exists there. ` +
            string `Use a commercial ('aws') or GovCloud ('aws-us-gov') region.`);
    }
}

// Partitions that can form a `bedrock-mantle` host. Host shape only: which regions
// actually serve Mantle is left for AWS to answer, so new regions work.
// https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints-region-availability.html
isolated function mantleServedOnPartition(string partition) returns boolean
    => partition == "aws" || partition == "aws-us-gov";

isolated function hostOf(string baseUrl) returns string {
    string rest = baseUrl;
    foreach string scheme in ["https://", "http://"] {
        if rest.startsWith(scheme) {
            rest = rest.substring(scheme.length());
            break;
        }
    }
    int? slash = rest.indexOf("/");
    return slash is int ? rest.substring(0, slash) : rest;
}

// A `customEndpoint` replaces only the origin and skips the host checks.
isolated function buildEndpoint(Route route, aws:EndpointConfig? endpointConfig = ())
        returns Endpoint|error {
    boolean derived = (endpointConfig?.customEndpoint) !is string;
    if derived {
        check guardBedrockPartition(route.partition, route.region);
    }

    if route.endpoint == MANTLE {
        if derived && (endpointConfig?.fips ?: false) {
            // There is no `bedrock-mantle-fips` host.
            // https://docs.aws.amazon.com/bedrock/latest/userguide/vpc-interface-endpoints.html
            return error("'fips' is not available on the bedrock-mantle endpoint: there is no " +
                "bedrock-mantle FIPS host. Use a Runtime*ModelProvider for a " +
                "FIPS-compliant Bedrock call.");
        }
        if derived && !mantleServedOnPartition(route.partition) {
            return error(string `bedrock-mantle is not available on partition '${route.partition}': no ` +
                string `bedrock-mantle host is served there. Use a Runtime*ModelProvider, or a ` +
                string `commercial ('aws') or GovCloud ('aws-us-gov') region.`);
        }
        MantleEntry entry = check route.mantleEntry.ensureType();
        string mantleBase = check resolveServiceUrl(route, endpointConfig);
        return {
            baseUrl: mantleBase,
            host: hostOf(mantleBase),
            path: check mantlePathFor(entry.basePath, route.api),
            signingService: SIGNING_BEDROCK_MANTLE
        };
    }

    string base = check resolveServiceUrl(route, endpointConfig);
    return {
        baseUrl: base,
        host: hostOf(base),
        path: check runtimePath(route),
        signingService: SIGNING_BEDROCK
    };
}

// Converse and InvokeModel carry the model id in the path; the others in the body.
// https://docs.aws.amazon.com/bedrock/latest/userguide/apis.html
isolated function runtimePath(Route route) returns string|error {
    match route.api {
        CONVERSE => {
            return string `/model/${encodePathSegment(route.effectiveModelId)}/converse`;
        }
        INVOKE => {
            return string `/model/${encodePathSegment(route.effectiveModelId)}/invoke`;
        }
        MESSAGES => {
            // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html
            return "/anthropic/v1/messages";
        }
        CHAT_COMPLETIONS => {
            // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html
            return "/openai/v1/chat/completions";
        }
        RESPONSES => {
            // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html
            return "/openai/v1/responses";
        }
    }
    return error(string `no bedrock-runtime path for api '${route.api}'`);
}

isolated function isPathAddressed(ApiFamily api) returns boolean
    => api == CONVERSE || api == INVOKE;

// No path: one transport serves many paths.
isolated function buildAgentEndpoint(AgentPlane plane, string region,
        aws:EndpointConfig? endpointConfig = ()) returns Endpoint|error {
    if (endpointConfig?.customEndpoint) !is string {
        check guardBedrockPartition(partitionForRegion(region), region);
    }
    string serviceName = plane == AGENT_DATA ? AGENT_RUNTIME_ENDPOINT_PREFIX : AGENT_ENDPOINT_PREFIX;
    string base = check resolveServiceUrlCore(serviceName, region, endpointConfig, false);
    return {baseUrl: base, host: hostOf(base), path: "", signingService: SIGNING_BEDROCK};
}

// RFC 3986 unreserved characters, the only ones SigV4 leaves as is.
// https://datatracker.ietf.org/doc/html/rfc3986#section-2.3
const string RFC3986_UNRESERVED =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";

final readonly & string[] HEX_DIGITS =
    ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"];

// Percent-encodes one path segment per RFC 3986, as SigV4 requires. Not `url:encode`,
// which encodes a space as `+` and escapes `~`, breaking the signature.
// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
isolated function encodePathSegment(string segment) returns string {
    string encoded = "";
    foreach string:Char ch in segment {
        if RFC3986_UNRESERVED.includes(ch) {
            encoded += ch;
            continue;
        }
        // Uppercase hex, as SigV4 requires.
        foreach byte b in ch.toBytes() {
            int value = <int>b;
            encoded += "%" + HEX_DIGITS[value / 16] + HEX_DIGITS[value % 16];
        }
    }
    return encoded;
}
