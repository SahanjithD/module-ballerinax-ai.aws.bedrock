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

// QwenModelProvider — `qwen.` prefix; Converse + Invoke; Qwen3 hybrid-thinking
// passthrough (CLAUDE.md §3).

# Well-known Qwen model ids. Any newer id can be passed as a `string`.
public enum QwenModel {
    QWEN3_32B = "qwen.qwen3-32b-v1:0"
}

# Qwen-specific configuration (CLAUDE.md §3).
public type QwenConfig record {|
    *CommonModelConfig;
    # Qwen3 hybrid thinking — forwarded as `enable_thinking` via the §9.3
    # passthrough. Leave unset to use the model's default.
    boolean showThinking?;
|};

# Qwen models on AWS Bedrock.
public isolated distinct client class QwenModelProvider {
    *ai:ModelProvider;

    private final ApiFamily family;
    private final string wireModelId;
    private final AuthHeaderStyle? authHeader;
    private final readonly & ModelCodec codec;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    private final boolean supportsStructuredOutput;

    # + credentials - Static keys, STS, or a Bedrock API key (§9.5)
    # + model - A Qwen id (bare, CRIS-prefixed, ARN, or route-prefixed)
    # + region - Default region; an ARN `model`'s region segment overrides it (§5.2)
    # + maxTokens - Maximum tokens to generate
    # + temperature - Sampling temperature
    # + config - Routing overrides, guardrails, passthrough, Qwen knobs
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Model"} QwenModel|string model,
            @display {label: "Region"} string region,
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = DEFAULT_TEMPERATURE,
            @display {label: "Configuration"} *QwenConfig config)
            returns ai:Error? {
        RouteConfig routeConfig = {
            apiFamily: config.apiFamily,
            modelSchema: config.modelSchema,
            routeOverrides: config.routeOverrides
        };
        [Route, readonly & ModelCodec, BedrockTransport] [route, codec, transport] =
            check resolveSpine("QwenModelProvider", credentials, model, region, routeConfig,
                config?.signingServiceName, config?.httpConfig, config?.retryConfig, config?.guardrail);

        self.family = route.family;
        self.wireModelId = route.effectiveModelId;
        self.authHeader = route.mantleEntry?.authHeader;
        self.codec = codec;
        self.transport = transport;
        self.supportsStructuredOutput = route.family != MANTLE; // amendment
        self.params = qwenParams(maxTokens, temperature, config);
        self.extraHeaders = commonExtraHeaders(route, config?.guardrail).cloneReadOnly();
    }

    # + messages - Chat messages or a single user message
    # + tools - Tool definitions for function calling
    # + stop - Stop sequence; overrides configured `stopSequences` (§7)
    # + return - The assistant message, or an `ai:Error`
    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns ai:ChatAssistantMessage|ai:Error
        => runChat("Qwen", self.family, self.wireModelId, self.codec, self.transport,
            self.extraHeaders, self.params, messages, tools, stop);

    # + prompt - The prompt to use in the chat request
    # + td - Type descriptor of the expected return type
    # + return - A value of the expected type, or an `ai:Error`
    isolated remote function generate(ai:Prompt prompt,
            @display {label: "Expected type"} typedesc<anydata> td = <>)
            returns td|ai:Error = @java:Method {
        'class: "io.ballerina.lib.ai.aws.bedrock.Generator"
    } external;
}

// Folds the Qwen3 hybrid-thinking knob into the §9.3 passthrough.
isolated function qwenParams(int? maxTokens, decimal? temperature, QwenConfig config)
        returns readonly & InferenceParams {
    map<json> extras = {};
    boolean? showThinking = config?.showThinking;
    if showThinking is boolean {
        extras["enable_thinking"] = showThinking;
    }
    json additional = foldRequestFields(config?.additionalModelRequestFields, extras);
    return buildInferenceParams(maxTokens, temperature, config?.topP, config?.stopSequences,
        additional, config?.additionalModelResponseFieldPaths, config?.serviceTier,
        config?.requestMetadata, config?.guardrail);
}
