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
import ballerina/http;
import ballerina/test;

// Construction-error tests. `init` fails before any I/O.

final BedrockAuthConfig TEST_CREDS = {accessKeyId: "AKIATEST", secretAccessKey: "secret"};

// ---------------------------------------------------------------------------
// Guardrails: refused on the APIs that would not apply them.
// ---------------------------------------------------------------------------

@test:Config {}
function testGuardrailIsRefusedOnTheResponsesApi() {
    // "Guardrails don't apply to the Responses API."
    // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html
    ai:Error? e = guardGuardrailSupport(RESPONSES, {guardrailIdentifier: "gr-1", guardrailVersion: "1"});
    test:assertTrue(e is ai:Error, "RESPONSES must refuse a guardrail");
    if e is ai:Error {
        test:assertTrue(e.message().includes("Responses"), e.message());
    }
}

@test:Config {}
function testGuardrailIsRefusedOnTheMessagesShapeAsAPolicyChoice() {
    // DELIBERATE, and the reason is the direction of the failure: AWS documents the
    // guardrail headers for Converse, InvokeModel and Chat Completions but says
    // nothing about `/anthropic/v1/messages`. Accepting them there and quietly not
    // applying them would leave a caller believing traffic is screened when it is
    // not, so the module refuses instead. Reversible the moment AWS documents it.
    ai:Error? e = guardGuardrailSupport(MESSAGES,
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
    ApiFamily[] apis = [CONVERSE, INVOKE, CHAT_COMPLETIONS];
    foreach ApiFamily api in apis {
        test:assertTrue(guardGuardrailSupport(api, guardrail) is (), string `${api} must accept a guardrail`);
    }
}

@test:Config {}
function testNoGuardrailIsNeverRefusedAnywhere() {
    // The guard keys on the guardrail being SET, not on the route.
    ApiFamily[] apis = [CONVERSE, INVOKE, CHAT_COMPLETIONS, RESPONSES, MESSAGES];
    foreach ApiFamily api in apis {
        test:assertTrue(guardGuardrailSupport(api, ()) is ());
    }
}

@test:Config {}
function testGuardrailOnARefusingRuntimeShapeFailsAtConstruction() returns error? {
    // End to end through a real class: the Anthropic runtime class CAN carry a
    // guardrail (it is on `CommonRuntimeConfig`), but not on the MESSAGES shape.
    RuntimeAnthropicModelProvider|ai:Error provider = new (
            "anthropic.claude-opus-5", TEST_CREDS, "us-east-1", MESSAGES,
            guardrail = {guardrailIdentifier: "gr-1", guardrailVersion: "1"});
    test:assertTrue(provider is ai:Error);
    if provider is ai:Error {
        test:assertTrue(provider.message().includes("ApplyGuardrail"), provider.message());
    }
    // ...and the same class on CONVERSE accepts it.
    RuntimeAnthropicModelProvider _ = check new (
            "anthropic.claude-opus-5", TEST_CREDS, "us-east-1", CONVERSE,
            guardrail = {guardrailIdentifier: "gr-1", guardrailVersion: "1"});
}

// ---------------------------------------------------------------------------
// Host-shape and model-id guards, all before any I/O.
// ---------------------------------------------------------------------------

@test:Config {}
function testChinaPartitionFailsAtConstruction() {
    // Bedrock is not offered in `aws-cn`.
    RuntimeAnthropicModelProvider|ai:Error provider = new ("anthropic.claude-opus-5", TEST_CREDS, "cn-north-1");
    test:assertTrue(provider is ai:Error);
    if provider is ai:Error {
        test:assertTrue(provider.message().includes("China"), provider.message());
    }
}

@test:Config {}
function testImportedModelArnIsRefusedAtConstruction() {
    // Custom Model Import is out of scope — refused by name, before any I/O.
    RuntimeAnthropicModelProvider|ai:Error provider = new (
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
    RuntimeAnthropicModelProvider provider =
        check new ("anthropic.claude-sonnet-4-6", TEST_CREDS, "us-east-1");
    test:assertTrue(provider is RuntimeAnthropicModelProvider);
}

@test:Config {}
function testBearerTokenCredentialsConstruct() returns error? {
    BedrockAuthConfig bearer = {apiKey: "bedrock-api-key"};
    RuntimeAnthropicModelProvider provider =
        check new ("anthropic.claude-sonnet-4-6", bearer, "us-east-1");
    test:assertTrue(provider is RuntimeAnthropicModelProvider);
}

@test:Config {}
function testTheVendorAgnosticClassConstructsOnAnyId() returns error? {
    // `ConverseModelProvider` is Converse-only and takes a plain string, so it
    // reaches the ten vendors with no dedicated class in this module.
    ConverseModelProvider _ = check new ("meta.llama3-70b-instruct-v1:0", TEST_CREDS, "us-east-1");
    ConverseModelProvider _ = check new ("ai21.jamba-1-5-large-v1:0", TEST_CREDS, "us-east-1");
    ConverseModelProvider _ = check new ("acme.brand-new-model-v9", TEST_CREDS, "us-east-1");
}

@test:Config {}
function testAnUnknownIdOnARuntimeClassJustGoesOnTheWire() returns error? {
    // Not an error: an id this module does not know goes on the wire as is and AWS
    // answers for it, so a new model works at once.
    RuntimeOpenAIModelProvider _ = check new ("openai.brand-new-model", TEST_CREDS, "us-east-1");
    Route route = check resolveRuntimeRoute("openai.brand-new-model", "us-east-1", CONVERSE);
    test:assertEquals(route.effectiveModelId, "openai.brand-new-model");
}

// ---------------------------------------------------------------------------
// Region resolution.
// ---------------------------------------------------------------------------

@test:Config {}
function testMissingRegionFailsAtConstructionWithANamedError() returns error? {
    RuntimeAnthropicModelProvider|error provider =
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
    RuntimeAnthropicModelProvider|error provider = new (
            "arn:aws:bedrock:eu-west-1:123456789012:inference-profile/eu.anthropic.claude-sonnet-4-6",
            TEST_CREDS, "");
    test:assertFalse(provider is error, provider is error ? provider.message() : "");
}

@test:Config {}
function testTheRequestTimeoutDefaultsUnlessTheCallerSetsOne() {
    test:assertEquals(withDefaultTimeout((), INFERENCE_TIMEOUT).timeout, INFERENCE_TIMEOUT);
    test:assertEquals(withDefaultTimeout({}, DEFAULT_TIMEOUT).timeout, DEFAULT_TIMEOUT);
    test:assertEquals(withDefaultTimeout({timeout: 45}, INFERENCE_TIMEOUT).timeout, <decimal>45);
    // Other settings survive the copy.
    test:assertEquals(withDefaultTimeout({httpVersion: http:HTTP_1_1}, DEFAULT_TIMEOUT).httpVersion, http:HTTP_1_1);
}
