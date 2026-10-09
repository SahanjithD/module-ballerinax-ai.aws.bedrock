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

// BARE ids: Mantle has no cross-region inference, so takes no geo prefix. Every one
// is also on `bedrock-runtime`, which adds guardrails, cross-region inference and
// typed `generate()`, so the runtime class is the better default.
// https://docs.aws.amazon.com/bedrock/latest/userguide/models-endpoint-availability.html

# Anthropic model IDs on `bedrock-mantle`.
public enum AnthropicMantleModel {
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-5-5.html
    MANTLE_CLAUDE_OPUS_5_5 = "anthropic.claude-opus-5-5",
    MANTLE_CLAUDE_OPUS_5 = "anthropic.claude-opus-5",
    MANTLE_CLAUDE_OPUS_4_8 = "anthropic.claude-opus-4-8",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-4-7.html
    MANTLE_CLAUDE_OPUS_4_7 = "anthropic.claude-opus-4-7",
    MANTLE_CLAUDE_SONNET_5 = "anthropic.claude-sonnet-5",
    MANTLE_CLAUDE_HAIKU_4_5 = "anthropic.claude-haiku-4-5",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-fable-5.html
    # Needs an account opt-in: set the data retention mode to `aws_review` first
    MANTLE_CLAUDE_FABLE_5 = "anthropic.claude-fable-5",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-fable-5-1.html
    # Needs the Fable 5 opt-in
    MANTLE_CLAUDE_FABLE_5_1 = "anthropic.claude-fable-5-1"
}

# Configuration for `MantleAnthropicModelProvider`.
public type AnthropicMantleConfig record {|
    *CommonMantleConfig;

    // A typed record rather than raw `json`, so the mode/budget pairing rules are
    // checked at construction.
    # Extended thinking settings
    ThinkingConfig thinking?;

    // Sent as `output_config.effort`.
    # Reasoning effort. The only depth control on Fable 5 and Opus 4.7
    Effort effort?;
|};

// Signs as `bedrock-mantle`, a separate IAM namespace, so credentials that work on
// `bedrock-runtime` can still be denied here. No guardrails or cross-region inference.
// https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html

# Anthropic models on the Bedrock Mantle endpoint. `generate` can only return `string` here.
# Needs the `bedrock-mantle:CreateInference` IAM permission.
@display {label: "Bedrock Mantle Anthropic Model Provider"}
public isolated distinct client class MantleAnthropicModelProvider {
    *ai:ModelProvider;

    private final ApiFamily api;
    private final string wireModelId;
    private final readonly & ModelConverter converter;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    private final StructuredOutputStyle structuredOutput;

    # + model - An Anthropic model id, or any id string the endpoint serves
    # + auth - AWS credentials or a Bedrock API key; `auth:DEFAULT_CREDENTIALS` uses the default chain
    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + endpoint - FIPS, dual-stack or custom-endpoint options. Derived from the region when unset
    # + maxTokens - Maximum tokens to generate, including any thinking. Anthropic requires it
    # + temperature - Sampling temperature. Unset uses the model's own default
    # + config - Inference, passthrough and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} AnthropicMantleModel|string model,
            @display {label: "Authentication"} BedrockAuthConfig auth,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Maximum Tokens"} int maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *AnthropicMantleConfig config)
            returns ai:Error? {
        Route|error resolved = resolveMantleRoute(model, region);
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("MantleAnthropicModelProvider", auth, resolved, endpoint,
                config?.httpConfig, config?.retryConfig, ());

        self.api = route.api;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        // Params BEFORE headers: `serviceTier`/`latencyOptimized` ride InvokeModel
        // REQUEST HEADERS, so the header builder has to see them, and the route has to
        // be able to refuse the ones it cannot carry before any of it is stored.
        ThinkingConfig? thinking = config?.thinking;
        if thinking is ThinkingConfig {
            check validateThinking(thinking, maxTokens);
        }
        readonly & InferenceParams resolvedParams = buildInferenceParams(maxTokens, temperature,
                config?.stopSequences, config?.additionalModelRequestFields, (), (),
                (), thinking, config?.effort);
        check validateParamsForRoute("MantleAnthropicModelProvider", route.api, converter, resolvedParams);
        self.params = resolvedParams;
        self.extraHeaders = buildRouteHeaders(route, (),
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
