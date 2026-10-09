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
// The guard paths are driven through `structuredGenerate` itself with an in-process
// `CannedTransport` (test_utils.bal), so they run offline and can assert that a
// refusal happened before any request was sent.

type Review record {|
    string sentiment;
    int score;
|};

// Stands in for the "where did this JSON come from" label the real call sites pass.
// Tests that exercise binding mechanics do not care which one; the test that asserts
// the label reaches the message names its own.
const TEST_BIND_ORIGIN = "the model response";

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
    Review review = check bindJson(toolCalls[0].arguments ?: {}, Review, TEST_BIND_ORIGIN).ensureType();
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
    Review review = check bindJson(toolCalls[0].arguments ?: {}, Review, TEST_BIND_ORIGIN).ensureType();
    test:assertEquals(review, {sentiment: "negative", score: 2});
}

@test:Config {}
function testBindJsonRejectsAMismatchedShape() {
    anydata|ai:Error bound = bindJson({"sentiment": "positive"}, Review, TEST_BIND_ORIGIN); // `score` missing
    test:assertTrue(bound is ai:LlmInvalidGenerationError,
            "a response that does not fit the expected type must be a clean ai:Error");
}

@test:Config {}
function testExtractJsonRecoversFencedJsonFromText() returns error? {
    // Fallback for models that answer with the JSON in prose instead of a tool call.
    json parsed = check extractJson("Sure!\n```json\n{\"sentiment\": \"ok\", \"score\": 5}\n```");
    Review review = check bindJson(parsed, Review, TEST_BIND_ORIGIN).ensureType();
    test:assertEquals(review, {sentiment: "ok", score: 5});
}

@test:Config {}
function testExtractJsonSignalsAbsenceWithAnError() {
    test:assertTrue(extractJson("no json here at all") is error);
}

// ---- Routes with no structured-output path refuse cleanly, before any I/O ----

// Canned replies in the two dialects these tests reach: Anthropic Messages and Converse.
final readonly & json MESSAGES_OK = {
    id: "msg_1", 'type: "message", role: "assistant",
    content: [{'type: "text", text: "OK"}],
    stop_reason: "end_turn", usage: {input_tokens: 3, output_tokens: 1}
};
final readonly & json CONVERSE_OK = {
    output: {message: {role: "assistant", content: [{text: "OK"}]}},
    stopReason: "end_turn", usage: {inputTokens: 3, outputTokens: 1}
};

// ---- `structuredOutputStyleFor` decides the mechanism, once, at construction ----

@test:Config {}
function testStructuredOutputStyleIsNoneWhenTheDialectCannotForceATool() {
    // Mistral text completion has no tool-calling at all, so neither mechanism is
    // available.
    test:assertEquals(structuredOutputStyleFor(NO_TOOL_CHOICE), NO_STRUCTURED_OUTPUT);
}

@test:Config {}
function testEveryToolCapableDialectUsesToolForcing() {
    ToolChoiceStyle[] styles = [CONVERSE_TOOL_CHOICE, ANTHROPIC_TOOL_CHOICE, OPENAI_CHAT_TOOL_CHOICE,
        RESPONSES_TOOL_CHOICE, MISTRAL_TOOL_CHOICE];
    foreach ToolChoiceStyle style in styles {
        test:assertEquals(structuredOutputStyleFor(style), TOOL_FORCING, style);
    }
}

@test:Config {}
function testNativeOutputConfigIsImplementedButNotYetSelected() {
    // The member exists and `generate()` dispatches on it; nothing SELECTS it while
    // the one live call that would settle `outputConfig` support is outstanding.
    // Pinned so flipping the single return in `structuredOutputStyleFor` is a
    // deliberate act with a failing test behind it, not a silent edit.
    ToolChoiceStyle[] styles = [CONVERSE_TOOL_CHOICE, ANTHROPIC_TOOL_CHOICE, OPENAI_CHAT_TOOL_CHOICE,
        RESPONSES_TOOL_CHOICE, MISTRAL_TOOL_CHOICE, NO_TOOL_CHOICE];
    foreach ToolChoiceStyle style in styles {
        test:assertNotEquals(structuredOutputStyleFor(style), NATIVE_OUTPUT_CONFIG,
                string `${style} must not select the native member yet`);
    }
}

@test:Config {}
function testAStringTargetIsNeverRefusedEvenWithNoStructuredOutput() returns error? {
    // `string` needs no structure, so the guard must not fire — it is checked before
    // any route capability. The text coming back proves the refusal did NOT happen.
    CannedTransport transport = new (MESSAGES_OK);
    anydata result = check structuredGenerate(NO_STRUCTURED_OUTPUT, MESSAGES,
            NATIVE_MESSAGES_CONVERTER, transport, "anthropic.claude-opus-5", {}, GEN_PARAMS,
            `Say OK`, string);
    test:assertEquals(result, "OK");
}

@test:Config {}
function testMistralTextDialectRefusesStructuredOutput() returns error? {
    // The refusal must come from the CONVERTER having no tool-calling at all.
    CannedTransport transport = new (CONVERSE_OK);
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

// ---- M1: where a forced tool is a 400, the tool is offered unforced ----

@test:Config {}
function testForcedToolRefusalIsKeyedOnTheBareId() {
    // Anthropic states the restriction for Claude Opus 5.5 and Claude Fable 5.1. It
    // must match whether the caller passed a CRIS-prefixed id or the bare one.
    // https://platform.claude.com/docs/en/models/opus-5-5/whats-new-opus-5-5
    foreach string id in ["anthropic.claude-opus-5-5", "us.anthropic.claude-opus-5-5",
            "global.anthropic.claude-opus-5-5", "anthropic.claude-fable-5-1",
            "us.anthropic.claude-fable-5-1"] {
        test:assertTrue(refusesForcedToolChoice(id), id + " refuses a forced tool choice");
    }
    // The siblings that DO accept one must not be swept up with them.
    foreach string id in ["anthropic.claude-opus-5", "us.anthropic.claude-opus-5",
            "anthropic.claude-fable-5", "anthropic.claude-sonnet-5", "anthropic.claude-opus-4-8"] {
        test:assertFalse(refusesForcedToolChoice(id), id + " accepts a forced tool choice");
    }
}

// Sends one typed generate() and returns the request body that went out.
function sentGenerateBody(ApiFamily api, readonly & ModelConverter converter, string modelId,
        readonly & InferenceParams params, json reply) returns map<json>|error {
    CannedTransport transport = new (reply);
    anydata result = check generateLlmResponse(TOOL_FORCING, api, converter, transport, modelId, {}, params,
            `Give me a point.`, MatrixPoint);
    test:assertEquals(result, <MatrixPoint>{x: 1, y: 2});
    return (<json>transport.requests()[0]).ensureType();
}

@test:Config {}
function testOpus55OffersTheToolUnforcedAndStillReturnsTheType() returns error? {
    // Opus 5.5 rejects a forced tool choice, so the tool is offered without one and
    // the reply is type-checked like any other.
    map<json> body = check sentGenerateBody(CONVERSE, CONVERSE_CONVERTER, "us.anthropic.claude-opus-5-5",
            GEN_PARAMS, converseReply((), RESULT_TOOL, {x: 1, y: 2}));
    map<json> toolConfig = check body["toolConfig"].ensureType();
    test:assertFalse(toolConfig.hasKey("toolChoice"), "the tool must not be forced");
    test:assertTrue(body.toJsonString().includes(RESULT_TOOL_INSTRUCTION), "the model is asked to use the tool");
}

@test:Config {}
function testThinkingOffersTheToolUnforcedOnEveryAnthropicApi() returns error? {
    // Anthropic accepts only `auto` or `none` as the tool choice while thinking is on.
    readonly & InferenceParams thinking = {maxTokens: 4000, thinking: {mode: ADAPTIVE}};
    map<json> invoke = check sentGenerateBody(INVOKE, INVOKE_ANTHROPIC_CONVERTER, "us.anthropic.claude-sonnet-4-6",
            thinking, anthropicReply((), RESULT_TOOL, {x: 1, y: 2}));
    test:assertFalse(invoke.hasKey("tool_choice"), "InvokeModel must not force the tool");
    map<json> messages = check sentGenerateBody(MESSAGES, NATIVE_MESSAGES_CONVERTER, "us.anthropic.claude-sonnet-4-6",
            thinking, anthropicReply((), RESULT_TOOL, {x: 1, y: 2}));
    test:assertFalse(messages.hasKey("tool_choice"), "Messages must not force the tool");
    map<json> converse = check sentGenerateBody(CONVERSE, CONVERSE_CONVERTER, "us.anthropic.claude-sonnet-4-6",
            thinking, converseReply((), RESULT_TOOL, {x: 1, y: 2}));
    map<json> converseTools = check converse["toolConfig"].ensureType();
    test:assertFalse(converseTools.hasKey("toolChoice"), "Converse must not force the tool");
}

@test:Config {}
function testThinkingSetThroughThePassthroughAlsoUnforcesTheTool() returns error? {
    readonly & InferenceParams params = {maxTokens: 4000,
        additionalModelRequestFields: {"thinking": {"type": "enabled", "budget_tokens": 2000}}};
    map<json> body = check sentGenerateBody(CONVERSE, CONVERSE_CONVERTER, "us.anthropic.claude-sonnet-4-6",
            params, converseReply((), RESULT_TOOL, {x: 1, y: 2}));
    map<json> toolConfig = check body["toolConfig"].ensureType();
    test:assertFalse(toolConfig.hasKey("toolChoice"));
}

@test:Config {}
function testDisabledThinkingStillForcesTheTool() returns error? {
    readonly & InferenceParams params = {maxTokens: 4000, thinking: {mode: DISABLED}};
    map<json> body = check sentGenerateBody(INVOKE, INVOKE_ANTHROPIC_CONVERTER, "us.anthropic.claude-sonnet-4-6",
            params, anthropicReply((), RESULT_TOOL, {x: 1, y: 2}));
    test:assertEquals(body["tool_choice"], <json>{"type": "tool", "name": RESULT_TOOL});
    test:assertFalse(body.toJsonString().includes(RESULT_TOOL_INSTRUCTION), "no extra instruction when forced");
}

@test:Config {}
function testOpus55StillAnswersAStringTarget() returns error? {
    // `string` needs no tool at all, so the guard must not fire.
    CannedTransport transport = new (CONVERSE_OK);
    anydata result = check structuredGenerate(TOOL_FORCING, CONVERSE, CONVERSE_CONVERTER,
            transport, "us.anthropic.claude-opus-5-5", {}, GEN_PARAMS, `Say OK`, string);
    test:assertEquals(result, "OK");
}

// ---- N8: a bind failure says what came back and where it came from ----

@test:Config {}
function testABindFailureCarriesTheOffendingJsonAndItsOrigin() {
    anydata|ai:Error bound = bindJson({"sentiment": "positive"}, Review,
            string `the arguments of the '${RESULT_TOOL}' tool call`);
    test:assertTrue(bound is ai:Error);
    if bound is ai:Error {
        // Item 3: the short message names the type; the detail lives in the cause.
        test:assertTrue(bound.message().includes("Review"), bound.message());
        string message = errorText(bound);
        test:assertTrue(message.includes(RESULT_TOOL),
                "the message must say which path produced the JSON; got: " + message);
        test:assertTrue(message.includes("\"sentiment\":\"positive\""),
                "the message must carry the offending JSON; got: " + message);
        test:assertTrue(message.includes("Review"),
                "the message must name the expected type; got: " + message);
    }
}

@test:Config {}
function testALongBindFailureTruncatesTheJson() {
    string filler = "";
    int i = 0;
    while i < 200 {
        filler += "abcdef";
        i += 1;
    }
    anydata|ai:Error bound = bindJson({"sentiment": filler}, Review, "the model response");
    test:assertTrue(bound is ai:Error);
    if bound is ai:Error {
        string message = errorText(bound);
        test:assertTrue(message.includes("(truncated)"),
                "an oversized payload must be cut, not pasted whole; got length " +
                message.length().toString());
        test:assertTrue(message.length() < 800, "the message must stay bounded");
    }
}

// ---- Converse tool choice: by name on Anthropic and Nova, `any` elsewhere ----

@test:Config {}
function testConverseForcesTheToolByNameOnlyOnAnthropicAndNova() returns error? {
    [string, json][] cases = [
        ["us.anthropic.claude-sonnet-4-6", {"tool": {"name": RESULT_TOOL}}],
        ["amazon.nova-pro-v1:0", {"tool": {"name": RESULT_TOOL}}],
        ["mistral.mistral-large-3-675b-instruct", {"any": {}}],
        ["qwen.qwen3-32b-v1:0", {"any": {}}],
        ["deepseek.v3.2", {"any": {}}]
    ];
    foreach [string, json] [id, expected] in cases {
        map<json> body = check sentGenerateBody(CONVERSE, CONVERSE_CONVERTER, id, GEN_PARAMS,
                converseReply((), RESULT_TOOL, {x: 1, y: 2}));
        map<json> toolConfig = check body["toolConfig"].ensureType();
        test:assertEquals(toolConfig["toolChoice"], expected, id);
    }
}

// Answers the first request with a 400 refusing the tool choice, then with `reply`.
isolated class RefusesToolChoiceOnce {
    private final json reply;
    private json[] sent = [];

    isolated function init(json reply) {
        self.reply = reply.clone();
    }

    isolated function execute(json body, map<string> extraHeaders = {}) returns TransportResponse|ai:Error {
        lock {
            self.sent.push(body.clone());
            if self.sent.length() == 1 {
                return error ai:Error("Bedrock ValidationException (HTTP 400): This model doesn't support the " +
                    "toolConfig.toolChoice.any field. Remove toolConfig.toolChoice.any and try again..");
            }
            return {body: self.reply.clone(), headers: {}};
        }
    }

    isolated function requests() returns json[] {
        lock {
            return self.sent.clone();
        }
    }
}

@test:Config {}
function testARejectedToolChoiceFallsBackToAnUnforcedTool() returns error? {
    RefusesToolChoiceOnce transport = new (converseReply((), RESULT_TOOL, {x: 1, y: 2}));
    anydata result = check generateLlmResponse(TOOL_FORCING, CONVERSE, CONVERSE_CONVERTER, transport,
            "meta.llama3-70b-instruct-v1:0", {}, GEN_PARAMS, `Give me a point.`, MatrixPoint);
    test:assertEquals(result, <MatrixPoint>{x: 1, y: 2});
    json[] requests = transport.requests();
    test:assertEquals(requests.length(), 2, "one forced attempt, one unforced retry");
    map<json> second = check requests[1].ensureType();
    map<json> toolConfig = check second["toolConfig"].ensureType();
    test:assertFalse(toolConfig.hasKey("toolChoice"), "the retry must not force the tool");
    test:assertTrue(second.toJsonString().includes(RESULT_TOOL_INSTRUCTION));
}

@test:Config {}
function testAnUnrelated400IsNotRetried() {
    test:assertFalse(rejectsToolChoice(error ai:Error("Bedrock ValidationException (HTTP 400): bad temperature")));
    test:assertFalse(rejectsToolChoice(error ai:Error("Bedrock transient error (HTTP 503): toolChoice")));
}

// ---- A response cut off at the token limit is a clear error ----

@test:Config {}
function testACutOffGenerateAsksToRaiseMaxTokens() {
    json cutTool = {
        output: {message: {role: "assistant", content: [{toolUse: {toolUseId: "c", name: RESULT_TOOL, input: {x: 1}}}]}},
        stopReason: "max_tokens",
        usage: {inputTokens: 5, outputTokens: 3}
    };
    json cutText = {
        output: {message: {role: "assistant", content: [{text: "Once upon a"}]}},
        stopReason: "max_tokens",
        usage: {inputTokens: 5, outputTokens: 3}
    };
    foreach [json, typedesc<anydata>] [reply, td] in [[cutTool, MatrixPoint], [cutText, string]] {
        CannedTransport transport = new (reply);
        anydata|ai:Error result = generateLlmResponse(TOOL_FORCING, CONVERSE, CONVERSE_CONVERTER, transport,
                "us.anthropic.claude-sonnet-4-6", {}, GEN_PARAMS, `Write a story.`, td);
        test:assertTrue(result is ai:LlmInvalidGenerationError, td.toString());
        if result is ai:Error {
            test:assertTrue(result.message().includes("maxTokens"), result.message());
        }
    }
}
