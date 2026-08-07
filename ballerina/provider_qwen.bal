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
// passthrough.

# Well-known Qwen model ids. Any newer id can be passed as a `string`.
public enum QwenModel {
    QWEN3_32B = "qwen.qwen3-32b-v1:0",
    # Qwen3 Coder 480B A35B — the flagship coding model (MoE, 480B/35B active).
    # This is the bedrock-runtime id; on bedrock-mantle the id differs
    # (`qwen.qwen3-coder-480b-a35b-instruct`, like gpt-oss) — `MANTLE_CAPABLE` carries
    # the swap, so forcing MANTLE works. In-Region callable (us-east-1 etc.); Geo/Global not
    # supported. Converse + Invoke; defaults to Converse here.
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-coder-480b-a35b-instruct.html
    QWEN3_CODER_480B = "qwen.qwen3-coder-480b-a35b-v1:0"
}

# Qwen-specific configuration.
public type QwenConfig record {|
    *CommonModelConfig;
    # Turns Qwen3's hybrid thinking mode on or off. Qwen3 can reason before
    # answering; enabling it trades latency and output tokens for quality on
    # multi-step tasks. Forwarded verbatim as `enable_thinking` via the
    # passthrough, so the name matches the wire field. Leave unset to use the
    # model's own default.
    #
    # This is a MODE switch, not a display switch: it controls whether the model
    # thinks at all, not whether the thinking text is returned.
    boolean enableThinking?;
|};

# Qwen models on AWS Bedrock.
public isolated distinct client class QwenModelProvider {
    *ai:ModelProvider;

    private final ApiFamily family;
    private final string wireModelId;
    private final readonly & ModelConverter converter;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    // The spine generate() uses. Same objects as the chat spine EXCEPT when AUTO
    // sent chat to Mantle and the model is also on bedrock-runtime — then these hold
    // a Converse spine so a typed generate() works instead of erroring.
    private final ApiFamily genFamily;
    private final string genModelId;
    private final readonly & ModelConverter genConverter;
    private final BedrockTransport genTransport;
    private final map<string> & readonly genHeaders;
    private final boolean supportsStructuredOutput;

    # + credentials - Static keys, STS, or a Bedrock API key
    # + model - A Qwen id (bare, CRIS-prefixed, ARN, or route-prefixed)
    # + region - Default region; an ARN `model`'s region segment overrides it. Also the
    #            SigV4 signing scope, which a custom `serviceUrl` does NOT change
    # + serviceUrl - Endpoint origin. The default template resolves per route —
    #                `{endpoint}` becomes `runtime` or `mantle`, `{region}` and
    #                `{domain}` follow the resolved route. Pass a concrete URL for a
    #                FIPS, dual-stack, PrivateLink or gateway host; the route-derived
    #                request path is still appended
    # + maxTokens - Maximum tokens to generate
    # + temperature - Sampling temperature. Leave unset (the default) to omit the
    #                 field entirely and use the model's own default — several current
    #                 models reject it outright
    # + config - Routing overrides, guardrails, passthrough, Qwen knobs
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Model"} QwenModel|string model,
            @display {label: "Region"} string region,
            @display {label: "Service URL"} string serviceUrl = DEFAULT_SERVICE_URL,
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *QwenConfig config)
            returns ai:Error? {
        RouteConfig routeConfig = {apiFamily: config.apiFamily};
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("QwenModelProvider", credentials, model, region, serviceUrl, routeConfig,
                config?.httpConfig, config?.retryConfig, config?.guardrail);

        self.family = route.family;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        map<string> chatHeaders = commonExtraHeaders(route, config?.guardrail, credentials);
        self.extraHeaders = chatHeaders.cloneReadOnly();
        [ApiFamily, string, readonly & ModelConverter, BedrockTransport, map<string>]
            [genFamily, genModelId, genConverter, genTransport, genHeaders] =
            check resolveGenerateSpine("QwenModelProvider", credentials, model, region, serviceUrl,
                routeConfig, config?.httpConfig, config?.retryConfig, config?.guardrail,
                route, converter, transport, chatHeaders);
        self.genFamily = genFamily;
        self.genModelId = genModelId;
        self.genConverter = genConverter;
        self.genTransport = genTransport;
        self.genHeaders = genHeaders.cloneReadOnly();
        self.supportsStructuredOutput = genFamily != MANTLE;
        self.params = qwenParams(maxTokens, temperature, config);
    }

    # + messages - Chat messages or a single user message
    # + tools - Tool definitions for function calling
    # + stop - Stop sequence; overrides configured `stopSequences`
    # + return - The assistant message, or an `ai:Error`
    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns ai:ChatAssistantMessage|ai:Error
        => runChat("Qwen", self.family, self.wireModelId, self.converter, self.transport,
            self.extraHeaders, self.params, messages, tools, stop);

    # Uses the generate spine, which differs from the chat spine when `AUTO` routed
    # chat to Mantle and the model is also served on `bedrock-runtime`.
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

// Folds the Qwen3 hybrid-thinking knob into the passthrough.
isolated function qwenParams(int? maxTokens, decimal? temperature, QwenConfig config)
        returns readonly & InferenceParams {
    map<json> extras = {};
    boolean? enableThinking = config?.enableThinking;
    if enableThinking is boolean {
        extras["enable_thinking"] = enableThinking;
    }
    AdditionalRequestFields? additional = foldRequestFields(config?.additionalModelRequestFields, extras);
    return buildInferenceParams(maxTokens, temperature, config?.stopSequences,
        additional, config?.serviceTier, config?.latencyOptimized, config?.guardrail);
}
