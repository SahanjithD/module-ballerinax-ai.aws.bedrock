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
    // `Authorization: Bearer`, or `x-api-key` on the Messages API.
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

// All five are served on `bedrock-runtime`.
// https://docs.aws.amazon.com/bedrock/latest/userguide/apis.html

# A Bedrock API a model provider can call.
public enum ApiFamily {
    // `POST /model/{id}/converse`.
    # Bedrock's Converse API, one request format for every model
    CONVERSE,
    // `POST /model/{id}/invoke`, vendor-keyed.
    # InvokeModel, in the model's own request format
    INVOKE,
    // `POST /openai/v1/chat/completions`.
    # OpenAI-compatible Chat Completions API
    CHAT_COMPLETIONS,
    // `POST /openai/v1/responses`.
    # OpenAI-compatible Responses API
    RESPONSES,
    // `POST /anthropic/v1/messages`.
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
    # No limit on depth. Support varies by model
    EFFORT_MAX = "max"
}

// A top-level `reasoning_effort` on Chat Completions, `reasoning: {effort}` on Responses.

# How much an OpenAI model reasons before answering. Accepted values vary by model.
public enum ReasoningEffort {
    # No reasoning. Support varies by model
    REASONING_NONE = "none",
    # Minimal reasoning. Not accepted by current models
    REASONING_MINIMAL = "minimal",
    # Light reasoning, lowest latency
    REASONING_LOW = "low",
    # Moderate reasoning
    REASONING_MEDIUM = "medium",
    # Deep reasoning
    REASONING_HIGH = "high",
    # Deeper than `high`. Support varies by model
    REASONING_XHIGH = "xhigh",
    # No limit on depth. Not accepted by current models
    REASONING_MAX = "max"
}

// ============================================================================
// Module-private: routing.
// ============================================================================

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
    # Not selected by any route yet.
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

# The resolved route, produced once at construction; the endpoint, converter and
# transport all read from it.
type Route record {|
    # The resolved wire dialect.
    ApiFamily api;
    # Lookup key with any CRIS geo prefix stripped, e.g. `anthropic.claude-opus-4-8`.
    string bareModelId;
    # The stripped cross-region prefix, put back on the wire.
    string? geoPrefix;
    # The id that goes on the wire: CRIS-prefixed, or the raw ARN for opaque ARNs.
    string effectiveModelId;
    # Region. An ARN's region segment overrides `config.region`.
    string region;
    # Partition: `aws`, `aws-cn`, `aws-us-gov`, or one of the isolated/EU Sovereign
    # partitions — see `partitionForRegion`.
    string partition;
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
    # `X-Amzn-Bedrock-Service-Tier` header. Refused on the other APIs at construction.
    ServiceTier serviceTier?;
    # Converse `performanceConfig.latency = "optimized"`, or the Invoke
    # `X-Amzn-Bedrock-PerformanceConfig-Latency` header. Refused on the other APIs.
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

// ============================================================================
// Module-private: endpoints, transport and prompt content.
// ============================================================================

# A parsed Bedrock ARN: `arn:partition:service:region:account-id:resource-type/resource-id`.
# Its region and partition override `config.region`.
type ParsedArn record {|
    # `aws` | `aws-cn` | `aws-us-gov`.
    string partition;
    # e.g. `bedrock`.
    string 'service;
    # The region; empty on global ARNs such as foundation-model ones, where the caller's
    # region is used.
    string region;
    # The 12-digit AWS account id; may be empty.
    string accountId;
    # e.g. `imported-model`, `provisioned-model`, `inference-profile`.
    string resourceType;
    # The opaque id after the `/` (or `:`) delimiter; may be empty.
    string resourceId;
|};

# The resolved wire endpoint. `signingService` is the SigV4 scope, not the IAM
# namespace; they differ inside this service family.
type Endpoint record {|
    # Origin, e.g. `https://bedrock-runtime.us-east-1.amazonaws.com`.
    string baseUrl;
    # Host header / SigV4 canonical host, e.g. `bedrock-runtime.us-east-1.amazonaws.com`.
    string host;
    # Wire request path with the model-id segment single-encoded.
    string path;
    # SigV4 signing name for this route.
    string signingService;
|};

# Which bedrock-agent plane an endpoint is for. Only the knowledge base spine needs it.
enum AgentPlane {
    # Control plane (`bedrock-agent`): create, list and get knowledge bases, data sources and documents
    AGENT_CONTROL,
    # Data plane (`bedrock-agent-runtime`): Retrieve
    AGENT_DATA
}

# A successful round trip: the JSON body and the response headers the caller needs.
type TransportResponse record {|
    # The response body
    json body;
    # Selected response headers, keyed as in `REQUEST_ID_HEADER`
    map<string> headers;
|};

# A retryable failure: HTTP 408, 429, 500, 502, 503 or 504, or a connection failure.
type RetryableError distinct error;

// A plain `distinct error`, like `RetryableError`; `executeRequest` turns it back into
// an `ai:Error` with the same message for every other caller.
# A Bedrock `ConflictException` (HTTP 409), which the caller may recover from.
type ConflictError distinct error<record {| string detail; |}>;

# One part of a user turn after its `ai:Prompt` has been flattened.
type ContentPart TextPart|ImagePart;

# Literal text.
type TextPart record {|
    # Discriminator.
    readonly "text" kind = "text";
    # The text.
    string text;
|};

# An image, always as raw bytes plus a concrete IANA type.
type ImagePart record {|
    # Discriminator.
    readonly "image" kind = "image";
    # Concrete type — never a wildcard. Both Converse's `format` and Anthropic's
    # `media_type` are derived from this, and neither accepts `image/*`.
    string mimeType;
    # UNencoded bytes. Each emitter base64-encodes at its own wire boundary.
    byte[] data;
|};

# A user message whose content has been resolved to parts. Assistant and function
# messages are unchanged — neither can carry an image.
type ResolvedUserMessage record {|
    # Always `ai:USER`.
    ai:USER role = ai:USER;
    # The message content, in order.
    ContentPart[] parts;
|};

# A chat message ready for a converter: user content resolved to parts, others unchanged.
type ResolvedMessage ResolvedUserMessage|ai:ChatAssistantMessage|ai:ChatFunctionMessage;
