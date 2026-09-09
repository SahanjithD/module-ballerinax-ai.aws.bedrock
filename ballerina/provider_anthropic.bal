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

// AnthropicModelProvider — a thin typed facade over the shared spine.
// Claude on Converse (default) / Mantle / Invoke-Anthropic.

# Well-known Claude model ids, in their BARE form. Any newer Claude is reachable by
# passing its id as a `string`.
#
# ON `bedrock-runtime` (Converse/Invoke) THESE IDS NEED A CROSS-REGION PREFIX.
# Current Claude models are served there through cross-region inference profiles
# only: the model card's regional-availability table marks In-Region unsupported in
# every region and lists the Geo (`us.`, `eu.`, `au.`) and Global (`global.`) profile
# ids as the way in — a bare id on Converse/Invoke fails with
# `on-demand throughput isn't supported`. So pass e.g. `"us.anthropic.claude-sonnet-5"`
# whenever you force `apiFamily = CONVERSE` or `INVOKE`. The resolver strips the
# prefix for lookup and re-applies it on the wire.
#
# The BARE id is the `bedrock-mantle` form, which takes no geo prefix — which is why
# these constants are bare and why an id carrying a prefix always routes to Converse.
# (One AWS doc inconsistency to be aware of: the model cards' own boto3 samples still
# show the bare id on Converse, contradicting the availability table on the same page.
# The table matches the error users actually hit.)
# https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html
public enum AnthropicModel {
    # Claude Opus 5 — 1M context, 128K max output, adaptive thinking on by default.
    # Dual-homed (Converse and Mantle); under `AUTO` it resolves to Mantle, so pass
    # `apiFamily = CONVERSE` for typed `generate()`.
    CLAUDE_OPUS_5 = "anthropic.claude-opus-5",
    CLAUDE_OPUS_4_8 = "anthropic.claude-opus-4-8",
    # Claude Sonnet 5 — 1M context, adaptive thinking always on. Dual-homed; under
    # `AUTO` it resolves to Mantle, so pass `apiFamily = CONVERSE` for typed
    # `generate()`.
    CLAUDE_SONNET_5 = "anthropic.claude-sonnet-5",
    CLAUDE_SONNET_4_6 = "anthropic.claude-sonnet-4-6",
    CLAUDE_HAIKU_4_5 = "anthropic.claude-haiku-4-5"
}

# Anthropic-specific configuration. Includes the shared `CommonModelConfig` and
# adds Claude-only knobs.
public type AnthropicConfig record {|
    *CommonModelConfig;
    # Extended/adaptive thinking. A typed record rather than raw `json`: the wire
    # spelling and the mode/budget pairing rules are enforced at construction.
    ThinkingConfig thinking?;
    # Reasoning depth, emitted as `output_config.effort`. The ONLY depth control on
    # the adaptive-only models (Mythos 5, Fable 5, Opus 4.7, Mythos Preview).
    Effort effort?;
|};

# Claude on AWS Bedrock. Routes to Converse, Mantle (Messages), or Invoke-Anthropic
# at construction.
public isolated distinct client class AnthropicModelProvider {
    *ai:ModelProvider;

    private final ApiFamily family;
    private final string wireModelId;
    private final readonly & ModelConverter converter;
    private final BedrockTransport transport;
    private final readonly & InferenceParams params;
    private final map<string> & readonly extraHeaders;
    // Structured output (generate() typed target) is unavailable on Mantle.
    // The spine generate() uses. Same objects as the chat spine EXCEPT when AUTO
    // sent chat to Mantle and the model is also on bedrock-runtime — then these hold
    // a Converse spine so a typed generate() works instead of erroring.
    private final ApiFamily genFamily;
    private final string genModelId;
    private final readonly & ModelConverter genConverter;
    private final BedrockTransport genTransport;
    private final map<string> & readonly genHeaders;
    private final boolean supportsStructuredOutput;

    # + model - A Claude id (bare, CRIS-prefixed, ARN, or `mantle/|converse/|invoke/` prefixed)
    # + credentials - AWS credential source. Pass `auth:DEFAULT_CREDENTIALS` for the full
    #                 AWS chain (env vars, EKS IRSA, SSO, shared config, EC2 IMDSv2), an
    #                 `auth:StaticAuthConfig`/`auth:AssumeRoleConfig`/... for an explicit
    #                 source, or a `BearerToken` for a Bedrock API key
    # + region - AWS region, e.g. `aws:US_EAST_1`. An ARN `model`'s region segment
    #            overrides it
    # + apiFamily - Route selection. `AUTO` (the default) runs the resolver;
    #               `CONVERSE`/`INVOKE`/`MANTLE` force that family and outrank every
    #               heuristic
    # + endpoint - Endpoint resolution options (`fips`, `dualstack`, `customEndpoint`).
    #              The host is derived from the region and the resolved route when this
    #              is `()`, which is correct in every partition — set it only for
    #              PrivateLink without private DNS, an egress gateway, or a local mock.
    #              A `customEndpoint` is a GLOBAL override with the same semantics as
    #              the AWS SDK's `AWS_ENDPOINT_URL`: it applies to every service this
    #              client talks to, and it skips the host-shape guards
    # + maxTokens - Maximum tokens to generate
    # + temperature - Sampling temperature. Leave unset (the default) to use the
    #                 model's own default — several current models reject it outright
    # + config - Routing overrides, guardrails, Converse passthrough, Claude knobs
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} AnthropicModel|string model,
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "API Family"} ApiFamily apiFamily = AUTO,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *AnthropicConfig config)
            returns ai:Error? {
        // ---- shared spine (identical in every vendor provider) ----
        RouteConfig routeConfig = {apiFamily};
        aws:EndpointConfig? endpointConfig = endpoint;
        // Resolved ONCE per provider and shared by the chat and generate spines.
        auth:CredentialProvider|BearerToken resolvedCredentials = check resolveCredentials(credentials);
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("AnthropicModelProvider", resolvedCredentials, model, region, endpointConfig, routeConfig,
                config?.httpConfig, config?.retryConfig, config?.guardrail);

        self.family = route.family;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        // Params BEFORE headers: `serviceTier`/`latencyOptimized` ride Invoke REQUEST
        // HEADERS, so the header builder has to see them, and the route has to be
        // able to refuse the ones it cannot carry before any of it is stored.
        readonly & InferenceParams resolvedParams = check resolveParams(maxTokens, temperature, config);
        check validateParamsForRoute("AnthropicModelProvider", route.family, converter, resolvedParams);
        self.params = resolvedParams;
        map<string> chatHeaders = buildExtraHeaders(route, config, credentials, resolvedParams);
        self.extraHeaders = chatHeaders.cloneReadOnly();
        [ApiFamily, string, readonly & ModelConverter, BedrockTransport, map<string>]
            [genFamily, genModelId, genConverter, genTransport, genHeaders] =
            check resolveGenerateSpine("AnthropicModelProvider", resolvedCredentials, credentials, model, region, endpointConfig,
                routeConfig, config?.httpConfig, config?.retryConfig, config?.guardrail,
                route, converter, transport, chatHeaders, resolvedParams);
        self.genFamily = genFamily;
        self.genModelId = genModelId;
        self.genConverter = genConverter;
        self.genTransport = genTransport;
        self.genHeaders = genHeaders.cloneReadOnly();
        self.supportsStructuredOutput = genFamily != MANTLE;
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
        => runChat("Anthropic", self.family, self.wireModelId, self.converter, self.transport,
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

// Resolves inference params once at construction. Folds the
// Claude `thinking` knob into the `additionalModelRequestFields`
// passthrough, which every Anthropic converter forwards.
isolated function resolveParams(int? maxTokens, decimal? temperature, AnthropicConfig config)
        returns readonly & InferenceParams|ai:Error {
    int resolvedMaxTokens = maxTokens ?: DEFAULT_MAX_TOKEN_COUNT;
    ThinkingConfig? thinking = config?.thinking;
    if thinking is ThinkingConfig {
        check validateThinking(thinking, resolvedMaxTokens);
    }
    return buildInferenceParams(maxTokens, temperature, config?.stopSequences,
        config?.additionalModelRequestFields, config?.serviceTier, config?.latencyOptimized,
        config?.guardrail, thinking, config?.effort);
}

// The budget rules AWS enforces with a 400. Checked before any I/O so the message
// names the actual mistake instead of surfacing as an opaque ValidationException.
// https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-extended-thinking.html
isolated function validateThinking(ThinkingConfig thinking, int maxTokens) returns ai:Error? {
    int? budget = thinking?.budgetTokens;
    if thinking.mode != ENABLED {
        if budget is int {
            return error ai:Error(string `'budgetTokens' is only valid with 'mode = ENABLED'; mode is ` +
                string `'${thinking.mode}'. Adaptive thinking is steered with 'effort' instead.`);
        }
        return;
    }
    if budget is () {
        return error ai:Error("'mode = ENABLED' requires 'budgetTokens' — manual extended thinking " +
            "has no default budget. Use 'mode = ADAPTIVE' to let the model decide.");
    }
    if budget < MIN_THINKING_BUDGET_TOKENS {
        return error ai:Error(string `'budgetTokens' must be at least ` +
            string `${MIN_THINKING_BUDGET_TOKENS}; got ${budget}.`);
    }
    if budget >= maxTokens {
        return error ai:Error(string `'budgetTokens' (${budget}) must be less than 'maxTokens' ` +
            string `(${maxTokens}) — the thinking budget is drawn from the same ceiling.`);
    }
}

// Route-specific headers computed once: the common Invoke
// guardrail and Mantle api-key headers, plus Anthropic's own Mantle Messages
// version header.
isolated function buildExtraHeaders(Route route, AnthropicConfig config, BedrockCredentials creds, InferenceParams? params = ())
        returns map<string> {
    // `x-api-key` is emitted by `commonExtraHeaders` for every Mantle Messages path —
    // it follows the path, not the vendor.
    map<string> headers = commonExtraHeaders(route, config?.guardrail, creds, params);
    MantleEntry? entry = route.mantleEntry;
    if route.family == MANTLE && entry is MantleEntry && usesApiKeyHeader(entry.path) {
        // Different value AND mechanism from the Invoke body field.
        // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html
        headers["anthropic-version"] = "2023-06-01";
    }
    return headers;
}
