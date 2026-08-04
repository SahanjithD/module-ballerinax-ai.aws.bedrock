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

// Sets `temperature` on a request body ONLY when the caller supplied one.
//
// The field cannot be defaulted. Anthropic deprecated sampling parameters on
// Claude 4.7 and later (Opus 4.7/4.8, Opus 5, Sonnet 5, Fable 5, Mythos 5) and
// OpenAI's GPT-5.x reasoning models never accepted them: on those models ANY
// value — including a module default the caller never asked for — is a hard 400
// (`temperature is deprecated for this model` / `Unsupported parameter`). Omitting
// the key is the only universally safe behaviour, and it lets each model apply its
// own default rather than one this module invents.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html
isolated function setTemperature(map<json> body, InferenceParams params, string key = "temperature") {
    decimal? temperature = params?.temperature;
    if temperature is decimal {
        body[key] = temperature;
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
    // Bedrock sometimes serializes token counts as decimals. `<int>` ROUNDS, so an
    // integral decimal (`5.0`) converts faithfully but a fractional one (`1.5`)
    // would silently become `2` — inventing a token count rather than reporting
    // that the field was unusable. A token count is never fractional, so treat that
    // as absent.
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

// Reads the InvokeModel guardrail-fired signal out of a response BODY (§9.5).
//
// It is a body field, NOT a response header. The InvokeModel Response Syntax has
// exactly three headers (contentType, performanceConfigLatency, serviceTier); the
// `X-Amzn-Bedrock-Guardrail*` headers are REQUEST-only. This module previously read
// a nonexistent `X-Amzn-Bedrock-GuardrailAction` response header, which meant every
// Invoke codec except Anthropic's silently reported "no guardrail fired" when one
// had — a safety signal dropped on 4 of 7 vendors.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModel.html
// (Response Syntax + Example 4: `"amazon-bedrock-guardrailAction": "INTERVENED | NONE"`)
isolated function invokeGuardrailAction(map<json> body) returns GuardrailAction? {
    string? action = strField(body, "amazon-bedrock-guardrailAction");
    if action is () {
        return ();
    }
    return action.toUpperAscii() == "INTERVENED" ? INTERVENED : NONE;
}

// Augments a decoded response with the request id, which arrives in a RESPONSE
// HEADER rather than the body (§9.5). No-op when the codec already set it.
isolated function augmentFromHeaders(DecodedResponse decoded, map<string> headers) {
    if decoded.responseId is () {
        string? requestId = headers[REQUEST_ID_HEADER];
        if requestId is string {
            decoded.responseId = requestId;
        }
    }
}
