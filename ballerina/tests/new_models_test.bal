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

// Routing for the flagship/workhorse ids carried by the enums. Each pins a fact from
// that model's card that a wrong id would violate.

@test:Config {}
function testDeepSeekV32UsesTheBareIdOnTheRuntimeEndpoint() returns error? {
    // The card marks In-Region YES, so the BARE id is callable (the opposite of R1,
    // which needs the `us.` CRIS prefix).
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-v3-2.html
    Route runtime = check resolveRuntimeRoute(DEEPSEEK_V3_2, "us-east-1", CONVERSE);
    test:assertEquals(runtime.effectiveModelId, "deepseek.v3.2");
}

@test:Config {}
function testMistralLarge3ResolvesOnTheRuntimeEndpoint() returns error? {
    Route runtime = check resolveRuntimeRoute(MISTRAL_LARGE_3, "us-east-1", CONVERSE);
    test:assertEquals(runtime.effectiveModelId, "mistral.mistral-large-3-675b-instruct");
}

@test:Config {}
function testQwen3IdsKeepTheirRuntimeIds() returns error? {
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-coder-480b-a35b-instruct.html
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-32b.html
    Route coder = check resolveRuntimeRoute(QWEN3_CODER_480B, "us-east-1", CONVERSE);
    test:assertEquals(coder.effectiveModelId, "qwen.qwen3-coder-480b-a35b-v1:0");
    Route small = check resolveRuntimeRoute(QWEN3_32B, REGION, CONVERSE);
    test:assertEquals(small.effectiveModelId, "qwen.qwen3-32b-v1:0");
}

@test:Config {}
function testTheRuntimeAnthropicEnumCarriesCrisPrefixedIds() returns error? {
    // Current Claude models are served on bedrock-runtime through cross-region
    // inference profiles only — a BARE id there fails with "on-demand throughput
    // isn't supported" — so the enum members carry `us.`.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html
    AnthropicRuntimeModelNames[] ids = [CLAUDE_OPUS_5, CLAUDE_OPUS_4_8, CLAUDE_SONNET_5,
            CLAUDE_SONNET_4_6, CLAUDE_HAIKU_4_5];
    foreach AnthropicRuntimeModelNames id in ids {
        Route route = check resolveRuntimeRoute(id, "us-east-1", CONVERSE);
        test:assertEquals(route.geoPrefix, "us", id + " must carry a CRIS prefix on bedrock-runtime");
        test:assertEquals(route.effectiveModelId, id, "the prefix must survive onto the wire");
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
    }
}

@test:Config {}
function testNewModelProvidersConstruct() returns error? {
    RuntimeAnthropicModelProvider _ = check new (CLAUDE_SONNET_5, TEST_CREDS, REGION);
    RuntimeMistralModelProvider _ = check new (MISTRAL_LARGE_3, TEST_CREDS, REGION);
    RuntimeQwenModelProvider _ = check new (QWEN3_CODER_480B, TEST_CREDS, REGION);
    RuntimeDeepSeekModelProvider _ = check new (DEEPSEEK_V3_2, TEST_CREDS, REGION);
}

@test:Config {}
function testClaudeSonnet5OnConverseSelectsToolForcing() returns error? {
    Route route = check resolveRuntimeRoute(CLAUDE_SONNET_5, REGION, CONVERSE);
    readonly & ModelConverter converter = check selectConverter(route);
    test:assertEquals(structuredOutputStyleFor(converter.toolChoice), TOOL_FORCING);
    RuntimeAnthropicModelProvider _ = check new (CLAUDE_SONNET_5, TEST_CREDS, REGION, CONVERSE);
}

@test:Config {}
function testOpus55AndOpus47NeedACrisProfile() returns error? {
    // Both cards mark In-Region unsupported on bedrock-runtime, hence `us.`.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-5-5.html
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-4-7.html
    foreach string id in [CLAUDE_OPUS_5_5, CLAUDE_OPUS_4_7] {
        Route runtime = check resolveRuntimeRoute(id, "us-east-1", CONVERSE);
        test:assertEquals(runtime.geoPrefix, "us", id + " needs a CRIS profile on bedrock-runtime");
        test:assertEquals(runtime.effectiveModelId, id, "the prefix must survive onto the wire");
    }
}

@test:Config {}
function testBothFableIdsNeedACrisProfile() returns error? {
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-fable-5.html
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-fable-5-1.html
    foreach string id in [CLAUDE_FABLE_5, CLAUDE_FABLE_5_1] {
        Route runtime = check resolveRuntimeRoute(id, "us-east-1", CONVERSE);
        test:assertEquals(runtime.geoPrefix, "us", id);
    }
}

@test:Config {}
function testOnlyFable51InheritsOpus55sForcedToolRefusal() {
    // Anthropic scopes the restriction to Opus 5.5 and Fable 5.1 ("The first three
    // also apply on Claude Fable 5.1"). Fable 5 is NOT in that set, so it must not be
    // swept up with its own successor.
    // https://platform.claude.com/docs/en/models/opus-5-5/whats-new-opus-5-5
    test:assertTrue(refusesForcedToolChoice(CLAUDE_OPUS_5_5));
    test:assertTrue(refusesForcedToolChoice(CLAUDE_FABLE_5_1));
    test:assertFalse(refusesForcedToolChoice(CLAUDE_FABLE_5));
    test:assertFalse(refusesForcedToolChoice(CLAUDE_OPUS_4_7));
}

@test:Config {}
function testTheGpt6FamilyIsCrisPrefixedOnRuntime() returns error? {
    // "You cannot use the base model ID for in-Region calls on this endpoint" —
    // the runtime ids MUST carry a profile prefix.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-sol.html
    foreach string id in [GPT_6_ASTRA, GPT_6_SOL, GPT_6_LUNA] {
        Route runtime = check resolveRuntimeRoute(id, "us-east-1", RESPONSES);
        test:assertEquals(runtime.geoPrefix, "us", id);
        test:assertEquals(runtime.effectiveModelId, id);
    }
}
