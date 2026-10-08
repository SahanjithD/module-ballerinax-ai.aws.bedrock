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

// ============================================================================
// Public enums.
// ============================================================================

// Which of these a provider class offers is expressed by the union subtypes below
// rather than a runtime check: the endpoint is fixed by the class, so an unreachable
// API is unrepresentable. `bedrock-runtime` serves all five; `bedrock-mantle` serves
// only the last three.
// https://docs.aws.amazon.com/bedrock/latest/userguide/apis.html

# A Bedrock API a model provider can call.
public enum ApiFamily {
    // `POST /model/{id}/converse`. `bedrock-runtime` only.
    # Bedrock's Converse API, one request format for every model
    CONVERSE,
    // `POST /model/{id}/invoke`, vendor-keyed. `bedrock-runtime` only.
    # InvokeModel, in the model's own request format
    INVOKE,
    // `/openai/v1/chat/completions` on `bedrock-runtime`; `/v1/chat/completions` or
    // `/openai/v1/chat/completions` on `bedrock-mantle`, per model.
    # OpenAI-compatible Chat Completions API
    CHAT_COMPLETIONS,
    // `/openai/v1/responses` on `bedrock-runtime`.
    # OpenAI-compatible Responses API
    RESPONSES,
    // `/anthropic/v1/messages` on both endpoints.
    # Anthropic-compatible Messages API
    MESSAGES
}

// The APIs each vendor's models are served in on `bedrock-runtime`. One alias per
// provider class, named for the vendor rather than for the set it holds today: four
// are the same union right now, but when AWS adds an API to one vendor only that
// alias moves. Union subtypes rather than per-vendor enums, so the same `CONVERSE`
// constant is valid on every class that admits it.
//
// `CHAT_COMPLETIONS` is deliberately NOT OpenAI-only: AWS lists DeepSeek, Gemma 3,
// Mistral, Qwen3 and others as Chat-Completions-capable on `bedrock-runtime`.
// https://docs.aws.amazon.com/bedrock/latest/userguide/models-api-compatibility.html

# APIs available for Anthropic models on `bedrock-runtime`.
public type AnthropicRuntimeApi CONVERSE|INVOKE|MESSAGES;

// Per-model gaps are left for AWS to reject: GPT OSS serves Chat Completions,
// Converse and Invoke here but NOT Responses.
// https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html

# APIs available for OpenAI models on `bedrock-runtime`.
public type OpenAIRuntimeApi CONVERSE|INVOKE|CHAT_COMPLETIONS|RESPONSES;

# APIs available for Amazon models on `bedrock-runtime`.
public type AmazonRuntimeApi CONVERSE|INVOKE;

# APIs available for Mistral models on `bedrock-runtime`.
public type MistralRuntimeApi CONVERSE|INVOKE|CHAT_COMPLETIONS;

# APIs available for Qwen models on `bedrock-runtime`.
public type QwenRuntimeApi CONVERSE|INVOKE|CHAT_COMPLETIONS;

# APIs available for Google Gemma models on `bedrock-runtime`.
public type GoogleRuntimeApi CONVERSE|INVOKE|CHAT_COMPLETIONS;

# APIs available for DeepSeek models on `bedrock-runtime`.
public type DeepSeekRuntimeApi CONVERSE|INVOKE|CHAT_COMPLETIONS;


# Which Bedrock endpoint a route targets. Module-private: the endpoint is chosen by
# the provider CLASS, never by a config field, so this never appears in public API.
# It decides the host, the SigV4 signing name, and the IAM namespace.
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

# How a wire dialect forces a single named tool. This is a property of
# the CONVERTER, not the route: Nova on InvokeModel is Converse-shaped, and Mistral's
# chat dialect looks OpenAI-shaped but forces tools with the bare string `"any"`.
# Deriving it from `ApiFamily` silently emits the wrong field for those dialects.
# Module-private: it lives on the internal `ModelConverter`, never on user config.
enum ToolChoiceStyle {
    # Converse: `toolConfig.toolChoice = {"tool": {"name": ...}}`.
    CONVERSE_TOOL_CHOICE,
    # Anthropic Messages: `tool_choice = {"type": "tool", "name": ...}`.
    ANTHROPIC_TOOL_CHOICE,
    # OpenAI Chat Completions: `tool_choice = {"type": "function", "function": {"name": ...}}`
    # — the function name NESTED, matching that dialect's nested `tools` entries.
    # https://github.com/openai/openai-python/blob/main/src/openai/types/chat/chat_completion_named_tool_choice_param.py
    OPENAI_CHAT_TOOL_CHOICE,
    # OpenAI Responses: `tool_choice = {"type": "function", "name": ...}` — FLAT, and
    # a different shape from Chat Completions above, mirroring this dialect's flat
    # `tools` entries. Sending the nested form here leaves the tool unforced: the
    # model answers in prose and generate() fails with "no tool call".
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

// The escape hatch for anything Bedrock exposes that this module does not model:
// `top_p`, `top_k`, Nova `reasoningConfig`, `anthropic_beta`, `cache_control`, …

# Extra request-body fields sent as-is. Quote the keys, e.g. `{"top_p": 0.9}`.
public type AdditionalRequestFields record {|
    json...;
|};

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
    // Sonnet 4.6 rejects it with `output_config.effort: Input should be 'low',
    // 'medium', 'high' or 'max'`.
    # Deeper than `high`. Opus 5 and Opus 4.6 only
    EFFORT_XHIGH = "xhigh",
    // NOT Opus-only: accepted on Sonnet 4.6 (verified live). On refusal the endpoint
    // lists the values it accepts, which is the authority for other models.
    # No limit on depth. Support varies by model
    EFFORT_MAX = "max"
}

// MEASURED ACCEPTANCE, 2026-09-24 (us-east-1), by sending each value for real:
//
//   openai.gpt-oss-120b  (Invoke)           low, medium, high
//   openai.gpt-5.4       (Mantle Responses) none, low, medium, high, xhigh
//
// The 2026-09-09 harvest that produced the earlier doc text read the set AWS
// ENUMERATES IN ITS 400 and assumed that was acceptance. It is not: that is the first
// validator's set, and deeper ones refuse more. gpt-oss reports `none` as valid, then
// rejects it with "Harmony does not support reasoning_effort='none'"; `minimal` is
// refused by BOTH families despite gpt-oss enumerating it; gpt-5.4 enumerated `max`
// on 09-09 and refuses it now. So the only sound reading is per model, per day.
//
// The enum stays a union of everything seen rather than splitting per family: a
// closed per-model table here would be one more thing to go stale, and AWS already
// reports its own set on refusal. The members are discoverability and typo-catching,
// NOT a promise of acceptance.

// Sent as a top-level `reasoning_effort` on Chat Completions and as
// `reasoning: {effort: ...}` on the Responses API. Which values a model accepts is
// the model's contract; an unsupported one is a 400 (measured sets above).

# How much an OpenAI model reasons before answering. Accepted values vary by model.
public enum ReasoningEffort {
    # No reasoning. GPT-5.x only
    REASONING_NONE = "none",
    // Refused by both families as of 2026-09-24, despite gpt-oss listing it as valid.
    // Kept because a model that accepts it may yet appear.
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

// There is no "standard" tier; the baseline is spelled `default`.

# Bedrock processing tier.
public enum ServiceTier {
    # Baseline pay-per-token processing
    TIER_DEFAULT = "default",
    # Higher throughput, time-based commitment
    TIER_PRIORITY = "priority",
    # Lower cost for non-time-sensitive work
    TIER_FLEX = "flex",
    # Dedicated throughput, term commitment
    TIER_RESERVED = "reserved"
}

# How `generate` obtains a typed result on a given route. Module-private: decided
# once at construction by `structuredOutputStyleFor`.
enum StructuredOutputStyle {
    # Converse `outputConfig.textFormat` carrying a JSON schema — AWS validates the
    # model's output against the schema rather than asking it nicely.
    #
    # NOT YET THE DEFAULT, and the reason is recorded rather than assumed. AWS's
    # structured-output page documents this member with a worked example and botocore
    # models it on ConverseRequest — but this module's own controlled live test on
    # 2026-08-11 found the SIBLING member `outputConfig.effort` rejected on the wire
    # ("This model doesn't support the effort field") on opus-4-8, sonnet-4-6 and
    # opus-4-7, while the same value folded into `additionalModelRequestFields` was
    # accepted (see converter_converse.bal). Two first-party sources therefore
    # disagree about whether `outputConfig` is honoured at all, and one live call
    # settles it. Until then `generate` keeps the path it is known to work on.
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

// ============================================================================
// Route resolution result.
// ============================================================================

# A single Mantle model's wire contract. Module-private routing-table data.
#
# WHY THIS TABLE EXISTS AT ALL, since `bedrock-runtime` needs no equivalent:
#
#   On bedrock-runtime the request path is a pure function of the SHAPE —
#   `/model/{id}/converse`, `/openai/v1/responses` and so on never vary by model, so
#   `runtimePath` derives it and no data is needed.
#
#   On bedrock-mantle the BASE PATH is a per-MODEL fact. AWS states it as an explicit
#   per-card Note because it is irregular, and the two notes contradict each other
#   across models of the same vendor:
#     gpt-oss-120b  "On bedrock-mantle, both APIs use the `/v1` base path, not
#                    `/openai/v1`."
#     GPT-5.6 Sol   "On bedrock-mantle, both APIs use the `/openai/v1` base path, not
#                    `/v1`."
#   Same vendor, same APIs, different base path. `google.gemma-3-*` (`/v1`) versus
#   `google.gemma-4-*` (`/openai/v1`) is the same story. So the base path is derivable
#   from neither the vendor prefix nor the API family, and something has to record it.
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

    # The id to put on the wire when it DIFFERS from the `bedrock-runtime` id.
    #
    # Some models are published under different ids per endpoint — gpt-oss is
    # `openai.gpt-oss-120b-1:0` on bedrock-runtime and `openai.gpt-oss-120b` on
    # bedrock-mantle. Without this, a Mantle call sends the runtime id and fails.
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
    string modelId?;
|};

# The fully resolved route — produced once by `resolveRuntimeRoute` or
# `resolveMantleRoute` at construction.
# Everything downstream (endpoint, converter, transport) reads from this.
# Module-private: the resolver's output, mirroring the private `Endpoint`.
type Route record {|
    # Which endpoint this route targets. Fixed by the provider class.
    BedrockEndpoint endpoint;
    # The resolved wire dialect.
    ApiFamily api;
    # Lookup key with any CRIS geo prefix stripped, e.g. `anthropic.claude-opus-4-8`.
    string bareModelId;
    # The stripped CRIS geo prefix, re-applied on the wire. Always `()` on a Mantle
    # route: cross-region inference is a `bedrock-runtime` concept and Mantle has
    # none.
    # https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
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
