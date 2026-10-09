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

import ballerina/http;

// ============================================================================
// Options shared by the `bedrock-runtime` model providers.
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

# Configuration for `ConverseModelProvider`.
public type ConverseConfig record {|
    *CommonRuntimeConfig;
|};

// ============================================================================
// APIs per vendor.
// ============================================================================

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

// ============================================================================
// Model IDs and configuration, per vendor.
// ============================================================================

// Current Anthropic models are served on this endpoint through cross-region inference
// profiles only: each model card's regional-availability table marks In-Region
// unsupported in every region and lists the Geo (`us.`, `eu.`, `au.`) and Global
// (`global.`) profile ids as the way in. A BARE id fails with `on-demand throughput
// isn't supported`. (The cards' own boto3 samples still show the bare id,
// contradicting the availability table on the same page; the table matches the
// error users actually hit.)
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html

# Anthropic model IDs on `bedrock-runtime`, with the `us.` cross-region prefix.
# For another geography, pass the ID as a string, e.g. `eu.anthropic.claude-sonnet-5`.
public enum AnthropicRuntimeModel {
    // Refuses a FORCED tool choice, so typed `generate()` offers its tool unforced.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-5-5.html
    # 1M context; adaptive thinking always on
    CLAUDE_OPUS_5_5 = "us.anthropic.claude-opus-5-5",
    # 1M context; adaptive thinking on by default
    CLAUDE_OPUS_5 = "us.anthropic.claude-opus-5",
    CLAUDE_OPUS_4_8 = "us.anthropic.claude-opus-4-8",
    // `thinking.type = "enabled"` with a manual budget is a 400.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-4-7.html
    # Adaptive thinking only. No `temperature`, `top_p` or `top_k`
    CLAUDE_OPUS_4_7 = "us.anthropic.claude-opus-4-7",
    # 1M context; adaptive thinking always on
    CLAUDE_SONNET_5 = "us.anthropic.claude-sonnet-5",
    CLAUDE_SONNET_4_6 = "us.anthropic.claude-sonnet-4-6",
    // DATED AND VERSIONED, unlike its siblings. The card's Programmatic Access table
    // gives `N/A` as the runtime Model ID and names only the dated profile ids; the
    // undated id is refused with "The provided model identifier is invalid".
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-haiku-4-5.html
    CLAUDE_HAIKU_4_5 = "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-fable-5.html
    # Needs an account opt-in: set the data retention mode to `aws_review` first
    CLAUDE_FABLE_5 = "us.anthropic.claude-fable-5",
    // Inherits Opus 5.5's restrictions: thinking cannot be disabled, and a FORCED
    // tool choice is refused, so typed `generate()` offers its tool unforced.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-fable-5-1.html
    # Needs the Fable 5 opt-in
    CLAUDE_FABLE_5_1 = "us.anthropic.claude-fable-5-1"
}

# Configuration for `RuntimeAnthropicModelProvider`.
public type AnthropicRuntimeConfig record {|
    *CommonRuntimeConfig;

    // A typed record rather than raw `json`, so the mode/budget pairing rules are
    // checked at construction.
    # Extended thinking settings
    ThinkingConfig thinking?;

    // Sent as `output_config.effort`.
    # Reasoning effort. The only depth control on Fable 5 and Opus 4.7
    Effort effort?;
|};

// The GPT-5.x ids are on `bedrock-mantle` in this module's verified per-card data —
// see `OpenAIMantleModel`. AWS's endpoint-availability page has since listed some
// GPT-5.6 ids on both endpoints, which contradicts those cards; rather than pick a
// side silently, this enum keeps the per-card reading, and any id can still be passed
// as a string. GPT OSS serves Chat Completions, Converse and Invoke here but NOT
// Responses.
// https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html

# OpenAI model IDs on `bedrock-runtime`.
public enum OpenAIRuntimeModel {
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
    # Not available on the `RESPONSES` API
    GPT_OSS_120B = "openai.gpt-oss-120b-1:0",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-20b.html
    # Not available on the `RESPONSES` API
    GPT_OSS_20B = "openai.gpt-oss-20b-1:0",
    // The GPT-6 family. CRIS-PREFIXED, unlike GPT OSS: each card says "You cannot use
    // the base model ID for in-Region calls on this endpoint". They serve Responses,
    // Chat Completions and Converse here, but NOT Invoke, and refuse the Chat
    // Completions `max_tokens` parameter (they are sent `max_completion_tokens`).
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-astra.html
    # Not available on the `INVOKE` API
    GPT_6_ASTRA = "us.openai.gpt-6-astra",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-sol.html
    # Not available on the `INVOKE` API
    GPT_6_SOL = "us.openai.gpt-6-sol",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-luna.html
    # Not available on the `INVOKE` API
    GPT_6_LUNA = "us.openai.gpt-6-luna"
}

# Configuration for `RuntimeOpenAIModelProvider`.
public type OpenAIRuntimeConfig record {|
    *CommonRuntimeConfig;

    // Top-level `reasoning_effort` on Chat Completions, nested `reasoning.effort` on
    // Responses.
    # How much the model reasons before answering
    ReasoningEffort reasoningEffort?;
|};

// Nova and Titan are served on the Bedrock-native APIs only — there is no
// vendor-compatible path for them and no Amazon model on `bedrock-mantle`, which is
// why this vendor has no Mantle class.
// https://docs.aws.amazon.com/bedrock/latest/userguide/models-endpoint-availability.html

# Amazon Nova model IDs.
public enum AmazonRuntimeModel {
    NOVA_PRO = "amazon.nova-pro-v1:0",
    NOVA_LITE = "amazon.nova-lite-v1:0",
    NOVA_MICRO = "amazon.nova-micro-v1:0"
}

# Configuration for `RuntimeAmazonModelProvider`.
public type AmazonRuntimeConfig record {|
    *CommonRuntimeConfig;
|};

// REGION MATTERS HERE MORE THAN FOR ANY OTHER VENDOR IN THIS MODULE. Mistral Large
// 2407 is the one id in these enums whose availability is a single region: AWS's
// regional-availability page lists exactly one row for it, `us-west-2` In-Region,
// with no Geo or Global profile. It is also no longer in the Mistral AI model-card
// index — the card titled "Mistral Large" is 24.02 — so the availability page is the
// only first-party statement left, and it is the one that matches what the endpoint
// does: every other region answers "The provided model identifier is invalid", which
// reads like a wrong id rather than a wrong region. Kept rather than removed, because
// AWS still documents it as live in that region.
// https://docs.aws.amazon.com/bedrock/latest/userguide/models-region-compatibility.html

# Mistral model IDs on `bedrock-runtime`.
public enum MistralRuntimeModel {
    # The current flagship: 675B, 256K context
    MISTRAL_LARGE_3 = "mistral.mistral-large-3-675b-instruct",
    // Chat-completion dialect on InvokeModel (`messages`/`choices`), and Converse.
    // Any other region answers "The provided model identifier is invalid".
    # Available in us-west-2 only
    MISTRAL_LARGE_2407 = "mistral.mistral-large-2407-v1:0",
    // Text-completion dialect on InvokeModel (`prompt`/`outputs`) — the opposite
    // dialect to its 24.07 sibling, despite the shared family name.
    MISTRAL_LARGE_2402 = "mistral.mistral-large-2402-v1:0",
    // Text-completion dialect on InvokeModel, which has no tool calling.
    # No tool calling on `INVOKE`, so `generate` can only return `string` there
    MISTRAL_7B_INSTRUCT = "mistral.mistral-7b-instruct-v0:2"
}

# Configuration for `RuntimeMistralModelProvider`.
public type MistralRuntimeConfig record {|
    *CommonRuntimeConfig;
|};

# Qwen model IDs on `bedrock-runtime`.
public enum QwenRuntimeModel {
    QWEN3_32B = "qwen.qwen3-32b-v1:0",
    // The card lists this exact id, In-Region, in us-east-1 among nine other regions,
    // so an "invalid model identifier" here is NOT a wrong id or a wrong region: it is
    // an account that has not been granted access to the model. Grant it in the
    // Bedrock console under Model access. The Mantle id works independently of that,
    // which is why one can succeed while the other does not.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-coder-480b-a35b-instruct.html

    # Coding model: 480B mixture of experts, 35B active
    QWEN3_CODER_480B = "qwen.qwen3-coder-480b-a35b-v1:0"
}

# Configuration for `RuntimeQwenModelProvider`.
public type QwenRuntimeConfig record {|
    *CommonRuntimeConfig;

    // Sent as `enable_thinking` in the request body.
    # Turns Qwen3 thinking on or off. Unset uses the model's default
    boolean enableThinking?;
|};

// Gemma is the open-weight family; Gemini is not on Bedrock.

# Google Gemma model IDs on `bedrock-runtime`. For Gemma 4, use `MantleGoogleModelProvider`.
public enum GoogleRuntimeModel {
    GEMMA_3_4B_IT = "google.gemma-3-4b-it",
    GEMMA_3_12B_IT = "google.gemma-3-12b-it",
    // AWS titles this card "Gemma 3 27B PT" but its id really is `-it` — do not "correct" this.
    GEMMA_3_27B_IT = "google.gemma-3-27b-it"
}

# Configuration for `RuntimeGoogleModelProvider`.
public type GoogleRuntimeConfig record {|
    *CommonRuntimeConfig;
|};

# DeepSeek model IDs on `bedrock-runtime`.
public enum DeepSeekRuntimeModel {
    // The bare `deepseek.r1-v1:0` is not callable in any region.
    # Cross-region ID. For another geography, pass the ID as a string
    DEEPSEEK_R1 = "us.deepseek.r1-v1:0",
    // Unlike R1, the bare id is callable directly.
    # The current flagship
    DEEPSEEK_V3_2 = "deepseek.v3.2"
}

# Configuration for `RuntimeDeepSeekModelProvider`.
public type DeepSeekRuntimeConfig record {|
    *CommonRuntimeConfig;
|};
