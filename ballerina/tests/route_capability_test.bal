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

// Regression tests for the route/config-matrix defects: a config field that reaches
// the wire in the wrong SHAPE on one dialect, or reaches it on none at all.
//
// The class of bug these cover is "the constructor accepted it and nothing
// happened". Every case therefore asserts one of exactly two acceptable outcomes —
// the field is emitted correctly for that dialect, or construction refuses it by
// name. A 200 with the field dropped is what must never happen again.

// ============================================================================
// `reasoningEffort` — one value, three dialects, three wire shapes.
// ============================================================================

@test:Config {}
function testReasoningEffortNestsUnderReasoningOnTheResponsesDialect() returns error? {
    // The Responses API has NO top-level `reasoning_effort`; that spelling is Chat
    // Completions', and sending it is a hard 400 (`Unknown parameter`).
    readonly & InferenceParams params = buildInferenceParams(256, (), (), (), (), (), (), (), (), "low");
    json body = check encodeResponses((), [userText("hi")], [], (), params);
    map<json> wire = <map<json>>body;
    test:assertFalse(wire.hasKey("reasoning_effort"), wire.toJsonString());
    test:assertEquals(wire["reasoning"], {"effort": "low"});
}

@test:Config {}
function testReasoningEffortStaysFlatOnTheChatCompletionsDialect() returns error? {
    readonly & InferenceParams params = buildInferenceParams(256, (), (), (), (), (), (), (), (), "high");
    json body = check encodeOpenAIChat((), [userText("hi")], [], (), params);
    map<json> wire = <map<json>>body;
    test:assertEquals(wire["reasoning_effort"], "high");
    test:assertFalse(wire.hasKey("reasoning"), wire.toJsonString());
}

@test:Config {}
function testReasoningEffortRidesThePassthroughOnConverse() returns error? {
    // Converse models no reasoning knob natively, so it goes down to the model's own
    // parser through `additionalModelRequestFields` — in that parser's spelling.
    readonly & InferenceParams params = buildInferenceParams(256, (), (), (), (), (), (), (), (), "medium");
    json body = check encodeConverse((), [userText("hi")], [], (), params);
    map<json> extra = <map<json>>(<map<json>>body)["additionalModelRequestFields"];
    test:assertEquals(extra["reasoning_effort"], "medium");
}

@test:Config {}
function testReasoningEffortNeverTouchesTheCallersPassthrough() returns error? {
    // It used to be FOLDED into `additionalModelRequestFields` at the provider, which
    // is what erased the per-dialect shape — and quietly put a module-owned key into
    // an escape hatch documented as forwarded verbatim.
    OpenAIConfig config = {reasoningEffort: "low", additionalModelRequestFields: {"top_p": 0.9}};
    readonly & InferenceParams params = openAIParams(256, (), config);
    AdditionalRequestFields? passthrough = params?.additionalModelRequestFields;
    test:assertTrue(passthrough is AdditionalRequestFields);
    if passthrough is AdditionalRequestFields {
        test:assertFalse(passthrough.hasKey("reasoning_effort"), passthrough.toJsonString());
        test:assertEquals(passthrough["top_p"], 0.9);
    }
    test:assertEquals(params?.reasoningEffort, "low");
}

// ============================================================================
// `serviceTier` / `latencyOptimized` — honoured on Converse AND Invoke, refused
// on Mantle. Never dropped.
// ============================================================================

@test:Config {}
function testInvokeCarriesServiceTierAndLatencyAsRequestHeaders() {
    // These are not Converse-only knobs. `InvokeModel` takes both as request headers,
    // so on Invoke the right answer is to SEND them — not to drop them, and not to
    // refuse a capability AWS actually offers.
    // https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModel.html
    map<string> headers = {};
    addInvokeRequestOptionHeaders(headers, buildInferenceParams(256, (), (), (), TIER_FLEX, true, ()));
    test:assertEquals(headers["X-Amzn-Bedrock-Service-Tier"], "flex");
    test:assertEquals(headers["X-Amzn-Bedrock-PerformanceConfig-Latency"], "optimized");
}

@test:Config {}
function testLatencyStandardIsOmittedRatherThanSentExplicitly() {
    // `standard` is the service default, so an unset or false flag sends nothing —
    // matching what the Converse converter emits for the same input.
    map<string> headers = {};
    addInvokeRequestOptionHeaders(headers, buildInferenceParams(256, (), (), (), (), false, ()));
    test:assertFalse(headers.hasKey("X-Amzn-Bedrock-PerformanceConfig-Latency"), headers.toString());
    test:assertFalse(headers.hasKey("X-Amzn-Bedrock-Service-Tier"), headers.toString());
}

@test:Config {}
function testConverseStillCarriesServiceTierAndLatencyInTheBody() returns error? {
    readonly & InferenceParams params = buildInferenceParams(256, (), (), (), TIER_PRIORITY, true, ());
    map<json> body = <map<json>>check encodeConverse((), [userText("hi")], [], (), params);
    test:assertEquals(body["serviceTier"], {"type": "priority"});
    test:assertEquals(body["performanceConfig"], {"latency": "optimized"});
}

@test:Config {}
function testLatencyOptimizedOnAMantleRouteIsRefusedAtConstruction() {
    // Mythos is Mantle-only, so `AUTO` resolves it there. Previously this constructed
    // fine, returned an ordinary 200, and did nothing.
    AnthropicModelProvider|ai:Error provider = new (
        "anthropic.claude-mythos-preview", TEST_CREDS, "us-east-1", latencyOptimized = true);
    test:assertTrue(provider is ai:Error);
    if provider is ai:Error {
        test:assertTrue(provider.message().includes("latencyOptimized"), provider.message());
        test:assertTrue(provider.message().includes("bedrock-mantle"), provider.message());
    }
}

@test:Config {}
function testServiceTierOnAMantleRouteIsRefusedAtConstruction() {
    // The sibling the live suite left open because it had no model that refuses a
    // tier to A/B against. It needs no live model: Mantle has no mechanism at all.
    AnthropicModelProvider|ai:Error provider = new (
        "anthropic.claude-mythos-preview", TEST_CREDS, "us-east-1", serviceTier = TIER_FLEX);
    test:assertTrue(provider is ai:Error);
    if provider is ai:Error {
        test:assertTrue(provider.message().includes("serviceTier"), provider.message());
        // The refusal must point somewhere: the two families that DO carry it, and
        // the passthrough for a caller who knows their model's own vocabulary.
        test:assertTrue(provider.message().includes("CONVERSE"), provider.message());
        test:assertTrue(provider.message().includes("additionalModelRequestFields"), provider.message());
    }
}

@test:Config {}
function testTheSameFieldsAreAcceptedWhenTheCallerForcesACarryingRoute() returns error? {
    // The refusal is about the ROUTE, not the field, so naming a route that carries
    // it must lift it — otherwise the guard is just a smaller cage.
    AnthropicModelProvider _ = check new (
        "anthropic.claude-sonnet-4-6", TEST_CREDS, "us-east-1", apiFamily = CONVERSE,
        serviceTier = TIER_FLEX, latencyOptimized = true);
    AnthropicModelProvider _ = check new (
        "anthropic.claude-sonnet-4-6", TEST_CREDS, "us-east-1", apiFamily = INVOKE,
        serviceTier = TIER_FLEX, latencyOptimized = true);
}

// ============================================================================
// Dialect capabilities are declared, not remembered.
// ============================================================================

@test:Config {}
function testConfiguredStopSequencesAreRefusedOnTheResponsesDialect() {
    // The Responses API has no stop-sequence parameter. The encoder already refused a
    // per-call `stop`; a CONFIGURED one now fails at construction, before any I/O.
    OpenAIModelProvider|ai:Error provider = new (
        "openai.gpt-5.6-sol", TEST_CREDS, "us-east-1", stopSequences = ["END"]);
    test:assertTrue(provider is ai:Error);
    if provider is ai:Error {
        test:assertTrue(provider.message().includes("stopSequences"), provider.message());
        test:assertTrue(provider.message().includes("OpenAI Responses"), provider.message());
    }
}

@test:Config {}
function testEveryConverterDeclaresWhatItCanCarry() {
    // The registry is the single source of truth for "this route cannot carry that
    // field". A converter added without a declaration would silently inherit the
    // record defaults, so assert the ones whose answers are load-bearing.
    test:assertTrue(CONVERSE_CONVERTER.supports.thinking);
    test:assertTrue(CONVERSE_CONVERTER.supports.effort);
    test:assertTrue(INVOKE_ANTHROPIC_CONVERTER.supports.thinking);
    test:assertTrue(MANTLE_MESSAGES_CONVERTER.supports.effort);
    test:assertFalse(MANTLE_RESPONSES_CONVERTER.supports.stopSequences);
    test:assertTrue(MANTLE_RESPONSES_CONVERTER.supports.reasoningEffort);
    test:assertTrue(INVOKE_OPENAI_CHAT_CONVERTER.supports.reasoningEffort);
    test:assertFalse(INVOKE_NOVA_CONVERTER.supports.reasoningEffort);
    test:assertFalse(INVOKE_MISTRAL_TEXT_CONVERTER.supports.thinking);
    // Every dialect names itself, so a refusal can say which one refused.
    test:assertNotEquals(INVOKE_MISTRAL_CHAT_CONVERTER.dialect, "");
    test:assertNotEquals(INVOKE_DEEPSEEK_CONVERTER.dialect, "");
    test:assertNotEquals(MANTLE_CHAT_CONVERTER.dialect, "");
}

// ============================================================================
// The caller's passthrough reaches the Anthropic Messages dialects.
// ============================================================================

@test:Config {}
function testThePassthroughIsSplicedOnTheAnthropicMessagesDialects() returns error? {
    // These two encoders were the only ones that dropped it, which made
    // `additionalModelRequestFields` inert on exactly the dialect it is most needed
    // for: `top_k`, `anthropic_beta` and `cache_control` are Anthropic Messages body
    // fields with no other way in.
    readonly & InferenceParams params = buildInferenceParams(256, (), (),
        {"top_k": 40, "anthropic_beta": ["context-1m-2025-08-07"]}, (), (), ());

    map<json> invoke = <map<json>>check encodeInvokeAnthropic((), [userText("hi")], [], (), params);
    test:assertEquals(invoke["top_k"], 40);
    test:assertEquals(invoke["anthropic_beta"], ["context-1m-2025-08-07"]);
    test:assertEquals(invoke["anthropic_version"], "bedrock-2023-05-31");

    map<json> mantle = <map<json>>check encodeMantleMessages((), [userText("hi")], [], (), params);
    test:assertEquals(mantle["top_k"], 40);
    test:assertFalse(mantle.hasKey("anthropic_version"), mantle.toJsonString());
}

@test:Config {}
function testThePassthroughDoesNotClobberTheModulesOwnAnthropicFields() returns error? {
    readonly & InferenceParams params = buildInferenceParams(256, (), (), {"top_k": 40}, (), (), (),
        {mode: ADAPTIVE}, EFFORT_HIGH);
    map<json> body = <map<json>>check encodeInvokeAnthropic((), [userText("hi")], [], (), params);
    test:assertEquals(body["thinking"], {"type": "adaptive"});
    test:assertEquals(body["output_config"], {"effort": "high"});
    test:assertEquals(body["top_k"], 40);
}

// ============================================================================
// `dualstack` — refused at construction on every host family that has none.
// ============================================================================

@test:Config {}
function testDualstackIsRefusedOnTheRuntimeHostFamily() {
    // DNS-verified: `bedrock-runtime.{region}.api.aws` has no record in any region
    // tried. Without the guard this built the host happily and died at call time as
    // a bare connection error after a full retry cycle.
    AnthropicModelProvider|ai:Error provider = new (
        "anthropic.claude-sonnet-4-6", TEST_CREDS, "us-east-1", apiFamily = CONVERSE,
        endpoint = {dualstack: true});
    test:assertTrue(provider is ai:Error);
    if provider is ai:Error {
        test:assertTrue(provider.message().includes("dualstack"), provider.message());
        test:assertTrue(provider.message().includes("bedrock-runtime"), provider.message());
    }
}

@test:Config {}
function testDualstackIsRefusedOnTheEmbeddingProvidersToo() {
    // The blast radius the live suite measured: embeddings resolve the same
    // `bedrock-runtime` host family, so a guard on the model providers alone would
    // have left this broken.
    TitanEmbeddingProvider|ai:Error provider = new (
        "amazon.titan-embed-text-v2:0", TEST_CREDS, "us-east-1", endpoint = {dualstack: true});
    test:assertTrue(provider is ai:Error);
    if provider is ai:Error {
        test:assertTrue(provider.message().includes("dualstack"), provider.message());
    }
}

@test:Config {}
function testDualstackIsRefusedOnBothKnowledgeBaseAgentPlanes() returns error? {
    // NOT covered by the live suite at all. `bedrock-agent.{region}.api.aws` and
    // `bedrock-agent-runtime.{region}.api.aws` have no DNS record either, so a
    // knowledge base built with the flag would have failed exactly like G69/P51.
    // Asserted at the endpoint builder: it fails before the spine does any I/O.
    Endpoint|error control = buildAgentEndpoint(AGENT_CONTROL, "us-east-1", {dualstack: true});
    test:assertTrue(control is error);
    if control is error {
        test:assertTrue(control.message().includes("bedrock-agent"), control.message());
    }
    Endpoint|error data = buildAgentEndpoint(AGENT_DATA, "us-east-1", {dualstack: true});
    test:assertTrue(data is error);

    // Unset, both planes still resolve normally.
    Endpoint _ = check buildAgentEndpoint(AGENT_CONTROL, "us-east-1");
    Endpoint _ = check buildAgentEndpoint(AGENT_DATA, "us-east-1", {});
}

@test:Config {}
function testDualstackIsStillHonouredWhereItExists() returns error? {
    // Mantle is the one host family that HAS a dualstack host, and the module forces
    // it there. The guard must not touch that.
    AnthropicModelProvider _ = check new (
        "anthropic.claude-mythos-preview", TEST_CREDS, "us-east-1", endpoint = {dualstack: true});
}

@test:Config {}
function testACustomEndpointStillOutranksTheDualstackGuard() returns error? {
    // A concrete origin means there is no derived host to validate — the same
    // doctrine the China-partition and Mantle+FIPS guards follow. It is also the
    // escape hatch if AWS publishes a dualstack host this guard does not know about.
    AnthropicModelProvider _ = check new (
        "anthropic.claude-sonnet-4-6", TEST_CREDS, "us-east-1", apiFamily = CONVERSE,
        endpoint = {dualstack: true, customEndpoint: "https://bedrock.internal.example.com"});
}

@test:Config {}
function testExplicitlyDisablingLatencyOptimizationIsNotRefusedAnywhere() returns error? {
    // `false` asks for `standard`, which is what an unset flag already produces on
    // every route. Refusing it would reject a call asking for what it will get.
    AnthropicModelProvider _ = check new (
        "anthropic.claude-mythos-preview", TEST_CREDS, "us-east-1", latencyOptimized = false);
}
