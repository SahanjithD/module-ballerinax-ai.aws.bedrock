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

# Claude model ids for `bedrock-mantle`, in their BARE form — Mantle takes no
# cross-region prefix, because it has no cross-region inference.
#
# All four are dual-homed (also on `bedrock-runtime`). Prefer the runtime class
# unless you need something only Mantle has: guardrails, cross-region inference and
# structured output are all runtime-only, and `generate()` with a typed target
# returns an error here.
# https://docs.aws.amazon.com/bedrock/latest/userguide/models-endpoint-availability.html
public enum AnthropicMantleModel {
    MANTLE_CLAUDE_OPUS_5 = "anthropic.claude-opus-5",
    MANTLE_CLAUDE_OPUS_4_8 = "anthropic.claude-opus-4-8",
    MANTLE_CLAUDE_SONNET_5 = "anthropic.claude-sonnet-5",
    MANTLE_CLAUDE_HAIKU_4_5 = "anthropic.claude-haiku-4-5"
}

# Configuration for `BedrockMantleAnthropicModelProvider`.
public type AnthropicMantleConfig record {|
    *CommonMantleConfig;

    # Extended/adaptive thinking. A typed record rather than raw `json`: the wire
    # spelling and the mode/budget pairing rules are enforced at construction.
    ThinkingConfig thinking?;

    # Reasoning depth, emitted as `output_config.effort`. The ONLY depth control on
    # the adaptive-only models (Fable 5, Opus 4.7).
    Effort effort?;
|};

# Anthropic models on the AWS Bedrock `bedrock-mantle` endpoint.
#
# Signs as `bedrock-mantle` and authorizes with `bedrock-mantle:CreateInference` — a
# SEPARATE IAM namespace, so credentials that work against `bedrock-runtime` can
# still return AccessDenied here. Guardrails, cross-region inference and structured
# output are not available on this endpoint.
# https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
public isolated distinct client class BedrockMantleAnthropicModelProvider {
    *ai:ModelProvider;

    private final ApiShape shape;
    private final string wireModelId;
    private final readonly & ModelConverter converter;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    private final StructuredOutputStyle structuredOutput;

    # + model - A Anthropic model id. Any id the endpoint serves may be passed as a `string`
    # + credentials - AWS credential source. Pass `auth:DEFAULT_CREDENTIALS` for the full
    #                 AWS chain (env vars, EKS IRSA, SSO, shared config, EC2 IMDSv2), an
    #                 `auth:StaticAuthConfig`/`auth:AssumeRoleConfig`/... for an explicit
    #                 source, or a `BearerToken` for a Bedrock API key
    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + endpoint - Endpoint resolution options (`fips`, `dualstack`, `customEndpoint`).
    #              The host is derived from the region when this is `()`, which is correct
    #              in every partition — set it only for PrivateLink without private DNS,
    #              an egress gateway, or a local mock. A `customEndpoint` is a GLOBAL
    #              override with the same semantics as the AWS SDK's `AWS_ENDPOINT_URL`,
    #              and it skips the host-shape guards
    # + maxTokens - Maximum tokens to generate
    # + temperature - Sampling temperature. Leave unset (the default) to use the
    #                 model's own default — several current models reject it outright
    # + config - Inference, passthrough and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} AnthropicMantleModel|string model,
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *AnthropicMantleConfig config)
            returns ai:Error? {
        Route|error resolved = resolveMantleRoute(model, region);
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("BedrockMantleAnthropicModelProvider", credentials, resolved, endpoint,
                config?.httpConfig, config?.retryConfig, ());

        self.shape = route.shape;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        // Params BEFORE headers: `serviceTier`/`latencyOptimized` ride InvokeModel
        // REQUEST HEADERS, so the header builder has to see them, and the route has to
        // be able to refuse the ones it cannot carry before any of it is stored.
        ThinkingConfig? thinking = config?.thinking;
        if thinking is ThinkingConfig {
            check validateThinking(thinking, maxTokens ?: DEFAULT_MAX_TOKEN_COUNT);
        }
        readonly & InferenceParams resolvedParams = buildInferenceParams(maxTokens, temperature,
                config?.stopSequences, config?.additionalModelRequestFields, (), (),
                (), thinking, config?.effort);
        check validateParamsForRoute("BedrockMantleAnthropicModelProvider", route.shape, converter, resolvedParams);
        self.params = resolvedParams;
        self.extraHeaders = buildRouteHeaders(route, (),
                credentials, resolvedParams).cloneReadOnly();
        self.structuredOutput =
            structuredOutputStyleFor(route.endpoint, route.shape, converter.toolChoice);
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
        => runChat("Anthropic", self.shape, self.wireModelId, self.converter, self.transport,
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
