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

// Golden-file codec tests (design §13.2). Fixed messages in → asserted body out;
// canned response in → asserted DecodedResponse out.

final ai:ChatMessage[] SAMPLE_MESSAGES = [{role: ai:USER, content: "Hello"}];
final ai:ChatSystemMessage SAMPLE_SYSTEM = {role: ai:SYSTEM, content: "Be brief"};

// ---- Converse encode ----

@test:Config {}
function testConverseHoistsSystemToTopLevelField() returns error? {
    InferenceParams params = {temperature: 0.5, maxTokens: 100};
    map<json> body = check encodeConverse(SAMPLE_SYSTEM, SAMPLE_MESSAGES, [], (), params).ensureType();
    test:assertTrue(body.hasKey("system"), "system must be a top-level field, not a message");
    json system = body["system"];
    test:assertEquals(system, <json>[{"text": "Be brief"}]);
    // Ensure no message carries role:system.
    json[] messages = check body["messages"].ensureType();
    foreach json m in messages {
        map<json> msg = check m.ensureType();
        test:assertNotEquals(msg["role"], "system");
    }
}

@test:Config {}
function testConversePerCallStopOverridesConfiguredStopSequences() returns error? {
    InferenceParams params = {temperature: 0.5, maxTokens: 100, stopSequences: ["CONFIGURED"]};
    map<json> body = check encodeConverse((), SAMPLE_MESSAGES, [], "PERCALL", params).ensureType();
    map<json> inferenceConfig = check body["inferenceConfig"].ensureType();
    test:assertEquals(inferenceConfig["stopSequences"], <json>["PERCALL"], "per-call stop must win outright (§7)");
}

@test:Config {}
function testConverseForwardsAdditionalModelRequestFieldsVerbatim() returns error? {
    InferenceParams params = {temperature: 0.5, maxTokens: 100, additionalModelRequestFields: {"top_k": 200}};
    map<json> body = check encodeConverse((), SAMPLE_MESSAGES, [], (), params).ensureType();
    test:assertEquals(body["additionalModelRequestFields"], <json>{"top_k": 200});
}

@test:Config {}
function testConverseGuardrailIsBodyField() returns error? {
    InferenceParams params = {
        temperature: 0.5,
        maxTokens: 100,
        guardrail: {guardrailIdentifier: "gr-1", guardrailVersion: "DRAFT"}
    };
    map<json> body = check encodeConverse((), SAMPLE_MESSAGES, [], (), params).ensureType();
    map<json> guardrailConfig = check body["guardrailConfig"].ensureType();
    test:assertEquals(guardrailConfig["guardrailIdentifier"], "gr-1");
}

// ---- Invoke-Anthropic vs Mantle Messages encode ----

@test:Config {}
function testInvokeAnthropicEmitsBedrockVersionBodyField() returns error? {
    InferenceParams params = {temperature: 0.5, maxTokens: 100};
    map<json> body = check encodeInvokeAnthropic(SAMPLE_SYSTEM, SAMPLE_MESSAGES, [], (), params).ensureType();
    test:assertEquals(body["anthropic_version"], "bedrock-2023-05-31", "§7.2 required body field");
    test:assertEquals(body["system"], "Be brief", "system is top-level (§7.1)");
}

@test:Config {}
function testMantleMessagesOmitsBedrockVersionBodyField() returns error? {
    // §7.3: Mantle carries anthropic-version in the HEADER, not the body.
    InferenceParams params = {temperature: 0.5, maxTokens: 100};
    map<json> body = check encodeMantleMessages(SAMPLE_SYSTEM, SAMPLE_MESSAGES, [], (), params).ensureType();
    test:assertFalse(body.hasKey("anthropic_version"), "Mantle must NOT emit the Invoke body version field");
}

// ---- Converse decode: usage + stopReason always populated (§7, §13.2) ----

@test:Config {}
function testConverseDecodePopulatesUsageAndStopReason() returns error? {
    json canned = {
        "output": {"message": {"role": "assistant", "content": [{"text": "Hi there"}]}},
        "stopReason": "end_turn",
        "usage": {"inputTokens": 10, "outputTokens": 5, "totalTokens": 15}
    };
    DecodedResponse decoded = check decodeConverse(canned);
    test:assertEquals(decoded.message.content, "Hi there");
    test:assertEquals(decoded.usage.inputTokens, 10);
    test:assertEquals(decoded.usage.outputTokens, 5);
    test:assertEquals(decoded.stopReason, "end_turn");
}

@test:Config {}
function testConverseDecodeSurfacesGuardrailIntervention() returns error? {
    // §9.5: never silently drop the fact a guardrail fired.
    json canned = {
        "output": {"message": {"role": "assistant", "content": [{"text": ""}]}},
        "stopReason": "guardrail_intervened",
        "usage": {"inputTokens": 3, "outputTokens": 0}
    };
    DecodedResponse decoded = check decodeConverse(canned);
    test:assertEquals(decoded.guardrailAction, INTERVENED);
}

@test:Config {}
function testConverseDecodeExtractsToolUse() returns error? {
    json canned = {
        "output": {
            "message": {
                "role": "assistant",
                "content": [{"toolUse": {"toolUseId": "tu_1", "name": "getWeather", "input": {"city": "NYC"}}}]
            }
        },
        "stopReason": "tool_use",
        "usage": {"inputTokens": 8, "outputTokens": 12}
    };
    DecodedResponse decoded = check decodeConverse(canned);
    ai:FunctionCall[] toolCalls = check decoded.message.toolCalls.ensureType();
    test:assertEquals(toolCalls[0].name, "getWeather");
    test:assertEquals(toolCalls[0].arguments, <map<json>>{"city": "NYC"});
    test:assertEquals(toolCalls[0].id, "tu_1");
}

// ---- Anthropic Messages decode ----

@test:Config {}
function testAnthropicMessagesDecodePopulatesUsageStopReasonAndId() returns error? {
    json canned = {
        "id": "msg_01",
        "role": "assistant",
        "content": [{"type": "text", "text": "Hello!"}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 7, "output_tokens": 3}
    };
    DecodedResponse decoded = check decodeAnthropicMessages(canned);
    test:assertEquals(decoded.message.content, "Hello!");
    test:assertEquals(decoded.responseId, "msg_01");
    test:assertEquals(decoded.usage.inputTokens, 7);
    test:assertEquals(decoded.usage.outputTokens, 3);
    test:assertEquals(decoded.stopReason, "end_turn");
}

@test:Config {}
function testInvokeAnthropicDecodeSurfacesBodyGuardrailAction() returns error? {
    // §9.5 / InvokeModel API ref: the fired signal is a response-BODY field.
    json canned = {
        "id": "msg_gr",
        "role": "assistant",
        "content": [{"type": "text", "text": "blocked"}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 2, "output_tokens": 1},
        "amazon-bedrock-guardrailAction": "INTERVENED"
    };
    DecodedResponse decoded = check decodeAnthropicMessages(canned);
    test:assertEquals(decoded.guardrailAction, INTERVENED);
}

@test:Config {}
function testAnthropicMessagesDecodeExtractsToolUse() returns error? {
    json canned = {
        "id": "msg_02",
        "role": "assistant",
        "content": [{"type": "tool_use", "id": "toolu_1", "name": "lookup", "input": {"q": "x"}}],
        "stop_reason": "tool_use",
        "usage": {"input_tokens": 4, "output_tokens": 9}
    };
    DecodedResponse decoded = check decodeAnthropicMessages(canned);
    ai:FunctionCall[] toolCalls = check decoded.message.toolCalls.ensureType();
    test:assertEquals(toolCalls[0].name, "lookup");
    test:assertEquals(toolCalls[0].id, "toolu_1");
}

// ---- Mistral: two dialects, one vendor prefix ----

@test:Config {}
function testMistralTextEncodesPromptNotMessages() returns error? {
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-text-completion.html
    map<json> body = check encodeMistralText((), SAMPLE_MESSAGES, [], (),
            {temperature: 0.5, maxTokens: 100}).ensureType();
    test:assertTrue(body.hasKey("prompt"), "the text dialect sends `prompt`, never `messages`");
    test:assertFalse(body.hasKey("messages"));
    test:assertEquals(body["prompt"], <json>"<s>[INST] Hello [/INST]",
            "user text must sit inside Mistral's [INST] template");
}

@test:Config {}
function testMistralTextFoldsSystemIntoTheFirstInstructionBlock() returns error? {
    // The template has no system slot; system must never become a role:system
    // message (§7.1), so it is prepended to the first [INST] block.
    map<json> body = check encodeMistralText(SAMPLE_SYSTEM, SAMPLE_MESSAGES, [], (),
            {temperature: 0.5, maxTokens: 100}).ensureType();
    test:assertEquals(body["prompt"], <json>"<s>[INST] Be brief\n\nHello [/INST]");
}

@test:Config {}
function testMistralTextRendersMultiTurnTemplate() returns error? {
    ai:ChatMessage[] messages = [
        {role: ai:USER, content: "First?"},
        {role: ai:ASSISTANT, content: "Answer."},
        {role: ai:USER, content: "Second?"}
    ];
    map<json> body = check encodeMistralText((), messages, [], (),
            {temperature: 0.5, maxTokens: 100}).ensureType();
    // Assistant turns sit OUTSIDE the [INST] tokens and are closed with </s>.
    test:assertEquals(body["prompt"], <json>"<s>[INST] First? [/INST] Answer.</s>[INST] Second? [/INST]");
}

@test:Config {}
function testMistralTextDecodePopulatesUsageAndStopReason() returns error? {
    json canned = {"outputs": [{"text": "hi there", "stop_reason": "length"}]};
    DecodedResponse decoded = check decodeMistralText(canned);
    test:assertEquals(decoded.message.content, "hi there");
    // This dialect returns no token counts at all — usage must still be populated.
    test:assertEquals(decoded.usage, {inputTokens: 0, outputTokens: 0});
    test:assertEquals(decoded.stopReason, "length");
}

@test:Config {}
function testMistralChatDecodeReadsStopReasonNotFinishReason() returns error? {
    // The regression that motivated splitting Mistral off the OpenAI codec: this
    // dialect spells it `stop_reason`, so the OpenAI decoder left stopReason empty.
    json canned = {
        "choices": [{"index": 0, "message": {"role": "assistant", "content": "hello"}, "stop_reason": "stop"}]
    };
    DecodedResponse decoded = check decodeMistralChat(canned);
    test:assertEquals(decoded.stopReason, "stop");
    test:assertEquals(decoded.message.content, "hello");
    test:assertEquals(decoded.usage, {inputTokens: 0, outputTokens: 0});
}

@test:Config {}
function testMistralChatKeepsSystemAsALeadingMessage() returns error? {
    // Unlike Converse/Anthropic, this dialect DOES model system as a role (per the
    // AWS page), so the hoisted system is re-added as the first message.
    map<json> body = check encodeMistralChat(SAMPLE_SYSTEM, SAMPLE_MESSAGES, [], (),
            {temperature: 0.5, maxTokens: 100}).ensureType();
    json[] messages = check body["messages"].ensureType();
    map<json> first = check messages[0].ensureType();
    test:assertEquals(first["role"], "system");
    test:assertEquals(first["content"], "Be brief");
}

@test:Config {}
function testMistralDialectIsSelectedByModelId() returns error? {
    // mistral-large-2402 is text-completion but mistral-large-2407 is chat: same
    // family, four months apart, opposite wire shapes.
    test:assertTrue(usesMistralTextDialect("mistral.mistral-large-2402-v1:0"));
    test:assertFalse(usesMistralTextDialect("mistral.mistral-large-2407-v1:0"));
    test:assertTrue(usesMistralTextDialect("mistral.mistral-7b-instruct-v0:2"));
    test:assertTrue(usesMistralTextDialect("mistral.mixtral-8x7b-instruct-v0:1"));
    // An id we have never seen defaults to the chat dialect, not the legacy one.
    test:assertFalse(usesMistralTextDialect("mistral.mistral-large-9999-v1:0"));
}

@test:Config {}
function testSelectInvokeCodecPicksTheRightMistralDialect() returns error? {
    readonly & ModelCodec text = check selectInvokeCodec("mistral.mistral-7b-instruct-v0:2", ());
    test:assertEquals(text.toolChoice, NO_TOOL_CHOICE);
    readonly & ModelCodec chat = check selectInvokeCodec("mistral.mistral-large-2407-v1:0", ());
    test:assertEquals(chat.toolChoice, MISTRAL_TOOL_CHOICE);
    // modelSchema is the escape hatch when the id cannot say (imported ARNs).
    readonly & ModelCodec forced = check selectInvokeCodec("my-imported-thing", MISTRAL_TEXT);
    test:assertEquals(forced.toolChoice, NO_TOOL_CHOICE);
}
