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

// The vendor facades. The public surface is cut by ENDPOINT: a
// `BedrockRuntime<V>ModelProvider` can only ever reach `bedrock-runtime` and a
// `BedrockMantle<V>ModelProvider` only `bedrock-mantle`, so "which endpoint did my
// model end up on" is answered by the type at the call site rather than by a
// routing ladder at runtime.

// ---- construction smoke tests for all fourteen classes (no I/O) ----

@test:Config {}
function testEveryRuntimeProviderConstructs() returns error? {
    BedrockCommonModelProvider _ = check new ("amazon.nova-pro-v1:0", TEST_CREDS, REGION);
    BedrockRuntimeAnthropicModelProvider _ = check new (CLAUDE_SONNET_4_6, TEST_CREDS, REGION);
    BedrockRuntimeOpenAIModelProvider _ = check new (GPT_OSS_120B, TEST_CREDS, REGION);
    BedrockRuntimeAmazonModelProvider _ = check new (NOVA_PRO, TEST_CREDS, REGION);
    BedrockRuntimeMistralModelProvider _ = check new (MISTRAL_LARGE_2407, TEST_CREDS, REGION);
    BedrockRuntimeQwenModelProvider _ = check new (QWEN3_32B, TEST_CREDS, REGION);
    BedrockRuntimeGoogleModelProvider _ = check new (GEMMA_3_27B_IT, TEST_CREDS, REGION);
    BedrockRuntimeDeepSeekModelProvider _ = check new (DEEPSEEK_R1, TEST_CREDS, REGION);
}

@test:Config {}
function testEveryMantleProviderConstructs() returns error? {
    // Six, not seven: Amazon has no model on bedrock-mantle, so there is no
    // `BedrockMantleAmazonModelProvider` to construct.
    BedrockMantleAnthropicModelProvider _ = check new (MANTLE_CLAUDE_OPUS_5, TEST_CREDS, REGION);
    BedrockMantleOpenAIModelProvider _ = check new (MANTLE_GPT_5_5, TEST_CREDS, REGION);
    BedrockMantleMistralModelProvider _ = check new (MANTLE_MISTRAL_LARGE_3, TEST_CREDS, REGION);
    BedrockMantleQwenModelProvider _ = check new (MANTLE_QWEN3_32B, TEST_CREDS, REGION);
    BedrockMantleGoogleModelProvider _ = check new (MANTLE_GEMMA_4_31B, TEST_CREDS, REGION);
    BedrockMantleDeepSeekModelProvider _ = check new (MANTLE_DEEPSEEK_V3_2, TEST_CREDS, REGION);
}

@test:Config {}
function testEveryRuntimeShapeAVendorClassOffersConstructs() returns error? {
    // The per-vendor `*RuntimeApi` union subtypes are the module's statement about
    // which shapes that vendor is served in. Each one must actually construct — a
    // shape in the type but with no converter behind it is a runtime failure on a
    // type the compiler said was fine.
    AnthropicRuntimeApi[] apis = [CONVERSE, INVOKE, MESSAGES];
    foreach AnthropicRuntimeApi api in apis {
        BedrockRuntimeAnthropicModelProvider _ =
            check new ("anthropic.claude-opus-5", TEST_CREDS, REGION, api);
    }
    OpenAIRuntimeApi[] openAIApis = [CONVERSE, INVOKE, CHAT_COMPLETIONS, RESPONSES];
    foreach OpenAIRuntimeApi api in openAIApis {
        BedrockRuntimeOpenAIModelProvider _ = check new (GPT_OSS_120B, TEST_CREDS, REGION, api);
    }
    QwenRuntimeApi[] chatApis = [CONVERSE, INVOKE, CHAT_COMPLETIONS];
    foreach QwenRuntimeApi api in chatApis {
        BedrockRuntimeQwenModelProvider _ = check new (QWEN3_32B, TEST_CREDS, REGION, api);
        BedrockRuntimeDeepSeekModelProvider _ = check new (DEEPSEEK_V3_2, TEST_CREDS, REGION, api);
        BedrockRuntimeMistralModelProvider _ = check new (MISTRAL_LARGE_2407, TEST_CREDS, REGION, api);
        BedrockRuntimeGoogleModelProvider _ = check new (GEMMA_3_27B_IT, TEST_CREDS, REGION, api);
    }
    AmazonRuntimeApi[] coreApis = [CONVERSE, INVOKE];
    foreach AmazonRuntimeApi api in coreApis {
        BedrockRuntimeAmazonModelProvider _ = check new (NOVA_PRO, TEST_CREDS, REGION, api);
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

// ---- Responses converter (GPT-5.x, Gemma 4) ----

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

// ---- Mantle: per-model paths, all table data ----

@test:Config {}
function testOpenAIMantleOnlyModelResolvesToTheResponsesPath() returns error? {
    // GPT-5.4 exists only on Mantle — the reason the Mantle classes exist.
    Route route = check resolveMantleRoute("openai.gpt-5.4", REGION);
    Endpoint ep = check buildEndpoint(route);
    test:assertEquals(ep.path, "/openai/v1/responses");
    test:assertEquals(ep.signingService, "bedrock-mantle");
}

@test:Config {}
function testGemma3AndGemma4SplitAcrossTwoMantlePathFamilies() returns error? {
    // One vendor prefix, two Mantle dialects: Gemma 3 speaks Chat Completions on
    // `/v1` and Gemma 4 speaks Responses on `/openai/v1`. This is exactly why the
    // path is per-model table data and never derived from the prefix.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-27b-pt.html
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-31b.html
    Route gemma3 = check resolveMantleRoute("google.gemma-3-27b-it", REGION);
    Endpoint ep3 = check buildEndpoint(gemma3);
    test:assertEquals(ep3.path, "/v1/chat/completions", "Gemma 3 uses Chat Completions, not Responses");
    test:assertEquals(gemma3.api, CHAT_COMPLETIONS);

    Route gemma4 = check resolveMantleRoute("google.gemma-4-31b", REGION);
    Endpoint ep4 = check buildEndpoint(gemma4);
    test:assertEquals(ep4.path, "/openai/v1/responses");
    test:assertEquals(gemma4.api, RESPONSES);
}

@test:Config {}
function testGemma3IsAlsoReachableOnTheRuntimeClass() returns error? {
    // Gemma 3 is dual-homed, so the runtime class reaches it on `bedrock-runtime`
    // with the `bedrock` signing scope. Nothing about the Mantle entry changes that.
    Route runtime = check resolveRuntimeRoute("google.gemma-3-27b-it", REGION, CONVERSE);
    Endpoint ep = check buildEndpoint(runtime);
    test:assertEquals(ep.signingService, "bedrock");
    test:assertTrue(ep.host.startsWith("bedrock-runtime."));
}

@test:Config {}
function testGemma4IsMantleOnlyAndSignsAsMantle() returns error? {
    // The Gemma 4 support matrix marks bedrock-runtime / Converse / Invoke / Messages
    // all NO, and there is no `BedrockRuntimeGoogleModelProvider` id for it. Signing
    // scope `bedrock` against a Mantle-only model is a 403 on every single call.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-31b.html
    foreach string id in ["google.gemma-4-31b", "google.gemma-4-e2b", "google.gemma-4-26b-a4b"] {
        Route route = check resolveMantleRoute(id, REGION);
        test:assertEquals(route.endpoint, MANTLE, id + " is served ONLY on bedrock-mantle");
        Endpoint ep = check buildEndpoint(route);
        test:assertEquals(ep.signingService, "bedrock-mantle", "wrong signing scope for " + id);
        test:assertTrue(ep.host.startsWith("bedrock-mantle."), "wrong host for " + id);
        // The card is explicit that this path differs from the `/v1/responses`
        // other Mantle models use.
        test:assertEquals(ep.path, "/openai/v1/responses", "wrong Mantle path for " + id);
    }
}

@test:Config {}
function testGemma4CanStillForceAToolOnItsResponsesPath() returns error? {
    // NOT a structured-output refusal any more. `structuredOutputStyleFor` refuses
    // only Mantle + MESSAGES; the OpenAI-compatible Mantle shapes keep tool forcing,
    // and Grok 4.3's card — structured outputs supported on bedrock-mantle — is the
    // evidence a blanket "Mantle has none" would contradict.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-xai-grok-4-3.html
    Route route = check resolveMantleRoute("google.gemma-4-31b", REGION);
    readonly & ModelConverter converter = check selectConverter(route);
    test:assertEquals(structuredOutputStyleFor(route.endpoint, route.api, converter.toolChoice),
            TOOL_FORCING);
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
function testAllKnownMantleOnlyModelsResolveOnTheMantleEndpoint() returns error? {
    // Cross-checked against AWS's endpoint-availability table, which is the only
    // page listing runtime-vs-mantle for every model in one place. Each id below is
    // marked `bedrock-runtime: NO` there and verified against its own card.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/models-endpoint-availability.html
    map<string> mantleOnly = {
        "openai.gpt-5.5": "/openai/v1/responses",
        "openai.gpt-5.4": "/openai/v1/responses",
        "openai.gpt-5.6-sol": "/openai/v1/responses",
        "openai.gpt-5.6-terra": "/openai/v1/responses",
        "openai.gpt-5.6-luna": "/openai/v1/responses",
        "google.gemma-4-31b": "/openai/v1/responses",
        "google.gemma-4-e2b": "/openai/v1/responses",
        "google.gemma-4-26b-a4b": "/openai/v1/responses"
    };
    foreach [string, string] [id, expectedPath] in mantleOnly.entries() {
        Route route = check resolveMantleRoute(id, REGION);
        test:assertEquals(route.endpoint, MANTLE, id + " is served ONLY on bedrock-mantle");
        Endpoint ep = check buildEndpoint(route);
        test:assertEquals(ep.signingService, "bedrock-mantle", "wrong signing scope for " + id);
        test:assertEquals(ep.path, expectedPath, "wrong Mantle path for " + id);
    }
}

@test:Config {}
function testDualHomedModelsResolveOnBothEndpointsWithNoTableOnTheRuntimeSide() returns error? {
    // The asymmetry the design rests on: a Mantle route needs a table row because its
    // base path is per-model data, while the SAME model on bedrock-runtime resolves
    // with no lookup at all, because there the path is a pure function of the shape.
    foreach string id in ["anthropic.claude-haiku-4-5", "anthropic.claude-opus-4-8",
            "anthropic.claude-opus-5", "anthropic.claude-sonnet-5", "zai.glm-5", "deepseek.v3.2",
            "mistral.mistral-large-3-675b-instruct", "qwen.qwen3-coder-480b-a35b-v1:0",
            "qwen.qwen3-32b-v1:0", "google.gemma-3-27b-it", "google.gemma-3-12b-it",
            "google.gemma-3-4b-it", "openai.gpt-oss-120b-1:0"] {
        Route mantle = check resolveMantleRoute(id, REGION);
        test:assertEquals(mantle.endpoint, MANTLE, id);
        Route runtime = check resolveRuntimeRoute(id, REGION, CONVERSE);
        test:assertEquals(runtime.endpoint, RUNTIME, id);
        test:assertEquals((check buildEndpoint(runtime)).path,
                string `/model/${encodePathSegment(id)}/converse`, id);
    }
}

@test:Config {}
function testRuntimeOnlyModelsHaveNoMantleEntryAtAll() returns error? {
    // The table-driven safety: we reach Mantle only where we hold a verified wire
    // shape, never by guessing. sonnet-4-6 is genuinely runtime-only (its card marks
    // bedrock-mantle NO); nova-pro simply has no entry.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-4-6.html
    foreach string id in ["anthropic.claude-sonnet-4-6", "amazon.nova-pro-v1:0",
            "mistral.mistral-large-2407-v1:0"] {
        test:assertFalse(MANTLE_CAPABLE.hasKey(id), id + " must have no Mantle entry");
        test:assertTrue(resolveMantleRoute(id, REGION) is error, id + " must be refused on Mantle");
        Route runtime = check resolveRuntimeRoute(id, REGION, CONVERSE);
        test:assertEquals(runtime.endpoint, RUNTIME, id);
    }
}
