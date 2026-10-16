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

// Table tests on the pure resolver. No AWS credentials needed.

const REGION = "us-east-1";

// ---- bare / CRIS-prefixed ids on bedrock-runtime ----

@test:Config {}
function testBareIdResolvesOnTheRuntimeEndpoint() returns error? {
    Route r = check resolveRuntimeRoute("amazon.nova-pro-v1:0", REGION, CONVERSE);
    test:assertEquals(r.api, CONVERSE);
    test:assertEquals(r.bareModelId, "amazon.nova-pro-v1:0");
    test:assertEquals(r.effectiveModelId, "amazon.nova-pro-v1:0");
    test:assertEquals(r.geoPrefix, ());
    test:assertEquals(r.region, REGION);
}

@test:Config {}
function testTheShapeArgumentIsCarriedOntoTheRoute() returns error? {
    // The `api` argument fixes the shape. Nothing in the resolver may override it.
    ApiFamily[] apis = [CONVERSE, INVOKE, CHAT_COMPLETIONS, RESPONSES, MESSAGES];
    foreach ApiFamily api in apis {
        Route r = check resolveRuntimeRoute("anthropic.claude-opus-5", REGION, api);
        test:assertEquals(r.api, api);
    }
}

@test:Config {}
function testCrisPrefixStrippedForLookupAndReappliedOnWire() returns error? {
    Route r = check resolveRuntimeRoute("us.anthropic.claude-opus-4-8", REGION, CONVERSE);
    test:assertEquals(r.bareModelId, "anthropic.claude-opus-4-8", "prefix must be stripped for lookup");
    test:assertEquals(r.geoPrefix, "us");
    test:assertEquals(r.effectiveModelId, "us.anthropic.claude-opus-4-8", "prefix must be re-applied on the wire");
}

@test:Config {}
function testGlobalPrefixNormalization() returns error? {
    Route r = check resolveRuntimeRoute("global.anthropic.claude-sonnet-4-6", REGION, CONVERSE);
    test:assertEquals(r.geoPrefix, "global");
    test:assertEquals(r.bareModelId, "anthropic.claude-sonnet-4-6");
    test:assertEquals(r.effectiveModelId, "global.anthropic.claude-sonnet-4-6");
}

@test:Config {}
function testUnknownBareModelIsNotAnErrorOnTheRuntimeEndpoint() returns error? {
    // Converse is model-agnostic, so an id this module has never heard of goes on the
    // wire as-is and AWS answers for it.
    Route r = check resolveRuntimeRoute("acme.brand-new-model-v9", REGION, CONVERSE);
    test:assertEquals(r.effectiveModelId, "acme.brand-new-model-v9");
}

// ---- ARN dispatch on bedrock-runtime ----

@test:Config {}
function testFoundationModelArnStripsToBareId() returns error? {
    Route r = check resolveRuntimeRoute(
            "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6", REGION, CONVERSE);
    test:assertEquals(r.bareModelId, "anthropic.claude-sonnet-4-6");
    test:assertEquals(r.region, "us-west-2", "ARN region overrides the region argument");
}

@test:Config {}
function testImportedModelArnIsRefusedByName() {
    // Custom Model Import is out of scope: AWS applies no default chat template to
    // imported weights, so no request body can be built without the caller naming the
    // dialect. Refuse at construction rather than fail opaquely on the wire.
    Route|error r = resolveRuntimeRoute(
            "arn:aws:bedrock:us-west-2:123456789012:imported-model/abc123def456", REGION, CONVERSE);
    test:assertTrue(r is error);
    if r is error {
        test:assertTrue(r.message().includes("imported-model"), r.message());
    }
}

@test:Config {}
function testOpaqueArnsResolveVerbatimOnTheRuntimeEndpoint() returns error? {
    // provisioned-model, custom-model-deployment, inference-profile and
    // application-inference-profile all go on the wire as the raw ARN.
    map<string> arns = {
        "arn:aws:bedrock:eu-west-1:123456789012:provisioned-model/xyz": "eu-west-1",
        "arn:aws:bedrock:us-east-1:123456789012:custom-model-deployment/xyz": "us-east-1",
        "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-opus-4-8": "us-east-1",
        "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/opaque123": "us-east-1"
    };
    foreach [string, string] [arn, region] in arns.entries() {
        Route r = check resolveRuntimeRoute(arn, REGION, CONVERSE);
        test:assertEquals(r.effectiveModelId, arn, "an opaque ARN goes on the wire verbatim");
        test:assertEquals(r.region, region, arn);
    }
}

@test:Config {}
function testCustomModelArnErrors() {
    // Policy choice: artifact, not a deployment.
    Route|error r = resolveRuntimeRoute(
            "arn:aws:bedrock:us-east-1:123456789012:custom-model/mymodel", REGION, CONVERSE);
    test:assertTrue(r is error);
    if r is error {
        test:assertTrue(r.message().includes("artifact"), r.message());
    }
}

@test:Config {}
function testChinaPartitionArn() returns error? {
    Route r = check resolveRuntimeRoute(
            "arn:aws-cn:bedrock:cn-north-1:123456789012:provisioned-model/xyz", REGION, CONVERSE);
    test:assertEquals(r.partition, "aws-cn");
    test:assertEquals(r.region, "cn-north-1");
}

@test:Config {}
function testChinaPartitionArnIsRejectedAtConstruction() returns error? {
    // Partition inference is only half the job. The partition is tracked so the
    // guards can fire, and `aws-cn` has no Bedrock at all — an ARN naming it is
    // well-formed and still unreachable.
    Route r = check resolveRuntimeRoute(
            "arn:aws-cn:bedrock:cn-north-1:123456789012:provisioned-model/xyz", REGION, CONVERSE);
    test:assertEquals(r.partition, "aws-cn");
    Endpoint|error ep = buildEndpoint(r);
    test:assertTrue(ep is error);
    if ep is error {
        test:assertTrue(ep.message().includes("China"), ep.message());
    }
}

// ---- partition inference for bare ids ----

@test:Config {}
function testGovCloudRegionInfersPartition() returns error? {
    Route r = check resolveRuntimeRoute("anthropic.claude-opus-4-8", "us-gov-west-1", CONVERSE);
    test:assertEquals(r.partition, "aws-us-gov");
}

@test:Config {}
function testGovCloudRouteBuildsACommercialSuffixHost() returns error? {
    // GovCloud keeps `.amazonaws.com` — only aws-cn differs. Asserted so the
    // partition-suffix branch cannot be "simplified" into applying to both.
    Route r = check resolveRuntimeRoute("anthropic.claude-opus-4-8", "us-gov-west-1", CONVERSE);
    Endpoint ep = check buildEndpoint(r);
    test:assertEquals(ep.host, "bedrock-runtime.us-gov-west-1.amazonaws.com");
    test:assertEquals(ep.signingService, SIGNING_BEDROCK);
}

@test:Config {}
function testCommercialRegionInfersAwsPartition() returns error? {
    Route r = check resolveRuntimeRoute("anthropic.claude-opus-4-8", "us-east-1", CONVERSE);
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

// ---- ARN structural segments ----

@test:Config {}
function testGlobalArnWithNoRegionFallsBackToTheCallerRegion() returns error? {
    // Foundation-model ARNs are commonly written without a region. Copying "" into
    // Route.region built the host `bedrock-runtime..amazonaws.com`, which surfaced
    // as an opaque DNS failure instead of anything actionable.
    Route r = check resolveRuntimeRoute(
            "arn:aws:bedrock::123456789012:foundation-model/anthropic.claude-sonnet-4-6",
            "eu-west-1", CONVERSE);
    test:assertEquals(r.region, "eu-west-1", "an empty ARN region must fall back to the caller's");
    Endpoint ep = check buildEndpoint(r);
    test:assertEquals(ep.host, "bedrock-runtime.eu-west-1.amazonaws.com");
}

@test:Config {}
function testArnRegionStillOverridesTheCallerRegionWhenPresent() returns error? {
    Route r = check resolveRuntimeRoute(
            "arn:aws:bedrock:ap-northeast-1:123456789012:inference-profile/apac.anthropic.claude-sonnet-4-6",
            "us-east-1", CONVERSE);
    test:assertEquals(r.region, "ap-northeast-1", "a present ARN region stays authoritative");
}

@test:Config {}
function testMalformedArnWithAnEmptyPartitionIsRejected() {
    Route|error r = resolveRuntimeRoute(
            "arn::bedrock:us-east-1:123456789012:provisioned-model/xyz", REGION, CONVERSE);
    test:assertTrue(r is error);
    if r is error {
        test:assertTrue(r.message().includes("partition"), r.message());
    }
}

@test:Config {}
function testNonBedrockArnIsRejectedAtConstruction() {
    // Without this the S3 ARN resolved fine and the user learned about it from an
    // opaque AWS error after a network call.
    Route|error r = resolveRuntimeRoute("arn:aws:s3:us-east-1:123456789012:bucket/foo", REGION, CONVERSE);
    test:assertTrue(r is error);
    if r is error {
        test:assertTrue(r.message().includes("Bedrock"), r.message());
    }
}

// ---------------------------------------------------------------------------
// Partition inference beyond `aws`/`aws-cn`/`aws-us-gov`. Bedrock carries a service
// entry in the isolated and EU Sovereign partitions too, and each has its own DNS
// suffix.
// ---------------------------------------------------------------------------

@test:Config {}
function testPartitionForRegionCoversEveryBedrockPartition() {
    test:assertEquals(partitionForRegion("us-east-1"), "aws");
    test:assertEquals(partitionForRegion("us-gov-west-1"), "aws-us-gov");
    test:assertEquals(partitionForRegion("cn-north-1"), "aws-cn");
    test:assertEquals(partitionForRegion("us-iso-east-1"), "aws-iso");
    test:assertEquals(partitionForRegion("us-isob-east-1"), "aws-iso-b");
    test:assertEquals(partitionForRegion("us-isof-east-1"), "aws-iso-f");
    test:assertEquals(partitionForRegion("eusc-de-east-1"), "aws-eusc");
}

@test:Config {}
function testIsobDoesNotMatchTheIsoPrefix() {
    // `us-isob-east-1`.startsWith("us-iso-") is false — the 7th character is `b`,
    // not `-` — so the four checks are order-independent. Pinned because a careless
    // `us-iso` (no trailing dash) would silently collapse three partitions into one.
    test:assertFalse("us-isob-east-1".startsWith("us-iso-"));
    test:assertFalse("us-isof-east-1".startsWith("us-iso-"));
}

@test:Config {}
function testTheRuntimeEndpointIsServedOnAnIsolatedPartition() returns error? {
    // The DNS suffix is the partition's, not `amazonaws.com`.
    Route r = check resolveRuntimeRoute("anthropic.claude-opus-4-8", "us-iso-east-1", CONVERSE);
    test:assertEquals(r.partition, "aws-iso");
    Endpoint ep = check buildEndpoint(r);
    test:assertEquals(ep.baseUrl, "https://bedrock-runtime.us-iso-east-1.c2s.ic.gov");
    test:assertEquals(ep.signingService, SIGNING_BEDROCK);
}
