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
    MISTRAL,
    DEEPSEEK
}

# Auth-header style for a Mantle model. Per-model data, not derivable from the
# vendor prefix (design §7.3, open item #1).
public enum AuthHeaderStyle {
    X_API_KEY,
    BEARER
}

# Converse `serviceTier` passthrough (design §9.3).
public enum ServiceTier {
    STANDARD,
    PRIORITY,
    FLEX,
    RESERVED
}

# Whether a guardrail intervened on a response (design §9.5).
public enum GuardrailAction {
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
# from this.
public type Route record {|
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
# from the seven per-vendor config shapes (design §5.1, §6).
public type RouteConfig record {|
    # Explicit route override — outranks every heuristic (design §5.1 step 1).
    ApiFamily apiFamily?;
    # Required for `imported-model/` ARNs (design §5.4).
    ModelSchema modelSchema?;
    # Extends the routing tables without a release (design §5.1 step 3, §7.3).
    map<ApiFamily|MantleEntry> routeOverrides?;
|};
