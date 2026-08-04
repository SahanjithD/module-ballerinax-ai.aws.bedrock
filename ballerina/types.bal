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
// Public enums — design §10.
// ============================================================================

# Route selection on the common config, plus the resolved wire family (design §5,
# amendment). `AUTO` (the config default) runs the resolver ladder; `CONVERSE`,
# `INVOKE`, `MANTLE` force that family. A resolved `Route.family` is never `AUTO`.
public enum ApiFamily {
    AUTO,
    CONVERSE,
    INVOKE,
    MANTLE
}

# Body schema selector for `imported-model/` ARNs, where AWS applies no default
# chat template and the codec cannot be inferred from the id (design §5.4, §7.2).
public enum ModelSchema {
    ANTHROPIC,
    OPENAI,
    NOVA,
    LLAMA,
    # Mistral's `messages`/`choices` chat-completion dialect (Mistral Large 24.07).
    MISTRAL,
    # Mistral's `prompt`/`outputs` text-completion dialect (7B, Mixtral, Large 24.02).
    # A SEPARATE schema because the two dialects share a vendor prefix but no wire
    # shape, and an imported model's id cannot tell them apart.
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-text-completion.html
    MISTRAL_TEXT,
    # DeepSeek-R1's `prompt`/`choices[].text` text-completion dialect. DeepSeek V3.1
    # and V3.2 speak OpenAI-shaped chat completion on InvokeModel instead — use
    # `OPENAI` for an imported model of that generation.
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-deepseek.html
    DEEPSEEK
}

# How a wire dialect forces a single named tool (design §8). This is a property of
# the CODEC, not the route: Nova on InvokeModel is Converse-shaped, and Mistral's
# chat dialect looks OpenAI-shaped but forces tools with the bare string `"any"`.
# Deriving it from `ApiFamily` silently emits the wrong field for those dialects.
# Module-private: it lives on the internal `ModelCodec`, never on user config.
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

# Auth-header style for a Mantle model. Per-model data, not derivable from the
# vendor prefix (design §7.3, open item #1).
public enum AuthHeaderStyle {
    X_API_KEY,
    BEARER
}

# Converse `serviceTier` passthrough (design §9.3).
#
# Values are AWS's, verbatim. Note there is no "standard" tier — the baseline is
# spelled `default`. The member names carry a `TIER_` prefix because a bare
# `DEFAULT` reads as a language keyword at the call site.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModel.html
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

# Whether a guardrail intervened on a response (design §9.5).
# Module-private: only reachable via the internal `DecodedResponse`.
enum GuardrailAction {
    INTERVENED,
    NONE
}

// ============================================================================
// Route resolution result — design §5.3.
// ============================================================================

# A single Mantle model's wire contract. Path, auth style, and codec are all
# per-model data (design §7.3) — none is derivable from the vendor prefix.
public type MantleEntry record {|
    # Request path on the `bedrock-mantle` host, e.g. `/anthropic/v1/messages`.
    string path;
    # Auth-header style AWS documents for this model.
    AuthHeaderStyle authHeader;
    # Codec key selecting the encode/decode pair for this Mantle dialect.
    MantleCodecKey codec;
    # The id to put on the wire when it DIFFERS from the `bedrock-runtime` id.
    #
    # For most models the two endpoints share an id, and this is omitted. But some
    # models are published under different ids per endpoint — gpt-oss is
    # `openai.gpt-oss-120b-1:0` on `bedrock-runtime` and `openai.gpt-oss-120b` on
    # `bedrock-mantle`. Without this, forcing Mantle sends the runtime id and fails.
    # https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html
    string modelId?;
|};

# Names the Mantle wire dialect a `MantleEntry` speaks. Kept as a key (not the
# codec value itself) so the routing tables in `constants.bal` stay pure data.
public enum MantleCodecKey {
    RESPONSES_CODEC,
    MESSAGES_CODEC,
    CHAT_CODEC
}

# The fully resolved route — produced once by `resolveRoute` at construction
# (design §5.3, §6). Everything downstream (endpoint, codec, transport) reads
# from this. Module-private: the resolver's output, mirroring the private `Endpoint`.
type Route record {|
    # The resolved wire dialect.
    ApiFamily family;
    # Lookup key with any CRIS geo prefix stripped, e.g. `anthropic.claude-opus-4-8`.
    string bareModelId;
    # The stripped CRIS geo prefix, re-applied per family on the wire (design §5.3).
    string? geoPrefix;
    # The id that goes on the wire — family-specific (CRIS-prefixed for Converse/
    # Invoke, bare for Mantle, or the raw ARN for opaque ARNs).
    string effectiveModelId;
    # Region. An ARN's region segment overrides `config.region` (design §5.2).
    string region;
    # Partition: `aws` | `aws-cn` | `aws-us-gov` (design §9.2).
    string partition;
    # Present only for MANTLE routes.
    MantleEntry? mantleEntry;
|};

// ============================================================================
// Internal route-resolution input — the routing slice of a vendor config.
// ============================================================================

# The subset of a vendor `*Config` that `resolveRoute` (pure) needs. Each vendor
# `init` builds this from its own config record, keeping the resolver decoupled
# from the seven per-vendor config shapes (design §5.1, §6). Module-private input.
type RouteConfig record {|
    # Explicit route override — outranks every heuristic (design §5.1 step 1).
    ApiFamily apiFamily?;
    # Required for `imported-model/` ARNs (design §5.4).
    ModelSchema modelSchema?;
    # Extends the routing tables without a release (design §5.1 step 3, §7.3).
    map<ApiFamily|MantleEntry> routeOverrides?;
|};
