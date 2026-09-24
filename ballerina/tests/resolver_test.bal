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

// Table tests on the pure resolvers. No AWS credentials needed.
//
// There is no longer ONE resolver with a preference ladder: the provider class fixes
// the endpoint, so `resolveRuntimeRoute` and `resolveMantleRoute` are separate
// functions with different rules, and neither can send a model to an endpoint the
// caller did not name.

const REGION = "us-east-1";

// ---- bare / CRIS-prefixed ids on bedrock-runtime ----

@test:Config {}
function testBareIdResolvesOnTheRuntimeEndpoint() returns error? {
    Route r = check resolveRuntimeRoute("amazon.nova-pro-v1:0", REGION, CONVERSE);
    test:assertEquals(r.endpoint, RUNTIME);
    test:assertEquals(r.api, CONVERSE);
    test:assertEquals(r.bareModelId, "amazon.nova-pro-v1:0");
    test:assertEquals(r.effectiveModelId, "amazon.nova-pro-v1:0");
    test:assertEquals(r.geoPrefix, ());
    test:assertEquals(r.region, REGION);
    test:assertEquals(r.mantleEntry, (), "a runtime route never carries a Mantle entry");
}

@test:Config {}
function testTheShapeArgumentIsCarriedOntoTheRoute() returns error? {
    // The class fixes the endpoint; the `api` argument fixes the shape. Nothing in
    // the resolver may override either.
    ApiFamily[] apis = [CONVERSE, INVOKE, CHAT_COMPLETIONS, RESPONSES, MESSAGES];
    foreach ApiFamily api in apis {
        Route r = check resolveRuntimeRoute("anthropic.claude-opus-5", REGION, api);
        test:assertEquals(r.api, api);
        test:assertEquals(r.endpoint, RUNTIME);
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
    // wire as-is and AWS answers for it. The old failure mode — absence from a map
    // read as evidence of Mantle — is gone with the ladder.
    Route r = check resolveRuntimeRoute("acme.brand-new-model-v9", REGION, CONVERSE);
    test:assertEquals(r.endpoint, RUNTIME);
    test:assertEquals(r.effectiveModelId, "acme.brand-new-model-v9");
    test:assertEquals(r.mantleEntry, ());
}

@test:Config {}
function testAMantleOnlyIdOnTheRuntimeResolverIsNotRewrittenOrRefused() returns error? {
    // GPT-5.5 is Mantle-only. The runtime resolver neither knows nor cares: it is
    // not a routing decision any more, so the id goes out verbatim and AWS refuses it
    // with its own diagnosis if it truly is not served there.
    Route r = check resolveRuntimeRoute("openai.gpt-5.5", REGION, RESPONSES);
    test:assertEquals(r.endpoint, RUNTIME);
    test:assertEquals(r.api, RESPONSES);
    test:assertEquals(r.effectiveModelId, "openai.gpt-5.5");
}

// ---- bedrock-mantle ----

@test:Config {}
function testMantleOnlyModelResolvesToItsPublishedPath() returns error? {
    Route r = check resolveMantleRoute("openai.gpt-5.4", REGION);
    test:assertEquals(r.endpoint, MANTLE);
    test:assertEquals(r.api, RESPONSES);
    test:assertEquals(r.effectiveModelId, "openai.gpt-5.4", "Mantle takes the bare id on the wire");
    MantleEntry entry = check r.mantleEntry.ensureType();
    test:assertEquals(check mantlePathFor(entry.basePath, r.api), "/openai/v1/responses");
    test:assertFalse(usesApiKeyHeader(r.api));
    test:assertEquals(NATIVE_RESPONSES_CONVERTER.toolChoice, RESPONSES_TOOL_CHOICE);
}

@test:Config {}
function testMantleAnthropicModelResolvesToTheMessagesPath() returns error? {
    Route r = check resolveMantleRoute("anthropic.claude-opus-5", REGION);
    test:assertEquals(r.endpoint, MANTLE);
    test:assertEquals(r.api, MESSAGES);
    MantleEntry entry = check r.mantleEntry.ensureType();
    test:assertEquals(check mantlePathFor(entry.basePath, r.api), "/anthropic/v1/messages");
    test:assertTrue(usesApiKeyHeader(r.api));
    test:assertEquals(NATIVE_MESSAGES_CONVERTER.toolChoice, ANTHROPIC_TOOL_CHOICE);
}

@test:Config {}
function testDualHomedModelResolvesOnBothEndpointsIndependently() returns error? {
    // Opus 4.8's card says bedrock-runtime YES + bedrock-mantle YES. Each class
    // reaches its own endpoint; neither resolution influences the other.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-4-8.html
    Route mantle = check resolveMantleRoute("anthropic.claude-opus-4-8", REGION);
    test:assertEquals(mantle.endpoint, MANTLE);
    test:assertEquals((check buildEndpoint(mantle)).path, "/anthropic/v1/messages");
    test:assertEquals((check buildEndpoint(mantle)).signingService, SIGNING_BEDROCK_MANTLE);

    Route runtime = check resolveRuntimeRoute("anthropic.claude-opus-4-8", REGION, CONVERSE);
    test:assertEquals(runtime.endpoint, RUNTIME);
    test:assertEquals((check buildEndpoint(runtime)).signingService, SIGNING_BEDROCK);
}

@test:Config {}
function testANonMantleModelIsRefusedByNameOnTheMantleResolver() {
    // Sonnet 4.6 is genuinely runtime-only per AWS's endpoint-availability table, so
    // there is no path to build — a clean construction error, not a hard 400 later.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/models-endpoint-availability.html
    Route|error r = resolveMantleRoute("anthropic.claude-sonnet-4-6", REGION);
    test:assertTrue(r is error);
    if r is error {
        test:assertTrue(r.message().includes("anthropic.claude-sonnet-4-6"), r.message());
        test:assertTrue(r.message().includes("bedrock-mantle"), r.message());
    }
}

@test:Config {}
function testAnUnknownModelIsRefusedRatherThanGivenAGuessedPath() {
    // The table must not become a fabricator: no entry means no URL exists to build.
    Route|error r = resolveMantleRoute("acme.totally-new", REGION);
    test:assertTrue(r is error);
}

@test:Config {}
function testMantleRejectsAnArn() {
    // An ARN names a bedrock-RUNTIME resource — a provisioned model, an inference
    // profile, a custom-model deployment. None of those exist on Mantle, and an ARN
    // is not a key into MANTLE_CAPABLE, so there is nothing to look up.
    Route|error r = resolveMantleRoute(
            "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-opus-5", REGION);
    test:assertTrue(r is error);
    if r is error {
        test:assertTrue(r.message().includes("ARN"), r.message());
        test:assertTrue(r.message().includes("bedrock-mantle"), r.message());
    }
}

@test:Config {}
function testMantleRejectsEveryArnResourceTypeIncludingFoundationModel() {
    // Even a foundation-model ARN, which the runtime resolver happily strips to a
    // bare id. Mantle takes bare ids only, and pretending otherwise would mean
    // accepting an ARN and silently ignoring everything it says.
    foreach string arn in [
        "arn:aws:bedrock::123456789012:foundation-model/anthropic.claude-opus-5",
        "arn:aws:bedrock:us-east-1:123456789012:provisioned-model/xyz",
        "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/opaque123",
        "arn:aws:bedrock:us-east-1:123456789012:custom-model-deployment/xyz"
    ] {
        test:assertTrue(resolveMantleRoute(arn, REGION) is error, arn + " must be refused on Mantle");
    }
}

@test:Config {}
function testMantleRejectsACrisGeoPrefixNamingTheBareId() {
    // A guard, not a silent strip: a caller who passed `us.` asked for cross-region
    // inference, and Mantle has none. Dropping the prefix would quietly give them
    // in-region routing under the name they used to request the opposite.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
    Route|error r = resolveMantleRoute("us.anthropic.claude-opus-5", REGION);
    test:assertTrue(r is error);
    if r is error {
        test:assertTrue(r.message().includes("anthropic.claude-opus-5"),
                "the refusal must name the bare id to pass instead; got: " + r.message());
        test:assertTrue(r.message().includes("cross-region"), r.message());
    }
}

@test:Config {}
function testMantleRejectsEveryCrisPrefixNotJustUs() {
    foreach string prefix in ["global", "us", "eu", "apac", "jp", "au", "us-gov"] {
        Route|error r = resolveMantleRoute(prefix + ".anthropic.claude-opus-5", REGION);
        test:assertTrue(r is error, prefix + ". must be refused on Mantle");
    }
}

@test:Config {}
function testAMantleRouteNeverCarriesAGeoPrefix() returns error? {
    Route r = check resolveMantleRoute("anthropic.claude-opus-5", REGION);
    test:assertEquals(r.geoPrefix, (), "cross-region inference is a bedrock-runtime concept");
}


@test:Config {}
function testMantleUsesItsOwnModelIdWhenTheEndpointsDisagree() returns error? {
    // gpt-oss is `openai.gpt-oss-120b-1:0` on bedrock-runtime but plain
    // `openai.gpt-oss-120b` on bedrock-mantle. Sending the runtime id to Mantle
    // fails, so MantleEntry.modelId overrides the wire id.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
    Route mantle = check resolveMantleRoute("openai.gpt-oss-120b-1:0", REGION);
    test:assertEquals(mantle.effectiveModelId, "openai.gpt-oss-120b", "Mantle has its own id for this model");
    test:assertEquals(mantle.bareModelId, "openai.gpt-oss-120b-1:0", "the lookup key stays the runtime id");

    // The runtime route keeps the `-1:0` id.
    Route runtime = check resolveRuntimeRoute("openai.gpt-oss-120b-1:0", REGION, CONVERSE);
    test:assertEquals(runtime.effectiveModelId, "openai.gpt-oss-120b-1:0");
}

// ---- Mantle path -> wire dialect ----

@test:Config {}
function testTheBasePathIsPerModelAndNotDerivableFromTheVendor() returns error? {
    // The single fact that forces this table to exist. `google.gemma-3-*` sits on
    // `/v1` while `google.gemma-4-*` sits on `/openai/v1` — one vendor prefix, two
    // base paths — and AWS's own cards say the same of gpt-oss (`/v1`) versus
    // GPT-5.6 (`/openai/v1`). No rule over the id or the shape produces this.
    MantleEntry gemma3 = check MANTLE_CAPABLE["google.gemma-3-27b-it"].ensureType();
    MantleEntry gemma4 = check MANTLE_CAPABLE["google.gemma-4-31b"].ensureType();
    test:assertEquals(gemma3.basePath, "/v1");
    test:assertEquals(gemma4.basePath, "/openai/v1");

    MantleEntry oss = check MANTLE_CAPABLE["openai.gpt-oss-120b-1:0"].ensureType();
    MantleEntry gpt56 = check MANTLE_CAPABLE["openai.gpt-5.6-sol"].ensureType();
    test:assertEquals(oss.basePath, "/v1");
    test:assertEquals(gpt56.basePath, "/openai/v1");
}

@test:Config {}
function testThePathSuffixIsDerivedFromTheShape() returns error? {
    // Only the base path is data; the suffix is a pure function of the shape and is
    // the same on both endpoints.
    test:assertEquals(check mantlePathFor("/anthropic/v1", MESSAGES), "/anthropic/v1/messages");
    test:assertEquals(check mantlePathFor("/openai/v1", RESPONSES), "/openai/v1/responses");
    test:assertEquals(check mantlePathFor("/v1", RESPONSES), "/v1/responses");
    test:assertEquals(check mantlePathFor("/openai/v1", CHAT_COMPLETIONS), "/openai/v1/chat/completions");
    test:assertEquals(check mantlePathFor("/v1", CHAT_COMPLETIONS), "/v1/chat/completions");
}

@test:Config {}
function testMantleServesNeitherConverseNorInvoke() {
    ApiFamily[] runtimeOnly = [CONVERSE, INVOKE];
    foreach ApiFamily api in runtimeOnly {
        string|error path = mantlePathFor("/v1", api);
        test:assertTrue(path is error, api);
    }
}

@test:Config {}
function testTheModelDecidesTheMantleShapeNotTheCaller() returns error? {
    // There is no shape argument on the Mantle classes: each model has exactly one
    // route this module takes, and it is the first shape its table row lists.
    Route oss = check resolveMantleRoute("openai.gpt-oss-120b-1:0", REGION);
    test:assertEquals(oss.api, CHAT_COMPLETIONS);
    test:assertEquals((check buildEndpoint(oss)).path, "/v1/chat/completions");

    Route claude = check resolveMantleRoute("anthropic.claude-opus-5", REGION);
    test:assertEquals(claude.api, MESSAGES);
    test:assertEquals((check buildEndpoint(claude)).path, "/anthropic/v1/messages");

    Route gpt = check resolveMantleRoute("openai.gpt-5.5", REGION);
    test:assertEquals(gpt.api, RESPONSES);
    test:assertEquals((check buildEndpoint(gpt)).path, "/openai/v1/responses");
}

@test:Config {}
function testChatCompletionsCarriesMostOfTheMantleSurface() returns error? {
    // A regression guard on a design question that came up twice: Chat Completions is
    // NOT an OpenAI-only shape on bedrock-mantle. Eight of the table's models use it
    // and none of them are OpenAI, so dropping it would leave the Mistral, Qwen and
    // DeepSeek Mantle classes with no constructible model at all.
    string[] chatOnly = ["zai.glm-5", "deepseek.v3.2", "mistral.mistral-large-3-675b-instruct",
        "qwen.qwen3-coder-480b-a35b-v1:0", "qwen.qwen3-32b-v1:0", "google.gemma-3-27b-it",
        "google.gemma-3-12b-it", "google.gemma-3-4b-it"];
    foreach string id in chatOnly {
        Route r = check resolveMantleRoute(id, REGION);
        test:assertEquals(r.api, CHAT_COMPLETIONS, id);
        test:assertFalse(id.startsWith("openai."), id + " is not an OpenAI model");
    }
}


@test:Config {}
function testEveryMantleTableEntryHasAResolvableDialect() returns error? {
    // The table stores only a base path and a shape list; everything else is derived.
    // An entry no derivation understands would fail at construction with an
    // internal-sounding message, so assert the whole table up front.
    foreach [string, MantleEntry] [id, entry] in MANTLE_CAPABLE.entries() {
        test:assertTrue(entry.apis.length() > 0, id);
        Route r = check resolveMantleRoute(id, REGION);
        test:assertEquals(r.api, entry.apis[0], id);
        string _ = check mantlePathFor(entry.basePath, r.api);
        readonly & ModelConverter _ = check selectConverter(r);
        Endpoint ep = check buildEndpoint(r);
        test:assertEquals(ep.path, check mantlePathFor(entry.basePath, r.api), id);
        test:assertEquals(ep.signingService, SIGNING_BEDROCK_MANTLE, id);
    }
}

@test:Config {}
function testMythosIsNotInTheMantleTable() {
    // `anthropic.claude-mythos-*` was never a real model. It was the canonical
    // "Mantle-only" fixture across eight test files; pinned here so it cannot drift
    // back in as a routing entry.
    test:assertFalse(MANTLE_CAPABLE.hasKey("anthropic.claude-mythos-preview"));
    test:assertFalse(MANTLE_CAPABLE.hasKey("anthropic.claude-mythos-5"));
}

// ---- ARN dispatch on bedrock-runtime ----

@test:Config {}
function testFoundationModelArnStripsToBareId() returns error? {
    Route r = check resolveRuntimeRoute(
            "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6", REGION, CONVERSE);
    test:assertEquals(r.endpoint, RUNTIME);
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
        test:assertEquals(r.endpoint, RUNTIME, arn);
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

@test:Config {}
function testMantleIsRejectedOnTheChinaPartitionBeforeAnyIo() returns error? {
    // The `api.aws` Mantle host is not partition-templated, and Bedrock is not
    // offered in `aws-cn` on any endpoint. Resolution succeeds — it is pure string
    // work — and `buildEndpoint` is where the mistake is named.
    Route r = check resolveMantleRoute("anthropic.claude-opus-4-8", "cn-north-1");
    test:assertEquals(r.partition, "aws-cn");
    Endpoint|error ep = buildEndpoint(r);
    test:assertTrue(ep is error, "Mantle must not build an endpoint on aws-cn");
    if ep is error {
        test:assertTrue(ep.message().includes("China") || ep.message().includes("partition"), ep.message());
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
// suffix — reporting them as `aws` let them past the Mantle host-shape guard.
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
function testTheRuntimeEndpointIsServedOnAPartitionThatHasNoMantle() returns error? {
    // The isolated partitions carry bedrock-runtime but no bedrock-mantle host, and
    // the DNS suffix is the partition's, not `amazonaws.com`.
    Route r = check resolveRuntimeRoute("anthropic.claude-opus-4-8", "us-iso-east-1", CONVERSE);
    test:assertEquals(r.partition, "aws-iso");
    Endpoint ep = check buildEndpoint(r);
    test:assertEquals(ep.baseUrl, "https://bedrock-runtime.us-iso-east-1.c2s.ic.gov");
    test:assertEquals(ep.signingService, SIGNING_BEDROCK);
}

@test:Config {}
function testMantleFailsOnAPartitionThatDoesNotServeIt() returns error? {
    // Constructing a BedrockMantle*ModelProvider in such a region is the caller
    // naming a destination that does not exist there. Name it, rather than building
    // a host that cannot answer.
    Route r = check resolveMantleRoute("anthropic.claude-opus-4-8", "us-iso-east-1");
    test:assertEquals(r.endpoint, MANTLE);
    Endpoint|error ep = buildEndpoint(r);
    test:assertTrue(ep is error);
    if ep is error {
        test:assertTrue(ep.message().includes("aws-iso"), ep.message());
        test:assertTrue(ep.message().includes("BedrockRuntime"),
                "the refusal must point at the class that works there; got: " + ep.message());
    }
}

@test:Config {}
function testMantleIsServedOnCommercialAndGovCloudPartitions() returns error? {
    foreach string region in ["us-east-1", "us-gov-west-1"] {
        Route r = check resolveMantleRoute("anthropic.claude-opus-4-8", region);
        Endpoint ep = check buildEndpoint(r);
        test:assertEquals(ep.signingService, SIGNING_BEDROCK_MANTLE, region);
        test:assertEquals(ep.host, string `bedrock-mantle.${region}.api.aws`, region);
    }
}
