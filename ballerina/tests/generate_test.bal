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
import ballerina/test;

// generate() tests: the tool-forcing path emits the schema as a
// forced tool and parses the tool-call arguments back into the record; the routes
// with no structured-output path refuse cleanly.
//
// The two halves are tested either side of the transport, which is covered
// separately (`transport_path_test.bal`) and cannot be intercepted here because it
// hardcodes https. The guard paths ARE driven through `structuredGenerate` itself,
// since they must return before any I/O — constructing a `BedrockTransport` opens
// no connection.

type Review record {|
    string sentiment;
    int score;
|};

final map<json> REVIEW_SCHEMA = {
    "type": "object",
    "properties": {"sentiment": {"type": "string"}, "score": {"type": "integer"}},
    "required": ["sentiment", "score"]
};

final ai:ChatCompletionFunctions RESULT_TOOL_DEF = {
    name: RESULT_TOOL,
    description: "Return the result strictly as structured arguments in the required schema.",
    parameters: REVIEW_SCHEMA
};

final readonly & InferenceParams GEN_PARAMS = {temperature: 0.5, maxTokens: 256};

// ---- The schema goes out as a forced tool ----

@test:Config {}
function testToolForcingEmitsSchemaAsForcedToolOnConverse() returns error? {
    json encoded = check encodeConverse((), [userText("Rate this")], [RESULT_TOOL_DEF], (),
            GEN_PARAMS);
    map<json> body = check applyToolChoice(encoded, CONVERSE_CONVERTER.toolChoice, RESULT_TOOL).ensureType();

    map<json> toolConfig = check body["toolConfig"].ensureType();
    // The expected type's schema must reach the wire as the tool's input schema.
    json[] tools = check toolConfig["tools"].ensureType();
    test:assertEquals(tools.length(), 1, "generate() must send exactly one tool");
    map<json> toolSpec = check tools[0].toolSpec.ensureType();
    test:assertEquals(toolSpec["name"], RESULT_TOOL);
    test:assertEquals(toolSpec["inputSchema"], <json>{"json": REVIEW_SCHEMA},
            "the typedesc's JSON schema must be the tool input schema");
    // ...and the tool must be FORCED, not merely offered.
    test:assertEquals(toolConfig["toolChoice"], <json>{"tool": {"name": RESULT_TOOL}});
}

@test:Config {}
function testToolForcingEmitsSchemaAsForcedToolOnInvokeAnthropic() returns error? {
    json encoded = check encodeInvokeAnthropic((), [userText("Rate this")], [RESULT_TOOL_DEF], (),
            GEN_PARAMS);
    map<json> body = check applyToolChoice(encoded, INVOKE_ANTHROPIC_CONVERTER.toolChoice, RESULT_TOOL).ensureType();

    json[] tools = check body["tools"].ensureType();
    test:assertEquals(tools.length(), 1);
    map<json> tool = check tools[0].ensureType();
    test:assertEquals(tool["name"], RESULT_TOOL);
    test:assertEquals(tool["input_schema"], <json>REVIEW_SCHEMA);
    test:assertEquals(body["tool_choice"], <json>{"type": "tool", "name": RESULT_TOOL});
}

// ---- Tool forcing is per-DIALECT, not per-route-family ----
//
// Regression: keying tool_choice off `ApiFamily` sent Anthropic's `tool_choice` to
// every non-Converse dialect. Those dialects ignore the unknown field, so the model
// answered in prose and generate() failed with "no tool call" — a silent 1-line bug
// that only shows up against live AWS.

@test:Config {}
function testNovaOnInvokeForcesToolTheConverseWay() returns error? {
    // Nova's InvokeModel body is Converse-shaped even though the family is INVOKE.
    json encoded = check encodeNovaInvoke((), [userText("Rate this")], [RESULT_TOOL_DEF], (),
            GEN_PARAMS);
    map<json> body = check applyToolChoice(encoded, INVOKE_NOVA_CONVERTER.toolChoice, RESULT_TOOL).ensureType();
    map<json> toolConfig = check body["toolConfig"].ensureType();
    test:assertEquals(toolConfig["toolChoice"], <json>{"tool": {"name": RESULT_TOOL}},
            "Nova is Converse-shaped: it must NOT get Anthropic's tool_choice");
    test:assertFalse(body.hasKey("tool_choice"), "Anthropic's tool_choice must not leak onto Nova");
}

@test:Config {}
function testMistralChatForcesToolWithBareAnyString() returns error? {
    // Mistral cannot name the forced tool: tool_choice is the bare string "any".
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-chat-completion.html
    json encoded = check encodeMistralChat((), [userText("Rate this")], [RESULT_TOOL_DEF], (),
            GEN_PARAMS);
    map<json> body = check applyToolChoice(encoded, INVOKE_MISTRAL_CHAT_CONVERTER.toolChoice, RESULT_TOOL).ensureType();
    test:assertEquals(body["tool_choice"], <json>"any", "Mistral's tool_choice is a bare string, not an object");
    json[] tools = check body["tools"].ensureType();
    map<json> fn = check tools[0].'function.ensureType();
    test:assertEquals(fn["parameters"], <json>REVIEW_SCHEMA);
}

@test:Config {}
function testOpenAIChatForcesToolWithFunctionObject() returns error? {
    json encoded = check encodeOpenAIChat((), [userText("Rate this")], [RESULT_TOOL_DEF], (),
            GEN_PARAMS);
    map<json> body = check applyToolChoice(encoded, INVOKE_OPENAI_CHAT_CONVERTER.toolChoice, RESULT_TOOL).ensureType();
    test:assertEquals(body["tool_choice"], <json>{"type": "function", "function": {"name": RESULT_TOOL}});
}

// ---- The tool-call arguments come back as the record ----

@test:Config {}
function testToolForcingParsesToolCallArgsBackIntoRecordOnConverse() returns error? {
    json canned = {
        "output": {
            "message": {
                "role": "assistant",
                "content": [{
                    "toolUse": {
                        "toolUseId": "tu_1",
                        "name": RESULT_TOOL,
                        "input": {"sentiment": "positive", "score": 9}
                    }
                }]
            }
        },
        "stopReason": "tool_use",
        "usage": {"inputTokens": 12, "outputTokens": 7}
    };
    DecodedResponse decoded = check decodeConverse(canned);
    ai:FunctionCall[] toolCalls = check decoded.message.toolCalls.ensureType();
    Review review = check bindJson(toolCalls[0].arguments ?: {}, Review).ensureType();
    test:assertEquals(review, {sentiment: "positive", score: 9});
}

@test:Config {}
function testToolForcingParsesToolCallArgsBackIntoRecordOnMistralChat() returns error? {
    // Mistral returns the arguments as a JSON *string*, not an object.
    json canned = {
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": "",
                "tool_calls": [{
                    "id": "call_1",
                    "function": {"name": RESULT_TOOL, "arguments": "{\"sentiment\": \"negative\", \"score\": 2}"}
                }]
            },
            "stop_reason": "tool_calls"
        }]
    };
    DecodedResponse decoded = check decodeMistralChat(canned);
    ai:FunctionCall[] toolCalls = check decoded.message.toolCalls.ensureType();
    Review review = check bindJson(toolCalls[0].arguments ?: {}, Review).ensureType();
    test:assertEquals(review, {sentiment: "negative", score: 2});
}

@test:Config {}
function testBindJsonRejectsAMismatchedShape() {
    anydata|ai:Error bound = bindJson({"sentiment": "positive"}, Review); // `score` missing
    test:assertTrue(bound is ai:LlmInvalidGenerationError,
            "a response that does not fit the expected type must be a clean ai:Error");
}

@test:Config {}
function testExtractJsonRecoversFencedJsonFromText() returns error? {
    // Fallback for models that answer with the JSON in prose instead of a tool call.
    json parsed = check extractJson("Sure!\n```json\n{\"sentiment\": \"ok\", \"score\": 5}\n```");
    Review review = check bindJson(parsed, Review).ensureType();
    test:assertEquals(review, {sentiment: "ok", score: 5});
}

@test:Config {}
function testExtractJsonSignalsAbsenceWithAnError() {
    test:assertTrue(extractJson("no json here at all") is error);
}

// ---- Routes with no structured-output path refuse cleanly, before any I/O ----

function mantleTransport(string path = "/anthropic/v1/messages") returns BedrockTransport|error =>
    new (check resolveCredentials(TEST_CREDS), "us-east-1",
        {baseUrl: string `https://bedrock-mantle.us-east-1.api.aws`,
            host: "bedrock-mantle.us-east-1.api.aws", path,
            signingService: SIGNING_BEDROCK_MANTLE});

// ---- `structuredOutputStyleFor` decides the mechanism, once, at construction ----

@test:Config {}
function testStructuredOutputStyleIsNoneWhenTheDialectCannotForceATool() {
    // Mistral text completion has no tool-calling at all, so neither mechanism is
    // available regardless of endpoint or shape.
    test:assertEquals(structuredOutputStyleFor(RUNTIME, INVOKE, NO_TOOL_CHOICE), NO_STRUCTURED_OUTPUT);
    test:assertEquals(structuredOutputStyleFor(MANTLE, CHAT_COMPLETIONS, NO_TOOL_CHOICE),
            NO_STRUCTURED_OUTPUT);
}

@test:Config {}
function testStructuredOutputStyleIsNoneOnMantleMessagesOnly() {
    // Anthropic Messages on bedrock-mantle rejects `output_config.format` AND
    // `strict: true` on a tool, so tool forcing does not rescue it either. Every
    // OTHER Mantle shape keeps tool forcing — "Mantle has no structured output" as a
    // blanket rule is wrong, and Grok 4.3's card is the counter-example.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-structured-outputs.html
    test:assertEquals(structuredOutputStyleFor(MANTLE, MESSAGES, ANTHROPIC_TOOL_CHOICE),
            NO_STRUCTURED_OUTPUT);
    test:assertEquals(structuredOutputStyleFor(MANTLE, CHAT_COMPLETIONS, OPENAI_CHAT_TOOL_CHOICE),
            TOOL_FORCING);
    test:assertEquals(structuredOutputStyleFor(MANTLE, RESPONSES, RESPONSES_TOOL_CHOICE), TOOL_FORCING);
}

@test:Config {}
function testMessagesOnTheRuntimeEndpointStillDoesToolForcing() {
    // The refusal is keyed on the ENDPOINT + shape pair, not the shape alone: the
    // same Anthropic Messages dialect on `bedrock-runtime` is not the surface AWS
    // documents the rejection for.
    test:assertEquals(structuredOutputStyleFor(RUNTIME, MESSAGES, ANTHROPIC_TOOL_CHOICE), TOOL_FORCING);
    test:assertEquals(structuredOutputStyleFor(RUNTIME, CONVERSE, CONVERSE_TOOL_CHOICE), TOOL_FORCING);
    test:assertEquals(structuredOutputStyleFor(RUNTIME, INVOKE, ANTHROPIC_TOOL_CHOICE), TOOL_FORCING);
}

@test:Config {}
function testNativeOutputConfigIsImplementedButNotYetSelected() {
    // The member exists and `generate()` dispatches on it; nothing SELECTS it while
    // the one live call that would settle `outputConfig` support is outstanding.
    // Pinned so flipping the single return in `structuredOutputStyleFor` is a
    // deliberate act with a failing test behind it, not a silent edit.
    BedrockEndpoint[] endpoints = [RUNTIME, MANTLE];
    foreach BedrockEndpoint endpoint in endpoints {
        ApiShape[] shapes = [CONVERSE, INVOKE, CHAT_COMPLETIONS, RESPONSES, MESSAGES];
        foreach ApiShape shape in shapes {
            test:assertNotEquals(structuredOutputStyleFor(endpoint, shape, CONVERSE_TOOL_CHOICE),
                    NATIVE_OUTPUT_CONFIG, string `${endpoint}/${shape} must not select the native member yet`);
        }
    }
}

@test:Config {}
function testMantleMessagesRefusesStructuredOutputNamingTheModel() returns error? {
    // The one route with no typed-generation path at all. It must fail locally,
    // before any I/O, and the message must name the model and the dialect.
    BedrockTransport transport = check mantleTransport();
    anydata|ai:Error result = structuredGenerate(NO_STRUCTURED_OUTPUT, MESSAGES,
            NATIVE_MESSAGES_CONVERTER, transport, "anthropic.claude-opus-5", {}, GEN_PARAMS,
            `Rate this`, Review);
    test:assertTrue(result is ai:Error, "a typed target on Mantle Messages must be a clean error");
    if result is ai:Error {
        string message = result.message();
        test:assertTrue(message.includes("anthropic.claude-opus-5"),
                "the error must name the model; got: " + message);
        test:assertTrue(message.includes("Anthropic Messages"),
                "the error must name the dialect that lacks the capability; got: " + message);
        test:assertTrue(message.includes("CONVERSE"),
                "the error must point at the way out; got: " + message);
    }
}

@test:Config {}
function testAStringTargetIsNeverRefusedEvenWithNoStructuredOutput() returns error? {
    // `string` needs no structure, so the guard must not fire — it is checked before
    // any route capability. Reaching the transport (and failing there, with no
    // credentials that AWS would accept) proves the refusal did NOT happen locally.
    BedrockTransport transport = check mantleTransport();
    anydata|ai:Error result = structuredGenerate(NO_STRUCTURED_OUTPUT, MESSAGES,
            NATIVE_MESSAGES_CONVERTER, transport, "anthropic.claude-opus-5", {}, GEN_PARAMS,
            `Say OK`, string);
    if result is ai:Error {
        test:assertFalse(result.message().includes("target type must be 'string'"),
                "a string target must not hit the structured-output refusal: " + result.message());
    }
}

@test:Config {}
function testMistralTextDialectRefusesStructuredOutput() returns error? {
    // INVOKE on bedrock-runtime, so the endpoint carries structured output — the
    // refusal must come from the CONVERTER having no tool-calling at all.
    BedrockTransport transport = check mantleTransport();
    anydata|ai:Error result = structuredGenerate(NO_STRUCTURED_OUTPUT, INVOKE,
            INVOKE_MISTRAL_TEXT_CONVERTER, transport,
            "mistral.mistral-7b-instruct-v0:2", {}, GEN_PARAMS, `Rate this`, Review);
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        string message = result.message();
        test:assertTrue(message.includes("mistral.mistral-7b-instruct-v0:2"),
                "the error must name the model; got: " + message);
        test:assertTrue(message.includes("CONVERSE"), "the error must point at the way out; got: " + message);
    }
}

@test:Config {}
function testMistralTextDialectRejectsToolsRatherThanDroppingThem() {
    json|ai:Error encoded = encodeMistralText((), [userText("Hi")], [RESULT_TOOL_DEF], (),
            GEN_PARAMS);
    test:assertTrue(encoded is ai:Error, "tools on a dialect with no tool support must fail loudly");
}
