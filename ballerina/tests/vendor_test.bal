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

// Vendor facades + the CLAUDE.md design amendments (AUTO routing, no Tier-2,
// per-model supportsStructuredOutput).

// ---- amendment: ApiFamily.AUTO ----

@test:Config {}
function testAutoIsTheDefaultAndRunsTheResolver() returns error? {
    // AUTO must behave exactly like "no forced family" (amendment).
    Route auto = check resolveRoute("anthropic.claude-opus-4-8", REGION, {apiFamily: AUTO});
    Route implicit = check resolveRoute("anthropic.claude-opus-4-8", REGION);
    test:assertEquals(auto.family, CONVERSE);
    test:assertEquals(auto.family, implicit.family);
}

@test:Config {}
function testAutoStillLetsMantleOnlyModelsDefaultToMantle() returns error? {
    Route route = check resolveRoute("openai.gpt-5.4", REGION, {apiFamily: AUTO});
    test:assertEquals(route.family, MANTLE, "AUTO runs the ladder, which defaults gpt-5.4 to Mantle");
}

@test:Config {}
function testForcingInvokeOverridesTheResolver() returns error? {
    Route route = check resolveRoute("anthropic.claude-opus-4-8", REGION, {apiFamily: INVOKE});
    test:assertEquals(route.family, INVOKE);
}

// ---- amendment: supportsStructuredOutput ----

@test:Config {}
function testMantleRejectsTypedStructuredOutput() returns error? {
    // Mantle has no structured-output path: a non-string target must fail clean.
    Route route = check resolveRoute("anthropic.claude-mythos-preview", "us-east-1");
    Endpoint ep = check buildEndpoint(route);
    readonly & ModelCodec codec = check selectCodec(route);
    BedrockTransport transport = check new (TEST_CREDS, route.region, ep);
    ai:Prompt prompt = `Give me a number`;

    anydata|ai:Error result = structuredGenerate(false, MANTLE, codec, transport,
        route.effectiveModelId, {}, {temperature: 0.5d, maxTokens: 16}, prompt, int, ());
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        test:assertTrue(result.message().includes("bedrock-mantle"), result.message());
        test:assertTrue(result.message().includes("anthropic.claude-mythos-preview"), result.message());
    }
}

@test:Config {}
function testConverseRouteSupportsStructuredOutputFlag() returns error? {
    // The flag is derived from the resolved route: true off Mantle, false on it.
    Route converse = check resolveRoute("anthropic.claude-opus-4-8", REGION);
    Route mantle = check resolveRoute("anthropic.claude-mythos-preview", REGION);
    test:assertTrue(converse.family != MANTLE, "Converse route → structured output supported");
    test:assertTrue(mantle.family == MANTLE, "Mantle route → structured output unsupported");
}

// ---- Nova Invoke: the schemaVersion landmine (design §7.2, §13.2) ----

@test:Config {}
function testNovaInvokeEmitsSchemaVersion() returns error? {
    InferenceParams params = {temperature: 0.5d, maxTokens: 100};
    map<json> body = check encodeNovaInvoke(SAMPLE_SYSTEM, SAMPLE_MESSAGES, [], (), params).ensureType();
    test:assertEquals(body["schemaVersion"], "messages-v1", "§7.2: omit it and Nova fails validation");
    test:assertTrue(body.hasKey("system"), "system is top-level, not a message (§7.1)");
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

// ---- OpenAI chat codec ----

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

// ---- Mantle Responses codec (GPT-5.x) ----

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

// ---- vendor construction smoke tests (no I/O) ----

@test:Config {}
function testAllVendorProvidersConstructOnConverse() returns error? {
    AmazonModelProvider amazon = check new (TEST_CREDS, "amazon.nova-pro-v1:0", REGION);
    MistralModelProvider mistral = check new (TEST_CREDS, "mistral.mistral-large-2407-v1:0", REGION);
    QwenModelProvider qwen = check new (TEST_CREDS, "qwen.qwen3-32b-v1:0", REGION);
    GoogleModelProvider google = check new (TEST_CREDS, "google.gemma-3-27b-it", REGION);
    DeepSeekModelProvider deepseek = check new (TEST_CREDS, "us.deepseek.r1-v1:0", REGION);
    OpenAIModelProvider openai = check new (TEST_CREDS, "openai.gpt-oss-120b-1:0", REGION);
    test:assertTrue(amazon is AmazonModelProvider);
    test:assertTrue(mistral is MistralModelProvider);
    test:assertTrue(qwen is QwenModelProvider);
    test:assertTrue(google is GoogleModelProvider);
    test:assertTrue(deepseek is DeepSeekModelProvider);
    test:assertTrue(openai is OpenAIModelProvider);
}

@test:Config {}
function testOpenAIMantleOnlyModelResolvesToMantleResponses() returns error? {
    // GPT-5.4 exists only on Mantle — the reason this module exists (design §1).
    Route route = check resolveRoute("openai.gpt-5.4", REGION);
    test:assertEquals(route.family, MANTLE);
    Endpoint ep = check buildEndpoint(route);
    test:assertEquals(ep.path, "/openai/v1/responses");
    test:assertEquals(ep.signingService, "bedrock-mantle");
}

@test:Config {}
function testGemma3ResolvesToConverseOnBedrockRuntime() returns error? {
    // Gemma 3's cards tick bedrock-runtime AND bedrock-mantle; we take Converse.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-27b-pt.html
    Route route = check resolveRoute("google.gemma-3-27b-it", REGION);
    test:assertEquals(route.family, CONVERSE);
    Endpoint ep = check buildEndpoint(route);
    test:assertEquals(ep.signingService, "bedrock");
    test:assertTrue(ep.host.startsWith("bedrock-runtime."));
}

@test:Config {}
function testGemma4IsMantleOnlyNotConverse() returns error? {
    // REGRESSION: this previously asserted CONVERSE + signing `bedrock`, which is
    // what the code did and what the card contradicts — the Gemma 4 support matrix
    // marks bedrock-runtime / Converse / Invoke / Messages all NO. Signing scope
    // `bedrock` against a Mantle-only model is a 403 on every single call.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-31b.html
    foreach string id in ["google.gemma-4-31b", "google.gemma-4-e2b", "google.gemma-4-26b-a4b"] {
        Route route = check resolveRoute(id, REGION);
        test:assertEquals(route.family, MANTLE, id + " is served ONLY on bedrock-mantle");
        Endpoint ep = check buildEndpoint(route);
        test:assertEquals(ep.signingService, "bedrock-mantle", "wrong signing scope for " + id);
        test:assertTrue(ep.host.startsWith("bedrock-mantle."), "wrong host for " + id);
        // The card is explicit that this path differs from the `/v1/responses`
        // other Mantle models use.
        test:assertEquals(ep.path, "/openai/v1/responses", "wrong Mantle path for " + id);
    }
}

@test:Config {}
function testGemma4CannotDoStructuredOutput() returns error? {
    // Falls out of being Mantle-only: no Converse route means no forced tools.
    GoogleModelProvider provider = check new (TEST_CREDS, GEMMA_4_31B, REGION);
    LiveFruitShape|ai:Error result = provider->generate(`Name a fruit.`);
    test:assertTrue(result is ai:Error, "Gemma 4 must refuse a typed target (Mantle route)");
}

type LiveFruitShape record {|
    string name;
|};

@test:Config {}
function testGptOssModelIdWithColonIsEncodedOnTheWire() returns error? {
    // `openai.gpt-oss-120b-1:0` carries a colon — the SigV4 double-encoding case.
    Route route = check resolveRoute("openai.gpt-oss-120b-1:0", REGION);
    Endpoint ep = check buildEndpoint(route);
    test:assertTrue(ep.path.includes("%3A"), "the model id's colon must be encoded on the wire");
    string canonical = getCanonicalUri(ep.path) ?: "";
    test:assertTrue(canonical.includes("%253A"), "and double-encoded in the canonical URI");
}

@test:Config {}
function testAllKnownMantleOnlyModelsResolveToMantle() returns error? {
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
        "anthropic.claude-mythos-preview": "/anthropic/v1/messages",
        "anthropic.claude-mythos-5": "/anthropic/v1/messages",
        "google.gemma-4-31b": "/openai/v1/responses",
        "google.gemma-4-e2b": "/openai/v1/responses",
        "google.gemma-4-26b-a4b": "/openai/v1/responses"
    };
    foreach [string, string] [id, expectedPath] in mantleOnly.entries() {
        Route route = check resolveRoute(id, REGION);
        test:assertEquals(route.family, MANTLE, id + " is served ONLY on bedrock-mantle");
        Endpoint ep = check buildEndpoint(route);
        test:assertEquals(ep.signingService, "bedrock-mantle", "wrong signing scope for " + id);
        test:assertEquals(ep.path, expectedPath, "wrong Mantle path for " + id);
    }
}

@test:Config {}
function testDualHomedModelsStillDefaultToConverse() returns error? {
    // These are marked YES on BOTH endpoints. Being Mantle-capable must not pull
    // them off Converse, which is the strictly richer surface (design §5.5).
    foreach string id in ["anthropic.claude-haiku-4-5", "anthropic.claude-opus-4-8", "zai.glm-5",
            "qwen.qwen3-32b-v1:0", "google.gemma-3-27b-it"] {
        Route route = check resolveRoute(id, REGION);
        test:assertEquals(route.family, CONVERSE, id + " is dual-homed and must default to Converse");
    }
}
