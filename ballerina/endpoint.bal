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

// Endpoint construction — host · path · partition · signing name.
// L2: runs once, at construction. The model-id path segment is
// URL-encoded HERE (single-encode): structural `/` stay literal, but the model
// id's `:`/`/` (ARNs, `-v1:0` ids) become `%3A`/`%2F`. This is the WIRE path; the
// transport double-encodes it for the SigV4 canonical URI (SigV4 non-S3 rule).

const SIGNING_BEDROCK = "bedrock";               // Converse / Invoke
const SIGNING_BEDROCK_MANTLE = "bedrock-mantle"; // Mantle

// Mantle is served from the partition-neutral `api.aws` suffix in every partition
// that has it — it does NOT follow `awsDomain(partition)`.
// https://docs.aws.amazon.com/bedrock/latest/userguide/bedrock-mantle.html
const MANTLE_DOMAIN = "api.aws";

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

// The default `serviceUrl`. A TEMPLATE, not a constant host, because the origin is
// decided by the resolved route: `bedrock-runtime.{region}.amazonaws.com` on
// Converse/Invoke, `bedrock-mantle.{region}.api.aws` on Mantle, and
// `amazonaws.com.cn` in China. One pattern spans all three.
//
// Substitution is a no-op on a string containing no placeholders, so a caller who
// passes a concrete URL needs no sentinel and no "did they override it?" check —
// their URL simply passes through untouched.
public const DEFAULT_SERVICE_URL = "https://bedrock-{endpoint}.{region}.{domain}";

// Resolves `serviceUrl` against a route: substitutes the placeholders, or passes a
// concrete URL through unchanged. Pure.
//
// `{region}` and `{domain}` come from the RESOLVED ROUTE, not the raw `region`
// argument, so an ARN whose region segment overrides `region` still lands correctly.
// The signing region and signing name are NOT derived from the result — a VPCE,
// FIPS or gateway host still signs the route's own region/service scope.
isolated function resolveServiceUrl(string serviceUrl, Route route, string endpointName) returns string|error {
    string domain = route.family == MANTLE ? MANTLE_DOMAIN : awsDomain(route.partition);
    string url = re `\{endpoint\}`.replaceAll(serviceUrl, endpointName);
    url = re `\{region\}`.replaceAll(url, route.region);
    url = re `\{domain\}`.replaceAll(url, domain);

    // A surviving brace is ALWAYS a typo (`{regoin}`), never a legal host: braces are
    // not valid in DNS names. Catching it here turns a silent DNS failure into a
    // construction error that names the mistake.
    if url.includes("{") || url.includes("}") {
        return error(string `unresolved placeholder in serviceUrl '${url}'; ` +
            string `supported placeholders are {endpoint}, {region} and {domain}`);
    }
    // Trailing slash would double up against the route-derived path.
    return url.endsWith("/") ? url.substring(0, url.length() - 1) : url;
}

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

// Builds the endpoint for a resolved route. Pure. Fails before
// any I/O for the one host-shape AWS cannot template: Mantle on a non-`aws`
// partition.
//
// `serviceUrl` replaces the ORIGIN only — the route-derived path is still appended,
// because that path differs per family (`/model/{id}/converse` vs
// `/anthropic/v1/messages`) and is not the caller's to choose.
isolated function buildEndpoint(Route route, string serviceUrl = DEFAULT_SERVICE_URL) returns Endpoint|error {
    if route.family == MANTLE {
        // Mantle is served from the partition-neutral `api.aws` suffix. That suffix
        // exists in the commercial AND GovCloud partitions — `bedrock-mantle.us-gov-west-1.api.aws`
        // is real — but has no China analogue: `aws-cn` uses `amazonaws.com.cn`
        // throughout, so no bedrock-mantle host can be formed there at all.
        //
        // This is a HOST-SHAPE guard, not an availability oracle. Within an allowed
        // partition Mantle ships in only a SUBSET of regions (us-west-1, ca-central-1
        // and us-gov-east-1 are `bedrock-runtime`-only today), and that subset grows as
        // AWS expands. Encoding the region list here would reject a newly-added Mantle
        // region until our next release — the exact staleness the routing escape
        // hatches exist to avoid — so a well-formed but not-yet-served region is left
        // for AWS to reject at call time with its own diagnosis.
        // https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints-region-availability.html
        if route.partition != "aws" && route.partition != "aws-us-gov" {
            return error(string `Mantle is not available on partition '${route.partition}': the ` +
                string `bedrock-mantle 'api.aws' host has no '${route.partition}' analogue. ` +
                string `Use a commercial ('aws') or GovCloud ('aws-us-gov') region.`);
        }
        MantleEntry entry = check route.mantleEntry.ensureType();
        string mantleBase = check resolveServiceUrl(serviceUrl, route, "mantle");
        return {
            baseUrl: mantleBase,
            host: hostOf(mantleBase),
            path: entry.path,
            signingService: SIGNING_BEDROCK_MANTLE
        };
    }

    // Converse / Invoke on `bedrock-runtime`, partition-aware domain.
    string base = check resolveServiceUrl(serviceUrl, route, "runtime");
    // Single-encode the model-id segment (ARNs/`-v1:0` ids carry `:` and `/`).
    string encodedId = encodePathSegment(route.effectiveModelId);
    string path = route.family == CONVERSE
        ? string `/model/${encodedId}/converse`
        : string `/model/${encodedId}/invoke`;
    return {baseUrl: base, host: hostOf(base), path, signingService: SIGNING_BEDROCK};
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

// Partition-aware DNS suffix. Route every host through here — n8n's
// hardcoded `.amazonaws.com` is a real China bug.
isolated function awsDomain(string partition) returns string
    => partition == "aws-cn" ? "amazonaws.com.cn" : "amazonaws.com";
