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

// Shared converter helpers. Converters stay pure and span-free so the
// golden-file tests are trivial.

// Falls back to an empty object schema.
isolated function toolParameters(ai:ChatCompletionFunctions tool) returns map<json> {
    map<json>? params = tool.parameters;
    return params ?: {"type": "object", "properties": {}};
}

// Sets `temperature` only when the caller set it: Claude 4.7+ and some reasoning
// models reject any value.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html
isolated function setTemperature(map<json> body, InferenceParams params, string key = "temperature") {
    decimal? temperature = params?.temperature;
    if temperature is decimal {
        body[key] = temperature;
    }
}

isolated function setMaxTokens(map<json> body, InferenceParams params, string key) {
    int? maxTokens = params?.maxTokens;
    if maxTokens is int {
        body[key] = maxTokens;
    }
}

// ---- typed JSON field accessors (decode helpers) ----

isolated function strField(map<json> m, string k) returns string? {
    json v = m[k];
    return v is string ? v : ();
}

isolated function intField(map<json> m, string k) returns int? {
    json v = m[k];
    if v is int {
        return v;
    }
    // A fractional token count is treated as absent rather than rounded.
    if v is decimal {
        return v == v.round(0) ? <int>v : ();
    }
    return ();
}

isolated function mapField(map<json> m, string k) returns map<json>? {
    json v = m[k];
    return v is map<json> ? v : ();
}

isolated function arrField(map<json> m, string k) returns json[]? {
    json v = m[k];
    return v is json[] ? v : ();
}

// The InvokeModel guardrail signal: a body field (`amazon-bedrock-guardrailAction`),
// not a response header.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModel.html
isolated function invokeGuardrailAction(map<json> body) returns GuardrailAction? {
    string? action = strField(body, "amazon-bedrock-guardrailAction");
    if action is () {
        return ();
    }
    return action.toUpperAscii() == "INTERVENED" ? INTERVENED : NONE;
}

// The request id arrives in a response header, not the body.
isolated function augmentFromHeaders(DecodedResponse decoded, map<string> headers) {
    if decoded.responseId is () {
        string? requestId = headers[REQUEST_ID_HEADER];
        if requestId is string {
            decoded.responseId = requestId;
        }
    }
}
