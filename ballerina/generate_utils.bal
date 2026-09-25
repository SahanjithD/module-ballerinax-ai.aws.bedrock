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

// generate() — obtains a typed result by whichever mechanism the resolved route
// supports (see `StructuredOutputStyle` / `structuredOutputStyleFor`). The external
// `Generator` shim passes the typedesc and the provider's resolved state in here;
// the JSON schema is derived on this side by `to_json_schema.bal`, as in the
// reference provider modules.

const RESULT_TOOL = "respond_with_result";

// Callback invoked by the external `Generator` shim.
// Regular (non-dependent) function returning `anydata`; the Java boundary coerces
// the result to the caller's `td`. Reads the provider's resolved state as
// parameters.
isolated function generateLlmResponse(StructuredOutputStyle structuredOutput, ApiFamily api,
        readonly & ModelConverter converter, BedrockTransport transport, string wireModelId,
        map<string> & readonly extraHeaders, readonly & InferenceParams params, ai:Prompt prompt,
        typedesc<anydata> td) returns anydata|ai:Error
    => structuredGenerate(structuredOutput, api, converter, transport, wireModelId,
        extraHeaders, params, prompt, td);

// Dispatches generate() on the route's structured-output style.
isolated function structuredGenerate(StructuredOutputStyle structuredOutput, ApiFamily api,
        readonly & ModelConverter converter, BedrockTransport transport, string wireModelId,
        map<string> & readonly extraHeaders, readonly & InferenceParams params, ai:Prompt prompt,
        typedesc<anydata> td) returns anydata|ai:Error {
    // A `string` target is plain text on EVERY route — there is nothing to structure.
    // Checked FIRST, before any route capability: forcing a tool to obtain a string
    // built a tool schema of `{"type": "string"}`, and Converse requires
    // `toolSpec.inputSchema.json.type` to be `object`, so a string-target generate()
    // on Converse died with a ValidationException. Verified live 2026-08-10 on Nova.
    if td is typedesc<string> {
        return plainTextResponse(api, converter, transport, wireModelId, extraHeaders, params, prompt);
    }
    match structuredOutput {
        NATIVE_OUTPUT_CONFIG => {
            return generateByOutputConfig(api, converter, transport, wireModelId, extraHeaders,
                    params, prompt, td);
        }
        TOOL_FORCING if refusesForcedToolChoice(wireModelId) => {
            // Named up front rather than relayed as a raw 400. Tool forcing is the
            // mechanism, not the goal, so "toolChoice is invalid" tells the caller
            // nothing about the generate() call they actually made — see
            // `FORCED_TOOL_UNSUPPORTED` for the models and the source.
            return error ai:LlmInvalidGenerationError(
                string `Model '${wireModelId}' does not support forced tool use, which is how ` +
                string `this module obtains a typed result, so generate() can only return ` +
                string `'string' on it. Use a model that accepts a forced tool choice — ` +
                string `Claude Opus 5 and Claude Sonnet 5 both do — or call chat() and parse ` +
                string `the reply yourself.`);
        }
        TOOL_FORCING => {
            return generateByToolForcing(api, converter, transport, wireModelId, extraHeaders,
                    params, prompt, td);
        }
    }
    return error ai:LlmInvalidGenerationError(
        string `Structured output is not available for model '${wireModelId}' on the ` +
        string `${converter.dialect} route${api == MESSAGES ? " on bedrock-mantle" : ""}, so the ` +
        string `target type must be 'string'. Use a BedrockRuntime*ModelProvider with the CONVERSE ` +
        string `api for typed generation.`);
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

// The synthetic property name used when a target type's own schema is not an object.
const RESULT_WRAPPER_KEY = "result";

// The schema to put on the wire, and whether it wraps the caller's type.
//
// Every dialect that forces a tool requires the tool's schema to be an OBJECT —
// Converse rejects anything else with "toolSpec.inputSchema.json.type must be one of
// the following: object", and Anthropic Messages says the same of `input_schema`. A
// target like `int` or `string[]` derives a bare `{"type": "integer"}` /
// `{"type": "array"}`, so it cannot be sent as-is. Wrapping it in a one-property
// object is the standard workaround; `unwrapResult` takes it back off before binding.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html
isolated function wireSchemaFor(typedesc<anydata> td) returns [map<json>, boolean]|ai:Error {
    map<json> schema = check schemaFor(td);
    if schema["type"] == "object" {
        return [schema, false];
    }
    return [
        {
            "type": "object",
            "properties": {[RESULT_WRAPPER_KEY]: schema},
            "required": [RESULT_WRAPPER_KEY],
            "additionalProperties": false
        },
        true
    ];
}

// Binds the model's JSON to the target type, unwrapping the synthetic object first.
// A model that ignores the wrapper and answers with the bare value still binds — the
// wrapper is this module's device, not something the caller asked for.
isolated function bindResult(json data, boolean wrapped, typedesc<anydata> td, string origin)
        returns anydata|ai:Error {
    if wrapped && data is map<json> && data.hasKey(RESULT_WRAPPER_KEY) {
        return bindJson(data[RESULT_WRAPPER_KEY], td, origin);
    }
    return bindJson(data, td, origin);
}

// Plain-text generation when the target type is `string`. Serves every route.
// Runs one chat turn and returns the assistant text.
isolated function plainTextResponse(ApiFamily api, readonly & ModelConverter converter, BedrockTransport transport,
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
    // Converse and InvokeModel carry the model id in the URL path; the three
    // vendor-native shapes carry it in the body. This function also serves the
    // NO_TOOL_CHOICE Mistral InvokeModel path, which would otherwise get a stray
    // `model` field. Same gate as `runChat` in provider_common.bal.
    json body = isPathAddressed(api) ? encoded : injectModel(encoded, wireModelId);
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
isolated function generateByToolForcing(ApiFamily api, readonly & ModelConverter converter,
        BedrockTransport transport, string wireModelId, map<string> & readonly extraHeaders,
        readonly & InferenceParams params, ai:Prompt prompt, typedesc<anydata> td)
        returns anydata|ai:Error {
    [map<json>, boolean] [schema, wrapped] = check wireSchemaFor(td);
    ai:ChatCompletionFunctions tool = {
        name: RESULT_TOOL,
        description: "Return the result strictly as structured arguments in the required schema.",
        parameters: schema
    };
    ResolvedUserMessage userMsg = {parts: check contentToParts(prompt)};
    RequestEncoder encode = converter.encode;
    json|ai:Error encoded = encode((), [userMsg], [tool], (), params);
    if encoded is ai:Error {
        return encoded;
    }
    json forced = applyToolChoice(encoded, converter.toolChoice, RESULT_TOOL);
    // The three vendor-native shapes name the model in the BODY. Without this a typed
    // generate() on MESSAGES/CHAT_COMPLETIONS/RESPONSES sent no `model` at all and was
    // rejected, even though chat() on the same provider worked. Same gate as `runChat`.
    json body = isPathAddressed(api) ? forced : injectModel(forced, wireModelId);
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
        return bindResult(toolCalls[0].arguments ?: {}, wrapped, td,
                string `the arguments of the '${RESULT_TOOL}' tool call`);
    }
    // Fallback: some models emit the JSON in the text content instead.
    string? content = decoded.message.content;
    if content is string {
        json|error parsed = extractJson(content);
        if parsed !is error {
            return bindResult(parsed, wrapped, td,
                    string `the JSON found in the reply text (the model answered in text instead ` +
                    string `of calling the '${RESULT_TOOL}' tool)`);
        }
    }
    return error ai:LlmInvalidGenerationError(
        string `Model did not return a '${RESULT_TOOL}' tool call for structured output`);
}

// Forces the single result tool on the encoded body. Keyed on the
// CONVERTER's dialect, not the route shape: Nova on InvokeModel is Converse-shaped,
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
//
// `origin` names WHERE the JSON came from, and the message carries the JSON itself.
// Both are load-bearing: this failure has three sources that look identical from the
// outside — a forced tool call whose arguments do not match the schema, a model that
// ignored the tool and put JSON in its text, and a schema-constrained response the
// model answered off-schema anyway — and the bare "failed to bind" told the caller
// none of that. The `fromJsonWithType` cause names the offending FIELD; only the
// value shows what the model actually sent.
isolated function bindJson(json data, typedesc<anydata> td, string origin) returns anydata|ai:Error {
    anydata|error bound = data.fromJsonWithType(td);
    if bound is error {
        return error ai:LlmInvalidGenerationError(
            string `Failed to bind ${origin} to the expected type '${td.toString()}': ` +
            string `${truncateForMessage(data.toJsonString())}`, bound);
    }
    return bound;
}

// Bound on how much model output an error message carries. Long enough to show the
// shape that failed to bind, short enough not to paste a whole response into a log.
const int MAX_ERROR_JSON_LENGTH = 512;

// Truncates a value for inclusion in an error message, marking that it was cut.
isolated function truncateForMessage(string value) returns string
    => value.length() <= MAX_ERROR_JSON_LENGTH
        ? value
        : value.substring(0, MAX_ERROR_JSON_LENGTH) + "… (truncated)";

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

// Native Converse structured output — `outputConfig.textFormat` carrying the derived
// JSON schema, which AWS validates the response against.
//
// WIRE SHAPE, from botocore's bedrock-runtime service model rather than the
// userguide's elided example, because the two differ in a way guessing gets wrong:
// `OutputFormatStructure.jsonSchema.schema` is a **String** (the schema SERIALISED to
// JSON), whereas the sibling `ToolSpecification.inputSchema.json` is a Document (a
// JSON object). `OutputFormatType` has exactly one member, `json_schema`.
// https://github.com/boto/botocore/blob/develop/botocore/data/bedrock-runtime/2023-09-30/service-2.json
//
// Not reachable until `structuredOutputStyleFor` returns NATIVE_OUTPUT_CONFIG; see
// `StructuredOutputStyle` for the live-evidence conflict that gates it.
isolated function generateByOutputConfig(ApiFamily api, readonly & ModelConverter converter,
        BedrockTransport transport, string wireModelId, map<string> & readonly extraHeaders,
        readonly & InferenceParams params, ai:Prompt prompt, typedesc<anydata> td)
        returns anydata|ai:Error {
    [map<json>, boolean] [schema, wrapped] = check wireSchemaFor(td);
    ResolvedUserMessage userMsg = {parts: check contentToParts(prompt)};
    RequestEncoder encode = converter.encode;
    json|ai:Error encoded = encode((), [userMsg], [], (), params);
    if encoded is ai:Error {
        return encoded;
    }
    if encoded !is map<json> {
        return error ai:LlmInvalidGenerationError("Encoded request body is not a JSON object");
    }
    map<json> body = encoded.clone();
    body["outputConfig"] = {
        "textFormat": {
            "type": "json_schema",
            "structure": {
                "jsonSchema": {
                    "schema": schema.toJsonString(),
                    "name": RESULT_TOOL,
                    "description": "The structure the response must adhere to."
                }
            }
        }
    };
    json sent = isPathAddressed(api) ? body : injectModel(body, wireModelId);
    TransportResponse|ai:Error response = transport.execute(sent, extraHeaders);
    if response is ai:Error {
        return response;
    }
    ResponseDecoder decode = converter.decode;
    DecodedResponse|ai:Error decoded = decode(response.body);
    if decoded is ai:Error {
        return decoded;
    }
    string? content = decoded.message.content;
    if content is () {
        return error ai:LlmInvalidGenerationError(
            string `Model '${wireModelId}' returned no text content for structured output`);
    }
    json|error parsed = extractJson(content);
    if parsed is error {
        return error ai:LlmInvalidGenerationError(
            string `Model '${wireModelId}' returned text that is not valid JSON despite a ` +
            string `schema-constrained request`, parsed);
    }
    return bindResult(parsed, wrapped, td, "the schema-constrained response text");
}
