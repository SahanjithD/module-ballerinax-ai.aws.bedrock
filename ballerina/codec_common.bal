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

// Shared codec helpers (design §7.1). Codecs stay pure and span-free so the
// golden-file tests are trivial (design §12).

// Splits the system message out of a message list (design §7.1). `system` is a
// top-level field on every route, NEVER a `role: system` message. Multiple system
// messages are concatenated. Returns [hoisted-system?, remaining-messages].
isolated function hoistSystem(ai:ChatMessage[] messages) returns [ai:ChatSystemMessage?, ai:ChatMessage[]] {
    string[] systemParts = [];
    ai:ChatMessage[] rest = [];
    foreach ai:ChatMessage m in messages {
        if m is ai:ChatSystemMessage {
            systemParts.push(contentToString(m.content));
        } else {
            rest.push(m);
        }
    }
    if systemParts.length() == 0 {
        return [(), rest];
    }
    ai:ChatSystemMessage system = {role: ai:SYSTEM, content: string:'join("\n\n", ...systemParts)};
    return [system, rest];
}

// Renders message content (`string` or an `ai:Prompt` raw template) to text.
isolated function contentToString(string|ai:Prompt content) returns string {
    if content is string {
        return content;
    }
    string[] & readonly strs = content.strings;
    anydata[] insertions = content.insertions;
    string result = "";
    int i = 0;
    while i < strs.length() {
        result += strs[i];
        if i < insertions.length() {
            result += insertions[i].toString();
        }
        i += 1;
    }
    return result;
}

// Maps an `ai:ChatCompletionFunctions` tool to its JSON-schema parameters (design
// §8 tool-forcing reuse). Falls back to an empty object schema.
isolated function toolParameters(ai:ChatCompletionFunctions tool) returns map<json> {
    map<json>? params = tool.parameters;
    return params ?: {"type": "object", "properties": {}};
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
    // Bedrock sometimes serializes token counts as decimals.
    if v is decimal {
        return <int>v;
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

// Augments a decoded response with values that arrive in RESPONSE HEADERS rather
// than the body (design §9.5): the Invoke guardrail-fired signal and the request
// id. No-op when the codec already populated them from the body (e.g. Converse
// `stopReason: guardrail_intervened`).
isolated function augmentFromHeaders(DecodedResponse decoded, map<string> headers) {
    if decoded.guardrailAction is () {
        string? action = headers[GUARDRAIL_ACTION_HEADER];
        if action is string {
            decoded.guardrailAction = action.toUpperAscii() == "INTERVENED" ? INTERVENED : NONE;
        }
    }
    if decoded.responseId is () {
        string? requestId = headers[REQUEST_ID_HEADER];
        if requestId is string {
            decoded.responseId = requestId;
        }
    }
}
