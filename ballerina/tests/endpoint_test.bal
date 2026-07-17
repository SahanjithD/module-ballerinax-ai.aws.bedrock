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

// Endpoint + SigV4 canonical-URI encoding (design §9.1, §9.4). Regression tests
// for the double-encoding fix from the sub-agent review.

const ARN = "arn:aws:bedrock:us-west-2:123456789012:imported-model/abc123";

@test:Config {}
function testWirePathSingleEncodesArnModelIdSegment() returns error? {
    Route route = check resolveRoute(ARN, REGION, {modelSchema: LLAMA});
    Endpoint ep = check buildEndpoint(route);
    test:assertTrue(ep.path.startsWith("/model/") && ep.path.endsWith("/invoke"));
    test:assertTrue(ep.path.includes("%3A"), "ARN colons must be %3A on the wire");
    test:assertTrue(ep.path.includes("%2F"), "ARN internal slash must be %2F on the wire");
    test:assertFalse(ep.path.includes("arn:aws"), "raw colons must not appear on the wire path");
}

@test:Config {}
function testCanonicalUriDoubleEncodesWirePath() returns error? {
    // SigV4 non-S3 rule (§9.4): the canonical URI is the wire path encoded again.
    Route route = check resolveRoute(ARN, REGION, {modelSchema: LLAMA});
    Endpoint ep = check buildEndpoint(route);
    string canonical = getCanonicalUri(ep.path) ?: "";
    test:assertTrue(canonical.includes("%253A"), "canonical URI must double-encode the colon");
    test:assertTrue(canonical.includes("%252F"), "canonical URI must double-encode the ARN slash");
    test:assertTrue(canonical.startsWith("/model/") && canonical.endsWith("/invoke"),
        "structural separators must stay literal '/'");
}

@test:Config {}
function testBareIdWirePathHasNoEncodingArtifacts() returns error? {
    Route route = check resolveRoute("us.anthropic.claude-opus-4-8", REGION);
    Endpoint ep = check buildEndpoint(route);
    test:assertEquals(ep.path, "/model/us.anthropic.claude-opus-4-8/converse");
    // Unreserved chars: single == double, so the signature matches without ARNs.
    test:assertEquals(getCanonicalUri(ep.path), "/model/us.anthropic.claude-opus-4-8/converse");
}

@test:Config {}
function testMantleEndpointHostAndSigningService() returns error? {
    Route route = check resolveRoute("anthropic.claude-mythos-preview", "us-east-1");
    Endpoint ep = check buildEndpoint(route);
    test:assertEquals(ep.host, "bedrock-mantle.us-east-1.api.aws");
    test:assertEquals(ep.path, "/anthropic/v1/messages");
    test:assertEquals(ep.signingService, "bedrock-mantle");
}

@test:Config {}
function testConverseSigningServiceIsBedrock() returns error? {
    Route route = check resolveRoute("anthropic.claude-opus-4-8", "us-east-1");
    Endpoint ep = check buildEndpoint(route);
    test:assertEquals(ep.host, "bedrock-runtime.us-east-1.amazonaws.com");
    test:assertEquals(ep.signingService, "bedrock");
}

// Invoke guardrail-fired signal / request id arrive in response headers (§9.5).

@test:Config {}
function testAugmentFromHeadersSurfacesInvokeGuardrailAndRequestId() {
    DecodedResponse decoded = {
        message: {role: ai:ASSISTANT, content: "hi"},
        usage: {inputTokens: 1, outputTokens: 1},
        stopReason: "end_turn",
        responseId: (),
        guardrailAction: (),
        additionalModelResponseFields: ()
    };
    map<string> headers = {[GUARDRAIL_ACTION_HEADER]: "INTERVENED", [REQUEST_ID_HEADER]: "req-123"};
    augmentFromHeaders(decoded, headers);
    test:assertEquals(decoded.guardrailAction, INTERVENED, "Invoke guardrail-fired signal must not be dropped");
    test:assertEquals(decoded.responseId, "req-123");
}

@test:Config {}
function testAugmentFromHeadersDoesNotOverrideBodyGuardrail() {
    // Converse already set INTERVENED from the body stopReason — headers must not clobber it.
    DecodedResponse decoded = {
        message: {role: ai:ASSISTANT, content: ""},
        usage: {inputTokens: 1, outputTokens: 0},
        stopReason: "guardrail_intervened",
        responseId: "existing",
        guardrailAction: INTERVENED,
        additionalModelResponseFields: ()
    };
    augmentFromHeaders(decoded, {[GUARDRAIL_ACTION_HEADER]: "NONE", [REQUEST_ID_HEADER]: "other"});
    test:assertEquals(decoded.guardrailAction, INTERVENED);
    test:assertEquals(decoded.responseId, "existing");
}
