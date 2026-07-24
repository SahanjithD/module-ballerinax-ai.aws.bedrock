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

import ballerina/ai;
import ballerina/crypto;
import ballerina/http;
import ballerina/lang.array;
import ballerina/lang.runtime;
import ballerina/time;
import ballerina/url;

// SigV4 transport — per-route signing (§9.4), retry (§9.5), error mapping (§9.5).
// SigV4 scaffolding (canonical request, signing-key derivation, base16 hex)
// mirrors the ballerinax/aws.dynamodb connector's proven `utils.bal`.

const APPLICATION_JSON = "application/json";
const AWS4_HMAC_SHA256 = "AWS4-HMAC-SHA256";
const AWS4_REQUEST = "aws4_request";

// Wraps SigV4 signing + an HTTP client + retry/error mapping for one resolved
// route (design §9.4-9.5). Resolve-once: host, path, and signing scope are fixed.
isolated client class BedrockTransport {
    private final readonly & BedrockCredentials credentials;
    private final string region;
    private final string signingService;
    private final string host;
    private final string wirePath; // model-id segment single-encoded (from buildEndpoint)
    private final http:Client httpClient;
    private final readonly & RetryConfig retryConfig;
    // Whether the RESOLVED ROUTE is Mantle. Derived from the route's own signing
    // name, never from the `signingServiceName` override — otherwise a user of that
    // escape hatch silently loses the `bedrock-mantle:CreateInference` hint on a
    // 403, which is the difference between a solvable and an unsolvable error.
    private final boolean isMantleRoute;

    isolated function init(BedrockCredentials credentials, string region, Endpoint ep,
            string? signingServiceName = (), http:ClientConfiguration? httpConfig = (),
            RetryConfig? retryConfig = ()) returns error? {
        self.credentials = credentials.cloneReadOnly();
        self.region = region;
        // Signing name defaults per route, overridable without a release (§9.4).
        self.signingService = signingServiceName ?: ep.signingService;
        self.isMantleRoute = ep.signingService == SIGNING_BEDROCK_MANTLE;
        self.host = ep.host;
        self.wirePath = ep.path;
        self.httpClient = check new (string `https://${ep.host}`, httpConfig ?: {});
        RetryConfig rc = retryConfig ?: {};
        self.retryConfig = rc.cloneReadOnly();
    }

    // POSTs a signed request and returns the JSON response plus the response
    // headers we care about (design §9.5), retrying transient errors with
    // exponential backoff. `extraHeaders` carry route-specific headers (guardrail,
    // anthropic-version, workspace, api-key) — all of them are signed.
    isolated function execute(json body, map<string> extraHeaders = {}) returns TransportResponse|ai:Error {
        RetryConfig rc = self.retryConfig;
        int attempt = 0;
        decimal delay = rc.initialDelay;
        while true {
            TransportResponse|RetryableError|ai:Error result = self.executeOnce(body, extraHeaders);
            if result is TransportResponse {
                return result; // success
            }
            if result is ai:Error {
                return result; // non-retryable
            }
            if result is RetryableError {
                // Back off unless attempts are exhausted.
                if attempt >= rc.maxRetries {
                    return error ai:LlmConnectionError(
                        string `${result.message()} (retries exhausted after ${rc.maxRetries} attempts)`, result.cause());
                }
                runtime:sleep(delay);
                delay = decimal:min(delay * rc.backoffFactor, rc.maxDelay);
                attempt += 1;
            }
        }
    }

    // A single signed round-trip (design §9.5). The wire path is sent single-
    // encoded; the canonical URI is double-encoded for the signature (§9.4).
    isolated function executeOnce(json body, map<string> extraHeaders)
            returns TransportResponse|RetryableError|ai:Error {
        string payload = body.toJsonString();
        map<string>|error headers = self.signedHeaders(payload, extraHeaders);
        if headers is error {
            return error ai:Error("Failed to sign the Bedrock request", headers);
        }
        http:Request req = new;
        req.setTextPayload(payload, contentType = APPLICATION_JSON);
        foreach [string, string] [k, v] in headers.entries() {
            req.setHeader(k, v);
        }
        // Wire path is already single-encoded by buildEndpoint; send it verbatim.
        http:Response|error resp = self.httpClient->post(self.wirePath, req);
        if resp is error {
            // Transport-level failure (DNS, TLS, socket) — treat as retryable.
            return error RetryableError("Connection error while calling Bedrock", resp);
        }
        return self.mapResponse(resp);
    }

    // Maps an HTTP response to a `TransportResponse` or a typed error (§9.5 table).
    isolated function mapResponse(http:Response resp) returns TransportResponse|RetryableError|ai:Error {
        int status = resp.statusCode;
        if status >= 200 && status < 300 {
            json|error jsonBody = resp.getJsonPayload();
            if jsonBody is error {
                return error ai:LlmInvalidResponseError("Bedrock response was not valid JSON", jsonBody);
            }
            // Capture the response headers the decoder/provider needs (§9.5).
            //
            // The guardrail-fired signal is NOT here: it is a response BODY field
            // (`amazon-bedrock-guardrailAction`), read by each Invoke codec via
            // `invokeGuardrailAction`. InvokeModel documents only three response
            // headers, and no guardrail among them — the `X-Amzn-Bedrock-Guardrail*`
            // headers are request-only.
            // https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModel.html
            map<string> responseHeaders = {};
            string? requestId = optionalHeader(resp, "x-amzn-RequestId");
            if requestId is string {
                responseHeaders[REQUEST_ID_HEADER] = requestId;
            }
            return {body: jsonBody, headers: responseHeaders};
        }
        string detail = self.errorDetail(resp);
        boolean mantle = self.isMantleRoute;
        match status {
            429|408|500|503 => {
                return error RetryableError(string `Bedrock transient error (HTTP ${status}): ${detail}`);
            }
            400 => {
                return error ai:Error(string `Bedrock ValidationException (HTTP 400): ${detail}. ` +
                    string `The model may not support this route; try 'apiFamily = INVOKE' (or CONVERSE).`);
            }
            403 => {
                string hint = mantle
                    ? " Mantle needs the separate 'bedrock-mantle:CreateInference' IAM action — " +
                        "'bedrock:InvokeModel' permissions are NOT sufficient."
                    : "";
                return error ai:Error(string `Bedrock AccessDeniedException (HTTP 403): ${detail}.${hint}`);
            }
            404 => {
                return error ai:Error(string `Bedrock ResourceNotFoundException (HTTP 404): ${detail}. ` +
                    string `Check the model id and region.`);
            }
            424 => {
                return error ai:LlmError(string `Bedrock ModelErrorException (HTTP 424): ${detail}`);
            }
            _ => {
                return error ai:LlmError(string `Bedrock error (HTTP ${status}): ${detail}`);
            }
        }
    }

    // Best-effort extraction of Bedrock's error message from the response body.
    isolated function errorDetail(http:Response resp) returns string {
        json|error j = resp.getJsonPayload();
        if j is map<json> {
            json? msg = j["message"] ?: j["Message"];
            if msg is string {
                return msg;
            }
        }
        return string `status ${resp.statusCode}`;
    }

    // Builds the SigV4 (or bearer) headers for one request (design §9.4-9.5).
    // `fixedClock` exists ONLY for tests: signing is otherwise unobservable without
    // live AWS, and a wall clock makes the output unassertable. Production callers
    // omit it and get `amzTimestamps()`.
    isolated function signedHeaders(string payload, map<string> extraHeaders,
            [string, string]? fixedClock = ()) returns map<string>|error {
        map<string> headers = {};
        foreach [string, string] [k, v] in extraHeaders.entries() {
            headers[k] = v;
        }
        BedrockCredentials creds = self.credentials;

        // Bedrock API key (bearer) — first-class on both endpoints (§9.5): skip SigV4.
        if creds is BearerToken {
            headers["Authorization"] = string `Bearer ${creds.apiKey}`;
            headers["Content-Type"] = APPLICATION_JSON;
            return headers;
        }

        // ---- SigV4 (static / STS) ----
        [string, string] [amzDate, dateStamp] = fixedClock ?: check amzTimestamps();
        // Canonical URI is the DOUBLE-encoded wire path (SigV4 non-S3 rule §9.4):
        // the server re-encodes the received (single-encoded) path once to match.
        // A signing input must never fail open: falling back to the single-encoded
        // path would sign something AWS cannot reconstruct, turning an encode bug
        // into an undiagnosable 403 on every request. Fail loudly instead.
        string? encodedUri = getCanonicalUri(self.wirePath);
        if encodedUri is () {
            return error("Failed to percent-encode the canonical URI for signing: " + self.wirePath);
        }
        string canonicalUri = encodedUri;
        string payloadHash = array:toBase16(crypto:hashSha256(payload.toBytes())).toLowerAscii();

        string accessKey = creds.accessKeyId;
        string secretKey = creds.secretAccessKey;
        string? sessionToken = creds is StsCredentials ? creds.sessionToken : ();

        // Sign EVERY header we send (§9.5), sorted by lowercased name.
        map<string> toSign = {"content-type": APPLICATION_JSON, "host": self.host, "x-amz-date": amzDate};
        if sessionToken is string {
            toSign["x-amz-security-token"] = sessionToken;
        }
        foreach [string, string] [name, value] in extraHeaders.entries() {
            toSign[name.toLowerAscii()] = value;
        }
        string[] sortedNames = toSign.keys().sort();
        string canonicalHeaders = "";
        foreach string name in sortedNames {
            canonicalHeaders += name + ":" + (toSign[name] ?: "").trim() + "\n";
        }
        string signedHeaderList = string:'join(";", ...sortedNames);

        string canonicalRequest = "POST" + "\n" + canonicalUri + "\n" + "" + "\n" +
            canonicalHeaders + "\n" + signedHeaderList + "\n" + payloadHash;
        string credentialScope = string `${dateStamp}/${self.region}/${self.signingService}/${AWS4_REQUEST}`;
        string stringToSign = AWS4_HMAC_SHA256 + "\n" + amzDate + "\n" + credentialScope + "\n" +
            array:toBase16(crypto:hashSha256(canonicalRequest.toBytes())).toLowerAscii();

        byte[] signingKey = check getSignatureKey(secretKey, dateStamp, self.region, self.signingService);
        string signature = array:toBase16(check crypto:hmacSha256(stringToSign.toBytes(), signingKey)).toLowerAscii();

        headers["Content-Type"] = APPLICATION_JSON;
        headers["X-Amz-Date"] = amzDate;
        if sessionToken is string {
            headers["X-Amz-Security-Token"] = sessionToken;
        }
        headers["Authorization"] = AWS4_HMAC_SHA256 + " " +
            string `Credential=${accessKey}/${credentialScope}, ` +
            string `SignedHeaders=${signedHeaderList}, Signature=${signature}`;
        return headers;
    }
}

// A successful transport round-trip: the JSON body plus the selected response
// headers the decoder/provider needs (design §9.5).
type TransportResponse record {|
    json body;
    map<string> headers;
|};

// Response-header keys captured into `TransportResponse.headers` (design §9.5).
const REQUEST_ID_HEADER = "requestId";

// A retryable transport outcome (429/408/500/503 or a connection failure — §9.5).
// A `distinct error` so it narrows cleanly against `json` and `ai:Error`.
type RetryableError distinct error;

// Returns a response header value, or `()` if absent.
isolated function optionalHeader(http:Response resp, string name) returns string? {
    string|error value = resp.getHeader(name);
    return value is string ? value : ();
}

// `[amzDate (ISO8601 basic), dateStamp (YYYYMMDD)]` for NOW, in UTC.
isolated function amzTimestamps() returns [string, string]|error {
    return formatAmzTimestamps(time:utcToCivil(time:utcNow()));
}

// The pure formatter behind `amzTimestamps` — split out so the format can be
// tested at a fixed clock, including the second-59 boundary that a wall-clock test
// would only hit once a minute (and only half the time).
isolated function formatAmzTimestamps(time:Civil c) returns [string, string]|error {
    string y = pad(c.year, 4);
    string mo = pad(c.month, 2);
    string d = pad(c.day, 2);
    string h = pad(c.hour, 2);
    string mi = pad(c.minute, 2);
    // `time:Civil.second` is a decimal carrying sub-second precision. `<int>` on a
    // decimal ROUNDS (half-to-even) in Ballerina — it does not truncate — so
    // `<int>59.7d` is 60, and second 59 with a fraction >= 0.5 would emit
    // "...T235960Z". That is not a valid ISO 8601 basic timestamp; AWS rejects the
    // X-Amz-Date header, and the resulting 403 is NOT retryable. Roughly 1 request
    // in 120 (P(second==59) * P(frac>=0.5)). `.floor()` truncates, which is what
    // SigV4 wants: whole seconds, no milliseconds.
    // https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-signing-elements.html
    decimal secDec = c.second ?: 0;
    string s = pad(<int>secDec.floor(), 2);
    string amzDate = string `${y}${mo}${d}T${h}${mi}${s}Z`;
    string dateStamp = string `${y}${mo}${d}`;
    return [amzDate, dateStamp];
}

// Zero-pads `n` to `width` digits.
isolated function pad(int n, int width) returns string {
    string s = n.toString();
    while s.length() < width {
        s = "0" + s;
    }
    return s;
}

// Double-encodes the (already single-encoded) wire path for the SigV4 canonical
// URI (non-S3 rule §9.4): URL-encode again, then restore structural `/` separators
// (their `%2F` maps back to `/`, while a model-id's internal `%2F`→`%252F` stays
// double-encoded). Returns `()` on encode failure (caller falls back to the input).
isolated function getCanonicalUri(string wirePath) returns string? {
    string|error encoded = url:encode(wirePath, "UTF-8");
    if encoded is error {
        return ();
    }
    return re `%2F`.replaceAll(encoded, "/");
}

// SigV4 signing-key derivation (design §9.4). Identical to aws.dynamodb.
isolated function getSignatureKey(string secretKey, string dateStamp, string region, string serviceName)
        returns byte[]|error {
    byte[] kDate = check crypto:hmacSha256(dateStamp.toBytes(), ("AWS4" + secretKey).toBytes());
    byte[] kRegion = check crypto:hmacSha256(region.toBytes(), kDate);
    byte[] kService = check crypto:hmacSha256(serviceName.toBytes(), kRegion);
    return crypto:hmacSha256(AWS4_REQUEST.toBytes(), kService);
}
