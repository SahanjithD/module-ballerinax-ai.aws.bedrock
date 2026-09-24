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

// Converter registry + selection. `selectConverter` runs once at
// construction (L1/L2). Ten converters ship. The three vendor-native ones are shared
// by both endpoints: bedrock-runtime and bedrock-mantle serve the same Messages,
// Responses and Chat Completions dialects and differ only in host, path and signing.

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

// Anthropic Messages, native path — `anthropic-version: 2023-06-01` HEADER and no
// body version field, the mirror image of INVOKE_ANTHROPIC_CONVERTER above. Serves
// `/anthropic/v1/messages` on BOTH endpoints; AWS documents the same header rule for
// each.
// https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html
final readonly & ModelConverter NATIVE_MESSAGES_CONVERTER = {
    encode: encodeMantleMessages,
    decode: decodeAnthropicMessages,
    toolChoice: ANTHROPIC_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "Anthropic Messages",
    supports: {stopSequences: true, thinking: true, effort: true, reasoningEffort: false}
};

// OpenAI Responses. `/openai/v1/responses` on bedrock-runtime; `/v1/responses` or
// `/openai/v1/responses` on bedrock-mantle, per model.
// https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html
final readonly & ModelConverter NATIVE_RESPONSES_CONVERTER = {
    encode: encodeResponses,
    decode: decodeResponses,
    // Responses forces tools with a FLAT `tool_choice`, unlike the Chat Completions
    // converters below — same vendor, different dialect.
    toolChoice: RESPONSES_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "OpenAI Responses",
    supports: {stopSequences: false, thinking: false, effort: false, reasoningEffort: true}
};

// OpenAI Chat Completions. `/openai/v1/chat/completions` on bedrock-runtime;
// `/v1/chat/completions` or `/openai/v1/chat/completions` on bedrock-mantle. Reaches
// far past OpenAI: AWS lists DeepSeek, Gemma 3, Mistral, Qwen3, MiniMax, Moonshot,
// NVIDIA, Writer, xAI and Z.AI on this shape.
// https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html
final readonly & ModelConverter NATIVE_CHAT_CONVERTER = {
    encode: encodeOpenAIChat,
    decode: decodeOpenAIChat,
    toolChoice: OPENAI_CHAT_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "OpenAI Chat Completions",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: true}
};

// Nova InvokeModel — `schemaVersion: messages-v1`; Converse-shaped response.
// Nova's Invoke body is Converse-shaped, so it forces tools the CONVERSE way even
// though the route family is INVOKE — see `ToolChoiceStyle`.
final readonly & ModelConverter INVOKE_NOVA_CONVERTER = {
    encode: encodeNovaInvoke,
    decode: decodeConverse,
    toolChoice: CONVERSE_TOOL_CHOICE,
    supportsStreaming: true,
    dialect: "Nova (InvokeModel)",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: false}
};

// OpenAI-shaped InvokeModel — GPT-OSS, Qwen, DeepSeek. NOT Mistral: that
// dialect differs on stop_reason, tool_choice, and usage — see `converter_mistral.bal`.
final readonly & ModelConverter INVOKE_OPENAI_CHAT_CONVERTER = {
    encode: encodeOpenAIChat,
    decode: decodeOpenAIChat,
    toolChoice: OPENAI_CHAT_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "OpenAI Chat Completions (InvokeModel)",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: true}
};

// Invoke-DeepSeek — text completion: `prompt` → `choices[].text`. NOT the OpenAI
// chat shape, despite the shared `choices` wrapper.
final readonly & ModelConverter INVOKE_DEEPSEEK_CONVERTER = {
    encode: encodeDeepSeekInvoke,
    decode: decodeDeepSeekInvoke,
    toolChoice: NO_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "DeepSeek text completion (InvokeModel)",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: false}
};

// Invoke-Mistral chat completion — `messages`/`choices`, `tool_choice: "any"`.
final readonly & ModelConverter INVOKE_MISTRAL_CHAT_CONVERTER = {
    encode: encodeMistralChat,
    decode: decodeMistralChat,
    toolChoice: MISTRAL_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "Mistral chat completion (InvokeModel)",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: false}
};

// Invoke-Mistral text completion — `prompt`/`outputs`; no tools at all.
final readonly & ModelConverter INVOKE_MISTRAL_TEXT_CONVERTER = {
    encode: encodeMistralText,
    decode: decodeMistralText,
    toolChoice: NO_TOOL_CHOICE,
    supportsStreaming: false,
    dialect: "Mistral text completion (InvokeModel)",
    supports: {stopSequences: true, thinking: false, effort: false, reasoningEffort: false}
};

// Selects the converter for a resolved route. Runs at construction.
//
// Dispatches on the resolved SHAPE, not the endpoint: the same three vendor-native
// dialects are served on both hosts, so `bedrock-runtime` and `bedrock-mantle` share
// these converters and differ only in host, path and signing name.
isolated function selectConverter(Route route) returns readonly & ModelConverter|error {
    match route.shape {
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
            return NATIVE_CHAT_CONVERTER;
        }
    }
    // INVOKE — the one shape whose body is the model's own, so it is keyed by the
    // bare id's vendor prefix.
    return selectInvokeConverter(route.bareModelId);
}

// The Mantle request path for a resolved shape: the model's base path plus the
// shape's own suffix.
//
// The SUFFIX is derivable and identical on both endpoints — only the base path is
// per-model data. That asymmetry is the whole reason `MantleEntry` exists and is
// this small.
isolated function mantlePathFor(string basePath, ApiShape shape) returns string|error {
    match shape {
        MESSAGES => {
            return basePath + "/messages";
        }
        RESPONSES => {
            return basePath + "/responses";
        }
        CHAT_COMPLETIONS => {
            return basePath + "/chat/completions";
        }
    }
    // CONVERSE and INVOKE are bedrock-runtime dialects; bedrock-mantle serves neither.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
    return error(string `the bedrock-mantle endpoint does not serve the ${shape} API`);
}

// Whether a route authenticates with `x-api-key` rather than `Authorization: Bearer`.
//
// Follows the SHAPE, and holds on both endpoints: AWS's documented curl for the
// Anthropic Messages path sends `-H "x-api-key: $AWS_BEARER_TOKEN_BEDROCK"` on
// bedrock-runtime and on bedrock-mantle alike, while the OpenAI-compatible Responses
// and Chat Completions paths both use Bearer.
//
// UNRESOLVED: `api-keys.html` documents only `Authorization: Bearer` generically and
// never mentions `x-api-key`, so whether Bearer is ALSO accepted on the Messages path
// is unverified. We send what AWS's own Messages examples send.
// https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html
isolated function usesApiKeyHeader(ApiShape shape) returns boolean => shape == MESSAGES;

// Picks the InvokeModel converter from the bare id's vendor prefix.
isolated function selectInvokeConverter(string bareModelId) returns readonly & ModelConverter|error {
    if bareModelId.startsWith("anthropic.") {
        return INVOKE_ANTHROPIC_CONVERTER;
    }
    // `amazon.` is Amazon's whole first-party namespace, not a Nova-only one: the
    // Titan text models live there too and take a completely different Invoke body
    // (`inputText` + `textGenerationConfig`, not `schemaVersion: messages-v1`). Match
    // Nova exactly and let `amazon.titan-*` fall through to the trailing error, which
    // already names Converse as the remedy.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-titan-text.html
    if bareModelId.startsWith("amazon.nova") {
        return INVOKE_NOVA_CONVERTER;
    }
    if bareModelId.startsWith("mistral.") {
        return usesMistralTextDialect(bareModelId) ? INVOKE_MISTRAL_TEXT_CONVERTER : INVOKE_MISTRAL_CHAT_CONVERTER;
    }
    if bareModelId.startsWith("deepseek.") {
        // R1 is text completion; V3.x is OpenAI-shaped chat — see converter_deepseek.bal.
        return usesDeepSeekTextDialect(bareModelId) ? INVOKE_DEEPSEEK_CONVERTER : INVOKE_OPENAI_CHAT_CONVERTER;
    }
    // `google.` is here on the card's own evidence, not by analogy: Gemma 3's
    // Programmatic Access section marks Invoke supported on bedrock-runtime and its
    // Invoke sample posts an OpenAI-shaped body — `{"messages": [...], "max_tokens": N}` —
    // which is exactly this converter's dialect.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-27b-pt.html
    if bareModelId.startsWith("openai.") || bareModelId.startsWith("qwen.") ||
        bareModelId.startsWith("zai.") || bareModelId.startsWith("google.") {
        return INVOKE_OPENAI_CHAT_CONVERTER;
    }
    return error(string `no InvokeModel converter for '${bareModelId}'; use 'api = CONVERSE'`);
}

// Mistral ids that speak the `prompt`/`outputs` TEXT-completion dialect on
// InvokeModel. Everything else under `mistral.` speaks chat completion.
//
// This is an allowlist of the legacy dialect rather than the reverse because the
// two are told apart only by exact id — `mistral-large-2402` is text-completion
// while `mistral-large-2407` is chat-completion, same family, four months apart.
// New ids therefore default to chat, and a wrong guess surfaces as a Bedrock
// `ValidationException` the caller can act on; `api = CONVERSE` is the escape
// hatch, since Converse is model-agnostic and sidesteps the dialect split entirely.
//
// text:  https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-text-completion.html
//        (supported models: Mistral 7B Instruct, Mixtral 8X7B; AWS's own InvokeModel
//        examples use this dialect for `mistral.mistral-large-2402-v1:0`)
// chat:  https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-large-2407.html
isolated function usesMistralTextDialect(string bareModelId) returns boolean =>
    bareModelId.startsWith("mistral.mistral-7b-instruct") ||
    bareModelId.startsWith("mistral.mixtral-") ||
    bareModelId.startsWith("mistral.mistral-large-2402");

// DeepSeek ids that speak the `prompt`/`choices[].text` TEXT-completion dialect on
// InvokeModel. Everything else under `deepseek.` speaks OpenAI-shaped chat
// completion (`messages`/`choices[].message`), same as the Mistral split above.
//
// R1 only. V3.1 (`deepseek.v3-v1:0`) and V3.2 (`deepseek.v3.2`) both take
// `{"messages": [...], "max_tokens": n}` on InvokeModel per their model cards, and a
// live V3.2 Invoke call against us-east-1 confirms it: sending `prompt` comes back
// `ValidationException ... missing field messages`.
//
// CONFLICTING FIRST-PARTY SOURCES on R1 — surfaced, not silently resolved:
// the DeepSeek parameters page documents the full text-completion request/response
// for R1 (and calls V3.1 text-completion too, which the V3.1 card contradicts),
// while R1's own model card now shows an Invoke sample using `messages`. We keep R1
// on the dialect that has a documented RESPONSE shape (`choices[].text` +
// `stop_reason`) — decoding is only defined for that pairing — and default every
// other DeepSeek id to chat.
//
// text:  https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-deepseek.html
// V3.2:  https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-v3-2.html
// V3.1:  https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-v3-1.html
// R1:    https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-r1.html
isolated function usesDeepSeekTextDialect(string bareModelId) returns boolean =>
    bareModelId.startsWith("deepseek.r1");

// How `generate()` should obtain a typed result on a resolved route. Decided once at
// construction from the endpoint, the shape and the dialect's tool-choice style.
//
// The answer is NOT a property of the endpoint alone, which is what the old
// `family != MANTLE` flag assumed. AWS's evidence cuts both ways:
//
//  - Anthropic Messages on bedrock-mantle: the NATIVE mechanism is documented as
//    unavailable — `output_config.format` is rejected with a 400.
//    https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-structured-outputs.html
//
//    Whether TOOL FORCING also fails there is UNVERIFIED, and the honest answer is
//    that it probably works: the Messages API forces a tool with `tool_choice`, which
//    this module emits and which AWS lists as a supported Mantle feature ("client-side
//    tool calling"). A previously cited counter-example — `strict: true` being
//    rejected on opus-4-7 — does NOT apply, because this module never sends `strict`
//    on any dialect. POLICY CHOICE, recorded so it can be overruled: refuse, matching
//    the documented native restriction, rather than ship a path no AWS page confirms.
//    One live call against `/anthropic/v1/messages` on bedrock-mantle settles it, and
//    relaxing this to TOOL_FORCING is then a one-line change.
//  - The OpenAI-compatible shapes on bedrock-mantle DO have it for at least some
//    models: Grok 4.3's card marks structured outputs supported on bedrock-mantle, so
//    a blanket "Mantle has no structured output" is wrong in that direction too.
//    https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-xai-grok-4-3.html
//
// Per-model variation beyond this is left for AWS to reject: a model that refuses a
// forced tool answers with its own diagnosis, which is more use than a stale table.
isolated function structuredOutputStyleFor(BedrockEndpoint endpoint, ApiShape shape,
        ToolChoiceStyle toolChoice) returns StructuredOutputStyle {
    // A dialect with no tool-calling at all (Mistral text completion) can do neither.
    if toolChoice == NO_TOOL_CHOICE {
        return NO_STRUCTURED_OUTPUT;
    }
    if endpoint == MANTLE && shape == MESSAGES {
        return NO_STRUCTURED_OUTPUT;
    }
    // Converse is where the native member lives; see StructuredOutputStyle for why it
    // is not yet selected. Flip this one return to NATIVE_OUTPUT_CONFIG once a live
    // call confirms `outputConfig.textFormat` is honoured.
    return TOOL_FORCING;
}
