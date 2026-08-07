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

// GoogleModelProvider — Gemma (open-weight). Gemini is NOT on Bedrock.
//
// Which endpoint serves Gemma? BOTH, and it splits by generation — the per-model
// cards are the only authority:
//
//   Gemma 3 — dual-homed. Its cards tick bedrock-runtime AND bedrock-mantle, so
//             the module routes it to Converse (the richer surface). Note AWS's
//             cards say "whenever possible, we recommend you use the bedrock-mantle
//             endpoint"; Converse is supported, so this is a deliberate choice.
//   Gemma 4 — bedrock-mantle ONLY. Its card marks bedrock-runtime / Converse /
//             Invoke / Messages all NO, and serves it from `/openai/v1/responses`.
//             So it signs `bedrock-mantle`, and it CANNOT do structured output.
//
// The routing lives in MANTLE_CAPABLE (constants.bal), not here.
//
// HISTORY: this file previously claimed Gemma was on bedrock-runtime because it
// appeared "in no Mantle table". That is routing by elimination — the very
// inference the design forbids — and it was wrong for Gemma 4.
// A model's absence from a table is never evidence of its endpoint.
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-31b.html
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-27b-pt.html

# Well-known Google Gemma model ids. Any newer id can be passed as a `string`.
public enum GoogleModel {
    # Converse on `bedrock-runtime` (also served on Mantle).
    GEMMA_3_4B_IT = "google.gemma-3-4b-it",
    # Converse on `bedrock-runtime` (also served on Mantle).
    GEMMA_3_12B_IT = "google.gemma-3-12b-it",
    # Converse on `bedrock-runtime` (also served on Mantle). AWS titles this card
    # "Gemma 3 27B PT" but its id really is `-it` — do not "correct" this.
    GEMMA_3_27B_IT = "google.gemma-3-27b-it",
    # `bedrock-mantle` ONLY — structured output is not available on this route.
    GEMMA_4_E2B = "google.gemma-4-e2b",
    # `bedrock-mantle` ONLY — structured output is not available on this route.
    GEMMA_4_26B_A4B = "google.gemma-4-26b-a4b",
    # `bedrock-mantle` ONLY — structured output is not available on this route.
    GEMMA_4_31B = "google.gemma-4-31b"
}

# Google-specific configuration.
public type GoogleConfig record {|
    *CommonModelConfig;
|};

# Google Gemma models on AWS Bedrock. Gemma 3 routes to Converse on
# `bedrock-runtime`; Gemma 4 is served only on `bedrock-mantle` and therefore
# supports neither structured output nor guardrails.
public isolated distinct client class GoogleModelProvider {
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
    # + model - A Gemma id (bare, CRIS-prefixed, ARN, or route-prefixed)
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
    # + config - Routing overrides, guardrails, Converse passthrough
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Model"} GoogleModel|string model,
            @display {label: "Region"} string region,
            @display {label: "Service URL"} string serviceUrl = DEFAULT_SERVICE_URL,
            @display {label: "Maximum Tokens"} int? maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Configuration"} *GoogleConfig config)
            returns ai:Error? {
        RouteConfig routeConfig = {apiFamily: config.apiFamily};
        [Route, readonly & ModelConverter, BedrockTransport] [route, converter, transport] =
            check resolveSpine("GoogleModelProvider", credentials, model, region, serviceUrl, routeConfig,
                config?.httpConfig, config?.retryConfig, config?.guardrail);

        self.family = route.family;
        self.wireModelId = route.effectiveModelId;
        self.converter = converter;
        self.transport = transport;
        map<string> chatHeaders = commonExtraHeaders(route, config?.guardrail, credentials);
        self.extraHeaders = chatHeaders.cloneReadOnly();
        [ApiFamily, string, readonly & ModelConverter, BedrockTransport, map<string>]
            [genFamily, genModelId, genConverter, genTransport, genHeaders] =
            check resolveGenerateSpine("GoogleModelProvider", credentials, model, region, serviceUrl,
                routeConfig, config?.httpConfig, config?.retryConfig, config?.guardrail,
                route, converter, transport, chatHeaders);
        self.genFamily = genFamily;
        self.genModelId = genModelId;
        self.genConverter = genConverter;
        self.genTransport = genTransport;
        self.genHeaders = genHeaders.cloneReadOnly();
        self.supportsStructuredOutput = genFamily != MANTLE;
        self.params = buildInferenceParams(maxTokens, temperature, config?.stopSequences,
            config?.additionalModelRequestFields, config?.serviceTier,
            config?.latencyOptimized, config?.guardrail);
    }

    # + messages - Chat messages or a single user message
    # + tools - Tool definitions for function calling
    # + stop - Stop sequence; overrides configured `stopSequences`
    # + return - The assistant message, or an `ai:Error`
    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns ai:ChatAssistantMessage|ai:Error
        => runChat("Google", self.family, self.wireModelId, self.converter, self.transport,
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
