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

// generate(): obtains a typed result by whichever mechanism the route supports.

const RESULT_TOOL = "respond_with_result";

// Called by the Java `Generator` shim, which does not check the result type, so
// `ensureType` below does.
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

// Whether the target is exactly `string`. Enums, literal unions and `string:Char` are
// `typedesc<string>` too, but need a schema.
isolated function isPlainStringType(typedesc<anydata> td) returns boolean = @java:Method {
    'class: "io.ballerina.lib.ai.aws.bedrock.Native",
    name: "isPlainString"
} external;

isolated function generationError(string message, string detail, error? cause = ())
        returns ai:LlmInvalidGenerationError
    => error ai:LlmInvalidGenerationError(message, error(detail, cause));

isolated function structuredGenerate(StructuredOutputStyle structuredOutput, ApiFamily api,
        readonly & ModelConverter converter, ModelTransport transport, string wireModelId,
        map<string> & readonly extraHeaders, readonly & InferenceParams params, ai:Prompt prompt,
        typedesc<anydata> td, observe:LlmSpan? span = ()) returns anydata|ai:Error {
    // A `string` target is plain text on every route, checked first: Converse rejects
    // a tool schema that is not an object.
    if isPlainStringType(td) {
        return plainTextResponse(api, converter, transport, wireModelId, extraHeaders, params, prompt, span);
    }
    match structuredOutput {
        NATIVE_OUTPUT_CONFIG => {
            return generateByOutputConfig(api, converter, transport, wireModelId, extraHeaders,
                    params, prompt, td, span);
        }
        TOOL_FORCING => {
            // Where forcing is rejected, the tool is offered unforced and the result is
            // still type-checked.
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

// The target type's JSON schema. A type outside `json` cannot be described to a model.
isolated function schemaFor(typedesc<anydata> td) returns map<json>|ai:Error {
    if td !is typedesc<json> {
        return error ai:LlmInvalidGenerationError(
            string `The expected type '${td.toString()}' must be a subtype of 'json'.`);
    }
    return generateJsonSchemaForTypedescAsJson(td);
}

// Wrapper property for a target whose schema is not an object.
const RESULT_WRAPPER_KEY = "result";

// The schema to send, and whether it wraps the target type: a forced tool's schema must
// be an object, so `int` or `string[]` is wrapped in `{"result": ...}`.
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

// A bare (unwrapped) value binds too.
isolated function bindResult(json data, boolean wrapped, typedesc<anydata> td, string origin)
        returns anydata|ai:Error {
    if wrapped && data is map<json> && data.hasKey(RESULT_WRAPPER_KEY) {
        return bindJson(data[RESULT_WRAPPER_KEY], td, origin);
    }
    return bindJson(data, td, origin);
}

isolated function plainTextResponse(ApiFamily api, readonly & ModelConverter converter, ModelTransport transport,
        string wireModelId, map<string> & readonly extraHeaders, readonly & InferenceParams params,
        ai:Prompt prompt, observe:LlmSpan? span) returns anydata|ai:Error {
    // Resolved like chat(), so an image is handled the same way.
    ResolvedUserMessage userMsg = {parts: check contentToParts(prompt)};
    RequestEncoder encode = converter.encode;
    json encoded = check encode((), [userMsg], [], (), params);
    DecodedResponse decoded = check sendGenerateRequest(span, api, wireModelId, converter, transport,
            extraHeaders, userMsg, encoded);
    check refuseCutOff(decoded, wireModelId);
    return decoded.message.content ?: "";
}

isolated function sendGenerateRequest(observe:LlmSpan? span, ApiFamily api, string wireModelId,
        readonly & ModelConverter converter, ModelTransport transport, map<string> & readonly extraHeaders,
        ResolvedUserMessage userMsg, json encoded) returns DecodedResponse|ai:Error {
    if span is observe:LlmSpan {
        span.addInputMessages(messagesForSpan((), [userMsg]));
    }
    return sendAndDecode(span, api, wireModelId, converter, transport, extraHeaders, encoded);
}

const RESULT_TOOL_INSTRUCTION = "Respond only by calling the " + RESULT_TOOL +
    " tool, with the result as its arguments.";

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
        // The model rejected the tool choice: offer the tool unforced.
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
    // Some models put the JSON in the text instead.
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

// A generate() answer stopped at the token limit is incomplete, typed or not.
isolated function refuseCutOff(DecodedResponse decoded, string wireModelId) returns ai:Error? {
    if finishReason(decoded.stopReason) == FINISH_LENGTH {
        return generationError(
            string `The response from model '${wireModelId}' was cut off at the token limit. Raise 'maxTokens'.`,
            string `The model stopped with '${decoded.stopReason}' before finishing. On a thinking model the ` +
            "thinking counts towards the same limit.");
    }
}

// Whether AWS rejected the tool choice itself, e.g. Converse's "This model doesn't
// support the toolConfig.toolChoice.any field".
isolated function rejectsToolChoice(ai:Error err) returns boolean {
    string message = err.message();
    return message.startsWith("Bedrock ValidationException") &&
        (message.includes("toolChoice") || message.includes("tool_choice"));
}

// Converse forces a tool by name only on Anthropic and Nova; other models get `any`,
// which forces the one tool offered.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_ToolChoice.html
isolated function acceptsNamedToolChoice(string wireModelId) returns boolean {
    [string, string?] [bareId, _] = normalizeModelId(wireModelId);
    return bareId.startsWith("anthropic.") || bareId.startsWith("amazon.nova");
}

// Forces the result tool in the converter's own format (Nova on InvokeModel uses the
// Converse form; Mistral chat uses `"any"`).
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
            // Flat, unlike Chat Completions.
            forced["tool_choice"] = {"type": "function", "name": toolName};
        }
        MISTRAL_TOOL_CHOICE => {
            // Mistral cannot name the tool; fine, since there is only one.
            forced["tool_choice"] = "any";
        }
    }
    return forced;
}

// The error shows the JSON and where it came from; the cause names the failing field.
isolated function bindJson(json data, typedesc<anydata> td, string origin) returns anydata|ai:Error {
    anydata|error bound = data.fromJsonWithType(td);
    if bound is error {
        return generationError(
            string `The model's response does not match the expected type '${td.toString()}'.`,
            string `Failed to bind ${origin}: ${truncateForMessage(data.toJsonString())}`, bound);
    }
    return bound;
}

// How much model output an error message shows.
const int MAX_ERROR_JSON_LENGTH = 512;

isolated function truncateForMessage(string value) returns string
    => value.length() <= MAX_ERROR_JSON_LENGTH
        ? value
        : value.substring(0, MAX_ERROR_JSON_LENGTH) + "… (truncated)";

// Returns an error when there is no JSON, since `()` is itself valid `json`.
isolated function extractJson(string content) returns json|error {
    string trimmed = content.trim();
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
    // The target can be an array, so brackets are tried after braces.
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

// `jsonSchema.schema` is a string (the serialised schema), unlike a tool's object
// schema. Not selected by any route yet.
// https://github.com/boto/botocore/blob/develop/botocore/data/bedrock-runtime/2023-09-30/service-2.json
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
