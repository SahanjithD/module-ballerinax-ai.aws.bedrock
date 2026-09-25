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

// Routing tables — DATA, not code. A new model for a listed vendor is reachable by
// extending these tables with no other code change.
//
// A new CONVERSE/INVOKE model needs no table entry at all: pass its id as a string
// and the resolver sinks it to Converse. Only a new MANTLE model needs a row here,
// because its path cannot be derived — and a module release is the cost of that,
// same as every other Ballerina model provider.

// There is deliberately NO default temperature. Anthropic deprecated sampling
// parameters on Claude 4.7 and later, and OpenAI's GPT-5.x reasoning models never
// accepted them — on those models any value at all is a 400, so a module default
// would make seven of this package's flagship model ids unusable out of the box.
// Unset means the key is absent from the request and the model's own default
// applies. See `setTemperature` in converter_common.bal.

// 512 was too low to be a safe default: on adaptive-thinking models (Claude 4.7+,
// Sonnet 5, Opus 5) thinking tokens count against this ceiling, so the response
// routinely stopped with `max_tokens` before producing any text — which reads as a
// module bug, not a config problem. 4096 leaves room for a thinking pass plus an
// answer while staying under the tightest per-model output cap in the supported set
// (Nova Pro/Lite/Micro are capped at 5K output tokens, so 8192 would be rejected
// outright on BedrockRuntimeAmazonModelProvider).
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-amazon-nova-pro.html
const int DEFAULT_MAX_TOKEN_COUNT = 4096;

// Cross-region-inference geo prefixes, stripped for lookup then re-applied on the
// wire. bedrock-runtime only: bedrock-mantle has no cross-region inference, and
// `resolveMantleRoute` refuses a prefixed id rather than silently stripping it. List copied from LiteLLM's cross-region
// inference regions helper — includes `us-gov`, which a hand-rolled list would miss.
// https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html
// Anthropic's documented floor for a manual thinking budget.
// https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-extended-thinking.html
const int MIN_THINKING_BUDGET_TOKENS = 1024;

final readonly & string[] CRIS_PREFIXES = ["global", "us", "eu", "apac", "jp", "au", "us-gov"];

// WHAT a model needs to speak Mantle — the registry the `BedrockMantle*ModelProvider`
// classes resolve against. Membership means we hold a verified request path for the
// model; absence is a clean "not available on Mantle" construction error.
//
// This is NO LONGER a routing-preference table. The provider class fixes the
// endpoint, so there is no resolver ladder that could prefer one endpoint over the
// other and no way for an unknown id to reach Mantle by elimination.
//
// The BASE PATH is the per-model datum — see `MantleEntry` for AWS's own two
// contradicting per-card notes that make it so. Everything else is derived: the path
// suffix from the API family (`mantlePathFor`), the converter from the API family
// (`selectConverter`), and the auth header style from the API family (`usesApiKeyHeader`).
// https://docs.aws.amazon.com/bedrock/latest/userguide/bedrock-mantle.html
final readonly & map<MantleEntry> MANTLE_CAPABLE = {
    // --- Anthropic: `/anthropic/v1`, Messages only. Uniform across every Claude. ---
    // Auth is `x-api-key` plus an `anthropic-version: 2023-06-01` header, both keyed
    // off the MESSAGES shape rather than stored here.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html
    "anthropic.claude-haiku-4-5": {basePath: "/anthropic/v1", apis: [MESSAGES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-4-8.html
    "anthropic.claude-opus-4-8": {basePath: "/anthropic/v1", apis: [MESSAGES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-5.html
    "anthropic.claude-opus-5": {basePath: "/anthropic/v1", apis: [MESSAGES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html
    "anthropic.claude-sonnet-5": {basePath: "/anthropic/v1", apis: [MESSAGES]},

    // --- `/openai/v1` models. The base path is the per-model datum, and these cards
    // --- say so in as many words: "both APIs use the `/openai/v1` base path, not
    // --- `/v1`". Only RESPONSES is listed because that is the API family each card's
    // --- Programmatic Access row records; adding CHAT_COMPLETIONS needs the same
    // --- per-card check rather than an inference from the base path.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-55.html
    "openai.gpt-5.5": {basePath: "/openai/v1", apis: [RESPONSES]},
    "openai.gpt-5.4": {basePath: "/openai/v1", apis: [RESPONSES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-sol.html
    "openai.gpt-5.6-sol": {basePath: "/openai/v1", apis: [RESPONSES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-terra.html
    "openai.gpt-5.6-terra": {basePath: "/openai/v1", apis: [RESPONSES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-luna.html
    "openai.gpt-5.6-luna": {basePath: "/openai/v1", apis: [RESPONSES]},
    // Gemma 4 is Mantle-ONLY, and sits on `/openai/v1` — unlike Gemma 3 below. One
    // vendor prefix, two base paths, which is the clearest single proof that this
    // cannot be derived from the vendor.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-31b.html
    "google.gemma-4-31b": {basePath: "/openai/v1", apis: [RESPONSES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-e2b.html
    "google.gemma-4-e2b": {basePath: "/openai/v1", apis: [RESPONSES]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-26b-a4b.html
    "google.gemma-4-26b-a4b": {basePath: "/openai/v1", apis: [RESPONSES]},

    // --- `/v1` models. ---
    // gpt-oss is the worked example for BOTH irregularities at once. Its card states
    // verbatim: "On bedrock-mantle, both APIs use the `/v1` base path, not
    // `/openai/v1`. Use either API with this model: For Responses, use
    // `/v1/responses`. For Chat Completions, use `/v1/chat/completions`." — hence two
    // shapes. It is also published under a different id per endpoint (`-1:0` on
    // bedrock-runtime, bare here), hence `modelId`.
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
    // Both Qwen3 ids are published under a different id per endpoint, like gpt-oss.
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
    // Gemma 3 sits on `/v1` with Chat Completions — the counterpart to Gemma 4 above.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-27b-pt.html
    "google.gemma-3-27b-it": {basePath: "/v1", apis: [CHAT_COMPLETIONS]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-12b-it.html
    "google.gemma-3-12b-it": {basePath: "/v1", apis: [CHAT_COMPLETIONS]},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-4b-it.html
    "google.gemma-3-4b-it": {basePath: "/v1", apis: [CHAT_COMPLETIONS]}
};

// NOTE: there is deliberately no `CONVERSE_MODELS` allowlist to mirror this one.
// Converse is model-agnostic — one converter serves every vendor — so a runtime
// class accepts any id and an unknown one simply goes on the wire. Mantle needs a
// table only because a Mantle request path is not derivable from a model id.

// Models that REFUSE a forced tool choice. `generate()` obtains a typed result by
// forcing a single result tool (`generateByToolForcing`), so on these models that
// mechanism is a hard 400 and the module reports it up front instead of relaying
// whatever AWS says about `toolChoice`.
//
// Anthropic states it for Claude Opus 5.5 and, in the same breath, for Claude Fable
// 5.1 ("The first three also apply on Claude Fable 5.1"):
//
//   Claude Opus 5.5 doesn't support forced tool use. `tool_choice` set to
//   {"type": "any"} or {"type": "tool", "name": "..."} returns a 400
//   invalid_request_error: tool_choice: type "tool" and "any" are not supported for
//   this model.
//
// It binds every dialect this module speaks for those models, not just the native
// Messages one: Converse's `toolConfig.toolChoice` and the OpenAI-compatible
// `tool_choice` both land on the same validator.
// https://platform.claude.com/docs/en/models/opus-5-5/whats-new-opus-5-5
//
// Keyed on the BARE id (no CRIS prefix), which is the form both endpoints agree on.
// An opaque ARN — a provisioned model or an inference profile — hides the model id,
// so those cannot be matched here and AWS answers for them instead.
final readonly & string[] FORCED_TOOL_UNSUPPORTED = [
    "anthropic.claude-opus-5-5",
    "anthropic.claude-fable-5-1"
];

// Whether a model refuses a forced tool choice. Takes the wire id, so a CRIS-prefixed
// `us.anthropic.claude-opus-5-5` is recognised as readily as the bare Mantle id.
isolated function refusesForcedToolChoice(string wireModelId) returns boolean {
    [string, string?] [bareId, _] = normalizeModelId(wireModelId);
    return FORCED_TOOL_UNSUPPORTED.indexOf(bareId) is int;
}
