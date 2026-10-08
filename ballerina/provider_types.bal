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
import ballerina/http;
import ballerinax/aws.auth;

// ============================================================================
// Credentials. SigV4 sources come from `ballerinax/aws.auth`; the bearer
// (Bedrock API key) is module-local because `auth:AuthConfig` is SigV4-only.
// (https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html)
// ============================================================================

# A Bedrock API key.
public type BearerToken record {|
    // Sent as `Authorization: Bearer`, or as `x-api-key` on a Mantle Messages path,
    // where the two headers are mutually exclusive.
    # The Bedrock API key
    string apiKey;
|};

// `auth:AuthConfig` covers static keys, assume-role, EKS IRSA, SSO, named profiles and
// `credential_process`; its default, `auth:DEFAULT_CREDENTIALS`, walks the full AWS
// credential chain so nothing needs configuring on EC2, ECS, EKS or Lambda. Named
// `...AuthConfig` rather than `...Credentials` because it also takes an API key.

# Authentication for the model and embedding providers: AWS credentials or a Bedrock API key.
public type BedrockAuthConfig auth:AuthConfig|BearerToken;

// ============================================================================
// Guardrails / retry.
// ============================================================================

// Sent as the Converse `guardrailConfig` body field, or as the
// `X-Amzn-Bedrock-GuardrailIdentifier`/`-GuardrailVersion` headers on InvokeModel.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_GuardrailConfiguration.html

# A Bedrock guardrail applied to every request.
public type GuardrailConfig record {|
    # Guardrail ID or ARN
    string guardrailIdentifier;
    # Guardrail version, e.g. `1` or `DRAFT`
    string guardrailVersion;
|};

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

// ============================================================================
// Shared model config. Each vendor `*Config` includes this and adds
// only its vendor-specific fields.
// ============================================================================

# Options shared by the `bedrock-runtime` model providers.
// NOTE `api` and `endpoint` are NOT here. Both are routing/transport decisions
// a caller makes at the same moment they choose the model and the region, so they sit
// directly on `init` alongside those rather than one level down in this record —
// visible in the Integrator panel without expanding a config, and impossible to miss
// when reading a call site.
public type CommonRuntimeConfig record {|
    // --- Inference ---
    # Sequences that stop generation. A `stop` passed to `chat` overrides them
    string[] stopSequences?;

    // --- Passthrough ---
    // Spliced verbatim: Converse's `additionalModelRequestFields`, and the top level
    // of each Invoke dialect. The module never rewrites, renames or reshapes it.
    // https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html
    # Extra fields sent as-is in the request body, for options this module does not cover
    AdditionalRequestFields additionalModelRequestFields?;

    // Converse `serviceTier` body field; `X-Amzn-Bedrock-Service-Tier` header on Invoke.
    # Processing tier for each request
    ServiceTier serviceTier?;

    // Converse `performanceConfig` body field; `X-Amzn-Bedrock-PerformanceConfig-Latency`
    // header on Invoke. Same output, only speed and cost change. Support is per model
    // and region, and AWS rejects unsupported combinations.
    // https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModel.html
    # Use latency-optimized inference, where the model and region support it
    boolean latencyOptimized?;

    // --- Cross-cutting ---
    # Guardrail applied to every request
    GuardrailConfig guardrail?;
    # Retry settings
    RetryConfig retryConfig?;
    # HTTP client settings, such as timeouts and proxy
    http:ClientConfiguration httpConfig?;
|};

// No `guardrail`, `serviceTier` or `latencyOptimized`: guardrails are a
// bedrock-runtime feature and Mantle carries no Bedrock request-option headers, so
// leaving the fields out makes them a compile error rather than a runtime refusal.
// https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html

# Options shared by the `bedrock-mantle` model providers.
public type CommonMantleConfig record {|
    # Sequences that stop generation. A `stop` passed to `chat` overrides them
    string[] stopSequences?;

    // Spliced verbatim into the top level of the request body, never rewritten.
    # Extra fields sent as-is in the request body, for options this module does not cover
    AdditionalRequestFields additionalModelRequestFields?;

    # Retry settings
    RetryConfig retryConfig?;

    # HTTP client settings, such as timeouts and proxy
    http:ClientConfiguration httpConfig?;
|};

// ============================================================================
// Inference params — resolved once at construction. Carries the
// Converse-body passthrough so the fixed converter signature can emit it; non-Converse
// converters ignore the extra fields.
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
    # OpenAI reasoning depth. FIRST-CLASS rather than folded into the passthrough,
    # because its wire SHAPE differs per dialect and only the converter knows which
    # dialect it is building: Chat Completions spells it as a top-level
    # `reasoning_effort`, the Responses API nests it as `reasoning: {effort: ...}`.
    # Folding it into `additionalModelRequestFields` at the provider erased that
    # distinction — the passthrough is spliced verbatim, so a GPT-5.x model on
    # `/openai/v1/responses` received the Chat Completions spelling and answered
    # `Unknown parameter: 'reasoning_effort'` (400). It also conflated a knob the
    # module owns with an escape hatch the CALLER owns, which must stay verbatim.
    ReasoningEffort reasoningEffort?;
    # Converse `guardrailConfig` body field; Invoke uses headers instead.
    GuardrailConfig guardrail?;
|};

// ============================================================================
// Converter contract. `decode` returns a record, never a bare message,
// because the span/guardrail/retry all need `usage` + `stopReason`.
// ============================================================================

// The only thing `chat()`, `generate()` and the embedding loop need of a transport:
// one request body in, one response out. `BedrockTransport` satisfies it
// structurally. Named as a type rather than taking the concrete class so these paths
// can be driven in tests by an in-process mock, without live AWS or a local port.
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

# Encode: system is hoisted out of `messages` into its own parameter, so a converter
# emits it deliberately or not at all — never by accidentally letting a system turn
# fall through the message loop. Most dialects carry it as a top-level field
# (`system`, `instructions`, or folded into the prompt string); the OpenAI Chat
# Completions and Mistral chat encoders DO emit `{"role": "system", ...}`, because
# that is what those wire formats specify. Module-private converter plumbing.
#
# Messages arrive ALREADY RESOLVED (`ResolvedMessage`): any `ai:Prompt` has been
# flattened to `ContentPart`s and any image URL fetched, by `resolveMessages`. That
# keeps every encoder pure — no network, no credentials — so the golden-file tests can
# drive them directly. See the header of content_parts.bal.
type RequestEncoder isolated function (
        string? system,
        ResolvedMessage[] messages,
        ai:ChatCompletionFunctions[] tools,
        string? stop,
        InferenceParams params) returns json|ai:Error;

# Decode: wire JSON → `DecodedResponse`. Module-private converter plumbing.
type ResponseDecoder isolated function (json response) returns DecodedResponse|ai:Error;

# Which optional `InferenceParams` members a wire dialect can actually put on the
# wire. Declared per converter so that "this route cannot carry that field" is a
# fact the registry states ONCE, checked in ONE place, rather than something each
# encoder is trusted to remember.
#
# The alternative — letting an encoder ignore what it does not understand — is a
# silent drop: the caller sets a field, the constructor accepts it, the request
# succeeds, and nothing happened. From the `ai:ModelProvider` contract that is
# indistinguishable from a request that honoured it. The module's own precedent is to
# refuse (the Responses dialect errors on stop sequences rather than ignoring them);
# this makes that precedent the default for every field on every dialect.
#
# `serviceTier` and `latencyOptimized` are NOT here: they are honoured by the route
# FAMILY rather than the dialect — a Converse body field, an InvokeModel request
# header, nothing on Mantle — so they are decided by `apiCarriesRequestOptions`.
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
