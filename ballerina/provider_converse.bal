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

// Converse only: it is the one API with a single request format for every model, so the
// class needs no knowledge of the vendor. An unknown id is sent as given.
// https://docs.aws.amazon.com/bedrock/latest/userguide/models-api-compatibility.html

# Any Bedrock model, through the Converse API on the Bedrock Runtime endpoint.
# Needs the `bedrock:InvokeModel` IAM permission.
@display {label: "Bedrock Converse Model Provider"}
public isolated distinct client class ConverseModelProvider {
    *ai:ModelProvider;

    private final ApiFamily api;
    private final string wireModelId;
    private final readonly & ModelConverter converter;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    private final StructuredOutputStyle structuredOutput;

    # + model - Any Bedrock model ID, inference profile ID or ARN
    # + auth - AWS credentials or a Bedrock API key; `auth:DEFAULT_CREDENTIALS` uses the default chain
    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + endpoint - FIPS, dual-stack or custom-endpoint options. Derived from the region when unset
    # + maxTokens - Maximum tokens to generate. Pass `()` to omit the field entirely
    # + temperature - Sampling temperature. Unset uses the model's own default
    # + config - Inference, passthrough and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} string model,
            @display {label: "Authentication"} BedrockAuthConfig auth,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *ConverseConfig config)
            returns ai:Error? {
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("ConverseModelProvider", auth,
                resolveRuntimeRoute(model, region, CONVERSE), endpoint,
                config?.httpConfig, config?.retryConfig, config?.guardrail);

        self.api = route.api;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        readonly & InferenceParams resolvedParams = buildInferenceParams(maxTokens, temperature,
                config?.stopSequences, config?.additionalModelRequestFields, config?.serviceTier,
                config?.latencyOptimized, config?.guardrail);
        check validateParamsForRoute("ConverseModelProvider", route.api, converter, resolvedParams);
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
