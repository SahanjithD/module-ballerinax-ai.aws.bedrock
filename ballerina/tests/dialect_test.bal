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

// Where two dialects of ONE vendor differ on the wire. These are the cases a
// vendor-shaped mental model gets wrong: "OpenAI" is not one format — Responses and
// Chat Completions disagree, and we serve both.

// A Route built by hand, so the header/dialect rules can be driven without going
// near a provider class. Mirrors exactly what the resolvers produce.
function mantleRoute(string bareModelId, string basePath, ApiFamily api) returns Route => {
    endpoint: MANTLE,
    api,
    bareModelId,
    geoPrefix: (),
    effectiveModelId: bareModelId,
    region: "us-east-1",
    partition: "aws",
    mantleEntry: {basePath, apis: [api]}
};

function runtimeRoute(string bareModelId, ApiFamily api) returns Route => {
    endpoint: RUNTIME,
    api,
    bareModelId,
    geoPrefix: (),
    effectiveModelId: bareModelId,
    region: "us-east-1",
    partition: "aws",
    mantleEntry: ()
};

// ---- tool_choice: Responses is FLAT, Chat Completions is NESTED ----

@test:Config {}
function testResponsesForcesToolsWithTheFlatShape() {
    // REGRESSION: both dialects shared one OPENAI_TOOL_CHOICE emitting the NESTED
    // Chat Completions shape. Responses ignores that, so the tool went unforced —
    // the model answered in prose and generate() failed with "no tool call" on every
    // GPT-5.x and Gemma 4 request. Sources, first-party and unambiguous:
    // https://github.com/openai/openai-python/blob/main/src/openai/types/responses/tool_choice_function.py
    map<json> forced = <map<json>>applyToolChoice({}, NATIVE_RESPONSES_CONVERTER.toolChoice, "my_tool");
    test:assertEquals(forced["tool_choice"], <json>{"type": "function", "name": "my_tool"},
            "Responses takes the tool name FLAT, not nested under `function`");
}

@test:Config {}
function testChatCompletionsForcesToolsWithTheNestedShape() {
    // https://github.com/openai/openai-python/blob/main/src/openai/types/chat/chat_completion_named_tool_choice_param.py
    map<json> forced = <map<json>>applyToolChoice({}, NATIVE_CHAT_CONVERTER.toolChoice, "my_tool");
    test:assertEquals(forced["tool_choice"], <json>{"type": "function", "function": {"name": "my_tool"}},
            "Chat Completions nests the tool name under `function`");
}

@test:Config {}
function testTheTwoOpenAiDialectsDoNotShareAToolChoiceStyle() {
    // The bug was one enum value spanning two incompatible dialects; keep them split.
    test:assertNotEquals(NATIVE_RESPONSES_CONVERTER.toolChoice, NATIVE_CHAT_CONVERTER.toolChoice);
    test:assertEquals(INVOKE_OPENAI_CHAT_CONVERTER.toolChoice, NATIVE_CHAT_CONVERTER.toolChoice,
            "gpt-oss on Invoke speaks Chat Completions, like the native chat route");
}

@test:Config {}
function testTheSameConvertersServeBothEndpoints() {
    // The three vendor-native dialects are served on bedrock-runtime AND
    // bedrock-mantle, so the converters are shared and the endpoints differ only in
    // host, path and signing name. That is why they are no longer named MANTLE_*.
    BedrockEndpoint[] endpoints = [RUNTIME, MANTLE];
    foreach BedrockEndpoint endpoint in endpoints {
        Route route = endpoint == RUNTIME ? runtimeRoute("m", MESSAGES) : mantleRoute("m", "/anthropic/v1", MESSAGES);
        readonly & ModelConverter converter = checkpanic selectConverter(route);
        test:assertEquals(converter.dialect, NATIVE_MESSAGES_CONVERTER.dialect);
    }
}

// ---- Responses has no stop-sequence parameter ----

@test:Config {}
function testResponsesRejectsAPerCallStopRatherThanDroppingIt() {
    // The Responses request schema has NO stop field at all (unlike Chat
    // Completions' `stop`), so there is nothing to map onto. We refuse: honouring
    // the request is impossible, and silently ignoring it lets the model run past
    // the caller's stop text and bill for the overrun.
    // https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_create_params.py
    json|ai:Error encoded = encodeResponses((), [userText("hi")], [], "STOP",
            {temperature: 0.5, maxTokens: 100});
    test:assertTrue(encoded is ai:Error, "a stop sequence must not be silently dropped");
    if encoded is ai:Error {
        test:assertTrue(encoded.message().includes("Responses"),
                "the error must name the dialect that lacks the capability; got: " + encoded.message());
    }
}

@test:Config {}
function testResponsesRejectsConfiguredStopSequencesToo() {
    // The configured form must not slip through the per-call check.
    json|ai:Error encoded = encodeResponses((), [userText("hi")], [], (),
            {temperature: 0.5, maxTokens: 100, stopSequences: ["END"]});
    test:assertTrue(encoded is ai:Error, "configured stopSequences must be refused as well");
}

@test:Config {}
function testResponsesEncodesNormallyWithNoStop() returns error? {
    // The guard must not fire on the ordinary path.
    map<json> body = check encodeResponses((), [userText("hi")], [], (),
            {temperature: 0.5, maxTokens: 100}).ensureType();
    test:assertTrue(body.hasKey("input"));
    test:assertFalse(body.hasKey("stop"), "no stop field exists in this dialect");
}

@test:Config {}
function testResponsesReplaysAssistantToolCallAsFunctionCallItem() returns error? {
    // REGRESSION (live 400, 2026-08-03): an assistant tool-call turn was encoded as an
    // empty `output_text`, dropping the `function_call`. The Responses API then rejected
    // the following `function_call_output` with "No tool call found for function call
    // output with call_id …" and the agent loop stalled. The call must be replayed as a
    // `function_call` item carrying its `call_id`, so a later output can pair to it.
    ResolvedMessage[] messages = [
        {parts: [{text: "What is 3607 multiplied by 4021?"}]},
        {role: ai:ASSISTANT, content: (),
            toolCalls: [{name: "multiply", arguments: {a: 3607, b: 4021}, id: "call_abc"}]}
    ];
    map<json> body = check encodeResponses((), messages, [], (),
            {temperature: 0, maxTokens: 100}).ensureType();
    json[] input = check body["input"].ensureType();

    json[] calls = from json it in input where it is map<json> && it["type"] == "function_call" select it;
    test:assertEquals(calls.length(), 1, "the assistant tool call must be replayed as a function_call item");
    map<json> call = check calls[0].ensureType();
    test:assertEquals(call["call_id"], "call_abc");
    test:assertEquals(call["name"], "multiply");
    // arguments is a JSON STRING in the Responses schema; assert on the parsed value so
    // the test is not brittle to key spacing.
    json parsedArgs = check (check call["arguments"].ensureType(string)).fromJsonString();
    test:assertEquals(parsedArgs, {"a": 3607, "b": 4021});
    // The dropped-to-empty-output_text bug must not recur: no blank assistant text item.
    json[] blanks = from json it in input
        where it is map<json> && it["role"] == "assistant" select it;
    test:assertEquals(blanks.length(), 0, "the tool-call turn must not become an empty output_text item");
}

// ---- x-api-key follows the SHAPE, not the vendor or the provider class ----

@test:Config {}
function testApiKeyHeaderFollowsTheMessagesShapeNotTheProviderClass() returns error? {
    // REGRESSION: this lived in the Anthropic facade alone, so the same rule was
    // honoured there and silently ignored everywhere else. Driven here through
    // `buildRouteHeaders` — the shared path — to prove the route decides, not the
    // class. A Messages shape gets `x-api-key`; see the Bearer case below.
    Route route = mantleRoute("anthropic.claude-opus-5", "/anthropic/v1", MESSAGES);
    map<string> headers = buildRouteHeaders(route, (), {apiKey: "secret-key"});
    test:assertEquals(headers["x-api-key"], "secret-key");

    // ...and it holds on bedrock-runtime too: AWS's documented curl for the Anthropic
    // Messages path sends `x-api-key` on both hosts.
    map<string> runtimeHeaders =
        buildRouteHeaders(runtimeRoute("anthropic.claude-opus-5", MESSAGES), (), {apiKey: "secret-key"});
    test:assertEquals(runtimeHeaders["x-api-key"], "secret-key");
}

@test:Config {}
function testApiKeyHeaderIsAbsentForTheBearerShapes() returns error? {
    // The OpenAI-compatible shapes need nothing extra: the transport's
    // `Authorization: Bearer` already carries the key.
    Route responses = mantleRoute("openai.gpt-5.4", "/openai/v1", RESPONSES);
    test:assertFalse(buildRouteHeaders(responses, (), {apiKey: "secret-key"}).hasKey("x-api-key"));

    Route chat = mantleRoute("deepseek.v3.2", "/v1", CHAT_COMPLETIONS);
    test:assertFalse(buildRouteHeaders(chat, (), {apiKey: "secret-key"}).hasKey("x-api-key"));

    ApiFamily[] apis = [CONVERSE, INVOKE, CHAT_COMPLETIONS, RESPONSES];

    foreach ApiFamily api in apis {
        test:assertFalse(usesApiKeyHeader(api), api + " must authenticate with Bearer/SigV4");
    }
    test:assertTrue(usesApiKeyHeader(MESSAGES));
}

@test:Config {}
function testApiKeyHeaderIsAbsentForSigV4Credentials() returns error? {
    // With SigV4 credentials there is no api key to send — the signature alone must
    // authenticate. Emitting the secret access key here would leak it in a header.
    Route route = mantleRoute("anthropic.claude-opus-5", "/anthropic/v1", MESSAGES);
    test:assertFalse(buildRouteHeaders(route, (), TEST_CREDS).hasKey("x-api-key"));
}

// ---- the two Anthropic version conventions, both live on bedrock-runtime ----

@test:Config {}
function testAnthropicVersionIsAHeaderOnMessagesAndABodyFieldOnInvoke() returns error? {
    // Same vendor, same host, two shapes, two mechanisms — and they must not cross.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-anthropic-claude-messages.html
    map<string> messagesHeaders =
        buildRouteHeaders(runtimeRoute("anthropic.claude-opus-5", MESSAGES), (), TEST_CREDS);
    test:assertEquals(messagesHeaders["anthropic-version"], "2023-06-01");

    map<string> invokeHeaders =
        buildRouteHeaders(runtimeRoute("anthropic.claude-opus-5", INVOKE), (), TEST_CREDS);
    test:assertFalse(invokeHeaders.hasKey("anthropic-version"),
            "InvokeModel carries the version in the BODY, never as this header");

    readonly & InferenceParams params = buildInferenceParams(256, (), (), (), (), (), ());
    map<json> invokeBody = <map<json>>check encodeInvokeAnthropic((), [userText("hi")], [], (), params);
    test:assertEquals(invokeBody["anthropic_version"], "bedrock-2023-05-31");

    map<json> messagesBody = <map<json>>check encodeMantleMessages((), [userText("hi")], [], (), params);
    test:assertFalse(messagesBody.hasKey("anthropic_version"),
            "the Messages dialect carries the version in the HEADER, never in the body");

    // And the header belongs to the SHAPE, so it is sent on Mantle's Messages path too.
    Route mantle = mantleRoute("anthropic.claude-opus-5", "/anthropic/v1", MESSAGES);
    test:assertEquals(buildRouteHeaders(mantle, (), TEST_CREDS)["anthropic-version"], "2023-06-01");
}

// ---- guardrail headers: InvokeModel AND Chat Completions ----

@test:Config {}
function testGuardrailHeadersAreEmittedOnInvokeAndChatCompletions() {
    // The OpenAI-compatible Chat Completions path reuses the INVOKEMODEL header
    // convention rather than the Converse body field — AWS documents
    // `X-Amzn-Bedrock-GuardrailIdentifier` / `-GuardrailVersion` as `extra_headers`
    // on that path.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html
    GuardrailConfig guardrail = {guardrailIdentifier: "gr-1", guardrailVersion: "DRAFT"};
    ApiFamily[] apis = [INVOKE, CHAT_COMPLETIONS];
    foreach ApiFamily api in apis {
        map<string> headers = buildRouteHeaders(runtimeRoute("m", api), guardrail, TEST_CREDS);
        test:assertEquals(headers["X-Amzn-Bedrock-GuardrailIdentifier"], "gr-1", api);
        test:assertEquals(headers["X-Amzn-Bedrock-GuardrailVersion"], "DRAFT", api);
    }
}

@test:Config {}
function testConverseCarriesTheGuardrailInTheBodyNotAHeader() returns error? {
    // Converse models `guardrailConfig` natively, so the headers must NOT appear —
    // sending both would be two ways of asking for the same thing.
    GuardrailConfig guardrail = {guardrailIdentifier: "gr-1", guardrailVersion: "DRAFT"};
    map<string> headers = buildRouteHeaders(runtimeRoute("m", CONVERSE), guardrail, TEST_CREDS);
    test:assertFalse(headers.hasKey("X-Amzn-Bedrock-GuardrailIdentifier"), headers.toString());

    readonly & InferenceParams params = buildInferenceParams(256, (), (), (), (), (), guardrail);
    map<json> body = <map<json>>check encodeConverse((), [userText("hi")], [], (), params);
    test:assertEquals(body["guardrailConfig"],
            <json>{"guardrailIdentifier": "gr-1", "guardrailVersion": "DRAFT"});
}

@test:Config {}
function testNoGuardrailMeansNoGuardrailHeaders() {
    ApiFamily[] apis = [CONVERSE, INVOKE, CHAT_COMPLETIONS, RESPONSES, MESSAGES];
    foreach ApiFamily api in apis {
        map<string> headers = buildRouteHeaders(runtimeRoute("m", api), (), TEST_CREDS);
        test:assertFalse(headers.hasKey("X-Amzn-Bedrock-GuardrailIdentifier"), api);
        test:assertFalse(headers.hasKey("X-Amzn-Bedrock-GuardrailVersion"), api);
    }
}

// ---- Claude-only knobs: `thinking` is a body field, `effort` its sibling ----

@test:Config {}
function testThinkingAndEffortReachTheMessagesDialectAsBodyFields() returns error? {
    // REGRESSION: `thinking` used to be folded into additionalModelRequestFields,
    // but `encodeMantleMessages` ignores that field entirely — so the knob was
    // silently dropped on exactly the two Claude-native dialects. It is now a
    // first-class body field and must actually reach the wire.
    AnthropicRuntimeConfig config = {thinking: {mode: ENABLED, budgetTokens: 1024}, effort: EFFORT_HIGH};
    readonly & InferenceParams params = check anthropicParams(8000, (), config);
    map<json> body = check encodeMantleMessages((), SAMPLE_MESSAGES, [], (), params).ensureType();
    test:assertEquals(body["thinking"], <json>{"type": "enabled", "budget_tokens": 1024},
            "thinking must be a top-level body field on the Messages dialect");

    // `effort` is a SIBLING of `thinking`, never nested inside it — AWS returns a
    // ValidationException for the nested form.
    test:assertEquals(body["output_config"], <json>{"effort": "high"});
    map<json> thinkingBlock = check body["thinking"].ensureType();
    test:assertFalse(thinkingBlock.hasKey("effort"),
            "effort inside thinking is a documented ValidationException");
}

@test:Config {}
function testThinkingBudgetRulesFailAtConstruction() {
    // All three are Bedrock 400s; catching them here names the actual mistake.
    test:assertTrue(anthropicParams(8000, (), {thinking: {mode: ENABLED, budgetTokens: 512}}) is ai:Error);
    test:assertTrue(anthropicParams(2000, (), {thinking: {mode: ENABLED, budgetTokens: 4000}}) is ai:Error);
    test:assertTrue(anthropicParams(8000, (), {thinking: {mode: ENABLED}}) is ai:Error);

    // budgetTokens is meaningless outside ENABLED — adaptive uses `effort` instead.
    test:assertTrue(anthropicParams(8000, (), {thinking: {mode: ADAPTIVE, budgetTokens: 4000}}) is ai:Error);

    // ADAPTIVE alone is the recommended, and default, configuration.
    test:assertTrue(anthropicParams(8000, (), {thinking: {}}) is InferenceParams);
}

@test:Config {}
function testThinkingBudgetRulesAlsoFireOnTheMantleClass() {
    // The validation moved into the shared spine, so it must hold on both endpoints.
    BedrockMantleAnthropicModelProvider|ai:Error provider = new (
            MANTLE_CLAUDE_OPUS_5, TEST_CREDS, REGION, (), 2000,
            thinking = {mode: ENABLED, budgetTokens: 4000});
    test:assertTrue(provider is ai:Error);
    if provider is ai:Error {
        test:assertTrue(provider.message().includes("budgetTokens"), provider.message());
    }
}
