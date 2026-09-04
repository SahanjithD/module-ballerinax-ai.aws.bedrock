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
import ballerinax/aws;
import ballerinax/aws.auth;
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
    # Accepted values differ between GPT-OSS (`low`|`medium`|`high`) and GPT-5.x
    # (the Responses API set, model-dependent); an unsupported value is rejected by
    # the endpoint. Leave unset to use the model's default.
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

    # + model - An OpenAI id (bare, CRIS-prefixed, ARN, or route-prefixed)
    # + credentials - AWS credential source. Pass `auth:DEFAULT_CREDENTIALS` for the full
    #                 AWS chain (env vars, EKS IRSA, SSO, shared config, EC2 IMDSv2), an
    #                 `auth:StaticAuthConfig`/`auth:AssumeRoleConfig`/... for an explicit
    #                 source, or a `BearerToken` for a Bedrock API key
    # + region - AWS region, e.g. `aws:US_EAST_1`. An ARN `model`'s region segment
    #            overrides it
    # + maxTokens - Maximum tokens to generate
    # + temperature - Sampling temperature. Leave unset (the default) to use the
    #                 model's own default — several current models reject it outright
    # + config - Routing overrides, guardrails, passthrough, OpenAI knobs
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} OpenAIModel|string model,
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *OpenAIConfig config)
            returns ai:Error? {
        RouteConfig routeConfig = {apiFamily: config.apiFamily};
        aws:EndpointConfig? endpointConfig = config?.endpoint;
        // Resolved ONCE per provider and shared by the chat and generate spines.
        auth:CredentialProvider|BearerToken resolvedCredentials = check resolveCredentials(credentials);
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("OpenAIModelProvider", resolvedCredentials, model, region, endpointConfig, routeConfig,
                config?.httpConfig, config?.retryConfig, config?.guardrail);

        self.family = route.family;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        map<string> chatHeaders = commonExtraHeaders(route, config?.guardrail, credentials);
        self.extraHeaders = chatHeaders.cloneReadOnly();
        [ApiFamily, string, readonly & ModelConverter, BedrockTransport, map<string>]
            [genFamily, genModelId, genConverter, genTransport, genHeaders] =
            check resolveGenerateSpine("OpenAIModelProvider", resolvedCredentials, credentials, model, region, endpointConfig,
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

    # Generates a value of the expected type by forcing a single tool whose schema
    # is that type. Available on the Converse and Invoke routes; a Mantle-routed
    # model returns an `ai:Error` for any target type other than `string`.
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
