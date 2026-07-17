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
    toolChoice: CONVERSE_TOOL_CHOICE,
    supportsStreaming: true
};

// Invoke-Anthropic — `anthropic_version: bedrock-2023-05-31` body field (§7.2).
final readonly & ModelCodec INVOKE_ANTHROPIC_CODEC = {
    encode: encodeInvokeAnthropic,
    decode: decodeAnthropicMessages,
    toolChoice: ANTHROPIC_TOOL_CHOICE,
    supportsStreaming: true
};

// Mantle Messages — `anthropic-version: 2023-06-01` header (added by transport, §7.3).
final readonly & ModelCodec MANTLE_MESSAGES_CODEC = {
    encode: encodeMantleMessages,
    decode: decodeAnthropicMessages,
    toolChoice: ANTHROPIC_TOOL_CHOICE,
    supportsStreaming: false
};

// Mantle Responses — OpenAI Responses API (GPT-5.x on `/openai/v1/responses`, §7.3).
final readonly & ModelCodec MANTLE_RESPONSES_CODEC = {
    encode: encodeResponses,
    decode: decodeResponses,
    toolChoice: OPENAI_TOOL_CHOICE,
    supportsStreaming: false
};

// Mantle Chat Completions — OpenAI chat shape (GLM on `/v1/chat/completions`, §7.3).
final readonly & ModelCodec MANTLE_CHAT_CODEC = {
    encode: encodeOpenAIChat,
    decode: decodeOpenAIChat,
    toolChoice: OPENAI_TOOL_CHOICE,
    supportsStreaming: false
};

// Nova InvokeModel — `schemaVersion: messages-v1`; Converse-shaped response (§7.2).
// Nova's Invoke body is Converse-shaped, so it forces tools the CONVERSE way even
// though the route family is INVOKE — see `ToolChoiceStyle`.
final readonly & ModelCodec INVOKE_NOVA_CODEC = {
    encode: encodeNovaInvoke,
    decode: decodeConverse,
    toolChoice: CONVERSE_TOOL_CHOICE,
    supportsStreaming: true
};

// OpenAI-shaped InvokeModel — GPT-OSS, Qwen, DeepSeek (§7.2). NOT Mistral: that
// dialect differs on stop_reason, tool_choice, and usage — see `codec_mistral.bal`.
final readonly & ModelCodec INVOKE_OPENAI_CHAT_CODEC = {
    encode: encodeOpenAIChat,
    decode: decodeOpenAIChat,
    toolChoice: OPENAI_TOOL_CHOICE,
    supportsStreaming: false
};

// Invoke-DeepSeek — text completion: `prompt` → `choices[].text`. NOT the OpenAI
// chat shape, despite the shared `choices` wrapper (§7.2).
final readonly & ModelCodec INVOKE_DEEPSEEK_CODEC = {
    encode: encodeDeepSeekInvoke,
    decode: decodeDeepSeekInvoke,
    toolChoice: NO_TOOL_CHOICE,
    supportsStreaming: false
};

// Invoke-Mistral chat completion — `messages`/`choices`, `tool_choice: "any"` (§7.2).
final readonly & ModelCodec INVOKE_MISTRAL_CHAT_CODEC = {
    encode: encodeMistralChat,
    decode: decodeMistralChat,
    toolChoice: MISTRAL_TOOL_CHOICE,
    supportsStreaming: false
};

// Invoke-Mistral text completion — `prompt`/`outputs`; no tools at all (§7.2).
final readonly & ModelCodec INVOKE_MISTRAL_TEXT_CODEC = {
    encode: encodeMistralText,
    decode: decodeMistralText,
    toolChoice: NO_TOOL_CHOICE,
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
            OPENAI => {
                return INVOKE_OPENAI_CHAT_CODEC;
            }
            DEEPSEEK => {
                return INVOKE_DEEPSEEK_CODEC;
            }
            MISTRAL => {
                return INVOKE_MISTRAL_CHAT_CODEC;
            }
            MISTRAL_TEXT => {
                return INVOKE_MISTRAL_TEXT_CODEC;
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
    if bareModelId.startsWith("mistral.") {
        return usesMistralTextDialect(bareModelId) ? INVOKE_MISTRAL_TEXT_CODEC : INVOKE_MISTRAL_CHAT_CODEC;
    }
    if bareModelId.startsWith("deepseek.") {
        // Text completion, NOT the OpenAI chat shape — see codec_deepseek.bal.
        return INVOKE_DEEPSEEK_CODEC;
    }
    if bareModelId.startsWith("openai.") || bareModelId.startsWith("qwen.") ||
        bareModelId.startsWith("zai.") {
        return INVOKE_OPENAI_CHAT_CODEC;
    }
    return error(string `no InvokeModel codec for '${bareModelId}'; pass 'modelSchema' or use Converse`);
}

// Mistral ids that speak the `prompt`/`outputs` TEXT-completion dialect on
// InvokeModel. Everything else under `mistral.` speaks chat completion.
//
// This is an allowlist of the legacy dialect rather than the reverse because the
// two are told apart only by exact id — `mistral-large-2402` is text-completion
// while `mistral-large-2407` is chat-completion, same family, four months apart.
// New ids therefore default to chat, and a wrong guess surfaces as a Bedrock
// `ValidationException` the caller can act on; `modelSchema: MISTRAL_TEXT` is the
// escape hatch.
//
// text:  https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-text-completion.html
//        (supported models: Mistral 7B Instruct, Mixtral 8X7B; AWS's own InvokeModel
//        examples use this dialect for `mistral.mistral-large-2402-v1:0`)
// chat:  https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-large-2407.html
isolated function usesMistralTextDialect(string bareModelId) returns boolean =>
    bareModelId.startsWith("mistral.mistral-7b-instruct") ||
    bareModelId.startsWith("mistral.mixtral-") ||
    bareModelId.startsWith("mistral.mistral-large-2402");
