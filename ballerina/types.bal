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
import ballerinax/aws.auth;

// ============================================================================
// Authentication. AWS credentials come from `ballerinax/aws.auth`; the API key type
// is defined here because `auth:AuthConfig` is SigV4 only.
// https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html
// ============================================================================

# A Bedrock API key.
public type BearerToken record {|
    // `Authorization: Bearer`, or `x-api-key` on the Mantle Messages path.
    # The Bedrock API key
    string apiKey;
|};

// `auth:DEFAULT_CREDENTIALS` walks the AWS credential chain, so nothing needs setting
// on EC2, ECS, EKS or Lambda.

# Authentication for the model and embedding providers: AWS credentials or a Bedrock API key.
public type BedrockAuthConfig auth:AuthConfig|BearerToken;

// ============================================================================
// Options shared by every model provider.
// ============================================================================

// Retried statuses: 408, 429, 500, 502, 503 and 504.

# Retry settings for throttled and transient failures.
public type RetryConfig record {|
    # Maximum number of retries
    int maxRetries = 3;
    # Delay before the first retry, in seconds
    decimal initialDelay = 1.0;
    # Longest delay between retries, in seconds
    decimal maxDelay = 20.0;
    # Factor the delay grows by after each retry
    decimal backoffFactor = 2.0;
|};

// For options this module does not model, e.g. `top_p`, `top_k`, `cache_control`.

# Extra request-body fields sent as-is. Quote the keys, e.g. `{"top_p": 0.9}`.
public type AdditionalRequestFields record {|
    json...;
|};

// `bedrock-runtime` serves all five; `bedrock-mantle` only the last three.
// https://docs.aws.amazon.com/bedrock/latest/userguide/apis.html

# A Bedrock API a model provider can call.
public enum ApiFamily {
    // `POST /model/{id}/converse`. `bedrock-runtime` only.
    # Bedrock's Converse API, one request format for every model
    CONVERSE,
    // `POST /model/{id}/invoke`, vendor-keyed. `bedrock-runtime` only.
    # InvokeModel, in the model's own request format
    INVOKE,
    // `/openai/v1/...` on `bedrock-runtime`; `/v1/...` or `/openai/v1/...` on
    // `bedrock-mantle`, per model.
    # OpenAI-compatible Chat Completions API
    CHAT_COMPLETIONS,
    // `/openai/v1/responses` on `bedrock-runtime`.
    # OpenAI-compatible Responses API
    RESPONSES,
    // `/anthropic/v1/messages` on both endpoints.
    # Anthropic-compatible Messages API
    MESSAGES
}

# How an Anthropic model thinks before answering.
public enum ThinkingMode {
    // The only mode Fable 5 and Opus 4.7 support.
    # The model decides how much to think. Recommended; steer depth with `effort`
    ADAPTIVE = "adaptive",
    // Deprecated on Opus 4.6 / Sonnet 4.6, refused on the adaptive-only models.
    # Thinks within a fixed `budgetTokens` budget. Older models only
    ENABLED = "enabled",
    # No extended thinking
    DISABLED = "disabled"
}

# Extended thinking settings for Anthropic models.
public type ThinkingConfig record {|
    # How the model thinks. Defaults to `ADAPTIVE`
    ThinkingMode mode = ADAPTIVE;
    # Token budget for `ENABLED`: at least 1024 and less than `maxTokens`
    int budgetTokens?;
|};

// The only depth control on the adaptive-only models (Fable 5, Opus 4.7), where
// `budgetTokens` is rejected.

# How much effort an Anthropic model spends on reasoning.
public enum Effort {
    # Least thinking; may skip it on simple tasks
    EFFORT_LOW = "low",
    # Moderate thinking
    EFFORT_MEDIUM = "medium",
    # Always thinks. The default
    EFFORT_HIGH = "high",
    // Sonnet 4.6 rejects it.
    # Deeper than `high`. Opus 5 and Opus 4.6 only
    EFFORT_XHIGH = "xhigh",
    // Accepted on Sonnet 4.6 too (verified live). A refusal lists the accepted values.
    # No limit on depth. Support varies by model
    EFFORT_MAX = "max"
}

// Measured 2026-09-24 (us-east-1): gpt-oss-120b on InvokeModel accepts low, medium and
// high; gpt-5.4 on Mantle Responses accepts none, low, medium, high and xhigh. The set
// AWS lists in a 400 is not what it accepts, so the enum is everything seen, not a
// promise.

// A top-level `reasoning_effort` on Chat Completions, `reasoning: {effort}` on Responses.

# How much an OpenAI model reasons before answering. Accepted values vary by model.
public enum ReasoningEffort {
    # No reasoning. GPT-5.x only
    REASONING_NONE = "none",
    // Refused by both as of 2026-09-24; kept for models that may accept it.
    # Minimal reasoning. Not accepted by current models
    REASONING_MINIMAL = "minimal",
    # Light reasoning, lowest latency
    REASONING_LOW = "low",
    # Moderate reasoning
    REASONING_MEDIUM = "medium",
    # Deep reasoning
    REASONING_HIGH = "high",
    # Deeper than `high`. GPT-5.x only
    REASONING_XHIGH = "xhigh",
    // Refused by gpt-oss, and by gpt-5.4 as of 2026-09-24.
    # No limit on depth. Not accepted by current models
    REASONING_MAX = "max"
}

// ============================================================================
// Module-private: routing.
// ============================================================================

# Which Bedrock endpoint a route targets, fixed by the provider class. Decides the host,
# the SigV4 signing name and the IAM namespace.
# https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
enum BedrockEndpoint {
    # `bedrock-runtime.{region}.amazonaws.com`, signing name `bedrock`, IAM
    # `bedrock:InvokeModel`. AWS's recommended endpoint for new applications.
    RUNTIME,
    # `bedrock-mantle.{region}.api.aws`, signing name `bedrock-mantle`, IAM
    # `bedrock-mantle:CreateInference` — a SEPARATE namespace, which is why
    # credentials that work on the runtime endpoint can still 403 here.
    MANTLE
}

# How a converter forces one named tool. A property of the converter, not the route:
# Nova on InvokeModel uses the Converse form, and Mistral chat forces with `"any"`.
enum ToolChoiceStyle {
    # Converse: `toolConfig.toolChoice = {"tool": {"name": ...}}`.
    CONVERSE_TOOL_CHOICE,
    # Anthropic Messages: `tool_choice = {"type": "tool", "name": ...}`.
    ANTHROPIC_TOOL_CHOICE,
    # OpenAI Chat Completions: `tool_choice = {"type": "function", "function": {"name": ...}}`
    # — the function name NESTED, matching that dialect's nested `tools` entries.
    # https://github.com/openai/openai-python/blob/main/src/openai/types/chat/chat_completion_named_tool_choice_param.py
    OPENAI_CHAT_TOOL_CHOICE,
    # OpenAI Responses: `tool_choice = {"type": "function", "name": ...}`, flat, unlike
    # Chat Completions. The nested form leaves the tool unforced.
    # https://github.com/openai/openai-python/blob/main/src/openai/types/responses/tool_choice_function.py
    RESPONSES_TOOL_CHOICE,
    # Mistral chat completion: `tool_choice = "any"` — a bare string, and it cannot
    # name the tool, so forcing works only when exactly one tool is supplied.
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-chat-completion.html
    MISTRAL_TOOL_CHOICE,
    # The dialect has no tool-calling at all (Mistral text completion), so
    # structured output is impossible on it.
    NO_TOOL_CHOICE
}

# How `generate` obtains a typed result on a given route. Module-private: decided
# once at construction by `structuredOutputStyleFor`.
enum StructuredOutputStyle {
    # Converse `outputConfig.textFormat` with a JSON schema that AWS validates against.
    # Not selected yet: a live test on 2026-08-11 saw the sibling `outputConfig.effort`
    # rejected on the wire, so it needs a live check first.
    # https://docs.aws.amazon.com/bedrock/latest/userguide/structured-output.html
    NATIVE_OUTPUT_CONFIG,
    # Force a single tool whose input schema is the target type, then read the
    # tool-call arguments back. Works on every dialect that can force a tool.
    TOOL_FORCING,
    # No typed generation on this route; the target type must be `string`.
    NO_STRUCTURED_OUTPUT
}

# Whether a guardrail intervened on a response.
# Module-private: only reachable via the internal `DecodedResponse`.
enum GuardrailAction {
    INTERVENED,
    NONE
}

# A Mantle model's base path, APIs and wire id. Unlike bedrock-runtime, the base path
# differs per model even within one vendor (gpt-oss `/v1`, GPT-5.6 `/openai/v1`), so it
# has to be recorded.
# https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
# https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-sol.html
type MantleEntry record {|
    # The base path — the ONE per-model fact here. `/v1`, `/openai/v1` or
    # `/anthropic/v1`. The full request path is this plus the API family's own suffix,
    # which IS derivable (see `mantlePathFor`).
    string basePath;
    # The shapes this model serves on that base path. More than one is normal —
    # gpt-oss serves both Responses and Chat Completions on `/v1` — and the `api`
    # argument selects among them. The first entry is the default.
    ApiFamily[] apis;
    # The Mantle id, when it differs from the bedrock-runtime one (gpt-oss drops `-1:0`).
    string modelId?;
|};

# The resolved route, produced once at construction; the endpoint, converter and
# transport all read from it.
type Route record {|
    # Which endpoint this route targets. Fixed by the provider class.
    BedrockEndpoint endpoint;
    # The resolved wire dialect.
    ApiFamily api;
    # Lookup key with any CRIS geo prefix stripped, e.g. `anthropic.claude-opus-4-8`.
    string bareModelId;
    # The stripped cross-region prefix, put back on the wire. Always `()` on Mantle.
    string? geoPrefix;
    # The id that goes on the wire — CRIS-prefixed on `bedrock-runtime`, the Mantle
    # id on Mantle, or the raw ARN for opaque ARNs.
    string effectiveModelId;
    # Region. An ARN's region segment overrides `config.region`.
    string region;
    # Partition: `aws`, `aws-cn`, `aws-us-gov`, or one of the isolated/EU Sovereign
    # partitions — see `partitionForRegion`.
    string partition;
    # Present only on a MANTLE route.
    MantleEntry? mantleEntry;
|};

// ============================================================================
// Module-private: the converter contract. `decode` returns a record, never a bare
// message, because the span, guardrail and retry all need `usage` + `stopReason`.
// ============================================================================

# Resolved inference parameters plus Converse-body passthrough.
# Module-private: built at construction and consumed only by the internal converters.
type InferenceParams record {|
    # Sampling temperature. OPTIONAL: when unset the field is omitted from the
    # request body entirely and the model's own default applies.
    decimal temperature?;
    # Maximum tokens to generate. OPTIONAL, exactly like `temperature` above: when
    # unset the field is omitted from the request body entirely and the model's own
    # cap applies.
    int maxTokens?;
    # Provider-level stop sequences; a per-call `stop` overrides these.
    string[] stopSequences?;
    # Converse `additionalModelRequestFields` passthrough.
    AdditionalRequestFields additionalModelRequestFields?;
    # Processing tier: Converse `serviceTier` body field, or the Invoke
    # `X-Amzn-Bedrock-Service-Tier` header. Refused on Mantle at construction.
    ServiceTier serviceTier?;
    # Converse `performanceConfig.latency = "optimized"`, or the Invoke
    # `X-Amzn-Bedrock-PerformanceConfig-Latency` header. Refused on Mantle.
    boolean latencyOptimized?;
    # Anthropic thinking. Emitted as a top-level `thinking` body field on the Anthropic
    # Messages dialects, and through `additionalModelRequestFields` on Converse
    # (which does not model it natively).
    ThinkingConfig thinking?;
    # `output_config.effort` — a SIBLING of `thinking`, never nested inside it.
    Effort effort?;
    # OpenAI reasoning depth. Its own field rather than passthrough, because the wire
    # form depends on the API (`reasoning_effort` vs `reasoning: {effort}`).
    ReasoningEffort reasoningEffort?;
    # Converse `guardrailConfig` body field; Invoke uses headers instead.
    GuardrailConfig guardrail?;
|};

// What `chat()`, `generate()` and embeddings need of a transport. A type rather than
// the class, so tests can use an in-process mock.

# Sends one request body and returns the response.
type ModelTransport isolated object {
    isolated function execute(json body, map<string> extraHeaders = {}) returns TransportResponse|ai:Error;
};

# Normalized token usage. Module-private — only reachable via `DecodedResponse`.
type TokenUsage record {|
    # Prompt tokens consumed.
    int inputTokens;
    # Completion tokens generated.
    int outputTokens;
|};

# What `decode` produces — more than the module-boundary message.
# Module-private: the span, guardrail signal, and retry loop read it.
type DecodedResponse record {|
    # The module invariant.
    ai:ChatAssistantMessage message;
    # Span input.
    TokenUsage usage;
    # Span + guardrail + retry signal.
    string stopReason;
    # Span input.
    string? responseId;
    # INTERVENED | NONE.
    GuardrailAction? guardrailAction;
|};

# Encodes a request. The system prompt is a separate argument, so each converter places
# it deliberately. Messages arrive resolved (`resolveMessages`), so encoders are pure.
type RequestEncoder isolated function (
        string? system,
        ResolvedMessage[] messages,
        ai:ChatCompletionFunctions[] tools,
        string? stop,
        InferenceParams params) returns json|ai:Error;

# Decode: wire JSON → `DecodedResponse`. Module-private converter plumbing.
type ResponseDecoder isolated function (json response) returns DecodedResponse|ai:Error;

# The optional `InferenceParams` fields a converter can send. A field the route cannot
# carry is refused at construction rather than silently dropped. `serviceTier` and
# `latencyOptimized` depend on the API family instead (`apiCarriesRequestOptions`).
type DialectSupport record {|
    # A stop-sequence parameter exists in this dialect's request schema.
    boolean stopSequences = true;
    # Anthropic `thinking`.
    boolean thinking = false;
    # Anthropic `output_config.effort`.
    boolean effort = false;
    # OpenAI reasoning depth, in whatever spelling this dialect uses.
    boolean reasoningEffort = false;
|};

# An encode/decode pair. Module-private converter registry record.
type ModelConverter record {|
    # Messages → request body.
    RequestEncoder encode;
    # Wire JSON → `DecodedResponse`.
    ResponseDecoder decode;
    # How structured generation forces the single result tool on this dialect.
    # Lives on the converter because tool-choice tracks the wire shape, not the route family.
    ToolChoiceStyle toolChoice;
    # Populated, unused today — streaming is out of scope.
    boolean supportsStreaming;
    # Wire-dialect name, as it appears in "not supported on this route" messages.
    string dialect;
    # What this dialect can carry.
    DialectSupport supports;
|};
