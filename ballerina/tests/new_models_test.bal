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

// Routing for the flagship/workhorse ids added to the enums. Each pins a fact from
// that model's card that a wrong id or wrong routing assumption would violate.

@test:Config {}
function testDeepSeekV32BareIdDefaultsToMantle() returns error? {
    // The card marks In-Region YES, so the BARE id is callable (the opposite of R1,
    // which needs the `us.` CRIS prefix). It is dual-homed, so under Amendment 2 AUTO
    // prefers Mantle. Mantle takes the bare id verbatim (no CRIS prefix on this id).
    Route route = check resolveRoute(DEEPSEEK_V3_2, "us-east-1");
    test:assertEquals(route.family, MANTLE);
    test:assertEquals(route.effectiveModelId, "deepseek.v3.2");
    // Forcing CONVERSE gives the runtime surface (needed for typed generate()).
    Route converse = check resolveRoute(DEEPSEEK_V3_2, "us-east-1", {apiFamily: CONVERSE});
    test:assertEquals(converse.family, CONVERSE);
    test:assertEquals(converse.effectiveModelId, "deepseek.v3.2");
}

@test:Config {}
function testMistralLarge3DefaultsToMantle() returns error? {
    Route route = check resolveRoute(MISTRAL_LARGE_3, "us-east-1");
    test:assertEquals(route.family, MANTLE, "dual-homed model prefers Mantle under AUTO (Amendment 2)");
    test:assertEquals(route.effectiveModelId, "mistral.mistral-large-3-675b-instruct");
}

@test:Config {}
function testQwen3Coder480BUsesItsMantleIdUnderAuto() returns error? {
    // The enum carries the bedrock-RUNTIME id; the mantle id differs. Under AUTO it
    // now routes to Mantle, so the MANTLE-side id must go on the wire.
    Route route = check resolveRoute(QWEN3_CODER_480B, "us-east-1");
    test:assertEquals(route.family, MANTLE);
    test:assertEquals(route.effectiveModelId, "qwen.qwen3-coder-480b-a35b-instruct",
            "Mantle has its own id for this model");
    test:assertEquals(route.bareModelId, "qwen.qwen3-coder-480b-a35b-v1:0", "lookup key stays the runtime id");
    // Forcing CONVERSE keeps the runtime id on the wire.
    Route converse = check resolveRoute(QWEN3_CODER_480B, "us-east-1", {apiFamily: CONVERSE});
    test:assertEquals(converse.effectiveModelId, "qwen.qwen3-coder-480b-a35b-v1:0");
}

@test:Config {}
function testClaudeSonnet5DefaultsToMantleAndUsesTheMessagesPath() returns error? {
    // Dual-homed: Amendment 2 makes AUTO prefer Mantle. The Messages entry is what
    // makes that resolve to `/anthropic/v1/messages`.
    Route auto = check resolveRoute(CLAUDE_SONNET_5, "us-east-1");
    test:assertEquals(auto.family, MANTLE);
    MantleEntry? entry = auto.mantleEntry;
    if entry is () {
        test:assertFail("Sonnet 5 under AUTO must yield a Mantle entry");
    }
    test:assertEquals(entry.path, "/anthropic/v1/messages");
    test:assertEquals(entry.codec, MESSAGES_CODEC);
    // And CONVERSE is still reachable explicitly (for typed generate()).
    Route converse = check resolveRoute(CLAUDE_SONNET_5, "us-east-1", {apiFamily: CONVERSE});
    test:assertEquals(converse.family, CONVERSE);
}

@test:Config {}
function testClaudeSonnet5AcceptsItsUsCrisProfile() returns error? {
    // The card lists `us.anthropic.claude-sonnet-5` as the US geo id: it must strip
    // for lookup and re-apply on the Converse wire.
    Route route = check resolveRoute("us.anthropic.claude-sonnet-5", "us-east-1");
    test:assertEquals(route.family, CONVERSE);
    test:assertEquals(route.effectiveModelId, "us.anthropic.claude-sonnet-5",
            "the geo prefix must survive onto the Converse wire");
}

@test:Config {}
function testNewModelProvidersConstruct() returns error? {
    _ = check new AnthropicModelProvider(TEST_CREDS, CLAUDE_SONNET_5, REGION);
    _ = check new MistralModelProvider(TEST_CREDS, MISTRAL_LARGE_3, REGION);
    _ = check new QwenModelProvider(TEST_CREDS, QWEN3_CODER_480B, REGION);
    _ = check new DeepSeekModelProvider(TEST_CREDS, DEEPSEEK_V3_2, REGION);
}

// ---- Amendment 2's sharp edge: generate() on an AUTO-routed Mantle model ----

type FruitShape record {|
    string name;
|};

@test:Config {}
function testTypedGenerateErrorsOnAutoRoutedMantleModel() returns error? {
    // The deliberate consequence of Amendment 2 (its point 2/3): a dual-homed model
    // now defaults to Mantle, and Mantle has no structured output — so generate() with
    // a NON-string target returns an ai:Error naming the model, WITHOUT any I/O (the
    // guard returns before the transport). The documented escape is apiFamily=CONVERSE
    // (its route resolution is covered in the routing tests above).
    AnthropicModelProvider auto = check new (TEST_CREDS, CLAUDE_SONNET_5, REGION);
    FruitShape|ai:Error typed = auto->generate(`Name a fruit.`);
    test:assertTrue(typed is ai:Error, "typed generate() on an AUTO (Mantle) route must error");
    if typed is ai:Error {
        test:assertTrue(typed.message().includes("bedrock-mantle"), typed.message());
        test:assertTrue(typed.message().includes("anthropic.claude-sonnet-5"), typed.message());
    }
}

// Qwen3 32B is served under a DIFFERENT id on Mantle (`qwen.qwen3-32b`) than on
// bedrock-runtime (`qwen.qwen3-32b-v1:0`). The caller always passes the RUNTIME id
// — MANTLE_CAPABLE is keyed by it — and the resolver performs the swap. Getting
// this backwards sends an id Mantle does not know, so both halves are asserted.
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-32b.html
@test:Config {}
function testQwen332bUsesItsOwnIdOnMantle() returns error? {
    Route mantle = check resolveRoute("qwen.qwen3-32b-v1:0", REGION, {apiFamily: MANTLE});
    test:assertEquals(mantle.family, MANTLE);
    test:assertEquals(mantle.effectiveModelId, "qwen.qwen3-32b",
            "Mantle serves this model under its own id");
    test:assertEquals(mantle.bareModelId, "qwen.qwen3-32b-v1:0",
            "the lookup key stays the runtime id");

    Route converse = check resolveRoute("qwen.qwen3-32b-v1:0", REGION, {apiFamily: CONVERSE});
    test:assertEquals(converse.effectiveModelId, "qwen.qwen3-32b-v1:0",
            "the runtime surface keeps the runtime id");
}
