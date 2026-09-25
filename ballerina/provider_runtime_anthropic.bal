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

# Well-known Claude model ids for `bedrock-runtime`, CRIS-PREFIXED.
#
# Current Claude models are served on this endpoint through cross-region inference
# profiles only: each model card's regional-availability table marks In-Region
# unsupported in every region and lists the Geo (`us.`, `eu.`, `au.`) and Global
# (`global.`) profile ids as the way in. A BARE id here fails with
# `on-demand throughput isn't supported`, which is why these constants carry `us.`.
# Pass a raw string for a different geo.
#
# (One AWS doc inconsistency to be aware of: the model cards' own boto3 samples still
# show the bare id, contradicting the availability table on the same page. The table
# matches the error users actually hit.)
# https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html
public enum AnthropicRuntimeModel {
    # Claude Opus 5 — 1M context, adaptive thinking on by default.
    CLAUDE_OPUS_5 = "us.anthropic.claude-opus-5",
    CLAUDE_OPUS_4_8 = "us.anthropic.claude-opus-4-8",
    # Claude Sonnet 5 — 1M context, adaptive thinking always on.
    CLAUDE_SONNET_5 = "us.anthropic.claude-sonnet-5",
    CLAUDE_SONNET_4_6 = "us.anthropic.claude-sonnet-4-6",
    # DATED AND VERSIONED, unlike its siblings above. The model card's Programmatic
    # Access table gives `N/A` as the runtime Model ID and names only
    # `us.|eu.|au.|jp.|global.anthropic.claude-haiku-4-5-20251001-v1:0`; the undated
    # id is refused with "The provided model identifier is invalid".
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-haiku-4-5.html
    CLAUDE_HAIKU_4_5 = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}

# Configuration for `BedrockRuntimeAnthropicModelProvider`.
public type AnthropicRuntimeConfig record {|
    *CommonRuntimeConfig;

    # Extended/adaptive thinking. A typed record rather than raw `json`: the wire
    # spelling and the mode/budget pairing rules are enforced at construction.
    ThinkingConfig thinking?;

    # Reasoning depth, emitted as `output_config.effort`. The ONLY depth control on
    # the adaptive-only models (Fable 5, Opus 4.7).
    Effort effort?;
|};

# Anthropic models on the AWS Bedrock `bedrock-runtime` endpoint — AWS's recommended
# endpoint for new applications.
#
# Signs as `bedrock` and authorizes with `bedrock:InvokeModel`.
# https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
public isolated distinct client class BedrockRuntimeAnthropicModelProvider {
    *ai:ModelProvider;

    private final ApiFamily api;
    private final string wireModelId;
    private final readonly & ModelConverter converter;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    private final StructuredOutputStyle structuredOutput;

    # + model - An Anthropic model id, or any id string the endpoint serves
    # + credentials - AWS credentials, or `auth:DEFAULT_CREDENTIALS` for the default chain
    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + api - The API family to call. Defaults to `CONVERSE`
    # + endpoint - FIPS, dual-stack or custom-endpoint options. Derived from the region when unset
    # + maxTokens - Maximum tokens to generate. Pass `()` to omit the field entirely
    # + temperature - Sampling temperature. Unset uses the model's own default
    # + config - Inference, passthrough and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} AnthropicRuntimeModel|string model,
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "API"} AnthropicRuntimeApi api = CONVERSE,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *AnthropicRuntimeConfig config)
            returns ai:Error? {
        Route|error resolved = resolveRuntimeRoute(model, region, api);
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("BedrockRuntimeAnthropicModelProvider", credentials, resolved, endpoint,
                config?.httpConfig, config?.retryConfig, config?.guardrail);

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
                config?.stopSequences, config?.additionalModelRequestFields, config?.serviceTier, config?.latencyOptimized,
                config?.guardrail, thinking, config?.effort);
        check validateParamsForRoute("BedrockRuntimeAnthropicModelProvider", route.api, converter, resolvedParams);
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
        => runChat("Anthropic", self.api, self.wireModelId, self.converter, self.transport,
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
