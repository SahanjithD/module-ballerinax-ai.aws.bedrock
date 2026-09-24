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
import ballerina/jballerina.java;

import ballerinax/aws;

# Google Gemma model ids served on `bedrock-runtime`. Gemma is the open-weight
# family; Gemini is not on Bedrock. Gemma 4 is Mantle-only — see `GoogleMantleModel`.
public enum GoogleRuntimeModel {
    GEMMA_3_4B_IT = "google.gemma-3-4b-it",
    GEMMA_3_12B_IT = "google.gemma-3-12b-it",
    // AWS titles this card "Gemma 3 27B PT" but its id really is `-it` — do not "correct" this.
    GEMMA_3_27B_IT = "google.gemma-3-27b-it"
}

# Configuration for `BedrockRuntimeGoogleModelProvider`.
public type GoogleRuntimeConfig record {|
    *CommonRuntimeConfig;
|};

# Google models on the AWS Bedrock `bedrock-runtime` endpoint — AWS's recommended
# endpoint for new applications.
#
# Signs as `bedrock` and authorizes with `bedrock:InvokeModel`.
# https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
public isolated distinct client class BedrockRuntimeGoogleModelProvider {
    *ai:ModelProvider;

    private final ApiShape shape;
    private final string wireModelId;
    private final readonly & ModelConverter converter;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    private final StructuredOutputStyle structuredOutput;

    # + model - A Google model id. Any id the endpoint serves may be passed as a `string`
    # + credentials - AWS credential source. Pass `auth:DEFAULT_CREDENTIALS` for the full
    #                 AWS chain (env vars, EKS IRSA, SSO, shared config, EC2 IMDSv2), an
    #                 `auth:StaticAuthConfig`/`auth:AssumeRoleConfig`/... for an explicit
    #                 source, or a `BearerToken` for a Bedrock API key
    # + region - AWS region, e.g. `aws:US_EAST_1`. An ARN `model`'s region segment
    #            overrides it
    # + api - The wire shape to use. `CONVERSE` (the default) is model-agnostic and
    #         the one AWS recommends; the others are this vendor's native dialects
    # + endpoint - Endpoint resolution options (`fips`, `dualstack`, `customEndpoint`).
    #              The host is derived from the region when this is `()`, which is correct
    #              in every partition — set it only for PrivateLink without private DNS,
    #              an egress gateway, or a local mock. A `customEndpoint` is a GLOBAL
    #              override with the same semantics as the AWS SDK's `AWS_ENDPOINT_URL`,
    #              and it skips the host-shape guards
    # + maxTokens - Maximum tokens to generate
    # + temperature - Sampling temperature. Leave unset (the default) to use the
    #                 model's own default — several current models reject it outright
    # + config - Inference, passthrough and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} GoogleRuntimeModel|string model,
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "API Shape"} ChatRuntimeApi api = CONVERSE,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *GoogleRuntimeConfig config)
            returns ai:Error? {
        Route|error resolved = resolveRuntimeRoute(model, region, api);
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("BedrockRuntimeGoogleModelProvider", credentials, resolved, endpoint,
                config?.httpConfig, config?.retryConfig, config?.guardrail);

        self.shape = route.shape;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        // Params BEFORE headers: `serviceTier`/`latencyOptimized` ride InvokeModel
        // REQUEST HEADERS, so the header builder has to see them, and the route has to
        // be able to refuse the ones it cannot carry before any of it is stored.
        readonly & InferenceParams resolvedParams = buildInferenceParams(maxTokens, temperature,
                config?.stopSequences, config?.additionalModelRequestFields, config?.serviceTier, config?.latencyOptimized, config?.guardrail);
        check validateParamsForRoute("BedrockRuntimeGoogleModelProvider", route.shape, converter, resolvedParams);
        self.params = resolvedParams;
        self.extraHeaders = buildRouteHeaders(route, config?.guardrail,
                credentials, resolvedParams).cloneReadOnly();
        self.structuredOutput =
            structuredOutputStyleFor(route.endpoint, route.shape, converter.toolChoice);
    }

    # Sends a chat request. Opens an observe span and closes it on every path.
    #
    # + messages - Chat messages or a single user message
    # + tools - Tool definitions for function calling
    # + stop - Stop sequence; overrides configured `stopSequences`
    # + return - The assistant message, or an `ai:Error`
    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns ai:ChatAssistantMessage|ai:Error
        => runChat("Google", self.shape, self.wireModelId, self.converter, self.transport,
            self.extraHeaders, self.params, messages, tools, stop);

    # Generates a value of the expected type.
    #
    # + prompt - The prompt to use in the chat request
    # + td - Type descriptor of the expected return type
    # + return - A value of the expected type, or an `ai:Error`
    isolated remote function generate(ai:Prompt prompt,
            @display {label: "Expected type"} typedesc<anydata> td = <>)
            returns td|ai:Error = @java:Method {
        'class: "io.ballerina.lib.ai.aws.bedrock.Generator"
    } external;
}
