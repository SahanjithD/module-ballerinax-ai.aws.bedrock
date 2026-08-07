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

// OpenAIModelProvider — GPT-5.x via Mantle Responses (`/openai/v1/responses`),
// GPT-OSS via Converse/Invoke.

# Well-known OpenAI model ids on Bedrock. Any newer id can be passed as a `string`.
public enum OpenAIModel {
    // Mantle-only — these do not exist on bedrock-runtime.
    # `bedrock-mantle` only, Responses API. No structured output.
    GPT_5_6_SOL = "openai.gpt-5.6-sol",
    # `bedrock-mantle` only, Responses API. No structured output.
    GPT_5_6_TERRA = "openai.gpt-5.6-terra",
    # `bedrock-mantle` only, Responses API. No structured output.
    GPT_5_6_LUNA = "openai.gpt-5.6-luna",
    # `bedrock-mantle` only, Responses API. No structured output.
    GPT_5_5 = "openai.gpt-5.5",
    # `bedrock-mantle` only, Responses API. No structured output.
    GPT_5_4 = "openai.gpt-5.4",
    // Open-weight, on bedrock-runtime.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
    GPT_OSS_120B = "openai.gpt-oss-120b-1:0",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-20b.html
    GPT_OSS_20B = "openai.gpt-oss-20b-1:0"
}

# OpenAI-specific configuration.
public type OpenAIConfig record {|
    *CommonModelConfig;

    # `reasoning_effort` — trades latency and token cost against reasoning depth.
    # Forwarded verbatim via the passthrough, so the ACCEPTED VALUES ARE NOT
    # THE SAME for the two families this provider serves, and an unsupported value
    # is rejected by the endpoint rather than caught here:
    #
    # - GPT-OSS on `bedrock-runtime` (`GPT_OSS_120B`, `GPT_OSS_20B`):
    #   `low` | `medium` | `high`.
    # - GPT-5.x on `bedrock-mantle` (`GPT_5_4`, `GPT_5_5`, `GPT_5_6_*`): the
    #   Responses API set, which also includes `minimal` on some cards and drops
    #   values on others — check the model card for the id you are using.
    #
    # Left as a `string` rather than an enum precisely because the two sets differ
    # and both move; leave it unset to use the model's default.
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-openai.html
    string reasoningEffort?;
|};

# OpenAI models on AWS Bedrock (GPT-5.x on Mantle, GPT-OSS on bedrock-runtime).
public isolated distinct client class OpenAIModelProvider {
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
    # + model - An OpenAI id (bare, CRIS-prefixed, ARN, or route-prefixed)
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
    # + config - Routing overrides, guardrails, passthrough, OpenAI knobs
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Model"} OpenAIModel|string model,
            @display {label: "Region"} string region,
            @display {label: "Service URL"} string serviceUrl = DEFAULT_SERVICE_URL,
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *OpenAIConfig config)
            returns ai:Error? {
        RouteConfig routeConfig = {apiFamily: config.apiFamily};
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("OpenAIModelProvider", credentials, model, region, serviceUrl, routeConfig,
                config?.httpConfig, config?.retryConfig, config?.guardrail);

        self.family = route.family;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        map<string> chatHeaders = commonExtraHeaders(route, config?.guardrail, credentials);
        self.extraHeaders = chatHeaders.cloneReadOnly();
        [ApiFamily, string, readonly & ModelConverter, BedrockTransport, map<string>]
            [genFamily, genModelId, genConverter, genTransport, genHeaders] =
            check resolveGenerateSpine("OpenAIModelProvider", credentials, model, region, serviceUrl,
                routeConfig, config?.httpConfig, config?.retryConfig, config?.guardrail,
                route, converter, transport, chatHeaders);
        self.genFamily = genFamily;
        self.genModelId = genModelId;
        self.genConverter = genConverter;
        self.genTransport = genTransport;
        self.genHeaders = genHeaders.cloneReadOnly();
        self.supportsStructuredOutput = genFamily != MANTLE;
        self.params = openAIParams(maxTokens, temperature, config);
    }

    # + messages - Chat messages or a single user message
    # + tools - Tool definitions for function calling
    # + stop - Stop sequence; overrides configured `stopSequences`
    # + return - The assistant message, or an `ai:Error`
    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns ai:ChatAssistantMessage|ai:Error
        => runChat("OpenAI", self.family, self.wireModelId, self.converter, self.transport,
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

// Folds the OpenAI `reasoningEffort` knob into the passthrough.
isolated function openAIParams(int? maxTokens, decimal? temperature, OpenAIConfig config)
        returns readonly & InferenceParams {
    map<json> extras = {};
    string? reasoningEffort = config?.reasoningEffort;
    if reasoningEffort is string {
        extras["reasoning_effort"] = reasoningEffort;
    }
    AdditionalRequestFields? additional = foldRequestFields(config?.additionalModelRequestFields, extras);
    return buildInferenceParams(maxTokens, temperature, config?.stopSequences,
        additional, config?.serviceTier, config?.latencyOptimized, config?.guardrail);
}
