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

# Mistral model ids served on `bedrock-runtime`.
public enum MistralRuntimeModel {
    # Mistral Large 3 — the current flagship (675B, 256K context).
    MISTRAL_LARGE_3 = "mistral.mistral-large-3-675b-instruct",
    # Chat-completion dialect on InvokeModel (`messages`/`choices`), and Converse.
    MISTRAL_LARGE_2407 = "mistral.mistral-large-2407-v1:0",
    # Text-completion dialect on InvokeModel (`prompt`/`outputs`) — the opposite
    # dialect to its 24.07 sibling above, despite the shared family name.
    MISTRAL_LARGE_2402 = "mistral.mistral-large-2402-v1:0",
    # Text-completion dialect on InvokeModel; no tool-calling, so `generate()` with a
    # typed target is unavailable on the INVOKE shape for this id.
    MISTRAL_7B_INSTRUCT = "mistral.mistral-7b-instruct-v0:2"
}

# Configuration for `BedrockRuntimeMistralModelProvider`.
public type MistralRuntimeConfig record {|
    *CommonRuntimeConfig;
|};

# Mistral models on the AWS Bedrock `bedrock-runtime` endpoint — AWS's recommended
# endpoint for new applications.
#
# Signs as `bedrock` and authorizes with `bedrock:InvokeModel`.
# https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
public isolated distinct client class BedrockRuntimeMistralModelProvider {
    *ai:ModelProvider;

    private final ApiFamily api;
    private final string wireModelId;
    private final readonly & ModelConverter converter;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    private final StructuredOutputStyle structuredOutput;

    # + model - A Mistral model id, or any id string the endpoint serves
    # + credentials - AWS credentials, or `auth:DEFAULT_CREDENTIALS` for the default chain
    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + api - The API family to call. Defaults to `CONVERSE`
    # + endpoint - FIPS, dual-stack or custom-endpoint options. Derived from the region when unset
    # + maxTokens - Maximum tokens to generate. Pass `()` to omit the field entirely
    # + temperature - Sampling temperature. Unset uses the model's own default
    # + config - Inference, passthrough and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} MistralRuntimeModel|string model,
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "API"} MistralRuntimeApi api = CONVERSE,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *MistralRuntimeConfig config)
            returns ai:Error? {
        Route|error resolved = resolveRuntimeRoute(model, region, api);
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("BedrockRuntimeMistralModelProvider", credentials, resolved, endpoint,
                config?.httpConfig, config?.retryConfig, config?.guardrail);

        self.api = route.api;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        // Params BEFORE headers: `serviceTier`/`latencyOptimized` ride InvokeModel
        // REQUEST HEADERS, so the header builder has to see them, and the route has to
        // be able to refuse the ones it cannot carry before any of it is stored.
        readonly & InferenceParams resolvedParams = buildInferenceParams(maxTokens, temperature,
                config?.stopSequences, config?.additionalModelRequestFields, config?.serviceTier, config?.latencyOptimized, config?.guardrail);
        check validateParamsForRoute("BedrockRuntimeMistralModelProvider", route.api, converter, resolvedParams);
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
        => runChat("Mistral", self.api, self.wireModelId, self.converter, self.transport,
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
