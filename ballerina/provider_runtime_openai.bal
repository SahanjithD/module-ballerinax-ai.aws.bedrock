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

// The GPT-5.x ids are on `bedrock-mantle` in this module's verified per-card data —
// see `OpenAIMantleModel`. AWS's endpoint-availability page has since listed some
// GPT-5.6 ids on both endpoints, which contradicts those cards; rather than pick a
// side silently, this enum keeps the per-card reading, and any id can still be passed
// as a string. GPT OSS serves Chat Completions, Converse and Invoke here but NOT
// Responses.
// https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html

# OpenAI model IDs on `bedrock-runtime`.
public enum OpenAIRuntimeModel {
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
    # Not available on the `RESPONSES` API
    GPT_OSS_120B = "openai.gpt-oss-120b-1:0",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-20b.html
    # Not available on the `RESPONSES` API
    GPT_OSS_20B = "openai.gpt-oss-20b-1:0",
    // The GPT-6 family. CRIS-PREFIXED, unlike GPT OSS: each card says "You cannot use
    // the base model ID for in-Region calls on this endpoint". They serve Responses,
    // Chat Completions and Converse here, but NOT Invoke, and refuse the Chat
    // Completions `max_tokens` parameter (they are sent `max_completion_tokens`).
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-astra.html
    # Not available on the `INVOKE` API
    GPT_6_ASTRA = "us.openai.gpt-6-astra",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-sol.html
    # Not available on the `INVOKE` API
    GPT_6_SOL = "us.openai.gpt-6-sol",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-luna.html
    # Not available on the `INVOKE` API
    GPT_6_LUNA = "us.openai.gpt-6-luna"
}

# Configuration for `RuntimeOpenAIModelProvider`.
public type OpenAIRuntimeConfig record {|
    *CommonRuntimeConfig;

    // Top-level `reasoning_effort` on Chat Completions, nested `reasoning.effort` on
    // Responses.
    # How much the model reasons before answering
    ReasoningEffort reasoningEffort?;
|};

// AWS's recommended endpoint for new applications. Signs as `bedrock`.
// https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html

# OpenAI models on the Bedrock Runtime endpoint.
# Needs the `bedrock:InvokeModel` IAM permission.
@display {label: "Bedrock Runtime OpenAI Model Provider"}
public isolated distinct client class RuntimeOpenAIModelProvider {
    *ai:ModelProvider;

    private final ApiFamily api;
    private final string wireModelId;
    private final readonly & ModelConverter converter;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    private final StructuredOutputStyle structuredOutput;

    # + model - An OpenAI model id, or any id string the endpoint serves
    # + auth - AWS credentials or a Bedrock API key; `auth:DEFAULT_CREDENTIALS` uses the default chain
    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + apiType - The Bedrock API to call. Defaults to `CONVERSE`
    # + endpoint - FIPS, dual-stack or custom-endpoint options. Derived from the region when unset
    # + maxTokens - Maximum tokens to generate. Pass `()` to omit the field entirely
    # + temperature - Sampling temperature. Unset uses the model's own default
    # + config - Inference, passthrough and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} OpenAIRuntimeModel|string model,
            @display {label: "Authentication"} BedrockAuthConfig auth,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "API Type"} OpenAIRuntimeApi apiType = CONVERSE,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *OpenAIRuntimeConfig config)
            returns ai:Error? {
        Route|error resolved = resolveRuntimeRoute(model, region, apiType);
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("RuntimeOpenAIModelProvider", auth, resolved, endpoint,
                config?.httpConfig, config?.retryConfig, config?.guardrail);

        self.api = route.api;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        // Params BEFORE headers: `serviceTier`/`latencyOptimized` ride InvokeModel
        // REQUEST HEADERS, so the header builder has to see them, and the route has to
        // be able to refuse the ones it cannot carry before any of it is stored.
        readonly & InferenceParams resolvedParams = buildInferenceParams(maxTokens, temperature,
                config?.stopSequences, config?.additionalModelRequestFields, config?.serviceTier, config?.latencyOptimized,
                config?.guardrail, (), (), config?.reasoningEffort);
        check validateParamsForRoute("RuntimeOpenAIModelProvider", route.api, converter, resolvedParams);
        self.params = resolvedParams;
        self.extraHeaders = buildRouteHeaders(route, config?.guardrail,
                auth, resolvedParams).cloneReadOnly();
        self.structuredOutput =
            structuredOutputStyleFor(route.endpoint, route.api, converter.toolChoice);
    }

    # Sends a chat request to the model.
    #
    # + messages - Chat messages or a single user message
    # + tools - Tool definitions for function calling
    # + stop - Stop sequence; overrides configured `stopSequences`
    # + return - The assistant message, or an `ai:Error`
    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns ai:ChatAssistantMessage|ai:Error
        => runChat(self.api, self.wireModelId, self.converter, self.transport,
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
