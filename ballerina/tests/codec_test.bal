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
