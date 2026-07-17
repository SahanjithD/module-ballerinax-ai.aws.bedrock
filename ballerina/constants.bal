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
// or not (design §7.3). The explicit override (ladder step 1) reads this table.
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
    "google.gemma-4-26b-a4b": {path: "/openai/v1/responses", authHeader: BEARER, codec: RESPONSES_CODEC}
    // Gemma 3 is deliberately absent: it is dual-homed (bedrock-runtime AND
    // bedrock-mantle) and defaults to Converse. Its Mantle rows sit on `/v1` with
    // Chat Completions — NOT `/openai/v1` + Responses like Gemma 4 — so one vendor
    // prefix spans two Mantle path families. Adding Gemma 3 entries needs each id's
    // own card read first; only 3-27b-it has been checked.
};

// WHICH models DEFAULT to Mantle — only the Mantle-only ones (design §5.5, §7.3).
// Dual-endpoint models are in MANTLE_CAPABLE but NOT here: they default to
// Converse (the strictly richer surface) and opt into Mantle explicitly.
// https://docs.aws.amazon.com/bedrock/latest/userguide/models-endpoint-availability.html
final readonly & string[] MANTLE_DEFAULT = [
    "openai.gpt-5.5",
    "openai.gpt-5.4",
    "openai.gpt-5.6-sol",
    "openai.gpt-5.6-terra",
    "openai.gpt-5.6-luna",
    "anthropic.claude-mythos-preview",
    "anthropic.claude-mythos-5",
    // Gemma 4 is Mantle-ONLY (no Converse row on its card), so Mantle is not an
    // opt-in here — it is the only endpoint that serves these models.
    "google.gemma-4-31b",
    "google.gemma-4-e2b",
    "google.gemma-4-26b-a4b"
];

// Positive Converse allowlist (design §5.1 step 5). Membership is documentation:
// an unknown bare id still resolves to Converse via the sink (step 6), so this
// table never routes to Mantle by elimination (design principle 2, §11).
final readonly & string[] CONVERSE_MODELS = [
    "anthropic.claude-opus-4-8",
    "anthropic.claude-sonnet-4-6",
    "anthropic.claude-haiku-4-5",
    "amazon.nova-pro-v1:0",
    "amazon.nova-lite-v1:0",
    "amazon.nova-micro-v1:0",
    "mistral.mistral-large-2407-v1:0",
    "deepseek.r1-v1:0",
    "qwen.qwen3-32b-v1:0"
];
