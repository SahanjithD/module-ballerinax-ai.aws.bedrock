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

# Qwen model ids served on `bedrock-runtime`.
public enum QwenRuntimeModel {
    QWEN3_32B = "qwen.qwen3-32b-v1:0",
    // The card lists this exact id, In-Region, in us-east-1 among nine other regions,
    // so an "invalid model identifier" here is NOT a wrong id or a wrong region: it is
    // an account that has not been granted access to the model. Grant it in the
    // Bedrock console under Model access. The Mantle id works independently of that,
    // which is why one can succeed while the other does not.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-coder-480b-a35b-instruct.html

    # Qwen3 Coder 480B A35B — the flagship coding model (MoE, 480B/35B active).
    QWEN3_CODER_480B = "qwen.qwen3-coder-480b-a35b-v1:0"
}

# Configuration for `BedrockRuntimeQwenModelProvider`.
public type QwenRuntimeConfig record {|
    *CommonRuntimeConfig;

    # Qwen3 hybrid thinking. Forwarded as `enable_thinking` in the request body.
    boolean enableThinking?;
|};

# Qwen models on the AWS Bedrock `bedrock-runtime` endpoint — AWS's recommended
# endpoint for new applications.
#
# Signs as `bedrock` and authorizes with `bedrock:InvokeModel`.
# https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
public isolated distinct client class BedrockRuntimeQwenModelProvider {
    *ai:ModelProvider;

    private final ApiFamily api;
    private final string wireModelId;
    private final readonly & ModelConverter converter;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    private final StructuredOutputStyle structuredOutput;

    # + model - A Qwen model id, or any id string the endpoint serves
    # + credentials - AWS credentials, or `auth:DEFAULT_CREDENTIALS` for the default chain
    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + api - The API family to call. Defaults to `CONVERSE`
    # + endpoint - FIPS, dual-stack or custom-endpoint options. Derived from the region when unset
    # + maxTokens - Maximum tokens to generate. Pass `()` to omit the field entirely
    # + temperature - Sampling temperature. Unset uses the model's own default
    # + config - Inference, passthrough and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} QwenRuntimeModel|string model,
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "API"} QwenRuntimeApi api = CONVERSE,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *QwenRuntimeConfig config)
            returns ai:Error? {
        Route|error resolved = resolveRuntimeRoute(model, region, api);
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("BedrockRuntimeQwenModelProvider", credentials, resolved, endpoint,
                config?.httpConfig, config?.retryConfig, config?.guardrail);

        self.api = route.api;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        // Params BEFORE headers: `serviceTier`/`latencyOptimized` ride InvokeModel
        // REQUEST HEADERS, so the header builder has to see them, and the route has to
        // be able to refuse the ones it cannot carry before any of it is stored.
        // Qwen3 hybrid thinking has no modelled field on any dialect, so it rides the
        // verbatim passthrough.
        // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-32b.html
        AdditionalRequestFields? extra = config?.additionalModelRequestFields;
        boolean? enableThinking = config?.enableThinking;
        if enableThinking is boolean {
            extra = foldRequestFields(extra, {"enable_thinking": enableThinking});
        }
        readonly & InferenceParams resolvedParams = buildInferenceParams(maxTokens, temperature,
                config?.stopSequences, extra, config?.serviceTier, config?.latencyOptimized, config?.guardrail);
        check validateParamsForRoute("BedrockRuntimeQwenModelProvider", route.api, converter, resolvedParams);
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
        => runChat("Qwen", self.api, self.wireModelId, self.converter, self.transport,
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
