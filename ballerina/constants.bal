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

// No default temperature: Claude 4.7+ and the GPT-5.x reasoning models reject any
// value, so the field is left out unless the caller sets it.

// Room for a thinking pass plus an answer, and still under Nova's 5K output cap.
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-amazon-nova-pro.html
const int DEFAULT_MAX_TOKEN_COUNT = 4096;

// Request timeouts in seconds, unless `httpConfig.timeout` is set. A reasoning model
// can think for minutes; embeddings and knowledge-base calls return quickly.
const decimal INFERENCE_TIMEOUT = 300;
const decimal DEFAULT_TIMEOUT = 60;
// `http:ClientConfiguration.timeout`'s own default, which is read as "not set".
const decimal HTTP_CLIENT_DEFAULT_TIMEOUT = 30;

// Anthropic's floor for a manual thinking budget.
// https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-extended-thinking.html
const int MIN_THINKING_BUDGET_TOKENS = 1024;

// Cross-region inference geo prefixes, stripped for lookup and put back on the wire.
// bedrock-runtime only: bedrock-mantle has no cross-region inference.
// https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html
final readonly & string[] CRIS_PREFIXES = ["global", "us", "eu", "apac", "jp", "au", "us-gov"];

// Models served on bedrock-mantle and each one's base path, which differs per model
// even within one vendor. A model not listed is refused by the Mantle classes.
// https://docs.aws.amazon.com/bedrock/latest/userguide/bedrock-mantle.html
final readonly & map<MantleEntry> MANTLE_CAPABLE = {
    // Anthropic: `/anthropic/v1`, Messages only.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html
    "anthropic.claude-haiku-4-5": {basePath: "/anthropic/v1", apis: [MESSAGES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-5-5.html
    "anthropic.claude-opus-5-5": {basePath: "/anthropic/v1", apis: [MESSAGES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-4-7.html
    "anthropic.claude-opus-4-7": {basePath: "/anthropic/v1", apis: [MESSAGES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-fable-5.html
    "anthropic.claude-fable-5": {basePath: "/anthropic/v1", apis: [MESSAGES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-fable-5-1.html
    "anthropic.claude-fable-5-1": {basePath: "/anthropic/v1", apis: [MESSAGES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-4-8.html
    "anthropic.claude-opus-4-8": {basePath: "/anthropic/v1", apis: [MESSAGES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-5.html
    "anthropic.claude-opus-5": {basePath: "/anthropic/v1", apis: [MESSAGES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html
    "anthropic.claude-sonnet-5": {basePath: "/anthropic/v1", apis: [MESSAGES]},

    // `/openai/v1` models, per each model card's Programmatic Access section.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-55.html
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-astra.html
    "openai.gpt-6-astra": {basePath: "/openai/v1", apis: [RESPONSES, CHAT_COMPLETIONS]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-sol.html
    "openai.gpt-6-sol": {basePath: "/openai/v1", apis: [RESPONSES, CHAT_COMPLETIONS]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-luna.html
    "openai.gpt-6-luna": {basePath: "/openai/v1", apis: [RESPONSES, CHAT_COMPLETIONS]},
    "openai.gpt-5.5": {basePath: "/openai/v1", apis: [RESPONSES]},
    "openai.gpt-5.4": {basePath: "/openai/v1", apis: [RESPONSES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-sol.html
    "openai.gpt-5.6-sol": {basePath: "/openai/v1", apis: [RESPONSES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-terra.html
    "openai.gpt-5.6-terra": {basePath: "/openai/v1", apis: [RESPONSES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-luna.html
    "openai.gpt-5.6-luna": {basePath: "/openai/v1", apis: [RESPONSES]},
    // Gemma 4 is on `/openai/v1`, unlike Gemma 3 on `/v1`.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-31b.html
    "google.gemma-4-31b": {basePath: "/openai/v1", apis: [RESPONSES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-e2b.html
    "google.gemma-4-e2b": {basePath: "/openai/v1", apis: [RESPONSES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-26b-a4b.html
    "google.gemma-4-26b-a4b": {basePath: "/openai/v1", apis: [RESPONSES]},

    // `/v1` models. gpt-oss serves both APIs there, and its Mantle id drops the `-1:0`.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
    "openai.gpt-oss-120b-1:0": {
        basePath: "/v1",
        apis: [CHAT_COMPLETIONS, RESPONSES],
        modelId: "openai.gpt-oss-120b"
    },
    "zai.glm-5": {basePath: "/v1", apis: [CHAT_COMPLETIONS]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-v3-2.html
    "deepseek.v3.2": {basePath: "/v1", apis: [CHAT_COMPLETIONS]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-mistral-ai-mistral-large-3.html
    "mistral.mistral-large-3-675b-instruct": {basePath: "/v1", apis: [CHAT_COMPLETIONS]},
    // The Qwen3 ids also differ per endpoint.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-coder-480b-a35b-instruct.html
    "qwen.qwen3-coder-480b-a35b-v1:0": {
        basePath: "/v1",
        apis: [CHAT_COMPLETIONS],
        modelId: "qwen.qwen3-coder-480b-a35b-instruct"
    },
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-32b.html
    "qwen.qwen3-32b-v1:0": {
        basePath: "/v1",
        apis: [CHAT_COMPLETIONS],
        modelId: "qwen.qwen3-32b"
    },
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-27b-pt.html
    "google.gemma-3-27b-it": {basePath: "/v1", apis: [CHAT_COMPLETIONS]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-12b-it.html
    "google.gemma-3-12b-it": {basePath: "/v1", apis: [CHAT_COMPLETIONS]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-4b-it.html
    "google.gemma-3-4b-it": {basePath: "/v1", apis: [CHAT_COMPLETIONS]}
};

// Models that reject a forced tool choice on every API, so `generate()` offers its
// tool unforced. Matched on the bare id; an ARN hides the model, so AWS answers.
// https://platform.claude.com/docs/en/models/opus-5-5/whats-new-opus-5-5
final readonly & string[] FORCED_TOOL_UNSUPPORTED = [
    "anthropic.claude-opus-5-5",
    "anthropic.claude-fable-5-1"
];

// Takes the wire id, so a cross-region `us.` id matches too.
isolated function refusesForcedToolChoice(string wireModelId) returns boolean {
    [string, string?] [bareId, _] = normalizeModelId(wireModelId);
    return FORCED_TOOL_UNSUPPORTED.indexOf(bareId) is int;
}

// With thinking on, Anthropic accepts only an `auto` or `none` tool choice.
// https://platform.claude.com/docs/en/build-with-claude/extended-thinking
isolated function thinkingEnabled(InferenceParams params) returns boolean {
    ThinkingConfig? thinking = params?.thinking;
    if thinking is ThinkingConfig {
        return thinking.mode != DISABLED;
    }
    AdditionalRequestFields? extra = params?.additionalModelRequestFields;
    json passthrough = extra is AdditionalRequestFields ? extra["thinking"] : ();
    if passthrough is map<json> {
        json kind = passthrough["type"];
        return kind is string && kind != "disabled";
    }
    return false;
}
