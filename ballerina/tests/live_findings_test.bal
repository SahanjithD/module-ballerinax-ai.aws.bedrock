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

// Regressions for defects the live suite found against module 1.0.0 (N1, N2, N3, N9
// in the register). Each one compiled clean and failed only against AWS, so each
// gets an offline test that would have caught it.

type IntTarget int;

type StringArrayTarget string[];

// --- N2: a non-object target type 400s on every tool-forcing dialect ---------------

@test:Config {}
function testANonObjectTargetTypeIsWrappedInAnObjectSchema() returns error? {
    // Converse rejects `toolSpec.inputSchema.json.type` that is not `object`, and
    // Anthropic Messages says the same of `input_schema`. `int` derives
    // `{"type": "integer"}`, so it has to be wrapped before it reaches the wire.
    [map<json>, boolean] [schema, wrapped] = check wireSchemaFor(IntTarget);
    test:assertTrue(wrapped, "an int target must be reported as wrapped");
    test:assertEquals(schema["type"], "object", "the tool schema must always be an object");
    test:assertEquals(schema["properties"], <json>{"result": {"type": "integer"}});
    test:assertEquals(schema["required"], <json>["result"]);
}

@test:Config {}
function testAnArrayTargetTypeIsWrappedToo() returns error? {
    [map<json>, boolean] [schema, wrapped] = check wireSchemaFor(StringArrayTarget);
    test:assertTrue(wrapped, "an array target must be reported as wrapped");
    test:assertEquals(schema["properties"],
            <json>{"result": {"type": "array", "items": {"type": "string"}}});
}

@test:Config {}
function testARecordTargetTypeIsSentUnwrapped() returns error? {
    // The wrapper is only for types whose own schema is not an object; a record
    // already is one, and wrapping it would change the shape callers already get.
    // `SchemaProbe` is the fixture with a real generate() call site, so the compiler
    // plugin has attached its `@ai:JsonSchema` annotation (see to_json_schema_test).
    [map<json>, boolean] [schema, wrapped] = check wireSchemaFor(SchemaProbe);
    test:assertFalse(wrapped, "a record target must not be wrapped");
    test:assertEquals(schema["type"], "object");
    test:assertEquals(schema["properties"],
            <json>{"sentiment": {"type": "string"}, "score": {"type": "integer", "format": "int64"}});
}

@test:Config {}
function testTheWrapperIsTakenBackOffBeforeBinding() returns error? {
    anydata bound = check bindResult({"result": 42}, true, IntTarget, TEST_BIND_ORIGIN);
    test:assertEquals(bound, 42, "the caller asked for an int, not the wrapper object");
}

@test:Config {}
function testBindingStillWorksWhenTheModelDropsTheWrapper() returns error? {
    // The wrapper is this module's device, not something the caller asked for, so a
    // model that answers with the bare value must still bind.
    anydata bound = check bindResult(42, true, IntTarget, TEST_BIND_ORIGIN);
    test:assertEquals(bound, 42);
}

// --- N3: region strings are validated for shape -----------------------------------

@test:Config {}
function testATrailingSpaceInTheRegionIsRefusedAtConstruction() {
    // Without this the space is percent-encoded into the hostname and the caller sees
    // a connection error against `bedrock-runtime.us-east-1%20.amazonaws.com`, which
    // reads as a network fault rather than a typo.
    BedrockRuntimeAmazonModelProvider|error provider =
        new ("amazon.nova-pro-v1:0", TEST_CREDS, "us-east-1 ");
    test:assertTrue(provider is error, "a region with a trailing space must not construct");
    if provider is error {
        test:assertTrue(provider.message().includes("whitespace"), provider.message());
        test:assertTrue(provider.message().includes("us-east-1 "), provider.message());
    }
}

@test:Config {}
function testAnUppercaseRegionIsRefusedAtConstruction() {
    // This one reaches SigV4 intact and returns 403 "Credential should be scoped to a
    // valid region" — indistinguishable from a broken login.
    BedrockRuntimeAmazonModelProvider|error provider =
        new ("amazon.nova-pro-v1:0", TEST_CREDS, "US-EAST-1");
    test:assertTrue(provider is error, "an uppercase region must not construct");
    if provider is error {
        test:assertTrue(provider.message().includes("lowercase"), provider.message());
    }
}

@test:Config {}
function testAnUnknownButWellShapedRegionStillConstructs() returns error? {
    // The guard is a SHAPE check, not an allowlist: AWS adds regions faster than this
    // module ships, so a region it has never heard of must still go through.
    BedrockRuntimeAmazonModelProvider _ =
        check new ("amazon.nova-pro-v1:0", TEST_CREDS, "ap-southeast-9");
}

// --- N9: the id printed on a Mantle model card is accepted ------------------------

@test:Config {}
function testTheMantleSideIdIsAcceptedByTheMantleClass() returns error? {
    // The table is keyed on the bedrock-runtime id so both endpoints share one lookup
    // key, but the id a user reads off the Mantle model card is the Mantle one.
    // Refusing it was this module's bookkeeping leaking into the public surface.
    Route route = check resolveMantleRoute("openai.gpt-oss-120b", "us-east-1");
    test:assertEquals(route.effectiveModelId, "openai.gpt-oss-120b",
            "the Mantle id must reach the wire unchanged");
    test:assertEquals(route.api, CHAT_COMPLETIONS);
}

@test:Config {}
function testTheRuntimeSideIdStillResolvesOnMantle() returns error? {
    // The canonical key must keep working — this is an addition, not a replacement.
    Route route = check resolveMantleRoute("openai.gpt-oss-120b-1:0", "us-east-1");
    test:assertEquals(route.effectiveModelId, "openai.gpt-oss-120b");
}

@test:Config {}
function testBothQwenMantleCardIdsResolve() returns error? {
    Route coder = check resolveMantleRoute("qwen.qwen3-coder-480b-a35b-instruct", "us-east-1");
    test:assertEquals(coder.effectiveModelId, "qwen.qwen3-coder-480b-a35b-instruct");
    Route small = check resolveMantleRoute("qwen.qwen3-32b", "us-east-1");
    test:assertEquals(small.effectiveModelId, "qwen.qwen3-32b");
}

@test:Config {}
function testAGenuinelyUnknownMantleIdIsStillRefused() {
    // The reverse lookup must not turn the clean "not on Mantle" refusal into a
    // silent match on some other model.
    Route|error route = resolveMantleRoute("acme.not-a-model", "us-east-1");
    test:assertTrue(route is error);
    if route is error {
        test:assertTrue(route.message().includes("not available on bedrock-mantle"), route.message());
    }
}

// --- N1: the Haiku 4.5 runtime id is the dated, versioned profile -----------------

@test:Config {}
function testHaikuCarriesTheDatedRuntimeProfileId() {
    // The model card's Programmatic Access table gives `N/A` as the runtime Model ID
    // and names only the dated ids; the undated one is "model identifier is invalid".
    test:assertEquals(CLAUDE_HAIKU_4_5, "us.anthropic.claude-haiku-4-5-20251001-v1:0");
}

// --- §3/P45: a connection failure names the host it could not reach ---------------

@test:Config {}
function testAConnectionFailureNamesTheHostItDialled() returns error? {
    // A mistyped `customEndpoint` parses fine and then points nowhere, so it surfaces
    // as a connection error like any other. The HOST is the one fact that tells a
    // typo apart from a VPCE without private DNS, a dualstack flag on a service with
    // no dualstack record, and a genuine outage — so it has to be in the message.
    // `localhost:1` refuses immediately; `maxRetries: 0` keeps the backoff out of it.
    Endpoint ep = {
        baseUrl: "http://nowhere.invalid.example:1",
        host: "nowhere.invalid.example",
        path: "/model/x/converse",
        signingService: SIGNING_BEDROCK
    };
    BedrockTransport transport = check new (check resolveCredentials(TEST_CREDS), "us-east-1", ep,
            (), {maxRetries: 0});
    TransportResponse|ai:Error result = transport.execute({});
    test:assertTrue(result is ai:Error, "an unreachable host must be an error");
    if result is ai:Error {
        test:assertTrue(result.message().includes("nowhere.invalid.example"),
                "the error must name the host it dialled; got: " + result.message());
    }
}
