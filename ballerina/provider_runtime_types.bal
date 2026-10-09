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
// `apiType` and `endpoint` are init parameters rather than fields here, so they show in
// the form without opening the config.
public type CommonRuntimeConfig record {|
    // --- Inference ---
    # Sequences that stop generation. A `stop` passed to `chat` overrides them
    string[] stopSequences?;
    // --- Passthrough ---
    // Sent verbatim: as Converse's `additionalModelRequestFields`, or at the top level
    // of an InvokeModel body.
    // https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html
    # Extra fields sent as-is in the request body, for options this module does not cover
    AdditionalRequestFields additionalModelRequestFields?;
    // Converse `serviceTier` body field; `X-Amzn-Bedrock-Service-Tier` header on Invoke.
    # Processing tier for each request
    ServiceTier serviceTier?;
    // Converse `performanceConfig`, or the `X-Amzn-Bedrock-PerformanceConfig-Latency`
    // header on InvokeModel. Support is per model and region.
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

// One alias per vendor, so when AWS adds an API for one vendor only its alias changes.
// Chat Completions is not OpenAI-only on `bedrock-runtime`.
// https://docs.aws.amazon.com/bedrock/latest/userguide/models-api-compatibility.html

# APIs available for Anthropic models on `bedrock-runtime`.
public type AnthropicRuntimeApi CONVERSE|INVOKE|MESSAGES;

// GPT OSS has no Responses API here; AWS rejects that combination.
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

// Current Anthropic models are served here only through cross-region profiles (`us.`,
// `eu.`, `au.`, `global.`); a bare id fails with "on-demand throughput isn't supported".
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html

# Anthropic model IDs on `bedrock-runtime`, with the `us.` cross-region prefix.
# For another geography, pass the ID as a string, e.g. `eu.anthropic.claude-sonnet-5`.
public enum AnthropicRuntimeModelNames {
    // Rejects a forced tool choice, so typed `generate()` offers its tool unforced.
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
    // Only the dated id works; the undated one is "invalid".
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-haiku-4-5.html
    CLAUDE_HAIKU_4_5 = "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-fable-5.html
    # Needs an account opt-in: set the data retention mode to `aws_review` first
    CLAUDE_FABLE_5 = "us.anthropic.claude-fable-5",
    // Like Opus 5.5: thinking cannot be disabled and a forced tool choice is rejected.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-fable-5-1.html
    # Needs the Fable 5 opt-in
    CLAUDE_FABLE_5_1 = "us.anthropic.claude-fable-5-1"
}

# Configuration for `RuntimeAnthropicModelProvider`.
public type AnthropicRuntimeConfig record {|
    *CommonRuntimeConfig;
    // A typed record, so the mode and budget rules are checked at construction.
    # Extended thinking settings
    ThinkingConfig thinking?;
    // Sent as `output_config.effort`.
    # Reasoning effort. The only depth control on Fable 5 and Opus 4.7
    Effort effort?;
|};

# OpenAI model IDs on `bedrock-runtime`.
public enum OpenAIRuntimeModelNames {
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
    # Not available on the `RESPONSES` API
    GPT_OSS_120B = "openai.gpt-oss-120b-1:0",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-20b.html
    # Not available on the `RESPONSES` API
    GPT_OSS_20B = "openai.gpt-oss-20b-1:0",
    // GPT-6: cross-region ids only ("You cannot use the base model ID for in-Region
    // calls on this endpoint"), and no InvokeModel.
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

// Nova and Titan have only the Bedrock-native APIs.
// https://docs.aws.amazon.com/bedrock/latest/userguide/models-endpoint-availability.html

# Amazon Nova model IDs.
public enum AmazonRuntimeModelNames {
    NOVA_PRO = "amazon.nova-pro-v1:0",
    NOVA_LITE = "amazon.nova-lite-v1:0",
    NOVA_MICRO = "amazon.nova-micro-v1:0"
}

# Configuration for `RuntimeAmazonModelProvider`.
public type AmazonRuntimeConfig record {|
    *CommonRuntimeConfig;
|};

// Mistral Large 2407 is served only in us-west-2; elsewhere AWS answers "The provided
// model identifier is invalid", which looks like a wrong id.
// https://docs.aws.amazon.com/bedrock/latest/userguide/models-region-compatibility.html

# Mistral model IDs on `bedrock-runtime`.
public enum MistralRuntimeModelNames {
    # The current flagship: 675B, 256K context
    MISTRAL_LARGE_3 = "mistral.mistral-large-3-675b-instruct",
    // Chat-completion format on InvokeModel.
    # Available in us-west-2 only
    MISTRAL_LARGE_2407 = "mistral.mistral-large-2407-v1:0",
    // Text-completion format on InvokeModel, unlike 2407.
    MISTRAL_LARGE_2402 = "mistral.mistral-large-2402-v1:0",
    # No tool calling on `INVOKE`, so `generate` can only return `string` there
    MISTRAL_7B_INSTRUCT = "mistral.mistral-7b-instruct-v0:2"
}

# Configuration for `RuntimeMistralModelProvider`.
public type MistralRuntimeConfig record {|
    *CommonRuntimeConfig;
|};

# Qwen model IDs on `bedrock-runtime`.
public enum QwenRuntimeModelNames {
    QWEN3_32B = "qwen.qwen3-32b-v1:0",
    // An "invalid model identifier" for this id means the account lacks model access;
    // grant it in the Bedrock console.
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

# Google Gemma model IDs on `bedrock-runtime`.
public enum GoogleRuntimeModelNames {
    GEMMA_3_4B_IT = "google.gemma-3-4b-it",
    GEMMA_3_12B_IT = "google.gemma-3-12b-it",
    // AWS titles this card "Gemma 3 27B PT", but the id is `-it`.
    GEMMA_3_27B_IT = "google.gemma-3-27b-it"
}

# Configuration for `RuntimeGoogleModelProvider`.
public type GoogleRuntimeConfig record {|
    *CommonRuntimeConfig;
|};

# DeepSeek model IDs on `bedrock-runtime`.
public enum DeepSeekRuntimeModelNames {
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
