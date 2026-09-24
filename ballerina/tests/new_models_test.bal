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

// Routing for the flagship/workhorse ids carried by the enums. Each pins a fact from
// that model's card that a wrong id or a wrong endpoint assumption would violate.
//
// The enums now come in PAIRS, and the difference between them is the point:
// `<V>RuntimeModel` carries the `bedrock-runtime` id (CRIS-prefixed where the model
// needs it) and `<V>MantleModel` carries the `bedrock-mantle` id (bare, always).

@test:Config {}
function testDeepSeekV32IsReachableOnBothEndpointsUnderTheSameId() returns error? {
    // The card marks In-Region YES, so the BARE id is callable (the opposite of R1,
    // which needs the `us.` CRIS prefix), and the two endpoints publish it under one
    // id — so neither side rewrites it.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-v3-2.html
    Route runtime = check resolveRuntimeRoute(DEEPSEEK_V3_2, "us-east-1", CONVERSE);
    test:assertEquals(runtime.endpoint, RUNTIME);
    test:assertEquals(runtime.effectiveModelId, "deepseek.v3.2");

    Route mantle = check resolveMantleRoute(MANTLE_DEEPSEEK_V3_2, "us-east-1");
    test:assertEquals(mantle.endpoint, MANTLE);
    test:assertEquals(mantle.effectiveModelId, "deepseek.v3.2");
    test:assertEquals(mantle.shape, CHAT_COMPLETIONS);
}

@test:Config {}
function testMistralLarge3IsReachableOnBothEndpoints() returns error? {
    Route runtime = check resolveRuntimeRoute(MISTRAL_LARGE_3, "us-east-1", CONVERSE);
    test:assertEquals(runtime.effectiveModelId, "mistral.mistral-large-3-675b-instruct");
    Route mantle = check resolveMantleRoute(MANTLE_MISTRAL_LARGE_3, "us-east-1");
    test:assertEquals(mantle.endpoint, MANTLE);
    test:assertEquals(mantle.effectiveModelId, "mistral.mistral-large-3-675b-instruct");
}

@test:Config {}
function testQwen3Coder480BUsesItsOwnIdOnMantle() returns error? {
    // The enums carry the bedrock-RUNTIME id on BOTH sides — `MANTLE_CAPABLE` is
    // keyed by it — and the Mantle resolver performs the swap. Getting this backwards
    // sends an id Mantle does not know, so both halves are asserted.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-coder-480b-a35b-instruct.html
    Route mantle = check resolveMantleRoute(MANTLE_QWEN3_CODER_480B, "us-east-1");
    test:assertEquals(mantle.effectiveModelId, "qwen.qwen3-coder-480b-a35b-instruct",
            "Mantle has its own id for this model");
    test:assertEquals(mantle.bareModelId, "qwen.qwen3-coder-480b-a35b-v1:0", "lookup key stays the runtime id");

    Route runtime = check resolveRuntimeRoute(QWEN3_CODER_480B, "us-east-1", CONVERSE);
    test:assertEquals(runtime.effectiveModelId, "qwen.qwen3-coder-480b-a35b-v1:0");
}

@test:Config {}
function testQwen332bUsesItsOwnIdOnMantle() returns error? {
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-32b.html
    Route mantle = check resolveMantleRoute(MANTLE_QWEN3_32B, REGION);
    test:assertEquals(mantle.effectiveModelId, "qwen.qwen3-32b",
            "Mantle serves this model under its own id");
    test:assertEquals(mantle.bareModelId, "qwen.qwen3-32b-v1:0", "the lookup key stays the runtime id");

    Route runtime = check resolveRuntimeRoute(QWEN3_32B, REGION, CONVERSE);
    test:assertEquals(runtime.effectiveModelId, "qwen.qwen3-32b-v1:0",
            "the runtime surface keeps the runtime id");
}

@test:Config {}
function testClaudeSonnet5AndOpus5UseTheMessagesPathOnMantle() returns error? {
    // Both are dual-homed (bedrock-runtime YES + bedrock-mantle YES), Messages API,
    // same id on both endpoints — so the Mantle side must not rewrite the id.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-5.html
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html
    map<string> ids = {
        [MANTLE_CLAUDE_SONNET_5]: "anthropic.claude-sonnet-5",
        [MANTLE_CLAUDE_OPUS_5]: "anthropic.claude-opus-5"
    };
    foreach [string, string] [id, wireId] in ids.entries() {
        Route route = check resolveMantleRoute(id, "us-east-1");
        MantleEntry entry = check route.mantleEntry.ensureType();
        test:assertEquals(check mantlePathFor(entry.basePath, route.shape), "/anthropic/v1/messages", id);
        test:assertEquals(route.shape, MESSAGES, id);
        test:assertEquals(NATIVE_MESSAGES_CONVERTER.toolChoice, ANTHROPIC_TOOL_CHOICE);
        test:assertTrue(usesApiKeyHeader(route.shape), id);
        test:assertEquals(route.effectiveModelId, wireId, "the card lists no separate Mantle id");
    }
}

@test:Config {}
function testTheRuntimeAnthropicEnumCarriesCrisPrefixedIds() returns error? {
    // Current Claude models are served on bedrock-runtime through cross-region
    // inference profiles only — a BARE id there fails with "on-demand throughput
    // isn't supported" — so the RUNTIME enum members carry `us.` and the MANTLE ones
    // never do.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html
    AnthropicRuntimeModel[] ids = [CLAUDE_OPUS_5, CLAUDE_OPUS_4_8, CLAUDE_SONNET_5,
            CLAUDE_SONNET_4_6, CLAUDE_HAIKU_4_5];
    foreach AnthropicRuntimeModel id in ids {
        Route route = check resolveRuntimeRoute(id, "us-east-1", CONVERSE);
        test:assertEquals(route.geoPrefix, "us", id + " must carry a CRIS prefix on bedrock-runtime");
        test:assertEquals(route.effectiveModelId, id, "the prefix must survive onto the wire");
    }
    AnthropicMantleModel[] mantleIds = [MANTLE_CLAUDE_OPUS_5, MANTLE_CLAUDE_OPUS_4_8,
            MANTLE_CLAUDE_SONNET_5, MANTLE_CLAUDE_HAIKU_4_5];
    foreach AnthropicMantleModel id in mantleIds {
        Route route = check resolveMantleRoute(id, "us-east-1");
        test:assertEquals(route.geoPrefix, (), id + " must be bare for bedrock-mantle");
    }
}

@test:Config {}
function testClaudeOpus5AcceptsItsGeoAndGlobalProfilesOnTheRuntimeEndpoint() returns error? {
    // The card lists `us.`/`eu.`/`au.` geo ids and `global.` — all must strip for
    // lookup and re-apply on the wire.
    foreach string id in ["us.anthropic.claude-opus-5", "eu.anthropic.claude-opus-5",
            "au.anthropic.claude-opus-5", "global.anthropic.claude-opus-5"] {
        Route route = check resolveRuntimeRoute(id, "us-east-1", CONVERSE);
        test:assertEquals(route.bareModelId, "anthropic.claude-opus-5");
        test:assertEquals(route.effectiveModelId, id, "the prefix must survive onto the wire");
        // ...and the same id is refused on Mantle, which has no cross-region inference.
        test:assertTrue(resolveMantleRoute(id, "us-east-1") is error, id + " must be refused on Mantle");
    }
}

@test:Config {}
function testNewModelProvidersConstruct() returns error? {
    BedrockRuntimeAnthropicModelProvider _ = check new (CLAUDE_SONNET_5, TEST_CREDS, REGION);
    BedrockRuntimeMistralModelProvider _ = check new (MISTRAL_LARGE_3, TEST_CREDS, REGION);
    BedrockRuntimeQwenModelProvider _ = check new (QWEN3_CODER_480B, TEST_CREDS, REGION);
    BedrockRuntimeDeepSeekModelProvider _ = check new (DEEPSEEK_V3_2, TEST_CREDS, REGION);
    BedrockMantleAnthropicModelProvider _ = check new (MANTLE_CLAUDE_SONNET_5, TEST_CREDS, REGION);
    BedrockMantleMistralModelProvider _ = check new (MANTLE_MISTRAL_LARGE_3, TEST_CREDS, REGION);
    BedrockMantleQwenModelProvider _ = check new (MANTLE_QWEN3_CODER_480B, TEST_CREDS, REGION);
    BedrockMantleDeepSeekModelProvider _ = check new (MANTLE_DEEPSEEK_V3_2, TEST_CREDS, REGION);
}

// ---- The sharp edge: typed generate() on the one route that cannot do it ----

type FruitShape record {|
    string name;
|};

@test:Config {}
function testTypedGenerateErrorsOnTheMantleMessagesRoute() returns error? {
    // Anthropic Messages on bedrock-mantle rejects `output_config.format` AND
    // `strict: true` on a tool, so neither structured-output mechanism exists there.
    // The refusal is local — no call is spent — and it names the model and the way
    // out. The SAME model on the runtime class does typed generation normally.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-structured-outputs.html
    BedrockMantleAnthropicModelProvider provider =
        check new (MANTLE_CLAUDE_SONNET_5, TEST_CREDS, REGION);
    FruitShape|ai:Error typed = provider->generate(`Name a fruit.`);
    test:assertTrue(typed is ai:Error, "Mantle Messages cannot do structured output");
    if typed is ai:Error {
        test:assertTrue(typed.message().includes("anthropic.claude-sonnet-5"), typed.message());
        test:assertTrue(typed.message().includes("CONVERSE"), typed.message());
    }
}

@test:Config {}
function testTheRuntimeClassIsTheDocumentedWayOutOfThatRefusal() returns error? {
    // The refusal points at `BedrockRuntime*ModelProvider` with the CONVERSE shape,
    // so that combination must actually construct and select tool forcing — otherwise
    // the advice is a dead end.
    Route route = check resolveRuntimeRoute(CLAUDE_SONNET_5, REGION, CONVERSE);
    readonly & ModelConverter converter = check selectConverter(route);
    test:assertEquals(structuredOutputStyleFor(route.endpoint, route.shape, converter.toolChoice),
            TOOL_FORCING);
    BedrockRuntimeAnthropicModelProvider _ = check new (CLAUDE_SONNET_5, TEST_CREDS, REGION, CONVERSE);
}
