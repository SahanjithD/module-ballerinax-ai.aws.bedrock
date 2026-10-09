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
// Options shared by the `bedrock-mantle` model providers.
// ============================================================================

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
// Model IDs and configuration, per vendor.
// ============================================================================

// BARE ids: Mantle has no cross-region inference, so takes no geo prefix. Every one
// is also on `bedrock-runtime`, which adds guardrails, cross-region inference and
// typed `generate()`, so the runtime class is the better default.
// https://docs.aws.amazon.com/bedrock/latest/userguide/models-endpoint-availability.html

# Anthropic model IDs on `bedrock-mantle`.
public enum AnthropicMantleModel {
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-5-5.html
    MANTLE_CLAUDE_OPUS_5_5 = "anthropic.claude-opus-5-5",
    MANTLE_CLAUDE_OPUS_5 = "anthropic.claude-opus-5",
    MANTLE_CLAUDE_OPUS_4_8 = "anthropic.claude-opus-4-8",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-4-7.html
    MANTLE_CLAUDE_OPUS_4_7 = "anthropic.claude-opus-4-7",
    MANTLE_CLAUDE_SONNET_5 = "anthropic.claude-sonnet-5",
    MANTLE_CLAUDE_HAIKU_4_5 = "anthropic.claude-haiku-4-5",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-fable-5.html
    # Needs an account opt-in: set the data retention mode to `aws_review` first
    MANTLE_CLAUDE_FABLE_5 = "anthropic.claude-fable-5",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-fable-5-1.html
    # Needs the Fable 5 opt-in
    MANTLE_CLAUDE_FABLE_5_1 = "anthropic.claude-fable-5-1"
}

# Configuration for `MantleAnthropicModelProvider`.
public type AnthropicMantleConfig record {|
    *CommonMantleConfig;

    // A typed record rather than raw `json`, so the mode/budget pairing rules are
    // checked at construction.
    # Extended thinking settings
    ThinkingConfig thinking?;

    // Sent as `output_config.effort`.
    # Reasoning effort. The only depth control on Fable 5 and Opus 4.7
    Effort effort?;
|};

// The GPT-5.x models are reachable only here.

# OpenAI model IDs on `bedrock-mantle`.
public enum OpenAIMantleModel {
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-55.html
    MANTLE_GPT_5_5 = "openai.gpt-5.5",
    MANTLE_GPT_5_4 = "openai.gpt-5.4",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-sol.html
    MANTLE_GPT_5_6_SOL = "openai.gpt-5.6-sol",
    MANTLE_GPT_5_6_TERRA = "openai.gpt-5.6-terra",
    MANTLE_GPT_5_6_LUNA = "openai.gpt-5.6-luna",
    // Published under a DIFFERENT id per endpoint — `-1:0` on bedrock-runtime, bare
    // here. The module puts the Mantle id on the wire.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
    MANTLE_GPT_OSS_120B = "openai.gpt-oss-120b-1:0",
    // The GPT-6 family. Bare here, and on `/openai/v1` — each card states it
    // explicitly ("On `bedrock-mantle`, both APIs use the `/openai/v1` base path. Do
    // not use `/v1`."). Sol and Luna are in us-east-1.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-astra.html
    # Available in us-west-2 only
    MANTLE_GPT_6_ASTRA = "openai.gpt-6-astra",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-sol.html
    MANTLE_GPT_6_SOL = "openai.gpt-6-sol",
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-luna.html
    MANTLE_GPT_6_LUNA = "openai.gpt-6-luna"
}

# Configuration for `MantleOpenAIModelProvider`.
public type OpenAIMantleConfig record {|
    *CommonMantleConfig;

    // Top-level `reasoning_effort` on Chat Completions, nested `reasoning.effort` on
    // Responses.
    # How much the model reasons before answering
    ReasoningEffort reasoningEffort?;
|};

# Mistral model IDs on `bedrock-mantle`.
public enum MistralMantleModel {
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-mistral-ai-mistral-large-3.html
    MANTLE_MISTRAL_LARGE_3 = "mistral.mistral-large-3-675b-instruct"
}

# Configuration for `MantleMistralModelProvider`.
public type MistralMantleConfig record {|
    *CommonMantleConfig;
|};

// Both are published under a different id on each endpoint. These constants carry
// the runtime-shaped id and the module puts the Mantle one on the wire.

# Qwen model IDs on `bedrock-mantle`.
public enum QwenMantleModel {
    // `qwen.qwen3-32b` on Mantle.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-32b.html
    MANTLE_QWEN3_32B = "qwen.qwen3-32b-v1:0",
    // `qwen.qwen3-coder-480b-a35b-instruct` on Mantle.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-coder-480b-a35b-instruct.html
    MANTLE_QWEN3_CODER_480B = "qwen.qwen3-coder-480b-a35b-v1:0"
}

# Configuration for `MantleQwenModelProvider`.
public type QwenMantleConfig record {|
    *CommonMantleConfig;

    // Sent as `enable_thinking` in the request body.
    # Turns Qwen3 thinking on or off. Unset uses the model's default
    boolean enableThinking?;
|};

// The two generations sit on DIFFERENT paths: Gemma 3 speaks Chat Completions on
// `/v1/chat/completions`, Gemma 4 speaks Responses on `/openai/v1/responses`. The
// module resolves the path per model.
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-31b.html

# Google Gemma model IDs on `bedrock-mantle`.
public enum GoogleMantleModel {
    // Gemma 3 sits on `/v1/chat/completions` …
    MANTLE_GEMMA_3_4B_IT = "google.gemma-3-4b-it",
    MANTLE_GEMMA_3_12B_IT = "google.gemma-3-12b-it",
    MANTLE_GEMMA_3_27B_IT = "google.gemma-3-27b-it",
    // … while Gemma 4 sits on `/openai/v1/responses`. One vendor prefix, two Mantle
    // path families — which is exactly why the path is per-model table data and never
    // derived from the prefix.
    # Not available on `bedrock-runtime`
    MANTLE_GEMMA_4_E2B = "google.gemma-4-e2b",
    # Not available on `bedrock-runtime`
    MANTLE_GEMMA_4_26B_A4B = "google.gemma-4-26b-a4b",
    # Not available on `bedrock-runtime`
    MANTLE_GEMMA_4_31B = "google.gemma-4-31b"
}

# Configuration for `MantleGoogleModelProvider`.
public type GoogleMantleConfig record {|
    *CommonMantleConfig;
|};

# DeepSeek model IDs on `bedrock-mantle`.
public enum DeepSeekMantleModel {
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-v3-2.html
    MANTLE_DEEPSEEK_V3_2 = "deepseek.v3.2"
}

# Configuration for `MantleDeepSeekModelProvider`.
public type DeepSeekMantleConfig record {|
    *CommonMantleConfig;
|};
