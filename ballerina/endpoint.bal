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

// Endpoint construction — host · path · partition · signing name.
// L2: runs once, at construction. The model-id path segment is
// URL-encoded HERE (single-encode): structural `/` stay literal, but the model
// id's `:`/`/` (ARNs, `-v1:0` ids) become `%3A`/`%2F`. This is the WIRE path; the
// transport double-encodes it for the SigV4 canonical URI (SigV4 non-S3 rule).

const SIGNING_BEDROCK = "bedrock";               // Converse / Invoke
const SIGNING_BEDROCK_MANTLE = "bedrock-mantle"; // Mantle

// SDK endpoint-metadata service prefixes. Mantle is served from the DUALSTACK
// suffix family, which is partition-SPECIFIC, not partition-neutral: `api.aws` in
// the commercial and GovCloud partitions, but `api.aws.ic.gov`, `api.aws.scloud`,
// `api.amazonwebservices.eu` and `api.amazonwebservices.com.cn` elsewhere.
// `aws:resolveEndpoint` picks the right one per partition.
// https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
const RUNTIME_ENDPOINT_PREFIX = "bedrock-runtime";
const MANTLE_ENDPOINT_PREFIX = "bedrock-mantle";

// Knowledge-base control/data planes. BOTH sign as SigV4 service `bedrock` — same as
// Converse/Invoke, NOT their own hostname — per the `signingName` field in both
// botocore service models (bedrock-agent/2023-06-05 and
// bedrock-agent-runtime/2023-07-26/service-2.json). The endpoint PREFIX (hostname)
// and the SIGNING service are two different things in this service family; only the
// former differs here.
const AGENT_ENDPOINT_PREFIX = "bedrock-agent";
const AGENT_RUNTIME_ENDPOINT_PREFIX = "bedrock-agent-runtime";

// The resolved wire endpoint. `signingService` is the SigV4 scope,
// not the IAM namespace — they differ inside this service family.
type Endpoint record {|
    # Origin, e.g. `https://bedrock-runtime.us-east-1.amazonaws.com`.
    string baseUrl;
    # Host header / SigV4 canonical host, e.g. `bedrock-runtime.us-east-1.amazonaws.com`.
    string host;
    # Wire request path with the model-id segment single-encoded.
    string path;
    # SigV4 signing name for this route.
    string signingService;
|};

// Resolves the origin for a route. A `customEndpoint` in `aws:EndpointConfig`
// replaces the origin wholesale; otherwise the whole job is deferred to AWS SDK
// endpoint metadata, which already covers every partition, the FIPS/dualstack
// variants, per-service exceptions, and a standard-pattern fallback for regions
// newer than the bundled metadata.
//
// `region` comes from the RESOLVED ROUTE, not the raw `region` argument, so an ARN
// whose region segment overrides `region` still lands correctly. The signing region
// and signing name are NOT derived from the result — a VPCE, FIPS or gateway host
// still signs the route's own region/service scope.
isolated function resolveServiceUrl(Route route, aws:EndpointConfig? endpointConfig) returns string {
    boolean mantle = route.family == MANTLE;
    string serviceName = mantle ? MANTLE_ENDPOINT_PREFIX : RUNTIME_ENDPOINT_PREFIX;
    // Mantle is served from the dualstack suffix family; without this flag the
    // metadata falls back to `bedrock-mantle.{region}.amazonaws.com`, which does not
    // resolve. Verified 2026-09-03 against ballerinax/aws 1.0.2 (identical on 1.0.1).
    return resolveServiceUrlCore(serviceName, route.region, endpointConfig, mantle);
}

// The core behind `resolveServiceUrl` and `buildAgentEndpoint`. `forceDualstack` is
// the Mantle case; a caller-supplied `dualstack` is honoured on top of it.
isolated function resolveServiceUrlCore(string serviceName, string region,
        aws:EndpointConfig? endpointConfig, boolean forceDualstack) returns string {
    aws:EndpointConfig config = endpointConfig ?: {};
    string? custom = config?.customEndpoint;
    if custom is string {
        // A concrete origin (PrivateLink, gateway, LocalStack) passes through
        // untouched. Note this is a GLOBAL override with the same semantics as the
        // SDK's `AWS_ENDPOINT_URL`: it applies to every service this client talks to.
        // https://docs.aws.amazon.com/sdkref/latest/guide/feature-ss-endpoints.html
        return trimTrailingSlash(custom);
    }
    return trimTrailingSlash(aws:resolveEndpoint(serviceName, region,
            {fips: config.fips, dualstack: forceDualstack || config.dualstack}));
}

// Trailing slash would double up against the route-derived path.
isolated function trimTrailingSlash(string url) returns string
    => url.endsWith("/") ? url.substring(0, url.length() - 1) : url;

// Amazon Bedrock is not offered in the AWS China partition on ANY endpoint. Three
// independent sources agree: the `aws-cn` partition carries no `bedrock` service
// entry in the SDK endpoint metadata, the regional-availability table has no China
// section, and `bedrock-runtime.cn-north-1.amazonaws.com` does not resolve in DNS.
// The endpoint resolver will still happily BUILD a host there — it is a string
// builder with a standard-pattern fallback and never fails — so without this guard a
// China user sees a bare connection error on their first call, naming nothing.
// https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints-region-availability.html
isolated function guardBedrockPartition(string partition, string region) returns error? {
    if partition == "aws-cn" {
        return error(string `Amazon Bedrock is not available in the AWS China partition ` +
            string `(region '${region}'): no Bedrock endpoint of any API family exists there. ` +
            string `Use a commercial ('aws') or GovCloud ('aws-us-gov') region.`);
    }
}

// Partitions that can form a `bedrock-mantle` host. HOST-SHAPE only, NOT an
// availability oracle: within an allowed partition Mantle ships in a SUBSET of
// regions (`us-gov-east-1` is `bedrock-runtime`-only today) and that subset grows as
// AWS expands. Encoding the region list here would reject a newly-added Mantle region
// until our next release — the exact staleness the routing escape hatches exist to
// avoid — so a well-formed but not-yet-served region is left for AWS to reject at
// call time with its own diagnosis. (DNS is no oracle either:
// `bedrock-mantle.us-gov-east-1.api.aws` resolves even though Mantle is not served
// there.)
//
// Under `AUTO` the resolver never SELECTS Mantle on a partition this rejects — it
// prefers Converse — so reaching the guard in `buildEndpoint` means the caller named
// `apiFamily = MANTLE` explicitly.
// https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints-region-availability.html
isolated function mantleServedOnPartition(string partition) returns boolean
    => partition == "aws" || partition == "aws-us-gov";

// Extracts the host from an origin for the `Host` header / SigV4 canonical host.
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

// Builds the endpoint for a resolved route. Pure. Fails before any I/O for the
// host shapes AWS cannot serve: any route in the China partition, and Mantle on a
// partition or with a FIPS variant that has no such host.
//
// A `customEndpoint` replaces the ORIGIN only — the route-derived path is still
// appended, because that path differs per family (`/model/{id}/converse` vs
// `/anthropic/v1/messages`) and is not the caller's to choose. It also SKIPS the
// host-shape guards: those validate a host we are about to derive, and a concrete
// origin means there is no longer one to validate.
isolated function buildEndpoint(Route route, aws:EndpointConfig? endpointConfig = ())
        returns Endpoint|error {
    boolean derived = (endpointConfig?.customEndpoint) !is string;
    if derived {
        check guardBedrockPartition(route.partition, route.region);
    }

    if route.family == MANTLE {
        if derived && (endpointConfig?.fips ?: false) {
            // No `bedrock-mantle-fips` host exists; `aws:resolveEndpoint` would
            // happily synthesise `bedrock-mantle-fips.{region}.api.aws` and fail at
            // DNS. Name the mistake here instead. Verified 2026-09-03.
            return error("'fips' is not available on the Mantle route: there is no " +
                "bedrock-mantle FIPS endpoint. Use 'apiFamily = CONVERSE' or 'INVOKE' " +
                "for a FIPS-compliant Bedrock call.");
        }
        // Reached only on an EXPLICIT `apiFamily = MANTLE`: under `AUTO` the resolver
        // prefers Converse on a partition that cannot serve Mantle rather than
        // failing. See `mantleServedOnPartition`.
        if derived && !mantleServedOnPartition(route.partition) {
            return error(string `Mantle is not available on partition '${route.partition}': no ` +
                string `bedrock-mantle host is served there. Use 'apiFamily = CONVERSE' or ` +
                string `'INVOKE', or a commercial ('aws') or GovCloud ('aws-us-gov') region.`);
        }
        MantleEntry entry = check route.mantleEntry.ensureType();
        string mantleBase = resolveServiceUrl(route, endpointConfig);
        return {
            baseUrl: mantleBase,
            host: hostOf(mantleBase),
            path: entry.path,
            signingService: SIGNING_BEDROCK_MANTLE
        };
    }

    // Converse / Invoke on `bedrock-runtime`, partition-aware domain.
    string base = resolveServiceUrl(route, endpointConfig);
    // Single-encode the model-id segment (ARNs/`-v1:0` ids carry `:` and `/`).
    string encodedId = encodePathSegment(route.effectiveModelId);
    string path = route.family == CONVERSE
        ? string `/model/${encodedId}/converse`
        : string `/model/${encodedId}/invoke`;
    return {baseUrl: base, host: hostOf(base), path, signingService: SIGNING_BEDROCK};
}

// Which bedrock-agent plane an endpoint is for. Module-private: only the knowledge
// base spine needs this distinction.
enum AgentPlane {
    // Control plane (`bedrock-agent`): CreateKnowledgeBase, CreateDataSource,
    // IngestKnowledgeBaseDocuments, List/Get/DeleteKnowledgeBaseDocuments, ...
    AGENT_CONTROL,
    // Data plane (`bedrock-agent-runtime`): Retrieve.
    AGENT_DATA
}

// Builds the endpoint for a knowledge-base agent plane. Unlike `buildEndpoint`, the
// request PATH is not fixed at construction — a single `BedrockTransport` for a
// plane serves many paths (`/knowledgebases/`, `/knowledgebases/{id}/retrieve`,
// `/knowledgebases/{id}/datasources/{id}/documents`, …) — so `path` is left empty
// and every call site of `BedrockTransport.executeRequest` supplies its own.
//
// NOTE both planes resolve from the SAME `aws:EndpointConfig`. That is correct for
// the derived case — `bedrock-agent` and `bedrock-agent-runtime` are separate
// service names and get separate hosts — but a `customEndpoint` applies to both, as
// the SDK's global `AWS_ENDPOINT_URL` does. That suits a mock or a single gateway;
// a real multi-VPCE deployment needs private DNS instead. See the README.
isolated function buildAgentEndpoint(AgentPlane plane, string region,
        aws:EndpointConfig? endpointConfig = ()) returns Endpoint|error {
    if (endpointConfig?.customEndpoint) !is string {
        check guardBedrockPartition(partitionForRegion(region), region);
    }
    string serviceName = plane == AGENT_DATA ? AGENT_RUNTIME_ENDPOINT_PREFIX : AGENT_ENDPOINT_PREFIX;
    string base = resolveServiceUrlCore(serviceName, region, endpointConfig, false);
    return {baseUrl: base, host: hostOf(base), path: "", signingService: SIGNING_BEDROCK};
}

// RFC 3986 unreserved set — the ONLY characters SigV4 leaves literal.
// https://datatracker.ietf.org/doc/html/rfc3986#section-2.3
const string RFC3986_UNRESERVED =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";

final readonly & string[] HEX_DIGITS =
    ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"];

// Percent-encodes one path segment per RFC 3986, which is what SigV4 requires.
//
// `url:encode` is NOT a path-segment encoder — it applies
// `application/x-www-form-urlencoded` rules, which differ from SigV4's on exactly
// the characters a model id can contain: a space becomes `+` instead of `%20`, and
// `~` is escaped even though it is unreserved. Since `getCanonicalUri` re-applies
// this same function to build the signing input, any such character produced a
// canonical URI AWS could not reconstruct — a `SignatureDoesNotMatch` on every
// request, with nothing in the message pointing at the encoder.
//
// Total by construction: every byte either passes through or becomes `%XX`, so
// there is no failure mode for a caller to handle.
// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
isolated function encodePathSegment(string segment) returns string {
    string encoded = "";
    foreach string:Char ch in segment {
        if RFC3986_UNRESERVED.includes(ch) {
            encoded += ch;
            continue;
        }
        // Percent-encode each UTF-8 byte, uppercase hex (SigV4 requires uppercase).
        foreach byte b in ch.toBytes() {
            int value = <int>b;
            encoded += "%" + HEX_DIGITS[value / 16] + HEX_DIGITS[value % 16];
        }
    }
    return encoded;
}
