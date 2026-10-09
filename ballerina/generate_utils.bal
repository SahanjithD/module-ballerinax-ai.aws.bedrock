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
import ballerina/ai.observe;
import ballerina/jballerina.java;

// generate() — obtains a typed result by whichever mechanism the resolved route
// supports (see `StructuredOutputStyle` / `structuredOutputStyleFor`). The external
// `Generator` shim passes the typedesc and the provider's resolved state in here;
// the JSON schema is derived on this side by `to_json_schema.bal`, as in the
// reference provider modules.

const RESULT_TOOL = "respond_with_result";

// Callback invoked by the external `Generator` shim.
// Regular (non-dependent) function returning `anydata`; the Java boundary returns the
// result to the caller as `td` WITHOUT re-checking it, so the `ensureType` below is
// what guarantees the value really is a `td`. Reads the provider's resolved state as
// parameters. Opens the generate span and is the ONE place it is closed.
isolated function generateLlmResponse(StructuredOutputStyle structuredOutput, ApiFamily api,
        readonly & ModelConverter converter, ModelTransport transport, string wireModelId,
        map<string> & readonly extraHeaders, readonly & InferenceParams params, ai:Prompt prompt,
        typedesc<anydata> td) returns anydata|ai:Error {
    observe:GenerateContentSpan span = observe:createGenerateContentSpan(wireModelId);
    span.addProvider(BEDROCK_PROVIDER_NAME);
    decimal? temperature = params?.temperature;
    if temperature is decimal {
        span.addTemperature(temperature);
    }
    anydata|ai:Error result = structuredGenerate(structuredOutput, api, converter, transport, wireModelId,
            extraHeaders, params, prompt, td, span);
    if result is ai:Error {
        span.close(result);
        return result;
    }
    anydata|error typed = result.ensureType(td);
    if typed is error {
        ai:Error err = error ai:LlmInvalidGenerationError(
            string `The model's response is not a valid '${td.toString()}'.`, typed);
        span.close(err);
        return err;
    }
    span.addOutputMessages(typed.toJson());
    span.addOutputType(isPlainStringType(td) ? observe:TEXT : observe:JSON);
    span.close();
    return typed;
}

// Whether the expected type is exactly `string`. NOT `td is typedesc<string>`: an
// enum, a string-literal union and `string:Char` are all `typedesc<string>` too, and
// free model text is not a member of any of them, so those must take the schema path.
isolated function isPlainStringType(typedesc<anydata> td) returns boolean = @java:Method {
    'class: "io.ballerina.lib.ai.aws.bedrock.Native",
    name: "isPlainString"
} external;

// A short, actionable `generate()` error. The reasoning behind it goes in the cause,
// with any underlying error chained beneath that, so nothing is lost for a caller who
// unwraps it.
isolated function generationError(string message, string detail, error? cause = ())
        returns ai:LlmInvalidGenerationError
    => error ai:LlmInvalidGenerationError(message, error(detail, cause));

// Dispatches generate() on the route's structured-output style. `span` is `()` only in
// tests that drive this directly.
isolated function structuredGenerate(StructuredOutputStyle structuredOutput, ApiFamily api,
        readonly & ModelConverter converter, ModelTransport transport, string wireModelId,
        map<string> & readonly extraHeaders, readonly & InferenceParams params, ai:Prompt prompt,
        typedesc<anydata> td, observe:LlmSpan? span = ()) returns anydata|ai:Error {
    // A `string` target is plain text on EVERY route — there is nothing to structure.
    // Checked FIRST, before any route capability: forcing a tool to obtain a string
    // built a tool schema of `{"type": "string"}`, and Converse requires
    // `toolSpec.inputSchema.json.type` to be `object`, so a string-target generate()
    // on Converse died with a ValidationException. Verified live 2026-08-10 on Nova.
    if isPlainStringType(td) {
        return plainTextResponse(api, converter, transport, wireModelId, extraHeaders, params, prompt, span);
    }
    match structuredOutput {
        NATIVE_OUTPUT_CONFIG => {
            return generateByOutputConfig(api, converter, transport, wireModelId, extraHeaders,
                    params, prompt, td, span);
        }
        TOOL_FORCING => {
            // Where forcing the tool is a 400, the tool is still offered but the model
            // chooses; the result is then checked against the type like any other.
            boolean forceTool = !refusesForcedToolChoice(wireModelId) && !thinkingEnabled(params);
            return generateByToolForcing(api, converter, transport, wireModelId, extraHeaders,
                    params, prompt, td, span, forceTool);
        }
    }
    return generationError(
        string `Model '${wireModelId}' cannot return a typed result on the ${converter.dialect} API. ` +
        "Use a 'string' target, or a model and API that support tool calling (e.g. the CONVERSE API).",
        string `The ${converter.dialect} route${api == MESSAGES ? " on bedrock-mantle" : ""} offers ` +
        "neither native structured output nor tool forcing, which are the two ways generate() can " +
        "obtain a typed result.");
}

// Derives the expected type's JSON schema (`to_json_schema.bal`). A target type
// outside `json` cannot be described to a model at all, so it is an error here
// rather than an empty schema the model would silently ignore.
isolated function schemaFor(typedesc<anydata> td) returns map<json>|ai:Error {
    if td !is typedesc<json> {
        return error ai:LlmInvalidGenerationError(
            string `The expected type '${td.toString()}' must be a subtype of 'json'.`);
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
isolated function plainTextResponse(ApiFamily api, readonly & ModelConverter converter, ModelTransport transport,
        string wireModelId, map<string> & readonly extraHeaders, readonly & InferenceParams params,
        ai:Prompt prompt, observe:LlmSpan? span) returns anydata|ai:Error {
    // Resolve the prompt the same way chat() does — a generate() prompt can carry an
    // image too, and it must reach the dialect (or be refused) identically.
    ResolvedUserMessage userMsg = {parts: check contentToParts(prompt)};
    RequestEncoder encode = converter.encode;
    json encoded = check encode((), [userMsg], [], (), params);
    DecodedResponse decoded = check sendGenerateRequest(span, api, wireModelId, converter, transport,
            extraHeaders, userMsg, encoded);
    check refuseCutOff(decoded, wireModelId);
    return decoded.message.content ?: "";
}

// Records the prompt on the span (when there is one) and sends the request through
// the same round trip `chat()` uses, which also names the model in the body where a
// vendor-native shape needs it.
isolated function sendGenerateRequest(observe:LlmSpan? span, ApiFamily api, string wireModelId,
        readonly & ModelConverter converter, ModelTransport transport, map<string> & readonly extraHeaders,
        ResolvedUserMessage userMsg, json encoded) returns DecodedResponse|ai:Error {
    if span is observe:LlmSpan {
        span.addInputMessages(messagesForSpan((), [userMsg]));
    }
    return sendAndDecode(span, api, wireModelId, converter, transport, extraHeaders, encoded);
}

// Asks for the result tool when it cannot be forced.
const RESULT_TOOL_INSTRUCTION = "Respond only by calling the " + RESULT_TOOL +
    " tool, with the result as its arguments.";

// Tier 1 — offer a single tool whose schema is the expected type, forced unless
// `forceTool` is false, and parse the tool-call arguments back into the record.
isolated function generateByToolForcing(ApiFamily api, readonly & ModelConverter converter,
        ModelTransport transport, string wireModelId, map<string> & readonly extraHeaders,
        readonly & InferenceParams params, ai:Prompt prompt, typedesc<anydata> td, observe:LlmSpan? span,
        boolean forceTool = true) returns anydata|ai:Error {
    [map<json>, boolean] [schema, wrapped] = check wireSchemaFor(td);
    ai:ChatCompletionFunctions tool = {
        name: RESULT_TOOL,
        description: "Return the result strictly as structured arguments in the required schema.",
        parameters: schema
    };
    ResolvedUserMessage userMsg = {parts: check contentToParts(prompt)};
    RequestEncoder encode = converter.encode;
    json encoded = check encode(forceTool ? () : RESULT_TOOL_INSTRUCTION, [userMsg], [tool], (), params);
    json body = forceTool
        ? applyToolChoice(encoded, converter.toolChoice, RESULT_TOOL, acceptsNamedToolChoice(wireModelId))
        : encoded;
    DecodedResponse|ai:Error sent = sendGenerateRequest(span, api, wireModelId, converter, transport,
            extraHeaders, userMsg, body);
    if sent is ai:Error && forceTool && rejectsToolChoice(sent) {
        // The model does not take the tool choice sent: offer the tool unforced instead.
        return generateByToolForcing(api, converter, transport, wireModelId, extraHeaders, params, prompt, td,
                span, false);
    }
    DecodedResponse decoded = check sent;
    check refuseCutOff(decoded, wireModelId);
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
    return generationError(string `Model '${wireModelId}' did not return a structured result.`,
        string `The response carried no '${RESULT_TOOL}' tool call and no JSON in its text ` +
        string `(stop reason '${decoded.stopReason}').`);
}

// A generate() answer that stopped at the token limit is incomplete: a typed result
// would fail to bind with a confusing message, and a string would be silently cut.
isolated function refuseCutOff(DecodedResponse decoded, string wireModelId) returns ai:Error? {
    if finishReason(decoded.stopReason) == FINISH_LENGTH {
        return generationError(
            string `The response from model '${wireModelId}' was cut off at the token limit. Raise 'maxTokens'.`,
            string `The model stopped with '${decoded.stopReason}' before finishing. On a thinking model the ` +
            "thinking counts towards the same limit.");
    }
}

// Whether a request failed because the model does not take the tool choice sent,
// e.g. Converse's "This model doesn't support the toolConfig.toolChoice.any field".
isolated function rejectsToolChoice(ai:Error err) returns boolean {
    string message = err.message();
    return message.startsWith("Bedrock ValidationException") &&
        (message.includes("toolChoice") || message.includes("tool_choice"));
}

// Converse can force a tool BY NAME only on Anthropic and Amazon Nova models; every
// other model is sent `any`, which forces the single tool offered just the same.
// "tool: ... This field is only supported by Anthropic Claude 3 and Amazon Nova models."
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_ToolChoice.html
isolated function acceptsNamedToolChoice(string wireModelId) returns boolean {
    [string, string?] [bareId, _] = normalizeModelId(wireModelId);
    return bareId.startsWith("anthropic.") || bareId.startsWith("amazon.nova");
}

// Forces the single result tool on the encoded body. Keyed on the
// CONVERTER's dialect, not the route shape: Nova on InvokeModel is Converse-shaped,
// and Mistral chat forces with a bare string. Deriving this from `ApiFamily` sends
// Anthropic's `tool_choice` to every non-Converse dialect, which they ignore —
// the model then answers in prose and `generate()` fails with "no tool call".
isolated function applyToolChoice(json body, ToolChoiceStyle style, string toolName, boolean byName = true)
        returns json {
    if body !is map<json> {
        return body;
    }
    map<json> forced = body.clone();
    match style {
        CONVERSE_TOOL_CHOICE => {
            json existing = forced["toolConfig"];
            map<json> toolConfig = existing is map<json> ? existing.clone() : {};
            toolConfig["toolChoice"] = byName ? {"tool": {"name": toolName}} : {"any": {}};
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
        return generationError(
            string `The model's response does not match the expected type '${td.toString()}'.`,
            string `Failed to bind ${origin}: ${truncateForMessage(data.toJsonString())}`, bound);
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
        ModelTransport transport, string wireModelId, map<string> & readonly extraHeaders,
        readonly & InferenceParams params, ai:Prompt prompt, typedesc<anydata> td, observe:LlmSpan? span)
        returns anydata|ai:Error {
    [map<json>, boolean] [schema, wrapped] = check wireSchemaFor(td);
    ResolvedUserMessage userMsg = {parts: check contentToParts(prompt)};
    RequestEncoder encode = converter.encode;
    json encoded = check encode((), [userMsg], [], (), params);
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
    DecodedResponse decoded = check sendGenerateRequest(span, api, wireModelId, converter, transport,
            extraHeaders, userMsg, body);
    check refuseCutOff(decoded, wireModelId);
    string? content = decoded.message.content;
    if content is () {
        return generationError(string `Model '${wireModelId}' did not return a structured result.`,
            "The schema-constrained response carried no text content.");
    }
    json|error parsed = extractJson(content);
    if parsed is error {
        return generationError(string `Model '${wireModelId}' did not return a structured result.`,
            "The schema-constrained response text is not valid JSON.", parsed);
    }
    return bindResult(parsed, wrapped, td, "the schema-constrained response text");
}
