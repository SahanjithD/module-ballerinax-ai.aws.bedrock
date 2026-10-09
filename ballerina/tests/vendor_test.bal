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

import ballerina/test;

// The vendor facades: one `Runtime<V>ModelProvider` per vendor, on `bedrock-runtime`.

// ---- construction smoke tests for every class (no I/O) ----

@test:Config {}
function testEveryRuntimeProviderConstructs() returns error? {
    ConverseModelProvider _ = check new ("amazon.nova-pro-v1:0", TEST_CREDS, REGION);
    RuntimeAnthropicModelProvider _ = check new (CLAUDE_SONNET_4_6, TEST_CREDS, REGION);
    RuntimeOpenAIModelProvider _ = check new (GPT_OSS_120B, TEST_CREDS, REGION);
    RuntimeAmazonModelProvider _ = check new (NOVA_PRO, TEST_CREDS, REGION);
    RuntimeMistralModelProvider _ = check new (MISTRAL_LARGE_2407, TEST_CREDS, REGION);
    RuntimeQwenModelProvider _ = check new (QWEN3_32B, TEST_CREDS, REGION);
    RuntimeGoogleModelProvider _ = check new (GEMMA_3_27B_IT, TEST_CREDS, REGION);
    RuntimeDeepSeekModelProvider _ = check new (DEEPSEEK_R1, TEST_CREDS, REGION);
}

@test:Config {}
function testEveryRuntimeShapeAVendorClassOffersConstructs() returns error? {
    // The per-vendor `*RuntimeApi` union subtypes are the module's statement about
    // which shapes that vendor is served in. Each one must actually construct — a
    // shape in the type but with no converter behind it is a runtime failure on a
    // type the compiler said was fine.
    AnthropicRuntimeApi[] apis = [CONVERSE, INVOKE, MESSAGES];
    foreach AnthropicRuntimeApi api in apis {
        RuntimeAnthropicModelProvider _ =
            check new ("anthropic.claude-opus-5", TEST_CREDS, REGION, api);
    }
    OpenAIRuntimeApi[] openAIApis = [CONVERSE, INVOKE, CHAT_COMPLETIONS, RESPONSES];
    foreach OpenAIRuntimeApi api in openAIApis {
        RuntimeOpenAIModelProvider _ = check new (GPT_OSS_120B, TEST_CREDS, REGION, api);
    }
    QwenRuntimeApi[] chatApis = [CONVERSE, INVOKE, CHAT_COMPLETIONS];
    foreach QwenRuntimeApi api in chatApis {
        RuntimeQwenModelProvider _ = check new (QWEN3_32B, TEST_CREDS, REGION, api);
        RuntimeDeepSeekModelProvider _ = check new (DEEPSEEK_V3_2, TEST_CREDS, REGION, api);
        RuntimeMistralModelProvider _ = check new (MISTRAL_LARGE_2407, TEST_CREDS, REGION, api);
        RuntimeGoogleModelProvider _ = check new (GEMMA_3_27B_IT, TEST_CREDS, REGION, api);
    }
    AmazonRuntimeApi[] coreApis = [CONVERSE, INVOKE];
    foreach AmazonRuntimeApi api in coreApis {
        RuntimeAmazonModelProvider _ = check new (NOVA_PRO, TEST_CREDS, REGION, api);
    }
}

@test:Config {}
function testGemmaOnInvokeSpeaksTheOpenAiShapedDialect() returns error? {
    // Gemma's InvokeModel body is OpenAI-shaped, not a Google-specific one: the model
    // card's own Invoke sample posts `{"messages": [...], "max_tokens": N}`. This test
    // pins the converter choice, because the `google.` prefix landing on the OpenAI
    // chat converter looks like a mistake until you have read that card.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-27b-pt.html
    Route route = check resolveRuntimeRoute(GEMMA_3_27B_IT, REGION, INVOKE);
    readonly & ModelConverter converter = check selectConverter(route);
    test:assertEquals(converter.dialect, "OpenAI Chat Completions (InvokeModel)");
}

// ---- Nova Invoke: the schemaVersion landmine ----

@test:Config {}
function testNovaInvokeEmitsSchemaVersion() returns error? {
    InferenceParams params = {temperature: 0.5d, maxTokens: 100};
    map<json> body = check encodeNovaInvoke(SAMPLE_SYSTEM, SAMPLE_MESSAGES, [], (), params).ensureType();
    test:assertEquals(body["schemaVersion"], "messages-v1", "omit it and Nova fails validation");
    test:assertTrue(body.hasKey("system"), "system is top-level, not a message");
    test:assertFalse(body.hasKey("anthropic_version"), "Nova must not carry the Anthropic body field");
}

@test:Config {}
function testNovaDecodeSharesConverseShape() returns error? {
    json canned = {
        "output": {"message": {"role": "assistant", "content": [{"text": "Nova here"}]}},
        "stopReason": "end_turn",
        "usage": {"inputTokens": 4, "outputTokens": 2}
    };
    DecodedResponse decoded = check decodeConverse(canned);
    test:assertEquals(decoded.message.content, "Nova here");
    test:assertEquals(decoded.usage.inputTokens, 4);
    test:assertEquals(decoded.stopReason, "end_turn");
}

// ---- OpenAI chat converter ----

@test:Config {}
function testOpenAIChatEmitsSystemAsMessageRole() returns error? {
    // Unlike Converse/Anthropic, the OpenAI wire format DOES use role:system.
    InferenceParams params = {temperature: 0.5d, maxTokens: 100};
    map<json> body = check encodeOpenAIChat(SAMPLE_SYSTEM, SAMPLE_MESSAGES, [], (), params).ensureType();
    json[] messages = check body["messages"].ensureType();
    map<json> first = check messages[0].ensureType();
    test:assertEquals(first["role"], "system");
    test:assertEquals(first["content"], "Be brief");
}

@test:Config {}
function testOpenAIChatDecodePopulatesUsageAndStopReason() returns error? {
    json canned = {
        "id": "chatcmpl-1",
        "choices": [{"message": {"role": "assistant", "content": "Hi"}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 9, "completion_tokens": 4}
    };
    DecodedResponse decoded = check decodeOpenAIChat(canned);
    test:assertEquals(decoded.message.content, "Hi");
    test:assertEquals(decoded.usage.inputTokens, 9);
    test:assertEquals(decoded.usage.outputTokens, 4);
    test:assertEquals(decoded.stopReason, "stop");
    test:assertEquals(decoded.responseId, "chatcmpl-1");
}

// ---- Responses converter ----

@test:Config {}
function testResponsesDecodePopulatesUsageAndStopReason() returns error? {
    json canned = {
        "id": "resp_1",
        "status": "completed",
        "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Yo"}]}],
        "usage": {"input_tokens": 6, "output_tokens": 2}
    };
    DecodedResponse decoded = check decodeResponses(canned);
    test:assertEquals(decoded.message.content, "Yo");
    test:assertEquals(decoded.usage.inputTokens, 6);
    test:assertEquals(decoded.usage.outputTokens, 2);
    test:assertEquals(decoded.stopReason, "completed");
    test:assertEquals(decoded.responseId, "resp_1");
}

@test:Config {}
function testResponsesEncodesSystemAsInstructions() returns error? {
    InferenceParams params = {temperature: 0.5d, maxTokens: 100};
    map<json> body = check encodeResponses(SAMPLE_SYSTEM, SAMPLE_MESSAGES, [], (), params).ensureType();
    test:assertEquals(body["instructions"], "Be brief");
    test:assertEquals(body["max_output_tokens"], 100);
}

@test:Config {}
function testGemma3ResolvesOnTheRuntimeEndpoint() returns error? {
    Route runtime = check resolveRuntimeRoute("google.gemma-3-27b-it", REGION, CONVERSE);
    Endpoint ep = check buildEndpoint(runtime);
    test:assertEquals(ep.signingService, "bedrock");
    test:assertTrue(ep.host.startsWith("bedrock-runtime."));
}

@test:Config {}
function testGptOssModelIdWithColonIsEncodedOnTheWire() returns error? {
    // `openai.gpt-oss-120b-1:0` carries a colon — the SigV4 double-encoding case. It
    // only lands in the URI on the path-addressed shapes, so exercise CONVERSE.
    Route route = check resolveRuntimeRoute("openai.gpt-oss-120b-1:0", REGION, CONVERSE);
    Endpoint ep = check buildEndpoint(route);
    test:assertTrue(ep.path.includes("%3A"), "the model id's colon must be encoded on the wire");
    string canonical = getCanonicalUri(ep.path);
    test:assertTrue(canonical.includes("%253A"), "and double-encoded in the canonical URI");
}

@test:Config {}
function testRuntimeIdsResolveWithNoLookupTable() returns error? {
    // On bedrock-runtime the path is a pure function of the shape, so any id
    // resolves with no lookup at all.
    foreach string id in ["anthropic.claude-haiku-4-5", "anthropic.claude-opus-4-8",
            "anthropic.claude-opus-5", "anthropic.claude-sonnet-5", "zai.glm-5", "deepseek.v3.2",
            "mistral.mistral-large-3-675b-instruct", "qwen.qwen3-coder-480b-a35b-v1:0",
            "qwen.qwen3-32b-v1:0", "google.gemma-3-27b-it", "google.gemma-3-12b-it",
            "google.gemma-3-4b-it", "openai.gpt-oss-120b-1:0"] {
        Route runtime = check resolveRuntimeRoute(id, REGION, CONVERSE);
        test:assertEquals((check buildEndpoint(runtime)).path,
                string `/model/${encodePathSegment(id)}/converse`, id);
    }
}
