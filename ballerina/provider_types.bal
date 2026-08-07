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

// ============================================================================
// Credentials. A union; bearer (Bedrock API key) is first-class
// on both endpoints (https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html).
// ============================================================================

# Long-lived IAM access keys.
public type StaticCredentials record {|
    # AWS access key id.
    string accessKeyId;
    # AWS secret access key.
    string secretAccessKey;
|};

# Temporary STS credentials — the required `sessionToken` distinguishes this from
# `StaticCredentials` and is emitted as `X-Amz-Security-Token`.
public type StsCredentials record {|
    # AWS access key id.
    string accessKeyId;
    # AWS secret access key.
    string secretAccessKey;
    # STS session token, sent as `X-Amz-Security-Token`.
    string sessionToken;
|};

# A Bedrock API key (bearer token) — first-class on both endpoints.
public type BearerToken record {|
    # The Bedrock API key, sent as `Authorization: Bearer`.
    string apiKey;
|};

# The credential union accepted by every provider.
public type BedrockCredentials StaticCredentials|StsCredentials|BearerToken;

// ============================================================================
// Guardrails / retry.
// ============================================================================

# Guardrail configuration. Placement is route-specific: Converse body field,
# Invoke headers, and a construction error on Mantle.
public type GuardrailConfig record {|
    # `guardrailIdentifier` (Converse body / `X-Amzn-Bedrock-GuardrailIdentifier`).
    string guardrailIdentifier;
    # `guardrailVersion`.
    string guardrailVersion;
    # Optional `trace` mode (`enabled` | `disabled` | `enabled_full`).
    string trace?;
|};

# Retry policy for the transport's throttling/warm-up backoff.
public type RetryConfig record {|
    # Max retry attempts for retryable errors (408/429/500/502/503/504).
    int maxRetries = 3;
    # Initial backoff delay, seconds.
    decimal initialDelay = 1.0;
    # Backoff ceiling, seconds.
    decimal maxDelay = 20.0;
    # Exponential backoff multiplier.
    decimal backoffFactor = 2.0;
|};

// ============================================================================
// Shared model config. Each vendor `*Config` includes this and adds
// only its vendor-specific fields.
// ============================================================================

# Everything that is not the model's identity, shared across vendors.
public type CommonModelConfig record {|
    // --- Routing ---
    # Route selection: `AUTO` (default) runs the resolver; `CONVERSE`/`INVOKE`/
    # `MANTLE` force that family. The escape hatch — outranks every heuristic.
    ApiFamily apiFamily = AUTO;

    // --- Inference ---
    # Provider-level stop sequences; a per-call `stop` overrides these.
    string[] stopSequences?;

    // --- Converse passthrough ---
    # Forwarded verbatim on Converse; ignored elsewhere.
    # https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html
    AdditionalRequestFields additionalModelRequestFields?;

    # `serviceTier`.
    ServiceTier serviceTier?;

    # Request latency-optimized inference on Converse: routes the call onto AWS's
    # faster serving path (custom silicon / reserved capacity) for a lower
    # time-to-first-token, at a higher price. Same output — a speed/cost dial only.
    # Support is per model and region; unsupported combinations are rejected by AWS.
    boolean latencyOptimized?;

    // --- Cross-cutting ---
    # Guardrail; construction error on a MANTLE route.
    GuardrailConfig guardrail?;
    # Retry policy.
    RetryConfig retryConfig?;
    # Underlying HTTP client configuration.
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
    # Maximum tokens to generate.
    int maxTokens;
    # Provider-level stop sequences; a per-call `stop` overrides these.
    string[] stopSequences?;
    # Converse `additionalModelRequestFields` passthrough.
    AdditionalRequestFields additionalModelRequestFields?;
    # Converse `serviceTier`.
    ServiceTier serviceTier?;
    # Converse `performanceConfig.latency = "optimized"` when set.
    boolean latencyOptimized?;
    # Claude thinking. Emitted as a top-level `thinking` body field on the Anthropic
    # Messages dialects, and through `additionalModelRequestFields` on Converse
    # (which does not model it natively).
    ThinkingConfig thinking?;
    # `output_config.effort` — a SIBLING of `thinking`, never nested inside it.
    Effort effort?;
    # Converse `guardrailConfig` body field; Invoke uses headers instead.
    GuardrailConfig guardrail?;
|};

// ============================================================================
// Converter contract. `decode` returns a record, never a bare message,
// because the span/guardrail/retry all need `usage` + `stopReason`.
// ============================================================================

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

# Encode: system is hoisted out of `messages` into the signature so
# no converter can emit it as a `role: system` message. Module-private converter plumbing.
type RequestEncoder isolated function (
        ai:ChatSystemMessage? system,
        ai:ChatMessage[] messages,
        ai:ChatCompletionFunctions[] tools,
        string? stop,
        InferenceParams params) returns json|ai:Error;

# Decode: wire JSON → `DecodedResponse`. Module-private converter plumbing.
type ResponseDecoder isolated function (json response) returns DecodedResponse|ai:Error;

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
|};
