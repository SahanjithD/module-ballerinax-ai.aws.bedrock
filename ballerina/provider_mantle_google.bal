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

// The two generations sit on DIFFERENT paths: Gemma 3 speaks Chat Completions on
// `/v1/chat/completions`, Gemma 4 speaks Responses on `/openai/v1/responses`. The
// module resolves the path per model.
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-31b.html

# Google Gemma model IDs on `bedrock-mantle`.
public enum GoogleMantleModel {
    // Gemma 3 sits on `/v1/chat/completions` …
    MANTLE_GEMMA_3_4B_IT = "google.gemma-3-4b-it",
    MANTLE_GEMMA_3_12B_IT = "google.gemma-3-12b-it",
    MANTLE_GEMMA_3_27B_IT = "google.gemma-3-27b-it",
    // … while Gemma 4 sits on `/openai/v1/responses`. One vendor prefix, two Mantle
    // path families — which is exactly why the path is per-model table data and never
    // derived from the prefix.
    # Not available on `bedrock-runtime`
    MANTLE_GEMMA_4_E2B = "google.gemma-4-e2b",
    # Not available on `bedrock-runtime`
    MANTLE_GEMMA_4_26B_A4B = "google.gemma-4-26b-a4b",
    # Not available on `bedrock-runtime`
    MANTLE_GEMMA_4_31B = "google.gemma-4-31b"
}

# Configuration for `MantleGoogleModelProvider`.
public type GoogleMantleConfig record {|
    *CommonMantleConfig;
|};

// Signs as `bedrock-mantle`, a separate IAM namespace, so credentials that work on
// `bedrock-runtime` can still be denied here. No guardrails or cross-region inference.
// https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html

# Google models on the Bedrock Mantle endpoint.
# Needs the `bedrock-mantle:CreateInference` IAM permission.
@display {label: "Bedrock Mantle Google Model Provider"}
public isolated distinct client class MantleGoogleModelProvider {
    *ai:ModelProvider;

    private final ApiFamily api;
    private final string wireModelId;
    private final readonly & ModelConverter converter;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    private final StructuredOutputStyle structuredOutput;

    # + model - A Google model id, or any id string the endpoint serves
    # + auth - AWS credentials or a Bedrock API key; `auth:DEFAULT_CREDENTIALS` uses the default chain
    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + endpoint - FIPS, dual-stack or custom-endpoint options. Derived from the region when unset
    # + maxTokens - Maximum tokens to generate. Pass `()` to omit the field entirely
    # + temperature - Sampling temperature. Unset uses the model's own default
    # + config - Inference, passthrough and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} GoogleMantleModel|string model,
            @display {label: "Authentication"} BedrockAuthConfig auth,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *GoogleMantleConfig config)
            returns ai:Error? {
        Route|error resolved = resolveMantleRoute(model, region);
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("MantleGoogleModelProvider", auth, resolved, endpoint,
                config?.httpConfig, config?.retryConfig, ());

        self.api = route.api;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        // Params BEFORE headers: `serviceTier`/`latencyOptimized` ride InvokeModel
        // REQUEST HEADERS, so the header builder has to see them, and the route has to
        // be able to refuse the ones it cannot carry before any of it is stored.
        readonly & InferenceParams resolvedParams = buildInferenceParams(maxTokens, temperature,
                config?.stopSequences, config?.additionalModelRequestFields, (), (), ());
        check validateParamsForRoute("MantleGoogleModelProvider", route.api, converter, resolvedParams);
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
