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

// ---- tool_choice: Responses is FLAT, Chat Completions is NESTED ----

@test:Config {}
function testResponsesForcesToolsWithTheFlatShape() {
    // REGRESSION: both dialects shared one OPENAI_TOOL_CHOICE emitting the NESTED
    // Chat Completions shape. Responses ignores that, so the tool went unforced —
    // the model answered in prose and generate() failed with "no tool call" on every
    // GPT-5.x and Gemma 4 request. Sources, first-party and unambiguous:
    // https://github.com/openai/openai-python/blob/main/src/openai/types/responses/tool_choice_function.py
    map<json> forced = <map<json>>applyToolChoice({}, MANTLE_RESPONSES_CODEC.toolChoice, "my_tool");
    test:assertEquals(forced["tool_choice"], <json>{"type": "function", "name": "my_tool"},
            "Responses takes the tool name FLAT, not nested under `function`");
}

@test:Config {}
function testChatCompletionsForcesToolsWithTheNestedShape() {
    // https://github.com/openai/openai-python/blob/main/src/openai/types/chat/chat_completion_named_tool_choice_param.py
    map<json> forced = <map<json>>applyToolChoice({}, MANTLE_CHAT_CODEC.toolChoice, "my_tool");
    test:assertEquals(forced["tool_choice"], <json>{"type": "function", "function": {"name": "my_tool"}},
            "Chat Completions nests the tool name under `function`");
}

@test:Config {}
function testTheTwoOpenAiDialectsDoNotShareAToolChoiceStyle() {
    // The bug was one enum value spanning two incompatible dialects; keep them split.
    test:assertNotEquals(MANTLE_RESPONSES_CODEC.toolChoice, MANTLE_CHAT_CODEC.toolChoice);
    test:assertEquals(INVOKE_OPENAI_CHAT_CODEC.toolChoice, MANTLE_CHAT_CODEC.toolChoice,
            "gpt-oss on Invoke speaks Chat Completions, like Mantle's chat route");
}

// ---- Responses has no stop-sequence parameter ----

@test:Config {}
function testResponsesRejectsAPerCallStopRatherThanDroppingIt() {
    // The Responses request schema has NO stop field at all (unlike Chat
    // Completions' `stop`), so there is nothing to map onto. We refuse: honouring
    // the request is impossible, and silently ignoring it lets the model run past
    // the caller's stop text and bill for the overrun.
    // https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_create_params.py
    json|ai:Error encoded = encodeResponses((), [{role: ai:USER, content: "hi"}], [], "STOP",
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
    json|ai:Error encoded = encodeResponses((), [{role: ai:USER, content: "hi"}], [], (),
            {temperature: 0.5, maxTokens: 100, stopSequences: ["END"]});
    test:assertTrue(encoded is ai:Error, "configured stopSequences must be refused as well");
}

@test:Config {}
function testResponsesEncodesNormallyWithNoStop() returns error? {
    // The guard must not fire on the ordinary path.
    map<json> body = check encodeResponses((), [{role: ai:USER, content: "hi"}], [], (),
            {temperature: 0.5, maxTokens: 100}).ensureType();
    test:assertTrue(body.hasKey("input"));
    test:assertFalse(body.hasKey("stop"), "no stop field exists in this dialect");
}

// ---- x-api-key is table data, honoured for every vendor ----

@test:Config {}
function testMantleApiKeyHeaderIsEmittedForAnyVendorDeclaringXApiKey() returns error? {
    // REGRESSION: this lived in the Anthropic facade alone, so the SAME table field
    // was honoured there and silently ignored for every other vendor — including a
    // user's routeOverrides. Driven here through a NON-Anthropic vendor to prove the
    // data, not the class, decides.
    MantleEntry entry = {path: "/v1/chat/completions", authHeader: X_API_KEY, codec: CHAT_CODEC};
    Route route = {
        family: MANTLE,
        bareModelId: "zai.glm-5",
        geoPrefix: (),
        effectiveModelId: "zai.glm-5",
        region: "us-east-1",
        partition: "aws",
        mantleEntry: entry
    };
    map<string> headers = commonExtraHeaders(route, (), {apiKey: "secret-key"});
    test:assertEquals(headers["x-api-key"], "secret-key");
}

@test:Config {}
function testMantleApiKeyHeaderIsAbsentForBearerStyleEntries() {
    // A BEARER entry needs nothing extra: the transport's `Authorization: Bearer`
    // already carries the key.
    MantleEntry entry = {path: "/openai/v1/responses", authHeader: BEARER, codec: RESPONSES_CODEC};
    Route route = {
        family: MANTLE,
        bareModelId: "openai.gpt-5.4",
        geoPrefix: (),
        effectiveModelId: "openai.gpt-5.4",
        region: "us-east-1",
        partition: "aws",
        mantleEntry: entry
    };
    map<string> headers = commonExtraHeaders(route, (), {apiKey: "secret-key"});
    test:assertFalse(headers.hasKey("x-api-key"));
}

@test:Config {}
function testMantleApiKeyHeaderIsAbsentForSigV4Credentials() {
    // With SigV4 credentials there is no api key to send — the signature alone must
    // authenticate. Emitting the secret access key here would leak it in a header.
    MantleEntry entry = {path: "/anthropic/v1/messages", authHeader: X_API_KEY, codec: MESSAGES_CODEC};
    Route route = {
        family: MANTLE,
        bareModelId: "anthropic.claude-mythos-5",
        geoPrefix: (),
        effectiveModelId: "anthropic.claude-mythos-5",
        region: "us-east-1",
        partition: "aws",
        mantleEntry: entry
    };
    map<string> headers = commonExtraHeaders(route, (), TEST_CREDS);
    test:assertFalse(headers.hasKey("x-api-key"));
}
