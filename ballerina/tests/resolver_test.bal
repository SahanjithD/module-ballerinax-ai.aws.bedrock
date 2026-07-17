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

// Table tests on the pure resolver (design §13.1). No AWS credentials needed.

const REGION = "us-east-1";

// ---- bare / CRIS-prefixed ids ----

@test:Config {}
function testBareIdResolvesToConverse() returns error? {
    Route r = check resolveRoute("anthropic.claude-opus-4-8", REGION);
    test:assertEquals(r.family, CONVERSE);
    test:assertEquals(r.bareModelId, "anthropic.claude-opus-4-8");
    test:assertEquals(r.effectiveModelId, "anthropic.claude-opus-4-8");
    test:assertEquals(r.geoPrefix, ());
    test:assertEquals(r.region, REGION);
    test:assertEquals(r.mantleEntry, ());
}

@test:Config {}
function testCrisPrefixStrippedForLookupAndReappliedOnWire() returns error? {
    // §5.3: the correct runtime id must resolve, and the prefix must survive to the wire.
    Route r = check resolveRoute("us.anthropic.claude-opus-4-8", REGION);
    test:assertEquals(r.family, CONVERSE);
    test:assertEquals(r.bareModelId, "anthropic.claude-opus-4-8", "prefix must be stripped for lookup");
    test:assertEquals(r.geoPrefix, "us");
    test:assertEquals(r.effectiveModelId, "us.anthropic.claude-opus-4-8", "prefix must be re-applied on the wire");
}

@test:Config {}
function testGlobalPrefixNormalization() returns error? {
    Route r = check resolveRoute("global.anthropic.claude-sonnet-4-6", REGION);
    test:assertEquals(r.geoPrefix, "global");
    test:assertEquals(r.bareModelId, "anthropic.claude-sonnet-4-6");
    test:assertEquals(r.effectiveModelId, "global.anthropic.claude-sonnet-4-6");
}

@test:Config {}
function testUnknownBareModelSinksToConverseNeverMantle() returns error? {
    // The fallback trap (design principle 2, §11): absence from a map is not evidence of Mantle.
    Route r = check resolveRoute("acme.brand-new-model-v9", REGION);
    test:assertEquals(r.family, CONVERSE);
    test:assertNotEquals(r.family, MANTLE);
    test:assertEquals(r.mantleEntry, ());
}

// ---- Mantle defaults ----

@test:Config {}
function testMantleOnlyModelDefaultsToMantle() returns error? {
    Route r = check resolveRoute("openai.gpt-5.4", REGION);
    test:assertEquals(r.family, MANTLE);
    test:assertEquals(r.effectiveModelId, "openai.gpt-5.4", "Mantle takes the bare id on the wire");
    MantleEntry entry = check r.mantleEntry.ensureType();
    test:assertEquals(entry.path, "/openai/v1/responses");
    test:assertEquals(entry.authHeader, BEARER);
    test:assertEquals(entry.codec, RESPONSES_CODEC);
}

@test:Config {}
function testMythosDefaultsToMantleWithMessagesPath() returns error? {
    Route r = check resolveRoute("anthropic.claude-mythos-preview", REGION);
    test:assertEquals(r.family, MANTLE);
    MantleEntry entry = check r.mantleEntry.ensureType();
    test:assertEquals(entry.path, "/anthropic/v1/messages");
    test:assertEquals(entry.authHeader, X_API_KEY);
    test:assertEquals(entry.codec, MESSAGES_CODEC);
}

// ---- explicit overrides ----

@test:Config {}
function testForceMantleOnDualEndpointModelResolvesViaCapable() returns error? {
    // §7.3: capability, not membership — a dual-endpoint model forced to Mantle must resolve.
    Route r = check resolveRoute("anthropic.claude-haiku-4-5", REGION, {apiFamily: MANTLE});
    test:assertEquals(r.family, MANTLE);
    MantleEntry entry = check r.mantleEntry.ensureType();
    test:assertEquals(entry.path, "/anthropic/v1/messages");
}

@test:Config {}
function testForceMantleOnConverseOnlyModelErrors() {
    // §7.3: not in MANTLE_CAPABLE → clean construction error, not a hard 400 later.
    Route|error r = resolveRoute("anthropic.claude-opus-4-8", REGION, {apiFamily: MANTLE});
    test:assertTrue(r is error);
    if r is error {
        test:assertTrue(r.message().includes("not available on Mantle"), r.message());
    }
}

@test:Config {}
function testMantlePrefixOverride() returns error? {
    Route r = check resolveRoute("mantle/anthropic.claude-haiku-4-5", REGION);
    test:assertEquals(r.family, MANTLE);
}

@test:Config {}
function testConversePrefixOverridesMantleDefault() returns error? {
    // Explicit override outranks the Mantle default (design principle 4, §5.1 step 1).
    Route r = check resolveRoute("converse/openai.gpt-5.4", REGION);
    test:assertEquals(r.family, CONVERSE);
    test:assertEquals(r.effectiveModelId, "openai.gpt-5.4");
}

@test:Config {}
function testRouteOverrideToMantleEntry() returns error? {
    MantleEntry newEntry = {path: "/openai/v1/responses", authHeader: BEARER, codec: RESPONSES_CODEC};
    Route r = check resolveRoute("openai.gpt-6", REGION, {routeOverrides: {"openai.gpt-6": newEntry}});
    test:assertEquals(r.family, MANTLE);
    MantleEntry entry = check r.mantleEntry.ensureType();
    test:assertEquals(entry.path, "/openai/v1/responses");
}

@test:Config {}
function testRouteOverrideToConverse() returns error? {
    Route r = check resolveRoute("newvendor.some-model", REGION, {routeOverrides: {"newvendor.some-model": INVOKE}});
    test:assertEquals(r.family, INVOKE);
}

// ---- ARN dispatch ----

@test:Config {}
function testFoundationModelArnStripsToBareId() returns error? {
    Route r = check resolveRoute(
        "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6", REGION);
    test:assertEquals(r.family, CONVERSE);
    test:assertEquals(r.bareModelId, "anthropic.claude-sonnet-4-6");
    test:assertEquals(r.region, "us-west-2", "ARN region overrides config.region (§5.2)");
}

@test:Config {}
function testImportedModelArnWithoutSchemaErrors() {
    Route|error r = resolveRoute(
        "arn:aws:bedrock:us-west-2:123456789012:imported-model/abc123def456", REGION);
    test:assertTrue(r is error);
    if r is error {
        test:assertTrue(r.message().includes("modelSchema"), r.message());
    }
}

@test:Config {}
function testImportedModelArnWithSchemaResolvesToInvoke() returns error? {
    Route r = check resolveRoute(
        "arn:aws:bedrock:us-west-2:123456789012:imported-model/abc123def456", REGION,
        {modelSchema: LLAMA});
    test:assertEquals(r.family, INVOKE);
    test:assertEquals(r.effectiveModelId,
        "arn:aws:bedrock:us-west-2:123456789012:imported-model/abc123def456",
        "opaque ARN goes on the wire verbatim");
    test:assertEquals(r.region, "us-west-2");
}

@test:Config {}
function testProvisionedModelArnResolvesToConverse() returns error? {
    Route r = check resolveRoute(
        "arn:aws:bedrock:eu-west-1:123456789012:provisioned-model/xyz", REGION);
    test:assertEquals(r.family, CONVERSE);
    test:assertEquals(r.region, "eu-west-1");
}

@test:Config {}
function testCustomModelDeploymentArnResolvesToConverse() returns error? {
    Route r = check resolveRoute(
        "arn:aws:bedrock:us-east-1:123456789012:custom-model-deployment/xyz", REGION);
    test:assertEquals(r.family, CONVERSE);
}

@test:Config {}
function testInferenceProfileArnResolvesToConverse() returns error? {
    Route r = check resolveRoute(
        "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-opus-4-8", REGION);
    test:assertEquals(r.family, CONVERSE);
}

@test:Config {}
function testApplicationInferenceProfileArnResolvesToConverse() returns error? {
    Route r = check resolveRoute(
        "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/opaque123", REGION);
    test:assertEquals(r.family, CONVERSE);
}

@test:Config {}
function testCustomModelArnErrors() {
    // §5.2 policy choice: artifact, not a deployment.
    Route|error r = resolveRoute(
        "arn:aws:bedrock:us-east-1:123456789012:custom-model/mymodel", REGION);
    test:assertTrue(r is error);
    if r is error {
        test:assertTrue(r.message().includes("artifact"), r.message());
    }
}

@test:Config {}
function testChinaPartitionArn() returns error? {
    Route r = check resolveRoute(
        "arn:aws-cn:bedrock:cn-north-1:123456789012:provisioned-model/xyz", REGION);
    test:assertEquals(r.partition, "aws-cn");
    test:assertEquals(r.region, "cn-north-1");
}

// ---- partition inference for bare ids ----

@test:Config {}
function testGovCloudRegionInfersPartition() returns error? {
    Route r = check resolveRoute("anthropic.claude-opus-4-8", "us-gov-west-1");
    test:assertEquals(r.partition, "aws-us-gov");
}

@test:Config {}
function testCommercialRegionInfersAwsPartition() returns error? {
    Route r = check resolveRoute("anthropic.claude-opus-4-8", "us-east-1");
    test:assertEquals(r.partition, "aws");
}

// ---- ARN parsing ----

@test:Config {}
function testParseArnSegments() returns error? {
    ParsedArn arn = check parseArn("arn:aws:bedrock:us-west-2:123456789012:imported-model/abc123");
    test:assertEquals(arn.partition, "aws");
    test:assertEquals(arn.'service, "bedrock");
    test:assertEquals(arn.region, "us-west-2");
    test:assertEquals(arn.accountId, "123456789012");
    test:assertEquals(arn.resourceType, "imported-model");
    test:assertEquals(arn.resourceId, "abc123");
}

@test:Config {}
function testParseArnRejectsNonArn() {
    ParsedArn|error r = parseArn("anthropic.claude-opus-4-8");
    test:assertTrue(r is error);
}

@test:Config {}
function testNormalizeModelIdKeepsNonCrisDotPrefix() {
    // "anthropic" is a vendor prefix, not a CRIS geo prefix — must not be stripped.
    [string, string?] [bareId, geoPrefix] = normalizeModelId("anthropic.claude-opus-4-8");
    test:assertEquals(bareId, "anthropic.claude-opus-4-8");
    test:assertEquals(geoPrefix, ());
}
