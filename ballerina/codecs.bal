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

// Codec registry + selection (design §7, §7.2, §7.3). `selectCodec` runs once at
// construction (L1/L2 — §4). The Anthropic vertical slice ships three codecs;
// the other Invoke/Mantle dialects error clearly until their vendor phase lands.

// Converse — model-agnostic, so one codec serves every Converse model (§5, §9.3).
final readonly & ModelCodec CONVERSE_CODEC = {
    encode: encodeConverse,
    decode: decodeConverse,
    supportsStreaming: true
};

// Invoke-Anthropic — `anthropic_version: bedrock-2023-05-31` body field (§7.2).
final readonly & ModelCodec INVOKE_ANTHROPIC_CODEC = {
    encode: encodeInvokeAnthropic,
    decode: decodeAnthropicMessages,
    supportsStreaming: true
};

// Mantle Messages — `anthropic-version: 2023-06-01` header (added by transport, §7.3).
final readonly & ModelCodec MANTLE_MESSAGES_CODEC = {
    encode: encodeMantleMessages,
    decode: decodeAnthropicMessages,
    supportsStreaming: false
};

// Mantle Responses — OpenAI Responses API (GPT-5.x on `/openai/v1/responses`, §7.3).
final readonly & ModelCodec MANTLE_RESPONSES_CODEC = {
    encode: encodeResponses,
    decode: decodeResponses,
    supportsStreaming: false
};

// Mantle Chat Completions — OpenAI chat shape (GLM on `/v1/chat/completions`, §7.3).
final readonly & ModelCodec MANTLE_CHAT_CODEC = {
    encode: encodeOpenAIChat,
    decode: decodeOpenAIChat,
    supportsStreaming: false
};

// Nova InvokeModel — `schemaVersion: messages-v1`; Converse-shaped response (§7.2).
final readonly & ModelCodec INVOKE_NOVA_CODEC = {
    encode: encodeNovaInvoke,
    decode: decodeConverse,
    supportsStreaming: true
};

// OpenAI-shaped InvokeModel — GPT-OSS, Qwen, DeepSeek, Mistral chat (§7.2).
final readonly & ModelCodec INVOKE_OPENAI_CHAT_CODEC = {
    encode: encodeOpenAIChat,
    decode: decodeOpenAIChat,
    supportsStreaming: false
};

// Selects the codec for a resolved route (design §7.2, §7.3). Runs at construction
// (§6). Fails cleanly for wire dialects / vendors not yet supported.
isolated function selectCodec(Route route, ModelSchema? schema = ()) returns readonly & ModelCodec|error {
    if route.family == CONVERSE {
        return CONVERSE_CODEC; // model-agnostic — serves every vendor (§5)
    }
    if route.family == MANTLE {
        MantleEntry entry = check route.mantleEntry.ensureType();
        match entry.codec {
            MESSAGES_CODEC => {
                return MANTLE_MESSAGES_CODEC;
            }
            RESPONSES_CODEC => {
                return MANTLE_RESPONSES_CODEC;
            }
            CHAT_CODEC => {
                return MANTLE_CHAT_CODEC;
            }
        }
        return error(string `unknown Mantle codec '${entry.codec}'`);
    }
    // INVOKE — keyed by modelSchema (imported ARNs) or vendor prefix (§7.2).
    return selectInvokeCodec(route.bareModelId, schema);
}

// Picks the InvokeModel codec by explicit `modelSchema` (imported ARNs) or the
// bare id's vendor prefix (design §5.4, §7.2).
isolated function selectInvokeCodec(string bareModelId, ModelSchema? schema) returns readonly & ModelCodec|error {
    if schema is ModelSchema {
        match schema {
            ANTHROPIC => {
                return INVOKE_ANTHROPIC_CODEC;
            }
            NOVA => {
                return INVOKE_NOVA_CODEC;
            }
            OPENAI|MISTRAL|DEEPSEEK => {
                return INVOKE_OPENAI_CHAT_CODEC;
            }
            LLAMA => {
                return error("Llama Invoke codec is intentionally out of scope for this build (CLAUDE.md §3)");
            }
        }
    }
    if bareModelId.startsWith("anthropic.") {
        return INVOKE_ANTHROPIC_CODEC;
    }
    if bareModelId.startsWith("amazon.") {
        return INVOKE_NOVA_CODEC;
    }
    if bareModelId.startsWith("openai.") || bareModelId.startsWith("qwen.") ||
        bareModelId.startsWith("deepseek.") || bareModelId.startsWith("mistral.") ||
        bareModelId.startsWith("zai.") {
        return INVOKE_OPENAI_CHAT_CODEC;
    }
    return error(string `no InvokeModel codec for '${bareModelId}'; pass 'modelSchema' or use Converse`);
}
