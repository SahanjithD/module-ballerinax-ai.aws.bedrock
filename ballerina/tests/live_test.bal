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

// Live integration tests. These call real AWS and cost real money,
// so they are inert by default: with no credentials configured every test returns
// immediately. `bal test` on a clean checkout runs the other suites unchanged.
//
// To run them, put credentials in `tests/Config.toml`:
//
//   [ballerinax.ai.aws.bedrock]
//   liveTestsEnabled = true          # REQUIRED — every live test carries
//                                    # `enable: liveTestsEnabled`, which defaults to
//                                    # false. Omit it and `bal test --groups live`
//                                    # runs zero tests and reports no failure.
//   liveAccessKeyId = "AKIA..."
//   liveSecretAccessKey = "..."
//   liveRegion = "us-east-1"
//   liveConverseModelArn = "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-6"
//
// then: bal test --groups live
//
// These are the checks that CANNOT be settled offline — every one of them exists
// because a golden-file test would happily pass against a body AWS rejects.

configurable boolean liveTestsEnabled = false;
configurable string liveAccessKeyId = "";
configurable string liveSecretAccessKey = "";
configurable string liveSessionToken = "";
configurable string liveRegion = "us-east-1";

// A US cross-region inference-profile ARN. Left empty by default
// because the account id makes it caller-specific.
configurable string liveConverseModelArn = "";

// Whether to exercise the FIPS endpoint. Separate from `liveTestsEnabled` because
// FIPS is a per-region deployment: `bedrock-runtime-fips.{region}.{domain}` resolves
// in the commercial and GovCloud partitions, but the MODEL must also be served there.
// A failure here is an availability fact about your region, not a module defect.
configurable boolean liveFipsEnabled = false;

// Whether the account has bedrock-mantle access. Mantle needs the separate
// `bedrock-mantle:CreateInference` IAM action, so an account with working
// `bedrock:InvokeModel` permissions may still 403 here — that is a real access
// gap, not a module defect, hence its own switch.
configurable boolean liveMantleEnabled = false;

// Skips the whole suite when nothing is configured.
function liveCredentials() returns BedrockCredentials? {
    if liveAccessKeyId == "" || liveSecretAccessKey == "" {
        return ();
    }
    if liveSessionToken != "" {
        return {accessKeyId: liveAccessKeyId, secretAccessKey: liveSecretAccessKey, sessionToken: liveSessionToken};
    }
    return {accessKeyId: liveAccessKeyId, secretAccessKey: liveSecretAccessKey};
}

// ---- Converse via a US CRIS inference-profile ARN ----

@test:Config {groups: ["live"], enable: liveTestsEnabled}
function testLiveConverseViaCrisInferenceProfileArn() returns error? {
    BedrockCredentials? creds = liveCredentials();
    if creds is () || liveConverseModelArn == "" {
        return;
    }
    // The ARN exercises the SigV4 path-encoding split: its `:` and `/`
    // characters are single-encoded on the wire and double-encoded in the
    // signature. Get that wrong and this is a 403 — no golden test can catch it.
    ai:ModelProvider provider = check new AnthropicModelProvider(creds, liveConverseModelArn, liveRegion);
    ai:ChatAssistantMessage response = check provider->chat([
        {role: ai:SYSTEM, content: "Answer with exactly one word."},
        {role: ai:USER, content: "What colour is the sky on a clear day?"}
    ]);
    string content = response.content ?: "";
    test:assertTrue(content.trim().length() > 0, "live Converse returned empty content");
}

@test:Config {groups: ["live"], enable: liveTestsEnabled}
function testLiveConverseWithABareModelId() returns error? {
    BedrockCredentials? creds = liveCredentials();
    if creds is () {
        return;
    }
    ai:ModelProvider provider = check new AnthropicModelProvider(creds, CLAUDE_SONNET_4_6, liveRegion);
    ai:ChatAssistantMessage response = check provider->chat({role: ai:USER, content: "Say OK."});
    test:assertTrue((response.content ?: "").trim().length() > 0);
}

// ---- generate() — native structured output on Converse ----

type LiveFruit record {|
    string name;
    string colour;
|};

@test:Config {groups: ["live"], enable: liveTestsEnabled}
function testLiveGenerateOnConverseReturnsTheRecord() returns error? {
    BedrockCredentials? creds = liveCredentials();
    if creds is () {
        return;
    }
    // Proves the forced-tool round trip end to end: the derived JSON schema is
    // accepted as a tool by AWS, and the model's tool-call arguments bind back
    // into the record.
    AnthropicModelProvider provider = check new (creds, CLAUDE_SONNET_4_6, liveRegion);
    LiveFruit fruit = check provider->generate(`Name one common fruit and its colour.`);
    test:assertTrue(fruit.name.trim().length() > 0, "generate() returned an empty name");
    test:assertTrue(fruit.colour.trim().length() > 0, "generate() returned an empty colour");
}

// ---- Mantle via openai.gpt-5.4 ----

@test:Config {groups: ["live"], enable: liveTestsEnabled}
function testLiveMantleChat() returns error? {
    BedrockCredentials? creds = liveCredentials();
    if creds is () || !liveMantleEnabled {
        return;
    }
    // Mantle is a different host, a different wire dialect, a different SigV4
    // signing scope, and a different IAM namespace. Nothing about this path is
    // shared with Converse except the credentials.
    ai:ModelProvider provider = check new OpenAIModelProvider(creds, GPT_5_4, liveRegion);
    ai:ChatAssistantMessage response = check provider->chat({role: ai:USER, content: "Say OK."});
    test:assertTrue((response.content ?: "").trim().length() > 0);
}

@test:Config {groups: ["live"], enable: liveTestsEnabled}
function testLiveMantleRefusesStructuredOutputButReturnsText() returns error? {
    BedrockCredentials? creds = liveCredentials();
    if creds is () || !liveMantleEnabled {
        return;
    }
    OpenAIModelProvider provider = check new (creds, GPT_5_4, liveRegion);

    // A typed target must be refused locally, without spending a call.
    LiveFruit|ai:Error typed = provider->generate(`Name one common fruit and its colour.`);
    test:assertTrue(typed is ai:Error, "Mantle must refuse a typed target");

    // ...but a string target still works.
    string text = check provider->generate(`Say OK.`);
    test:assertTrue(text.trim().length() > 0);
}

// ---- Embeddings: Titan V2 + Cohere Embed English v3 ----

@test:Config {groups: ["live"], enable: liveTestsEnabled}
function testLiveTitanEmbedding() returns error? {
    BedrockCredentials? creds = liveCredentials();
    if creds is () {
        return;
    }
    ai:EmbeddingProvider provider = check new TitanEmbeddingProvider(
        creds, TITAN_EMBED_TEXT_V2, liveRegion, dimensions = 1024);
    ai:Embedding embedding = check provider->embed({content: "hello world", 'type: "text-chunk"});
    test:assertTrue(embedding is float[], "Titan must return a dense vector");
    if embedding is float[] {
        test:assertEquals(embedding.length(), 1024, "the configured dimensions must reach the wire");
    }
}

@test:Config {groups: ["live"], enable: liveTestsEnabled}
function testLiveCohereEmbeddingPreservesOrderAcrossWindows() returns error? {
    BedrockCredentials? creds = liveCredentials();
    if creds is () {
        return;
    }
    // 100 chunks > Cohere's 96-per-call wire limit, so this crosses a window
    // boundary (96 + 4) and is the real test of index-based reassembly.
    ai:TextChunk[] chunks = [];
    foreach int i in 0 ..< 100 {
        chunks.push({content: string `item number ${i}`, 'type: "text-chunk"});
    }
    ai:EmbeddingProvider provider = check new CohereEmbeddingProvider(
        creds, COHERE_EMBED_ENGLISH_V3, liveRegion, inputType = SEARCH_DOCUMENT);
    ai:Embedding[] embeddings = check provider->batchEmbed(chunks);
    test:assertEquals(embeddings.length(), 100, "one embedding per input, in input order");

    // Re-embed one item from the far side of the window boundary on its own; it
    // must match the batched result at the same index. If reassembly dropped or
    // reordered a window, this is where it shows.
    ai:Embedding single = check provider->embed(chunks[97]);
    ai:Embedding batched = embeddings[97];
    if single is float[] && batched is float[] {
        test:assertEquals(single.length(), batched.length());
        test:assertTrue(single.length() > 0);
        // Compare the leading components rather than the whole vector: identical
        // input and settings, so these must agree.
        foreach int i in 0 ..< 8 {
            test:assertTrue((single[i] - batched[i]).abs() < 0.0001,
                    string `index 97 differs at component ${i} — batch reassembly is misaligned`);
        }
    } else {
        test:assertFail("Cohere must return dense vectors");
    }
}


// ---- serviceUrl: FIPS endpoint ----

@test:Config {groups: ["live"], enable: liveTestsEnabled}
function testLiveFipsEndpointAcceptsASignedRequest() returns error? {
    BedrockCredentials? creds = liveCredentials();
    if creds is () || !liveFipsEnabled {
        return;
    }
    // The ONE thing no offline test can settle: whether AWS ACCEPTS a request to the
    // FIPS host. DNS proves the name exists and the mock-server test proves we send
    // the right bytes to whatever origin we are given — but only a real call proves
    // the signature validates against a host we did not derive ourselves.
    //
    // The invariant under test: the host changes, the signing scope does NOT. If
    // `serviceUrl` leaked into the SigV4 credential scope this returns 403
    // SignatureDoesNotMatch, which is exactly the regression worth paying for.
    ai:ModelProvider provider = check new AnthropicModelProvider(
            creds, "anthropic.claude-sonnet-4-6", liveRegion,
            serviceUrl = "https://bedrock-{endpoint}-fips.{region}.{domain}");
    ai:ChatAssistantMessage response = check provider->chat([
        {role: ai:USER, content: "Reply with the single word: ok"}
    ]);
    string content = response.content ?: "";
    test:assertTrue(content.trim().length() > 0, "live FIPS Converse returned empty content");
}

@test:Config {groups: ["live"], enable: liveTestsEnabled}
function testLiveDefaultAndFipsEndpointsAgree() returns error? {
    BedrockCredentials? creds = liveCredentials();
    if creds is () || !liveFipsEnabled {
        return;
    }
    // Same prompt, same model, two origins. Both must succeed — this catches a FIPS
    // host that resolves and authenticates but does not actually serve the model in
    // this region, which would otherwise surface only to the first customer to try it.
    ai:ModelProvider dflt = check new AnthropicModelProvider(
            creds, "anthropic.claude-sonnet-4-6", liveRegion);
    ai:ModelProvider fips = check new AnthropicModelProvider(
            creds, "anthropic.claude-sonnet-4-6", liveRegion,
            serviceUrl = "https://bedrock-{endpoint}-fips.{region}.{domain}");
    ai:ChatMessage[] prompt = [{role: ai:USER, content: "Reply with the single word: ok"}];
    ai:ChatAssistantMessage a = check dflt->chat(prompt);
    ai:ChatAssistantMessage b = check fips->chat(prompt);
    test:assertTrue((a.content ?: "").trim().length() > 0);
    test:assertTrue((b.content ?: "").trim().length() > 0);
}


// ---- effort: which Converse mechanism does Bedrock actually honour? ----

@test:Config {groups: ["live"], enable: liveTestsEnabled}
function testLiveConverseEffortIsAccepted() returns error? {
    BedrockCredentials? creds = liveCredentials();
    if creds is () {
        return;
    }
    // UNRESOLVED, and this is the test that resolves it. Two first-party sources
    // disagree on how `effort` reaches Converse:
    //
    //   botocore  -> a native `outputConfig: {effort}` member on ConverseRequest
    //   AWS docs  -> additionalModelRequestFields: {"output_config": {"effort": ...}}
    //
    // `converter_converse.bal` emits the NATIVE member. If Bedrock returns a 400
    // ValidationException here, that choice is wrong: switch to folding
    // `output_config` into the passthrough instead.
    ai:ModelProvider provider = check new AnthropicModelProvider(
            creds, "anthropic.claude-sonnet-4-6", liveRegion,
            apiFamily = CONVERSE,
            thinking = {mode: ADAPTIVE},
            effort = EFFORT_LOW);
    ai:ChatAssistantMessage response = check provider->chat([
        {role: ai:USER, content: "Reply with the single word: ok"}
    ]);
    test:assertTrue((response.content ?: "").trim().length() > 0,
            "Converse rejected the native outputConfig.effort member — use the passthrough form");
}

@test:Config {groups: ["live"], enable: liveTestsEnabled}
function testLiveAdaptiveThinkingOnTheMessagesDialect() returns error? {
    BedrockCredentials? creds = liveCredentials();
    if creds is () || !liveMantleEnabled {
        return;
    }
    // The regression this whole change exists for: `thinking` used to be folded into
    // `additionalModelRequestFields`, which the Anthropic Messages encoder ignores —
    // so the knob was silently dropped on this exact route. It is now a top-level
    // body field, and `output_config.effort` rides beside it.
    ai:ModelProvider provider = check new AnthropicModelProvider(
            creds, "anthropic.claude-haiku-4-5", liveRegion,
            apiFamily = MANTLE,
            thinking = {mode: ADAPTIVE},
            effort = EFFORT_LOW);
    ai:ChatAssistantMessage response = check provider->chat([
        {role: ai:USER, content: "Reply with the single word: ok"}
    ]);
    test:assertTrue((response.content ?: "").trim().length() > 0);
}
