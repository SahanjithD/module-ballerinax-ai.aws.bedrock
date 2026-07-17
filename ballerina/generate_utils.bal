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

// generate() — tool-forcing on Converse/Invoke (structured output supported);
// Mantle has NO structured-output path (amendment): a non-string target type is a
// clean error, a string target returns text. The external `Generator` shim derives
// the JSON schema from the typedesc (reusing ballerina/ai's native generator,
// already on the runtime classpath) and passes it, plus the per-model
// `supportsStructuredOutput` flag, in here.

const RESULT_TOOL = "respond_with_result";

// Callback invoked by the external `Generator` shim (design §3, §8; amendment).
// Regular (non-dependent) function returning `anydata`; the Java boundary coerces
// the result to the caller's `td`. Reads the provider's resolved state as
// parameters; `schema` is the JSON schema the shim derived from `td`.
isolated function generateLlmResponse(boolean supportsStructuredOutput, ApiFamily family,
        readonly & ModelCodec codec, BedrockTransport transport, string wireModelId,
        map<string> & readonly extraHeaders, readonly & InferenceParams params, ai:Prompt prompt,
        typedesc<anydata> td, map<json>? schema) returns anydata|ai:Error
    => structuredGenerate(supportsStructuredOutput, family, codec, transport, wireModelId,
        extraHeaders, params, prompt, td, schema);

// Dispatches generate() (amendment). Converse/Invoke → tool-forcing. Mantle
// (`supportsStructuredOutput == false`) → text only; a typed target is an error,
// reversible per-model once a card shows Mantle structured-output support.
isolated function structuredGenerate(boolean supportsStructuredOutput, ApiFamily family,
        readonly & ModelCodec codec, BedrockTransport transport, string wireModelId,
        map<string> & readonly extraHeaders, readonly & InferenceParams params, ai:Prompt prompt,
        typedesc<anydata> td, map<json>? schema) returns anydata|ai:Error {
    if !supportsStructuredOutput {
        if td is typedesc<string> {
            // No structured output on Mantle, but a plain-text generation is fine.
            return plainTextResponse(codec, transport, wireModelId, extraHeaders, params, prompt);
        }
        return error ai:LlmInvalidGenerationError(
            string `Structured output is not supported on the bedrock-mantle route for model ` +
            string `'${wireModelId}'; the target type must be 'string'. Use a Converse/Invoke model ` +
            string `for typed generation.`);
    }
    return generateByToolForcing(family, codec, transport, wireModelId, extraHeaders, params, prompt, td, schema);
}

// Plain-text generation for the Mantle route when the target type is `string`
// (amendment). Runs one chat turn and returns the assistant text.
isolated function plainTextResponse(readonly & ModelCodec codec, BedrockTransport transport,
        string wireModelId, map<string> & readonly extraHeaders, readonly & InferenceParams params,
        ai:Prompt prompt) returns anydata|ai:Error {
    ai:ChatUserMessage userMsg = {role: ai:USER, content: prompt};
    RequestCodec encode = codec.encode;
    json|ai:Error encoded = encode((), [userMsg], [], (), params);
    if encoded is ai:Error {
        return encoded;
    }
    json body = injectModel(encoded, wireModelId); // Mantle carries the model in the body
    TransportResponse|ai:Error response = transport.execute(body, extraHeaders);
    if response is ai:Error {
        return response;
    }
    ResponseCodec decode = codec.decode;
    DecodedResponse|ai:Error decoded = decode(response.body);
    if decoded is ai:Error {
        return decoded;
    }
    return decoded.message.content ?: "";
}

// Tier 1 — force a single tool whose schema is the expected type; parse the
// tool-call arguments back into the record (design §8).
isolated function generateByToolForcing(ApiFamily family, readonly & ModelCodec codec,
        BedrockTransport transport, string wireModelId, map<string> & readonly extraHeaders,
        readonly & InferenceParams params, ai:Prompt prompt, typedesc<anydata> td,
        map<json>? schema) returns anydata|ai:Error {
    ai:ChatCompletionFunctions tool = {
        name: RESULT_TOOL,
        description: "Return the result strictly as structured arguments in the required schema.",
        parameters: schema ?: {"type": "object", "properties": {}}
    };
    ai:ChatUserMessage userMsg = {role: ai:USER, content: prompt};
    RequestCodec encode = codec.encode;
    json|ai:Error encoded = encode((), [userMsg], [tool], (), params);
    if encoded is ai:Error {
        return encoded;
    }
    json body = applyToolChoice(encoded, family, RESULT_TOOL);
    TransportResponse|ai:Error response = transport.execute(body, extraHeaders);
    if response is ai:Error {
        return response;
    }
    ResponseCodec decode = codec.decode;
    DecodedResponse|ai:Error decoded = decode(response.body);
    if decoded is ai:Error {
        return decoded;
    }
    ai:FunctionCall[]? toolCalls = decoded.message.toolCalls;
    if toolCalls is ai:FunctionCall[] && toolCalls.length() > 0 {
        return bindJson(toolCalls[0].arguments ?: {}, td);
    }
    // Fallback: some models emit the JSON in the text content instead.
    string? content = decoded.message.content;
    if content is string {
        json|error parsed = extractJson(content);
        if parsed !is error {
            return bindJson(parsed, td);
        }
    }
    return error ai:LlmInvalidGenerationError(
        string `Model did not return a '${RESULT_TOOL}' tool call for structured output`);
}

// Forces the single result tool on the encoded body, per route (design §8).
isolated function applyToolChoice(json body, ApiFamily family, string toolName) returns json {
    if body !is map<json> {
        return body;
    }
    map<json> forced = body.clone();
    if family == CONVERSE {
        json existing = forced["toolConfig"];
        map<json> toolConfig = existing is map<json> ? existing.clone() : {};
        toolConfig["toolChoice"] = {"tool": {"name": toolName}};
        forced["toolConfig"] = toolConfig;
    } else {
        // Anthropic Messages (Invoke / Mantle) tool_choice.
        forced["tool_choice"] = {"type": "tool", "name": toolName};
    }
    return forced;
}

// Binds a JSON value to the expected type (design §8).
isolated function bindJson(json data, typedesc<anydata> td) returns anydata|ai:Error {
    anydata|error bound = data.fromJsonWithType(td);
    if bound is error {
        return error ai:LlmInvalidGenerationError(
            "Failed to bind the model response to the expected type", bound);
    }
    return bound;
}

// Best-effort JSON extraction from model text (handles code fences and prose).
// Returns an `error` sentinel when no JSON is found (`()` cannot signal absence —
// it is itself a valid `json`).
isolated function extractJson(string content) returns json|error {
    string trimmed = content.trim();
    // Strip a leading ```json / ``` fence and a trailing ``` fence.
    if trimmed.startsWith("```") {
        int? firstNl = trimmed.indexOf("\n");
        if firstNl is int {
            trimmed = trimmed.substring(firstNl + 1);
        }
        if trimmed.endsWith("```") {
            trimmed = trimmed.substring(0, trimmed.length() - 3);
        }
        trimmed = trimmed.trim();
    }
    json|error direct = trimmed.fromJsonString();
    if direct is json {
        return direct;
    }
    // Fall back to the substring between the first and last brace/bracket.
    int? objStart = trimmed.indexOf("{");
    int? objEnd = trimmed.lastIndexOf("}");
    if objStart is int && objEnd is int && objEnd > objStart {
        json|error slice = trimmed.substring(objStart, objEnd + 1).fromJsonString();
        if slice is json {
            return slice;
        }
    }
    return error("no JSON value found in model output");
}
