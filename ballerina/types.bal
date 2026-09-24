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

# A wire dialect. Bedrock serves five, and which of them a given provider class
# offers is expressed by the union subtypes below rather than by a runtime check —
# the endpoint is fixed by the class, so an unreachable shape is unrepresentable.
#
# `bedrock-runtime` serves all five; `bedrock-mantle` serves only the last three and
# has no Converse and no InvokeModel at all.
# https://docs.aws.amazon.com/bedrock/latest/userguide/apis.html
public enum ApiShape {
    # `POST /model/{id}/converse` — the model-agnostic Bedrock dialect, and the only
    # one that works without per-vendor knowledge. `bedrock-runtime` only.
    CONVERSE,
    # `POST /model/{id}/invoke` — the model's own native body. Vendor-keyed.
    # `bedrock-runtime` only.
    INVOKE,
    # OpenAI Chat Completions. `/openai/v1/chat/completions` on `bedrock-runtime`;
    # `/v1/chat/completions` or `/openai/v1/chat/completions` on `bedrock-mantle`,
    # per model.
    CHAT_COMPLETIONS,
    # OpenAI Responses. `/openai/v1/responses` on `bedrock-runtime`.
    RESPONSES,
    # Anthropic Messages. `/anthropic/v1/messages` on both endpoints.
    MESSAGES
}

# The shapes each vendor's models are served in on `bedrock-runtime`. A union
# subtype rather than a per-vendor enum so the members stay a single set: the same
# `CONVERSE` constant is valid on every class that admits it.
#
# `CHAT_COMPLETIONS` is deliberately NOT OpenAI-only. AWS lists DeepSeek, Gemma 3,
# Mistral, Qwen3, MiniMax, Moonshot, NVIDIA, Writer, xAI and Z.AI as
# Chat-Completions-capable on `bedrock-runtime`, so restricting it to the OpenAI
# class would drop real coverage.
# https://docs.aws.amazon.com/bedrock/latest/userguide/models-api-compatibility.html

# Anthropic on `bedrock-runtime`: Converse, InvokeModel, and the native Messages API.
public type AnthropicRuntimeApi CONVERSE|INVOKE|MESSAGES;

# OpenAI on `bedrock-runtime`. Both OpenAI-compatible shapes, plus Converse/Invoke.
# Per-model gaps remain and are left for AWS to reject: GPT OSS serves Chat
# Completions, Converse and Invoke here but NOT Responses.
# https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html
public type OpenAIRuntimeApi CONVERSE|INVOKE|CHAT_COMPLETIONS|RESPONSES;

# DeepSeek, Google, Mistral and Qwen on `bedrock-runtime`: Converse, InvokeModel and
# the OpenAI-compatible Chat Completions path.
public type ChatRuntimeApi CONVERSE|INVOKE|CHAT_COMPLETIONS;

# Amazon on `bedrock-runtime`. Nova and Titan are served on the Bedrock-native
# dialects only — no vendor-compatible path carries them.
public type CoreRuntimeApi CONVERSE|INVOKE;

# The shapes `bedrock-mantle` serves.
#
# This is an ASSERTION, not a selector. Which shape a model takes is decided entirely
# by its `MANTLE_CAPABLE` row, because that row holds the one request path this module
# has verified for it. Passing a value here does not change the path — it only states
# what you expect, and turns a mismatch into a construction error instead of a
# surprise at call time. Leave it unset unless you want that check.
#
# KNOWN LIMITATION: some models really are published on two shapes — AWS's cards show
# both Responses and Chat Completions for `openai.gpt-5.5` and `openai.gpt-oss-120b` —
# and this module reaches only the one its table records. Selecting the other would
# require `MantleEntry` to hold a shape-to-path map, with each additional path
# verified per model card.
# https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
public type MantleApi MESSAGES|CHAT_COMPLETIONS|RESPONSES;

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
# Deriving it from `ApiShape` silently emits the wrong field for those dialects.
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

# Fields forwarded verbatim to the model — the escape hatch for anything Bedrock
# exposes that this module does not model (`top_p`, `top_k`, Nova `reasoningConfig`,
# `anthropic_beta`, prompt-caching `cache_control`, …). Keys must be quoted string
# literals, e.g. `{"top_p": 0.9}`.
public type AdditionalRequestFields record {
};

# How Claude allocates internal reasoning before answering.
public enum ThinkingMode {
    # Claude decides when and how much to think. The recommended mode, and the only
    # one supported by Claude Fable 5 and Opus 4.7. Pair
    # with `effort` to steer depth.
    ADAPTIVE = "adaptive",
    # Manual budget via `budgetTokens`. Deprecated on Opus 4.6 / Sonnet 4.6 and
    # unsupported on the adaptive-only models above.
    ENABLED = "enabled",
    # No extended thinking.
    DISABLED = "disabled"
}

# Extended/adaptive thinking configuration for Claude.
public type ThinkingConfig record {|
    # Thinking mode. Defaults to `ADAPTIVE`, which every current Claude accepts.
    ThinkingMode mode = ADAPTIVE;
    # Reasoning-token budget. Valid only with `ENABLED`, minimum 1024, and must be
    # less than `maxTokens`.
    int budgetTokens?;
|};

# How much reasoning the model should spend. Also the only depth control available
# on the adaptive-only models (Fable 5, Opus 4.7), where
# `budgetTokens` is rejected.
public enum Effort {
    # Minimises thinking; may skip it entirely on simple tasks.
    EFFORT_LOW = "low",
    # Moderate thinking.
    EFFORT_MEDIUM = "medium",
    # The default. Claude always thinks.
    EFFORT_HIGH = "high",
    # Extended depth. Claude Opus 5 and Opus 4.6 ONLY — Sonnet 4.6 rejects it with
    # `output_config.effort: Input should be 'low', 'medium', 'high' or 'max'`.
    EFFORT_XHIGH = "xhigh",
    # No constraint on depth. NOT Opus-only: accepted on Sonnet 4.6 as well
    # (verified live), and named as valid by the very refusal that rejects `xhigh`
    # there. Support is still per model — the endpoint enumerates the set it accepts
    # when it refuses one, which is the authority for any model not listed here.
    EFFORT_MAX = "max"
}

# How much reasoning an OpenAI model spends before answering. Sent in the spelling
# the resolved route uses — a top-level `reasoning_effort` on Chat Completions,
# `reasoning: {effort: ...}` on the Responses API.
#
# These are the UNION of what the OpenAI models on Bedrock accept, harvested on
# 2026-09-09 from the endpoint's own refusals in `us-east-1` (AWS documents the
# parameter on neither the gpt-oss-120b nor the GPT-5.5 model card). Membership here
# does not mean every model takes it: which values a given model accepts is the
# MODEL's contract, and `REASONING_MINIMAL` is already accepted by one family and
# refused by the other. An unsupported value is rejected by the endpoint, and the
# refusal enumerates the set that model does accept — the authority for anything not
# stated here.
public enum ReasoningEffort {
    # No reasoning. Accepted on both families today; OpenAI documents models that
    # refuse it, so it is not universal.
    REASONING_NONE = "none",
    # gpt-oss ONLY. The single value the two families disagree on: `openai.gpt-oss-*`
    # accepts it, every `openai.gpt-5.x` refuses it with `Invalid value: 'minimal'`
    # (HTTP 400, verified live 2026-09-09).
    REASONING_MINIMAL = "minimal",
    # Least reasoning, lowest latency.
    REASONING_LOW = "low",
    # Moderate reasoning.
    REASONING_MEDIUM = "medium",
    # Deep reasoning.
    REASONING_HIGH = "high",
    # Extended depth beyond `high`.
    REASONING_XHIGH = "xhigh",
    # No constraint on depth.
    REASONING_MAX = "max"
}

# Converse `serviceTier` passthrough. Note there is no "standard" tier — the
# baseline is spelled `default`.
public enum ServiceTier {
    # Baseline pay-per-token processing.
    TIER_DEFAULT = "default",
    # Higher throughput, time-based commitment.
    TIER_PRIORITY = "priority",
    # Lower cost for non-time-sensitive work.
    TIER_FLEX = "flex",
    # Dedicated throughput, term commitment.
    TIER_RESERVED = "reserved"
}

# How `generate()` obtains a typed result on a given route. Module-private: decided
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
    # settles it. Until then `generate()` keeps the path it is known to work on.
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
# The PATH is the only per-model fact here. Converter and auth-header style used to be
# stored alongside it and are now DERIVED from the path (see `mantleShapeForPath`
# and `usesApiKeyHeader`), because path → dialect is 1:1 across every model AWS
# serves on Mantle. They are not derivable from the VENDOR prefix, which is the
# mistake this shape invites: `google.gemma-3-*` speaks Chat Completions on `/v1`
# while `google.gemma-4-*` speaks Responses on `/openai/v1` — one prefix, two
# dialects. Keying off the path keeps that distinction intact with no extra fields.
type MantleEntry record {|
    # Request path on the `bedrock-mantle` host, e.g. `/anthropic/v1/messages`.
    string path;

    # Whether this model is ALSO served on `bedrock-runtime`.
    #
    # DOCUMENTATION, not behaviour: nothing reads this field. It stopped driving
    # routing when the endpoint became a property of the provider class, and it is
    # retained only because it records a per-model fact the table would otherwise
    # lose — which of these models have a `BedrockRuntime*` alternative (all but
    # GPT-5.4/5.5 and Gemma 4). Delete it, or wire it into the "use the runtime class
    # instead" error messages; do not let it drift.
    # Verified per model against AWS's API-compatibility matrix.
    # https://docs.aws.amazon.com/bedrock/latest/userguide/models-api-compatibility.html
    boolean onRuntime = false;

    # The id to put on the wire when it DIFFERS from the `bedrock-runtime` id.
    #
    # For most models the two endpoints share an id, and this is omitted. But some
    # models are published under different ids per endpoint — gpt-oss is
    # `openai.gpt-oss-120b-1:0` on `bedrock-runtime` and `openai.gpt-oss-120b` on
    # `bedrock-mantle`. Without this, forcing Mantle sends the runtime id and fails.
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
    ApiShape shape;
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
