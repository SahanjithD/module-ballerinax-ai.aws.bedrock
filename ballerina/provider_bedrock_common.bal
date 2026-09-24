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

# Configuration for `BedrockCommonModelProvider`.
public type BedrockCommonConfig record {|
    *CommonRuntimeConfig;
|};

# Any Bedrock model, on the `bedrock-runtime` Converse API.
#
# This is the vendor-agnostic provider: it takes a model id as a plain `string` and
# reaches every model Bedrock serves on Converse — 15 of AWS's 17 providers, including
# the ten with no dedicated class in this module (Meta, Cohere, AI21, MiniMax,
# Moonshot, NVIDIA, Writer, xAI, Z.AI, Stability).
# https://docs.aws.amazon.com/bedrock/latest/userguide/models-api-compatibility.html
#
# CONVERSE-ONLY, and deliberately so. Converse is the one model-agnostic surface —
# a single request shape serves every vendor — so it is the only API this class can
# offer without knowing whose model it is holding. The alternatives all need that
# knowledge: InvokeModel's body is the model's own and is selected by vendor prefix,
# and the vendor-native shapes are specific protocols served for specific model sets.
# Offering those here would mean guessing a dialect from an id this module has never
# seen, and a wrong guess is a confusing 400 rather than an honest refusal. Use the
# matching `BedrockRuntime<Vendor>ModelProvider` when you need one of them.
#
# An unknown id is NOT an error: it goes on the wire as-is and AWS answers for it,
# which is what keeps a model AWS ships tomorrow usable without a module release.
#
# Signs as `bedrock` and authorizes with `bedrock:InvokeModel`.
public isolated distinct client class BedrockCommonModelProvider {
    *ai:ModelProvider;

    private final ApiFamily api;
    private final string wireModelId;
    private final readonly & ModelConverter converter;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    private final StructuredOutputStyle structuredOutput;

    # + model - Any Bedrock model id served on Converse — bare, cross-region-prefixed
    #           (`us.`, `eu.`, `apac.`, `global.`, ...), or an ARN for a provisioned
    #           model, inference profile or custom-model deployment
    # + credentials - AWS credential source. Pass `auth:DEFAULT_CREDENTIALS` for the full
    #                 AWS chain (env vars, EKS IRSA, SSO, shared config, EC2 IMDSv2), an
    #                 `auth:StaticAuthConfig`/`auth:AssumeRoleConfig`/... for an explicit
    #                 source, or a `BearerToken` for a Bedrock API key
    # + region - AWS region, e.g. `aws:US_EAST_1`. An ARN `model`'s region segment
    #            overrides it
    # + endpoint - Endpoint resolution options (`fips`, `dualstack`, `customEndpoint`).
    #              The host is derived from the region when this is `()`, which is correct
    #              in every partition — set it only for PrivateLink without private DNS,
    #              an egress gateway, or a local mock
    # + maxTokens - Maximum tokens to generate
    # + temperature - Sampling temperature. Leave unset (the default) to use the
    #                 model's own default — several current models reject it outright
    # + config - Inference, passthrough and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} string model,
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *BedrockCommonConfig config)
            returns ai:Error? {
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("BedrockCommonModelProvider", credentials,
                resolveRuntimeRoute(model, region, CONVERSE), endpoint,
                config?.httpConfig, config?.retryConfig, config?.guardrail);

        self.api = route.api;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        readonly & InferenceParams resolvedParams = buildInferenceParams(maxTokens, temperature,
                config?.stopSequences, config?.additionalModelRequestFields, config?.serviceTier,
                config?.latencyOptimized, config?.guardrail);
        check validateParamsForRoute("BedrockCommonModelProvider", route.api, converter, resolvedParams);
        self.params = resolvedParams;
        self.extraHeaders = buildRouteHeaders(route, config?.guardrail,
                credentials, resolvedParams).cloneReadOnly();
        self.structuredOutput =
            structuredOutputStyleFor(route.endpoint, route.api, converter.toolChoice);
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
        => runChat("Bedrock", self.api, self.wireModelId, self.converter, self.transport,
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
