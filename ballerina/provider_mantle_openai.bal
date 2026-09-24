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

# OpenAI model ids served on `bedrock-mantle`. The GPT-5.x models are reachable
# ONLY here; `generate()` with a typed target therefore returns an error for them.
public enum OpenAIMantleModel {
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-55.html
    MANTLE_GPT_5_5 = "openai.gpt-5.5",
    MANTLE_GPT_5_4 = "openai.gpt-5.4",
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-sol.html
    MANTLE_GPT_5_6_SOL = "openai.gpt-5.6-sol",
    MANTLE_GPT_5_6_TERRA = "openai.gpt-5.6-terra",
    MANTLE_GPT_5_6_LUNA = "openai.gpt-5.6-luna",
    # Published under a DIFFERENT id per endpoint — `-1:0` on bedrock-runtime, bare
    # here. The module puts the Mantle id on the wire for you.
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
    MANTLE_GPT_OSS_120B = "openai.gpt-oss-120b-1:0"
}

# Configuration for `BedrockMantleOpenAIModelProvider`.
public type OpenAIMantleConfig record {|
    *CommonMantleConfig;

    # How much reasoning the model spends. Emitted in the spelling the resolved
    # shape uses — top-level `reasoning_effort` on Chat Completions, nested
    # `reasoning.effort` on Responses.
    ReasoningEffort reasoningEffort?;
|};

# OpenAI models on the AWS Bedrock `bedrock-mantle` endpoint.
#
# Signs as `bedrock-mantle` and authorizes with `bedrock-mantle:CreateInference` — a
# SEPARATE IAM namespace, so credentials that work against `bedrock-runtime` can
# still return AccessDenied here. Guardrails, cross-region inference and structured
# output are not available on this endpoint.
# https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
public isolated distinct client class BedrockMantleOpenAIModelProvider {
    *ai:ModelProvider;

    private final ApiFamily api;
    private final string wireModelId;
    private final readonly & ModelConverter converter;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    private final StructuredOutputStyle structuredOutput;

    # + model - A OpenAI model id. Any id the endpoint serves may be passed as a `string`
    # + credentials - AWS credential source. Pass `auth:DEFAULT_CREDENTIALS` for the full
    #                 AWS chain (env vars, EKS IRSA, SSO, shared config, EC2 IMDSv2), an
    #                 `auth:StaticAuthConfig`/`auth:AssumeRoleConfig`/... for an explicit
    #                 source, or a `BearerToken` for a Bedrock API key
    # + region - AWS region, e.g. `aws:US_EAST_1`
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
            @display {label: "Model"} OpenAIMantleModel|string model,
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *OpenAIMantleConfig config)
            returns ai:Error? {
        Route|error resolved = resolveMantleRoute(model, region);
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("BedrockMantleOpenAIModelProvider", credentials, resolved, endpoint,
                config?.httpConfig, config?.retryConfig, ());

        self.api = route.api;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        // Params BEFORE headers: `serviceTier`/`latencyOptimized` ride InvokeModel
        // REQUEST HEADERS, so the header builder has to see them, and the route has to
        // be able to refuse the ones it cannot carry before any of it is stored.
        readonly & InferenceParams resolvedParams = buildInferenceParams(maxTokens, temperature,
                config?.stopSequences, config?.additionalModelRequestFields, (), (),
                (), (), (), config?.reasoningEffort);
        check validateParamsForRoute("BedrockMantleOpenAIModelProvider", route.api, converter, resolvedParams);
        self.params = resolvedParams;
        self.extraHeaders = buildRouteHeaders(route, (),
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
        => runChat("OpenAI", self.api, self.wireModelId, self.converter, self.transport,
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
