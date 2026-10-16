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

// The converters, chosen once at construction.

// Converse — model-agnostic, so one converter serves every Converse model.
final readonly & ModelConverter CONVERSE_CONVERTER = {
    encode: encodeConverse,
    decode: decodeConverse,
    toolChoice: CONVERSE_TOOL_CHOICE,
    supportsStreaming: true,
    dialect: "Converse",
    supports: {stopSequences: true, thinking: true, effort: true, reasoningEffort: true}
};

// Invoke-Anthropic — `anthropic_version: bedrock-2023-05-31` body field.
final readonly & ModelConverter INVOKE_ANTHROPIC_CONVERTER = {
    encode: encodeInvokeAnthropic,
    decode: decodeAnthropicMessages,
    toolChoice: ANTHROPIC_TOOL_CHOICE,
    supportsStreaming: true,
    dialect: "Anthropic Messages (InvokeModel)",
    supports: {stopSequences: true, thinking: true, effort: true, reasoningEffort: false}
};

// Anthropic Messages: the version goes in an `anthropic-version` header, not the body.
// https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html
final readonly & ModelConverter NATIVE_MESSAGES_CONVERTER = {
    encode: encodeNativeMessages,
    decode: decodeAnthropicMessages,
    toolChoice: ANTHROPIC_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "Anthropic Messages",
    supports: {stopSequences: true, thinking: true, effort: true, reasoningEffort: false}
};

// OpenAI Responses.
// https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html
final readonly & ModelConverter NATIVE_RESPONSES_CONVERTER = {
    encode: encodeResponses,
    decode: decodeResponses,
    // A flat `tool_choice`, unlike Chat Completions.
    toolChoice: RESPONSES_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "OpenAI Responses",
    supports: {stopSequences: false, thinking: false, effort: false, reasoningEffort: true}
};

// OpenAI Chat Completions, also used by DeepSeek, Gemma 3, Mistral, Qwen3 and others.
// https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html
final readonly & ModelConverter NATIVE_CHAT_CONVERTER = {
    encode: encodeOpenAIChat,
    decode: decodeOpenAIChat,
    toolChoice: OPENAI_CHAT_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "OpenAI Chat Completions",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: true}
};

// Chat Completions for an OpenAI model, which takes `max_completion_tokens`.
final readonly & ModelConverter NATIVE_OPENAI_MODEL_CHAT_CONVERTER = {
    encode: encodeOpenAIModelChat,
    decode: decodeOpenAIChat,
    toolChoice: OPENAI_CHAT_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "OpenAI Chat Completions",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: true}
};

// Nova InvokeModel: a Converse-shaped body, so tools are forced the Converse way.
final readonly & ModelConverter INVOKE_NOVA_CONVERTER = {
    encode: encodeNovaInvoke,
    decode: decodeConverse,
    toolChoice: CONVERSE_TOOL_CHOICE,
    supportsStreaming: true,
    dialect: "Nova (InvokeModel)",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: false}
};

// OpenAI-shaped InvokeModel for Qwen, Gemma and DeepSeek V3. Not Mistral, whose
// stop reason, tool choice and usage differ.
final readonly & ModelConverter INVOKE_OPENAI_CHAT_CONVERTER = {
    encode: encodeOpenAIChat,
    decode: decodeOpenAIChat,
    toolChoice: OPENAI_CHAT_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "OpenAI Chat Completions (InvokeModel)",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: true}
};

// The same for an OpenAI model (gpt-oss), with `max_completion_tokens`.
final readonly & ModelConverter INVOKE_OPENAI_MODEL_CHAT_CONVERTER = {
    encode: encodeOpenAIModelChat,
    decode: decodeOpenAIChat,
    toolChoice: OPENAI_CHAT_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "OpenAI Chat Completions (InvokeModel)",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: true}
};

// DeepSeek R1 InvokeModel: text completion (`prompt` -> `choices[].text`).
final readonly & ModelConverter INVOKE_DEEPSEEK_CONVERTER = {
    encode: encodeDeepSeekInvoke,
    decode: decodeDeepSeekInvoke,
    toolChoice: NO_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "DeepSeek text completion (InvokeModel)",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: false}
};

// Mistral chat completion on InvokeModel; forces tools with `"any"`.
final readonly & ModelConverter INVOKE_MISTRAL_CHAT_CONVERTER = {
    encode: encodeMistralChat,
    decode: decodeMistralChat,
    toolChoice: MISTRAL_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "Mistral chat completion (InvokeModel)",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: false}
};

// Mistral text completion on InvokeModel; no tools.
final readonly & ModelConverter INVOKE_MISTRAL_TEXT_CONVERTER = {
    encode: encodeMistralText,
    decode: decodeMistralText,
    toolChoice: NO_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "Mistral text completion (InvokeModel)",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: false}
};

// Chosen by API, not endpoint.
isolated function selectConverter(Route route) returns readonly & ModelConverter|error {
    match route.api {
        CONVERSE => {
            return CONVERSE_CONVERTER; // model-agnostic — serves every vendor
        }
        MESSAGES => {
            return NATIVE_MESSAGES_CONVERTER;
        }
        RESPONSES => {
            return NATIVE_RESPONSES_CONVERTER;
        }
        CHAT_COMPLETIONS => {
            return isOpenAIModel(route.bareModelId) ? NATIVE_OPENAI_MODEL_CHAT_CONVERTER : NATIVE_CHAT_CONVERTER;
        }
    }
    // InvokeModel takes the model's own body, so the vendor prefix decides.
    return selectInvokeConverter(route.bareModelId);
}

// The Messages path takes a Bedrock API key as `x-api-key`, as in AWS's examples;
// the OpenAI-compatible paths use `Authorization: Bearer`.
// https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html
isolated function usesApiKeyHeader(ApiFamily api) returns boolean => api == MESSAGES;

// OpenAI's own models take `max_completion_tokens`.
isolated function isOpenAIModel(string bareModelId) returns boolean => bareModelId.startsWith("openai.");

isolated function selectInvokeConverter(string bareModelId) returns readonly & ModelConverter|error {
    if bareModelId.startsWith("anthropic.") {
        return INVOKE_ANTHROPIC_CONVERTER;
    }
    // Nova only: Titan text models are under `amazon.` too but take another body, so
    // they fall through to the error that points at Converse.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-titan-text.html
    if bareModelId.startsWith("amazon.nova") {
        return INVOKE_NOVA_CONVERTER;
    }
    if bareModelId.startsWith("mistral.") {
        return usesMistralTextDialect(bareModelId) ? INVOKE_MISTRAL_TEXT_CONVERTER : INVOKE_MISTRAL_CHAT_CONVERTER;
    }
    if bareModelId.startsWith("deepseek.") {
        return usesDeepSeekTextDialect(bareModelId) ? INVOKE_DEEPSEEK_CONVERTER : INVOKE_OPENAI_CHAT_CONVERTER;
    }
    // Gemma 3's card shows an OpenAI-shaped InvokeModel body.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-27b-pt.html
    if isOpenAIModel(bareModelId) {
        return INVOKE_OPENAI_MODEL_CHAT_CONVERTER;
    }
    if bareModelId.startsWith("qwen.") ||
        bareModelId.startsWith("zai.") || bareModelId.startsWith("google.") {
        return INVOKE_OPENAI_CHAT_CONVERTER;
    }
    return error(string `no InvokeModel converter for '${bareModelId}'; use 'apiType = CONVERSE'`);
}

// Mistral ids that use the text-completion format on InvokeModel; all others use chat.
// Listed by exact id because Large 2402 is text and Large 2407 is chat.
// text: https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-text-completion.html
// chat: https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-large-2407.html
isolated function usesMistralTextDialect(string bareModelId) returns boolean =>
    bareModelId.startsWith("mistral.mistral-7b-instruct") ||
    bareModelId.startsWith("mistral.mixtral-") ||
    bareModelId.startsWith("mistral.mistral-large-2402");

// R1 uses the text-completion format on InvokeModel; V3.x use chat.
// text: https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-deepseek.html
// R1:   https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-r1.html
isolated function usesDeepSeekTextDialect(string bareModelId) returns boolean =>
    bareModelId.startsWith("deepseek.r1");

// How `generate()` gets a typed result on a route, decided at construction.
isolated function structuredOutputStyleFor(ToolChoiceStyle toolChoice) returns StructuredOutputStyle {
    // No tool calling at all (Mistral text completion).
    if toolChoice == NO_TOOL_CHOICE {
        return NO_STRUCTURED_OUTPUT;
    }
    // Native `outputConfig` is not selected yet; see `StructuredOutputStyle`.
    return TOOL_FORCING;
}
