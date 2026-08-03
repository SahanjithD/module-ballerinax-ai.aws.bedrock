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

// Routing tables — DATA, not code (design principle 5, §5.5, §7.3). A new model
// for a listed vendor is reachable by extending these tables (or via
// `routeOverrides`) with no other code change.

const decimal DEFAULT_TEMPERATURE = 0.7d;
const int DEFAULT_MAX_TOKEN_COUNT = 512;

// Cross-region-inference geo prefixes, stripped for lookup then re-applied per
// family on the wire (design §5.3). List copied from LiteLLM's cross-region
// inference regions helper — includes `us-gov`, which a hand-rolled list would miss.
// https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html
final readonly & string[] CRIS_PREFIXES = ["global", "us", "eu", "apac", "jp", "au", "us-gov"];

// WHAT a model needs to speak Mantle — every Mantle-capable model, dual-endpoint
// or not (design §7.3). This is now THE table that drives AUTO routing: under
// Amendment 2 the preference order is MANTLE → CONVERSE → INVOKE, so membership here
// means a bare id resolves to Mantle by default (as well as when forced). Because
// membership requires a verified path/auth/codec, an unknown model is still absent
// and sinks to Converse — never Mantle by elimination.
// Path, auth style, and codec are per-model data; deriving the path from the
// `openai.` prefix would break the moment AWS ships an `openai.*` model on a
// different path (design §7.3, model-card-openai-gpt-55).
// https://docs.aws.amazon.com/bedrock/latest/userguide/bedrock-mantle.html
final readonly & map<MantleEntry> MANTLE_CAPABLE = {
    // GPT-5.x use `/openai/v1/responses`, distinct from the `/v1/responses` other
    // models use — every card below states this in its own Note.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-55.html
    "openai.gpt-5.5": {path: "/openai/v1/responses", authHeader: BEARER, codec: RESPONSES_CODEC},
    "openai.gpt-5.4": {path: "/openai/v1/responses", authHeader: BEARER, codec: RESPONSES_CODEC},
    // GPT-5.6 (launched 2026-07-13). Each id verified against its own card: Mantle
    // only, Responses YES / Chat Completions NO, path `/openai/v1`.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-sol.html
    "openai.gpt-5.6-sol": {path: "/openai/v1/responses", authHeader: BEARER, codec: RESPONSES_CODEC},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-terra.html
    "openai.gpt-5.6-terra": {path: "/openai/v1/responses", authHeader: BEARER, codec: RESPONSES_CODEC},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-luna.html
    "openai.gpt-5.6-luna": {path: "/openai/v1/responses", authHeader: BEARER, codec: RESPONSES_CODEC},
    // Anthropic Messages on Mantle: `anthropic-version: 2023-06-01` header (§7.3).
    // Default auth header X_API_KEY per AWS's documented curl (§14 open item #1).
    "anthropic.claude-mythos-preview": {path: "/anthropic/v1/messages", authHeader: X_API_KEY, codec: MESSAGES_CODEC},
    // Mantle-only, Messages API (Converse/Invoke/Responses all NO).
    // NOTE: this card's sample uses the Anthropic SDK with AWS_BEARER_TOKEN_BEDROCK,
    // which does not settle the wire header — so it keeps X_API_KEY for consistency
    // with mythos-preview above. This is design §14 open item #1, still unresolved;
    // one live call settles it for both.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-mythos-5.html
    "anthropic.claude-mythos-5": {path: "/anthropic/v1/messages", authHeader: X_API_KEY, codec: MESSAGES_CODEC},
    "anthropic.claude-haiku-4-5": {path: "/anthropic/v1/messages", authHeader: X_API_KEY, codec: MESSAGES_CODEC},
    "zai.glm-5": {path: "/v1/chat/completions", authHeader: BEARER, codec: CHAT_CODEC},
    // --- Dual-endpoint models (bedrock-runtime YES + bedrock-mantle YES). ---
    // Under Amendment 2 these DEFAULT to Mantle under AUTO (preference MANTLE →
    // CONVERSE → INVOKE); pass `apiFamily = CONVERSE` (or a `converse/` prefix) to use
    // the runtime surface instead — which `generate()` with a typed target requires,
    // since Mantle has no structured output.
    //
    // Card: bedrock-runtime YES + bedrock-mantle YES; Messages API YES,
    // Responses/Chat Completions NO; Mantle URL `/anthropic/v1/messages`.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-4-8.html
    "anthropic.claude-opus-4-8": {path: "/anthropic/v1/messages", authHeader: X_API_KEY, codec: MESSAGES_CODEC},
    // Opus 5 (launched 2026-07-24) is dual-homed: bedrock-runtime YES +
    // bedrock-mantle YES; Messages YES, Responses NO, Chat Completions NO. Same id on
    // both endpoints, Mantle URL `/anthropic/v1/messages`. X_API_KEY for consistency
    // with the Anthropic entries above (the card's sample uses the Anthropic SDK with
    // AWS_BEARER_TOKEN_BEDROCK, which does not state the wire header) — §14 open
    // item #1.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-5.html
    "anthropic.claude-opus-5": {path: "/anthropic/v1/messages", authHeader: X_API_KEY, codec: MESSAGES_CODEC},
    // Sonnet 5 is dual-homed like opus-4-8: bedrock-runtime YES + bedrock-mantle YES,
    // Messages API on `/anthropic/v1/messages`. Defaults to Converse (richer); this
    // entry exists so forcing MANTLE works instead of erroring "not on Mantle".
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html
    "anthropic.claude-sonnet-5": {path: "/anthropic/v1/messages", authHeader: X_API_KEY, codec: MESSAGES_CODEC},
    // gpt-oss is published under DIFFERENT IDS PER ENDPOINT — `-1:0` on
    // bedrock-runtime, bare on bedrock-mantle — hence `modelId`. Mantle base URL is
    // `/v1` (not `/openai/v1` like GPT-5.x), and it serves both Responses and Chat
    // Completions; we take Chat Completions.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
    "openai.gpt-oss-120b-1:0": {
        path: "/v1/chat/completions",
        authHeader: BEARER,
        codec: CHAT_CODEC,
        modelId: "openai.gpt-oss-120b"
    },
    // DeepSeek V3.2 — dual-homed; Mantle serves Chat Completions on `/v1`, same id on
    // both endpoints, BEARER (card sample sets OPENAI_API_KEY against the `/v1` base).
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-v3-2.html
    "deepseek.v3.2": {path: "/v1/chat/completions", authHeader: BEARER, codec: CHAT_CODEC},
    // Mistral Large 3 — dual-homed; Mantle Chat Completions on `/v1`, same id both
    // endpoints, BEARER.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-mistral-ai-mistral-large-3.html
    "mistral.mistral-large-3-675b-instruct":
        {path: "/v1/chat/completions", authHeader: BEARER, codec: CHAT_CODEC},
    // Qwen3 Coder 480B — dual-homed; DIFFERENT id per endpoint (`-v1:0` on runtime,
    // `-instruct` on Mantle, like gpt-oss), so `modelId` overrides the wire id. Mantle
    // Chat Completions on `/v1`, BEARER.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-coder-480b-a35b-instruct.html
    "qwen.qwen3-coder-480b-a35b-v1:0": {
        path: "/v1/chat/completions",
        authHeader: BEARER,
        codec: CHAT_CODEC,
        modelId: "qwen.qwen3-coder-480b-a35b-instruct"
    },
    // Qwen3 32B — dual-homed; DIFFERENT id per endpoint (`-v1:0` on runtime, bare
    // `qwen.qwen3-32b` on Mantle), Chat Completions on `/v1`, BEARER. In-Region YES.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-32b.html
    "qwen.qwen3-32b-v1:0": {
        path: "/v1/chat/completions",
        authHeader: BEARER,
        codec: CHAT_CODEC,
        modelId: "qwen.qwen3-32b"
    },
    // Gemma 4 is Mantle-ONLY. Its card's support matrix marks bedrock-runtime,
    // Converse, Invoke and Messages all NO, and states: "Gemma 4 models are
    // available only on the `bedrock-mantle` endpoint. This model is available on
    // the `openai/v1/responses` path ... different from the `v1/responses` path
    // used by other models." Its Programmatic Access table gives exactly one row:
    // bedrock-mantle | google.gemma-4-31b | https://bedrock-mantle.{region}.api.aws/openai/v1
    // Auth is BEARER: the card's sample sets OPENAI_API_KEY against that base URL.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-31b.html
    // Each id below was checked against its OWN card — same matrix, same Note, and
    // a Programmatic Access table with exactly one row (bedrock-mantle, /openai/v1).
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-31b.html
    "google.gemma-4-31b": {path: "/openai/v1/responses", authHeader: BEARER, codec: RESPONSES_CODEC},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-e2b.html
    "google.gemma-4-e2b": {path: "/openai/v1/responses", authHeader: BEARER, codec: RESPONSES_CODEC},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-26b-a4b.html
    "google.gemma-4-26b-a4b": {path: "/openai/v1/responses", authHeader: BEARER, codec: RESPONSES_CODEC},
    // Gemma 3 (dual-homed) — CRUCIALLY DIFFERENT from Gemma 4: its Mantle rows sit on
    // `/v1` with Chat Completions, NOT `/openai/v1` + Responses. So one vendor prefix
    // (`google.`) spans two Mantle path families, which is exactly why the path is
    // per-model table data and never derived from the prefix. Each id verified against
    // its own card: same id on both endpoints, `/v1` Chat Completions, BEARER,
    // In-Region YES in us-east-1.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-27b-pt.html
    "google.gemma-3-27b-it": {path: "/v1/chat/completions", authHeader: BEARER, codec: CHAT_CODEC},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-12b-it.html
    "google.gemma-3-12b-it": {path: "/v1/chat/completions", authHeader: BEARER, codec: CHAT_CODEC},
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-4b-it.html
    "google.gemma-3-4b-it": {path: "/v1/chat/completions", authHeader: BEARER, codec: CHAT_CODEC}
};

// NOTE: there is no separate `MANTLE_DEFAULT` list (removed under Amendment 2). It
// once held only the Mantle-ONLY models, because dual-endpoint models defaulted to
// Converse. Amendment 2 flips that default — any Mantle-CAPABLE model prefers Mantle
// under AUTO — so `MANTLE_CAPABLE` membership alone now decides the default, and a
// second list would only drift out of sync. There is likewise no `CONVERSE_MODELS`
// allowlist: everything absent from `MANTLE_CAPABLE` (and every geo-prefixed id)
// sinks to Converse, so an unknown id can never reach Mantle by elimination (§11).
