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

    # Reasoning depth — trades latency and token cost against how much the model
    # thinks. Sent in the spelling the resolved route uses: a top-level
    # `reasoning_effort` on Chat Completions, `reasoning: {effort: ...}` on the
    # Responses API. You pass the value; the module picks the shape.
    #
    # The ACCEPTED VALUES are the model's, not this module's, and are deliberately not
    # enumerated here: they differ per model and AWS documents no closed list for
    # either family. `low`/`medium`/`high` work broadly; `max` is accepted on GPT-OSS
    # too (verified live, against an earlier doc comment that said otherwise). An
    # unsupported value is rejected by the endpoint, and the refusal enumerates the
    # set that model does accept — which is the authority worth reading, and the
    # reason a hard-coded list here would only ever go stale.
    #
    # Leave unset to use the model's default.
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
    # + config - Routing overrides, guardrails, passthrough, OpenAI knobs
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} OpenAIModel|string model,
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "API Family"} ApiFamily apiFamily = AUTO,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *OpenAIConfig config)
            returns ai:Error? {
        RouteConfig routeConfig = {apiFamily};
        aws:EndpointConfig? endpointConfig = endpoint;
        // Resolved ONCE per provider and shared by the chat and generate spines.
        auth:CredentialProvider|BearerToken resolvedCredentials = check resolveCredentials(credentials);
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("OpenAIModelProvider", resolvedCredentials, model, region, endpointConfig, routeConfig,
                config?.httpConfig, config?.retryConfig, config?.guardrail);

        self.family = route.family;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        // Params BEFORE headers: `serviceTier`/`latencyOptimized` ride Invoke REQUEST
        // HEADERS, so the header builder has to see them, and the route has to be
        // able to refuse the ones it cannot carry before any of it is stored.
        readonly & InferenceParams resolvedParams = openAIParams(maxTokens, temperature, config);
        check validateParamsForRoute("OpenAIModelProvider", route.family, converter, resolvedParams);
        self.params = resolvedParams;
        map<string> chatHeaders =
            commonExtraHeaders(route, config?.guardrail, credentials, resolvedParams);
        self.extraHeaders = chatHeaders.cloneReadOnly();
        [ApiFamily, string, readonly & ModelConverter, BedrockTransport, map<string>]
            [genFamily, genModelId, genConverter, genTransport, genHeaders] =
            check resolveGenerateSpine("OpenAIModelProvider", resolvedCredentials, credentials, model, region, endpointConfig,
                routeConfig, config?.httpConfig, config?.retryConfig, config?.guardrail,
                route, converter, transport, chatHeaders, resolvedParams);
        self.genFamily = genFamily;
        self.genModelId = genModelId;
        self.genConverter = genConverter;
        self.genTransport = genTransport;
        self.genHeaders = genHeaders.cloneReadOnly();
        self.supportsStructuredOutput = genFamily != MANTLE;
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

// Resolves the OpenAI knobs.
//
// `reasoningEffort` is passed as a FIRST-CLASS param, not folded into
// `additionalModelRequestFields`. Folding it there erased the one thing that matters
// about it — the wire spelling differs per dialect (`reasoning_effort` at top level
// on Chat Completions, `reasoning: {effort}` on Responses) — because the passthrough
// is spliced verbatim and this function has no idea which route the request is bound
// for. Only the converter knows, so only the converter can spell it. Keeping it out
// of the passthrough also keeps that escape hatch what it says it is: the CALLER's,
// forwarded untouched.
isolated function openAIParams(int? maxTokens, decimal? temperature, OpenAIConfig config)
        returns readonly & InferenceParams
    => buildInferenceParams(maxTokens, temperature, config?.stopSequences,
        config?.additionalModelRequestFields, config?.serviceTier, config?.latencyOptimized,
        config?.guardrail, (), (), config?.reasoningEffort);
