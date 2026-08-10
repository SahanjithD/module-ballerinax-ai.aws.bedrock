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
// Mantle has NO structured-output path: a non-string target type is a
// clean error, a string target returns text. The external `Generator` shim passes
// the typedesc and the per-model `supportsStructuredOutput` flag in here; the JSON
// schema is derived on this side by `to_json_schema.bal`, as in the reference
// provider modules.

const RESULT_TOOL = "respond_with_result";

// Callback invoked by the external `Generator` shim.
// Regular (non-dependent) function returning `anydata`; the Java boundary coerces
// the result to the caller's `td`. Reads the provider's resolved state as
// parameters.
isolated function generateLlmResponse(boolean supportsStructuredOutput, ApiFamily family,
        readonly & ModelConverter converter, BedrockTransport transport, string wireModelId,
        map<string> & readonly extraHeaders, readonly & InferenceParams params, ai:Prompt prompt,
        typedesc<anydata> td) returns anydata|ai:Error
    => structuredGenerate(supportsStructuredOutput, family, converter, transport, wireModelId,
        extraHeaders, params, prompt, td);

// Dispatches generate(). Converse/Invoke → tool-forcing. Mantle
// (`supportsStructuredOutput == false`) → text only; a typed target is an error,
// reversible per-model once a card shows Mantle structured-output support.
isolated function structuredGenerate(boolean supportsStructuredOutput, ApiFamily family,
        readonly & ModelConverter converter, BedrockTransport transport, string wireModelId,
        map<string> & readonly extraHeaders, readonly & InferenceParams params, ai:Prompt prompt,
        typedesc<anydata> td) returns anydata|ai:Error {
    // A `string` target is plain text on EVERY route — there is nothing to structure.
    // Checked FIRST, before any route capability: forcing a tool to obtain a string
    // built a tool schema of `{"type": "string"}`, and Converse requires
    // `toolSpec.inputSchema.json.type` to be `object`, so a string-target generate()
    // on Converse died with a ValidationException. Verified live 2026-08-10 on Nova.
    if td is typedesc<string> {
        return plainTextResponse(family, converter, transport, wireModelId, extraHeaders, params, prompt);
    }
    if !supportsStructuredOutput {
        return error ai:LlmInvalidGenerationError(
            string `Structured output is not supported on the bedrock-mantle route for model ` +
            string `'${wireModelId}'; the target type must be 'string'. Use a Converse/Invoke model ` +
            string `for typed generation.`);
    }
    if converter.toolChoice == NO_TOOL_CHOICE {
        // A dialect with no tool-calling at all (Mistral text completion). Same
        // shape as the Mantle guard, and reversible the same way. The `string` case
        // is already handled above, so only a typed target reaches here.
        return error ai:LlmInvalidGenerationError(
            string `Structured output is not supported for model '${wireModelId}': its InvokeModel ` +
            string `dialect (Mistral text completion) has no tool-calling, so the target type must be ` +
            string `'string'. Use the Converse route (the module default) for typed generation.`);
    }
    return generateByToolForcing(converter, transport, wireModelId, extraHeaders, params, prompt, td);
}

// Derives the expected type's JSON schema (`to_json_schema.bal`). A target type
// outside `json` cannot be described to a model at all, so it is an error here
// rather than an empty schema the model would silently ignore.
isolated function schemaFor(typedesc<anydata> td) returns map<json>|ai:Error {
    if td !is typedesc<json> {
        return error ai:LlmInvalidGenerationError(
            string `Cannot derive a JSON schema for the expected type '${td.toString()}': ` +
            string `structured output requires a type that is a subtype of 'json'.`);
    }
    return generateJsonSchemaForTypedescAsJson(td);
}

// Plain-text generation for the Mantle route when the target type is `string`.
// Runs one chat turn and returns the assistant text.
isolated function plainTextResponse(ApiFamily family, readonly & ModelConverter converter, BedrockTransport transport,
        string wireModelId, map<string> & readonly extraHeaders, readonly & InferenceParams params,
        ai:Prompt prompt) returns anydata|ai:Error {
    // Resolve the prompt the same way chat() does — a generate() prompt can carry an
    // image too, and it must reach the dialect (or be refused) identically.
    ResolvedUserMessage userMsg = {parts: check contentToParts(prompt)};
    RequestEncoder encode = converter.encode;
    json|ai:Error encoded = encode((), [userMsg], [], (), params);
    if encoded is ai:Error {
        return encoded;
    }
    // Only Mantle carries the model id in the body; Converse and Invoke carry it in
    // the URL path. This function also serves the NO_TOOL_CHOICE Mistral InvokeModel
    // path, which would otherwise get a stray `model` field. Same gate as
    // `runChat` in provider_common.bal.
    json body = family == MANTLE ? injectModel(encoded, wireModelId) : encoded;
    TransportResponse|ai:Error response = transport.execute(body, extraHeaders);
    if response is ai:Error {
        return response;
    }
    ResponseDecoder decode = converter.decode;
    DecodedResponse|ai:Error decoded = decode(response.body);
    if decoded is ai:Error {
        return decoded;
    }
    return decoded.message.content ?: "";
}

// Tier 1 — force a single tool whose schema is the expected type; parse the
// tool-call arguments back into the record.
isolated function generateByToolForcing(readonly & ModelConverter converter,
        BedrockTransport transport, string wireModelId, map<string> & readonly extraHeaders,
        readonly & InferenceParams params, ai:Prompt prompt, typedesc<anydata> td)
        returns anydata|ai:Error {
    ai:ChatCompletionFunctions tool = {
        name: RESULT_TOOL,
        description: "Return the result strictly as structured arguments in the required schema.",
        parameters: check schemaFor(td)
    };
    ResolvedUserMessage userMsg = {parts: check contentToParts(prompt)};
    RequestEncoder encode = converter.encode;
    json|ai:Error encoded = encode((), [userMsg], [tool], (), params);
    if encoded is ai:Error {
        return encoded;
    }
    json body = applyToolChoice(encoded, converter.toolChoice, RESULT_TOOL);
    TransportResponse|ai:Error response = transport.execute(body, extraHeaders);
    if response is ai:Error {
        return response;
    }
    ResponseDecoder decode = converter.decode;
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

// Forces the single result tool on the encoded body. Keyed on the
// CONVERTER's dialect, not the route family: Nova on InvokeModel is Converse-shaped,
// and Mistral chat forces with a bare string. Deriving this from `ApiFamily` sends
// Anthropic's `tool_choice` to every non-Converse dialect, which they ignore —
// the model then answers in prose and `generate()` fails with "no tool call".
isolated function applyToolChoice(json body, ToolChoiceStyle style, string toolName) returns json {
    if body !is map<json> {
        return body;
    }
    map<json> forced = body.clone();
    match style {
        CONVERSE_TOOL_CHOICE => {
            json existing = forced["toolConfig"];
            map<json> toolConfig = existing is map<json> ? existing.clone() : {};
            toolConfig["toolChoice"] = {"tool": {"name": toolName}};
            forced["toolConfig"] = toolConfig;
        }
        ANTHROPIC_TOOL_CHOICE => {
            forced["tool_choice"] = {"type": "tool", "name": toolName};
        }
        OPENAI_CHAT_TOOL_CHOICE => {
            forced["tool_choice"] = {"type": "function", "function": {"name": toolName}};
        }
        RESPONSES_TOOL_CHOICE => {
            // FLAT — Responses does not nest the name under `function` the way Chat
            // Completions does; the two dialects genuinely differ (see ToolChoiceStyle).
            forced["tool_choice"] = {"type": "function", "name": toolName};
        }
        MISTRAL_TOOL_CHOICE => {
            // Mistral cannot name the forced tool — `"any"` means "call some tool".
            // Safe here because generate() supplies exactly one tool.
            forced["tool_choice"] = "any";
        }
    }
    return forced;
}

// Binds a JSON value to the expected type.
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
    // Fall back to the substring between the first and last brace, then the first
    // and last bracket — the target type can be an array, so a JSON array wrapped
    // in prose has to be recoverable too.
    int? objStart = trimmed.indexOf("{");
    int? objEnd = trimmed.lastIndexOf("}");
    if objStart is int && objEnd is int && objEnd > objStart {
        json|error slice = trimmed.substring(objStart, objEnd + 1).fromJsonString();
        if slice is json {
            return slice;
        }
    }
    int? arrStart = trimmed.indexOf("[");
    int? arrEnd = trimmed.lastIndexOf("]");
    if arrStart is int && arrEnd is int && arrEnd > arrStart {
        json|error slice = trimmed.substring(arrStart, arrEnd + 1).fromJsonString();
        if slice is json {
            return slice;
        }
    }
    return error("no JSON value found in model output");
}
