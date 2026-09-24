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

// Construction-error tests. `init` fails before any I/O.

final BedrockCredentials TEST_CREDS = {accessKeyId: "AKIATEST", secretAccessKey: "secret"};

// ---------------------------------------------------------------------------
// Guardrails. The endpoint is now fixed by the CLASS, so `guardrail` does not even
// exist on `CommonMantleConfig` — a guardrail on a Mantle class is a COMPILE error
// and cannot be asserted from here. What remains testable, and what actually
// decides the outcome, is the shared guard.
// ---------------------------------------------------------------------------

@test:Config {}
function testGuardrailIsRefusedOnEveryMantleRoute() {
    // AWS's feature-availability table marks Guardrails supported on bedrock-runtime
    // and unsupported on bedrock-mantle — for every shape Mantle serves.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
    GuardrailConfig guardrail = {guardrailIdentifier: "gr-1", guardrailVersion: "1"};
    ApiShape[] shapes = [MESSAGES, CHAT_COMPLETIONS, RESPONSES];
    foreach ApiShape shape in shapes {
        ai:Error? e = guardGuardrailSupport(MANTLE, shape, guardrail);
        test:assertTrue(e is ai:Error, string `Mantle/${shape} must refuse a guardrail`);
        if e is ai:Error {
            test:assertTrue(e.message().includes("ApplyGuardrail"), e.message());
        }
    }
}

@test:Config {}
function testGuardrailIsRefusedOnTheResponsesShapeOnEitherEndpoint() {
    // Stated verbatim: "Guardrails don't apply to the Responses API. To apply a
    // guardrail to a GPT model on this endpoint, call the Converse API instead."
    // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html
    GuardrailConfig guardrail = {guardrailIdentifier: "gr-1", guardrailVersion: "1"};
    BedrockEndpoint[] endpoints = [RUNTIME, MANTLE];
    foreach BedrockEndpoint endpoint in endpoints {
        ai:Error? e = guardGuardrailSupport(endpoint, RESPONSES, guardrail);
        test:assertTrue(e is ai:Error, string `${endpoint}/RESPONSES must refuse a guardrail`);
    }
    ai:Error? runtimeResponses = guardGuardrailSupport(RUNTIME, RESPONSES, guardrail);
    if runtimeResponses is ai:Error {
        test:assertTrue(runtimeResponses.message().includes("Responses"), runtimeResponses.message());
    }
}

@test:Config {}
function testGuardrailIsRefusedOnTheMessagesShapeAsAPolicyChoice() {
    // DELIBERATE, and the reason is the direction of the failure: AWS documents the
    // guardrail headers for Converse, InvokeModel and Chat Completions but says
    // nothing about `/anthropic/v1/messages`. Accepting them there and quietly not
    // applying them would leave a caller believing traffic is screened when it is
    // not, so the module refuses instead. Reversible the moment AWS documents it.
    ai:Error? e = guardGuardrailSupport(RUNTIME, MESSAGES,
            {guardrailIdentifier: "gr-1", guardrailVersion: "1"});
    test:assertTrue(e is ai:Error);
    if e is ai:Error {
        test:assertTrue(e.message().includes("Messages"), e.message());
        test:assertTrue(e.message().includes("ApplyGuardrail"), e.message());
    }
}

@test:Config {}
function testGuardrailIsAllowedOnConverseInvokeAndChatCompletions() {
    // The three shapes AWS documents guardrail parameters for. A guard that refused
    // everything would be trivially "safe" and useless.
    GuardrailConfig guardrail = {guardrailIdentifier: "gr-1", guardrailVersion: "1"};
    ApiShape[] shapes = [CONVERSE, INVOKE, CHAT_COMPLETIONS];
    foreach ApiShape shape in shapes {
        test:assertTrue(guardGuardrailSupport(RUNTIME, shape, guardrail) is (),
                string `RUNTIME/${shape} must accept a guardrail`);
    }
}

@test:Config {}
function testNoGuardrailIsNeverRefusedAnywhere() {
    // The guard keys on the guardrail being SET, not on the route.
    BedrockEndpoint[] endpoints = [RUNTIME, MANTLE];
    foreach BedrockEndpoint endpoint in endpoints {
        ApiShape[] shapes = [CONVERSE, INVOKE, CHAT_COMPLETIONS, RESPONSES, MESSAGES];
        foreach ApiShape shape in shapes {
            test:assertTrue(guardGuardrailSupport(endpoint, shape, ()) is ());
        }
    }
}

@test:Config {}
function testGuardrailOnARefusingRuntimeShapeFailsAtConstruction() returns error? {
    // End to end through a real class: the Anthropic runtime class CAN carry a
    // guardrail (it is on `CommonRuntimeConfig`), but not on the MESSAGES shape.
    BedrockRuntimeAnthropicModelProvider|ai:Error provider = new (
            "anthropic.claude-opus-5", TEST_CREDS, "us-east-1", MESSAGES,
            guardrail = {guardrailIdentifier: "gr-1", guardrailVersion: "1"});
    test:assertTrue(provider is ai:Error);
    if provider is ai:Error {
        test:assertTrue(provider.message().includes("ApplyGuardrail"), provider.message());
    }
    // ...and the same class on CONVERSE accepts it.
    BedrockRuntimeAnthropicModelProvider _ = check new (
            "anthropic.claude-opus-5", TEST_CREDS, "us-east-1", CONVERSE,
            guardrail = {guardrailIdentifier: "gr-1", guardrailVersion: "1"});
}

// ---------------------------------------------------------------------------
// Host-shape and model-id guards, all before any I/O.
// ---------------------------------------------------------------------------

@test:Config {}
function testMantleOnChinaPartitionFailsAtConstruction() {
    // Mantle's `api.aws` host is not partition-templated, and Bedrock is not offered
    // in `aws-cn` on any endpoint at all.
    BedrockMantleAnthropicModelProvider|ai:Error provider = new (
            MANTLE_CLAUDE_OPUS_5, TEST_CREDS, "cn-north-1");
    test:assertTrue(provider is ai:Error);
    if provider is ai:Error {
        test:assertTrue(provider.message().toLowerAscii().includes("partition") ||
                provider.message().toLowerAscii().includes("mantle"), provider.message());
    }
}

@test:Config {}
function testImportedModelArnIsRefusedAtConstruction() {
    // Custom Model Import is out of scope — refused by name, before any I/O.
    BedrockRuntimeAnthropicModelProvider|ai:Error provider = new (
            "arn:aws:bedrock:us-west-2:123456789012:imported-model/abc123", TEST_CREDS, "us-east-1");
    test:assertTrue(provider is ai:Error);
    if provider is ai:Error {
        test:assertTrue(provider.message().includes("imported-model"), provider.message());
    }
}

@test:Config {}
function testConverseHappyPathConstructsWithoutError() returns error? {
    // A valid Converse model constructs (no I/O until chat()). The class fixes the
    // endpoint, so there is no routing ladder that could send this elsewhere.
    BedrockRuntimeAnthropicModelProvider provider =
        check new ("anthropic.claude-sonnet-4-6", TEST_CREDS, "us-east-1");
    test:assertTrue(provider is BedrockRuntimeAnthropicModelProvider);
}

@test:Config {}
function testBearerTokenCredentialsConstruct() returns error? {
    BedrockCredentials bearer = {apiKey: "bedrock-api-key"};
    BedrockRuntimeAnthropicModelProvider provider =
        check new ("anthropic.claude-sonnet-4-6", bearer, "us-east-1");
    test:assertTrue(provider is BedrockRuntimeAnthropicModelProvider);
}

@test:Config {}
function testTheVendorAgnosticClassConstructsOnAnyId() returns error? {
    // `BedrockCommonModelProvider` is Converse-only and takes a plain string, so it
    // reaches the ten vendors with no dedicated class in this module.
    BedrockCommonModelProvider _ = check new ("meta.llama3-70b-instruct-v1:0", TEST_CREDS, "us-east-1");
    BedrockCommonModelProvider _ = check new ("ai21.jamba-1-5-large-v1:0", TEST_CREDS, "us-east-1");
    BedrockCommonModelProvider _ = check new ("acme.brand-new-model-v9", TEST_CREDS, "us-east-1");
}

// ---------------------------------------------------------------------------
// The endpoint is the CLASS's. An id the other endpoint owns is either sent
// verbatim (runtime, which is model-agnostic) or refused by name (Mantle, whose
// request path is per-model table data).
// ---------------------------------------------------------------------------

@test:Config {}
function testAMantleOnlyIdOnARuntimeClassJustGoesOnTheWire() returns error? {
    // NOT an error. Converse is model-agnostic — an id this module has never heard
    // of goes on the wire as-is and AWS answers for it, which is what keeps a model
    // AWS ships tomorrow usable today. The old resolver's "unknown id → Mantle by
    // elimination" failure mode is unrepresentable now.
    BedrockRuntimeOpenAIModelProvider _ = check new ("openai.gpt-5.5", TEST_CREDS, "us-east-1");
    Route route = check resolveRuntimeRoute("openai.gpt-5.5", "us-east-1", CONVERSE);
    test:assertEquals(route.endpoint, RUNTIME);
    test:assertEquals(route.effectiveModelId, "openai.gpt-5.5");
    test:assertEquals(route.mantleEntry, ());
}

@test:Config {}
function testANonMantleIdOnAMantleClassIsACleanConstructionError() {
    // Sonnet 4.6's card marks bedrock-mantle NO, so there is no path to build and
    // nothing to guess at. The refusal must name the model.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/models-endpoint-availability.html
    BedrockMantleAnthropicModelProvider|ai:Error provider = new (
            "anthropic.claude-sonnet-4-6", TEST_CREDS, "us-east-1");
    test:assertTrue(provider is ai:Error);
    if provider is ai:Error {
        test:assertTrue(provider.message().includes("anthropic.claude-sonnet-4-6"), provider.message());
        test:assertTrue(provider.message().includes("bedrock-mantle"), provider.message());
    }
}

@test:Config {}
function testAnUnknownIdOnAMantleClassIsRefusedRatherThanGuessed() {
    // The table is the only source of a Mantle request path. Absence is a refusal,
    // never a fabricated URL.
    BedrockMantleOpenAIModelProvider|ai:Error provider = new (
            "acme.totally-new", TEST_CREDS, "us-east-1");
    test:assertTrue(provider is ai:Error);
    if provider is ai:Error {
        test:assertTrue(provider.message().includes("acme.totally-new"), provider.message());
    }
}

// ---------------------------------------------------------------------------
// Region resolution.
// ---------------------------------------------------------------------------

@test:Config {}
function testMissingRegionFailsAtConstructionWithANamedError() returns error? {
    BedrockRuntimeAnthropicModelProvider|error provider =
        new ("anthropic.claude-sonnet-4-6", TEST_CREDS, "");
    test:assertTrue(provider is error);
    if provider is error {
        test:assertTrue(provider.message().includes("No AWS region"), provider.message());
    }
}

@test:Config {}
function testAnArnCarryingItsOwnRegionNeedsNoRegionArgument() returns error? {
    // The region guard must run on the RESOLVED route, not the argument: an ARN
    // supplies its own region, so this is well-formed with no region and no
    // AWS_REGION in the environment.
    BedrockRuntimeAnthropicModelProvider|error provider = new (
            "arn:aws:bedrock:eu-west-1:123456789012:inference-profile/eu.anthropic.claude-sonnet-4-6",
            TEST_CREDS, "");
    test:assertFalse(provider is error, provider is error ? provider.message() : "");
}
