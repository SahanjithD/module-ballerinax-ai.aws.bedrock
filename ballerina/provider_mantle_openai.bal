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
    MANTLE_GPT_OSS_120B = "openai.gpt-oss-120b-1:0",
    # The GPT-6 family. Bare here, and on `/openai/v1` — each card states it
    # explicitly ("On `bedrock-mantle`, both APIs use the `/openai/v1` base path. Do
    # not use `/v1`."). Regions differ per model on this endpoint: Astra is us-west-2
    # only, Sol and Luna are us-east-1.
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-astra.html
    MANTLE_GPT_6_ASTRA = "openai.gpt-6-astra",
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-sol.html
    MANTLE_GPT_6_SOL = "openai.gpt-6-sol",
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-luna.html
    MANTLE_GPT_6_LUNA = "openai.gpt-6-luna"
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
# SEPARATE IAM namespace, so `bedrock-runtime` credentials can still be denied here.
# No guardrails, cross-region inference or native structured output.
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

    # + model - An OpenAI model id, or any id string the endpoint serves
    # + credentials - AWS credentials, or `auth:DEFAULT_CREDENTIALS` for the default chain
    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + endpoint - FIPS, dual-stack or custom-endpoint options. Derived from the region when unset
    # + maxTokens - Maximum tokens to generate. Pass `()` to omit the field entirely
    # + temperature - Sampling temperature. Unset uses the model's own default
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
