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
import ballerinax/aws.auth;

// SigV4 transport: per-route signing, retry and error mapping. Signing is done here,
// not with `auth:getSignedHeaders`, because that treats `/` as a path separator and
// so cannot sign a model-id ARN (`inference-profile%252F...`). Re-check on every
// `ballerinax/aws` upgrade.

// Resolves a client's credentials once, at construction, so a bad profile or role
// fails early. Every transport of that client shares the provider and its cache.
isolated function resolveCredentials(BedrockAuthConfig credentials)
        returns auth:CredentialProvider|BearerToken|ai:Error {
    if credentials is BearerToken {
        return credentials;
    }
    auth:CredentialProvider|error provider = new (credentials);
    if provider is error {
        return error ai:Error(string `Failed to resolve AWS credentials: ${provider.message()}`, provider);
    }
    return provider;
}

const APPLICATION_JSON = "application/json";
const AWS4_HMAC_SHA256 = "AWS4-HMAC-SHA256";
const AWS4_REQUEST = "aws4_request";

# SigV4 signing, an HTTP client and retry/error mapping for one resolved route.
# Host, path and signing scope are fixed at construction.
isolated client class BedrockTransport {
    // Exactly one is set. A Bedrock API key skips SigV4.
    private final auth:CredentialProvider? credProvider;
    private final readonly & BearerToken? bearer;
    private final string region;
    private final string signingService;
    private final string host;
    private final string wirePath; // model-id segment single-encoded (from buildEndpoint)
    private final http:Client httpClient;
    private final readonly & RetryConfig retryConfig;
    // For the `bedrock-mantle:CreateInference` hint on a 403.
    private final boolean isMantleRoute;
    // A knowledge-base plane: different 400/403/404 hints, and 402/409 handling.
    private final boolean isAgentRoute;

    isolated function init(auth:CredentialProvider|BearerToken credentials, string region, Endpoint ep,
            http:ClientConfiguration? httpConfig = (), RetryConfig? retryConfig = (),
            boolean isAgentRoute = false, decimal defaultTimeout = DEFAULT_TIMEOUT) returns error? {
        if credentials is BearerToken {
            self.bearer = credentials.cloneReadOnly();
            self.credProvider = ();
        } else {
            self.bearer = ();
            // Resolved once per client and safe to share.
            self.credProvider = credentials;
        }
        self.region = region;
        // From the route only: a `customEndpoint` changes the host, not the signing name.
        self.signingService = ep.signingService;
        self.isMantleRoute = ep.signingService == SIGNING_BEDROCK_MANTLE;
        self.isAgentRoute = isAgentRoute;
        self.host = ep.host;
        self.wirePath = ep.path;
        self.httpClient = check new (ep.baseUrl, withDefaultTimeout(httpConfig, defaultTimeout));
        RetryConfig rc = retryConfig ?: {};
        self.retryConfig = rc.cloneReadOnly();
    }

    // POSTs a signed request to the route's path, with retries. `extraHeaders` are
    // signed too.
    isolated function execute(json body, map<string> extraHeaders = {}) returns TransportResponse|ai:Error
        => self.executeRequest("POST", self.wirePath, body, extraHeaders);

    // Method and path per call, for the knowledge-base planes. A `()` body is signed
    // as the empty string.
    isolated function executeRequest(string method, string path, json? body, map<string> extraHeaders = {})
            returns TransportResponse|ai:Error {
        TransportResponse|ConflictError|ai:Error result =
            self.executeRequestRetrying(method, path, body, extraHeaders);
        if result is ConflictError {
            // Every caller but the knowledge-base create recovery wants a plain error.
            return error ai:Error(result.message());
        }
        return result;
    }

    // Like `executeRequest`, but returns a 409 as `ConflictError` so the knowledge-base
    // create can recover from it.
    isolated function executeRequestDetectingConflict(string method, string path, json? body,
            map<string> extraHeaders = {}) returns TransportResponse|ConflictError|ai:Error
        => self.executeRequestRetrying(method, path, body, extraHeaders);

    // The retry loop. A 409 is not retried.
    isolated function executeRequestRetrying(string method, string path, json? body, map<string> extraHeaders)
            returns TransportResponse|ConflictError|ai:Error {
        RetryConfig rc = self.retryConfig;
        int attempt = 0;
        decimal delay = rc.initialDelay;
        while true {
            TransportResponse|RetryableError|ConflictError|ai:Error result =
                self.executeRequestOnce(method, path, body, extraHeaders);
            if result is TransportResponse|ConflictError {
                return result; // success, or a non-retryable conflict
            }
            if result is ai:Error {
                return result; // non-retryable
            }
            if attempt >= rc.maxRetries {
                return error ai:LlmConnectionError(
                    string `${result.message()} (retries exhausted after ${rc.maxRetries} attempts)`, result.cause());
            }
            runtime:sleep(delay);
            delay = decimal:min(delay * rc.backoffFactor, rc.maxDelay);
            attempt += 1;
        }
    }

    // One signed round trip. The path goes out single-encoded; the signature uses it
    // double-encoded.
    isolated function executeRequestOnce(string method, string path, json? body, map<string> extraHeaders)
            returns TransportResponse|RetryableError|ConflictError|ai:Error {
        string payload = body is () ? "" : body.toJsonString();
        map<string>|error headers = self.signedHeadersFor(method, path, payload, extraHeaders);
        if headers is error {
            return error ai:Error("Failed to sign the Bedrock request", headers);
        }
        http:Request req = new;
        if body !is () {
            req.setTextPayload(payload, contentType = APPLICATION_JSON);
        }
        foreach [string, string] [k, v] in headers.entries() {
            req.setHeader(k, v);
        }
        http:Response|error resp = self.httpClient->execute(method, path, req);
        if resp is error {
            // A connection failure (DNS, TLS, socket); retryable. The host is named,
            // since it is what tells a wrong region or endpoint from an outage.
            return error RetryableError(
                string `Connection error while calling Bedrock at '${self.host}'`, resp);
        }
        return self.mapResponse(resp);
    }

    isolated function mapResponse(http:Response resp) returns TransportResponse|RetryableError|ConflictError|ai:Error {
        int status = resp.statusCode;
        // The value AWS Support asks for. OpenAI-compatible paths may use `x-request-id`.
        string? requestId = optionalHeader(resp, "x-amzn-RequestId") ?: optionalHeader(resp, "x-request-id");
        if status >= 200 && status < 300 {
            json|error jsonBody = resp.getJsonPayload();
            if jsonBody is error {
                return error ai:LlmInvalidResponseError("Bedrock response was not valid JSON", jsonBody);
            }
            // The guardrail signal is a body field, not a header; each InvokeModel
            // decoder reads it.
            // https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModel.html
            map<string> responseHeaders = {};
            if requestId is string {
                responseHeaders[REQUEST_ID_HEADER] = requestId;
            }
            return {body: jsonBody, headers: responseHeaders};
        }
        string detail = self.errorDetail(resp);
        if requestId is string {
            detail += string ` (request id: ${requestId})`;
        }
        boolean mantle = self.isMantleRoute;
        boolean agent = self.isAgentRoute;
        match status {
            // 502 and 504 come from the load balancers; they are transient too.
            429|408|500|502|503|504 => {
                return error RetryableError(string `Bedrock transient error (HTTP ${status}): ${detail}`);
            }
            400 => {
                // Only when AWS gave no reason, and only on a runtime model route.
                string hint = !agent && !mantle && detail.startsWith("status ")
                    ? " The model may not support this API; try 'apiType = INVOKE' (or CONVERSE)."
                    : "";
                return error ai:Error(string `Bedrock ValidationException (HTTP 400): ${detail}.${hint}`);
            }
            // The knowledge-base control plane answers 402 for a quota violation.
            // https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_IngestKnowledgeBaseDocuments.html
            402 => {
                return error ai:Error(string `Bedrock ServiceQuotaExceededException (HTTP 402): ${detail}`);
            }
            403 => {
                string hint = mantle
                    ? " Mantle needs the separate 'bedrock-mantle:CreateInference' IAM action — " +
                        "'bedrock:InvokeModel' permissions are NOT sufficient."
                    : agent
                    ? " Knowledge base ingestion needs BOTH 'bedrock:StartIngestionJob' and " +
                        "'bedrock:IngestKnowledgeBaseDocuments' — either alone is insufficient."
                    : "";
                return error ai:Error(string `Bedrock AccessDeniedException (HTTP 403): ${detail}.${hint}`);
            }
            404 => {
                string hint = agent
                    ? "Check the knowledge base and data source id."
                    : "Check the model id and region.";
                return error ai:Error(string `Bedrock ResourceNotFoundException (HTTP 404): ${detail}. ${hint}`);
            }
            409 => {
                // Typed so the knowledge-base create can recover from it.
                return error ConflictError(string `Bedrock ConflictException (HTTP 409): ${detail}`, detail = detail);
            }
            424 => {
                return error ai:LlmError(string `Bedrock ModelErrorException (HTTP 424): ${detail}`);
            }
            _ => {
                return error ai:LlmError(string `Bedrock error (HTTP ${status}): ${detail}`);
            }
        }
    }

    // AWS's message from the body. Bedrock uses `message`; OpenAI-compatible paths use
    // `{"error": {"message", "code"}}`, or a bare `error` string.
    isolated function errorDetail(http:Response resp) returns string {
        json|error j = resp.getJsonPayload();
        if j !is map<json> {
            return string `status ${resp.statusCode}`;
        }
        json? msg = j["message"] ?: j["Message"];
        if msg is string && msg.trim() != "" {
            return msg;
        }
        json? err = j["error"];
        if err is map<json> {
            json? nested = err["message"];
            if nested is string && nested.trim() != "" {
                // The provider's code says whether the body or the model is the problem.
                json? code = err["code"] ?: err["type"];
                return code is string ? string `${nested} (${code})` : nested;
            }
        }
        if err is string && err.trim() != "" {
            return err;
        }
        return string `status ${resp.statusCode}`;
    }

    // SigV4 (or bearer) headers for a `POST` to the route's path.
    isolated function signedHeaders(string payload, map<string> extraHeaders,
            [string, string]? fixedClock = ()) returns map<string>|error
        => self.signedHeadersFor("POST", self.wirePath, payload, extraHeaders, fixedClock);

    // SigV4 (or bearer) headers for any method and path. `fixedClock` is for tests.
    isolated function signedHeadersFor(string method, string path, string payload, map<string> extraHeaders,
            [string, string]? fixedClock = ()) returns map<string>|error {
        map<string> headers = {};
        foreach [string, string] [k, v] in extraHeaders.entries() {
            headers[k] = v;
        }
        BearerToken? bearerCreds = self.bearer;

        // Bedrock API key: no SigV4.
        if bearerCreds is BearerToken {
            // The Mantle Messages path rejects a request with both `Authorization` and
            // `x-api-key` (verified live), so no Bearer when `x-api-key` is present.
            if !hasApiKeyHeader(headers) {
                headers["Authorization"] = string `Bearer ${bearerCreds.apiKey}`;
            }
            headers["Content-Type"] = APPLICATION_JSON;
            return headers;
        }

        // ---- SigV4 ----
        // Credentials are read on every request: temporary ones expire and the
        // provider refreshes them.
        auth:CredentialProvider provider = check self.credProvider.ensureType();
        auth:Credentials creds = check provider.getCredentials();
        [string, string] [amzDate, dateStamp] = fixedClock ?: check amzTimestamps();
        // The canonical URI is the wire path encoded twice (SigV4, non-S3).
        string canonicalUri = getCanonicalUri(path);
        string payloadHash = array:toBase16(crypto:hashSha256(payload.toBytes())).toLowerAscii();

        string accessKey = creds.accessKeyId;
        string secretKey = creds.secretAccessKey;
        // Only temporary credentials have one.
        string? sessionToken = creds?.sessionToken;

        // Every header sent is signed.
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

        string canonicalRequest = method + "\n" + canonicalUri + "\n" + "" + "\n" +
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

// Whether `headers` has an `x-api-key` in any casing.
isolated function hasApiKeyHeader(map<string> headers) returns boolean {
    foreach string name in headers.keys() {
        if name.toLowerAscii() == "x-api-key" {
            return true;
        }
    }
    return false;
}

# A successful round trip: the JSON body and the response headers the caller needs.
type TransportResponse record {|
    # The response body
    json body;
    # Selected response headers, keyed as in `REQUEST_ID_HEADER`
    map<string> headers;
|};

const REQUEST_ID_HEADER = "requestId";

# A retryable failure: HTTP 408, 429, 500, 502, 503 or 504, or a connection failure.
type RetryableError distinct error;

// A plain `distinct error`, like `RetryableError`; `executeRequest` turns it back into
// an `ai:Error` with the same message for every other caller.

# A Bedrock `ConflictException` (HTTP 409), which the caller may recover from.
type ConflictError distinct error<record {| string detail; |}>;

isolated function optionalHeader(http:Response resp, string name) returns string? {
    string|error value = resp.getHeader(name);
    return value is string ? value : ();
}

isolated function amzTimestamps() returns [string, string]|error {
    return formatAmzTimestamps(time:utcToCivil(time:utcNow()));
}

// Split out so the format can be tested at a fixed clock.
isolated function formatAmzTimestamps(time:Civil c) returns [string, string]|error {
    string y = pad(c.year, 4);
    string mo = pad(c.month, 2);
    string d = pad(c.day, 2);
    string h = pad(c.hour, 2);
    string mi = pad(c.minute, 2);
    // Floor, not `<int>`: `<int>` rounds, so 59.7 s would become an invalid `60`.
    // https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-signing-elements.html
    decimal secDec = c.second ?: 0;
    string s = pad(<int>secDec.floor(), 2);
    string amzDate = string `${y}${mo}${d}T${h}${mi}${s}Z`;
    string dateStamp = string `${y}${mo}${d}`;
    return [amzDate, dateStamp];
}

isolated function pad(int n, int width) returns string {
    string s = n.toString();
    while s.length() < width {
        s = "0" + s;
    }
    return s;
}

// Encodes the single-encoded wire path again for the SigV4 canonical URI, keeping `/`
// separators. Must use the same encoder as `buildEndpoint`.
isolated function getCanonicalUri(string wirePath) returns string {
    return re `%2F`.replaceAll(encodePathSegment(wirePath), "/");
}

isolated function getSignatureKey(string secretKey, string dateStamp, string region, string serviceName)
        returns byte[]|error {
    byte[] kDate = check crypto:hmacSha256(dateStamp.toBytes(), ("AWS4" + secretKey).toBytes());
    byte[] kRegion = check crypto:hmacSha256(region.toBytes(), kDate);
    byte[] kService = check crypto:hmacSha256(serviceName.toBytes(), kRegion);
    return crypto:hmacSha256(AWS4_REQUEST.toBytes(), kService);
}

// `httpConfig` with `timeout` set to `defaultTimeout`, unless the caller changed it.
isolated function withDefaultTimeout(http:ClientConfiguration? httpConfig, decimal defaultTimeout)
        returns http:ClientConfiguration {
    // A copy, so the caller's record is never written to.
    http:ClientConfiguration base = httpConfig ?: {};
    http:ClientConfiguration config = {...base};
    if config.timeout == HTTP_CLIENT_DEFAULT_TIMEOUT {
        config.timeout = defaultTimeout;
    }
    return config;
}
