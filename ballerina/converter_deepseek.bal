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

import ballerina/ai;

// DeepSeek R1 on InvokeModel: text completion, despite the `choices` wrapper.
//   request:  {"prompt", "temperature", "top_p", "max_tokens", "stop"}
//   response: {"choices": [{"text", "stop_reason"}]}, with no usage
// DeepSeek V3.x takes `messages` and uses the OpenAI chat converter instead.
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-deepseek.html

// Encodes a DeepSeek text-completion request body.
isolated function encodeDeepSeekInvoke(string? system, ResolvedMessage[] messages,
        ai:ChatCompletionFunctions[] tools, string? stop, InferenceParams params) returns json|ai:Error {
    // Text-only by construction: the whole conversation is one prompt string.
    check rejectImagesIn(messages, "the DeepSeek-R1 prompt dialect");
    if tools.length() > 0 {
        // Fail loudly rather than drop them: this dialect models no tools, so a
        // silent no-op would look like the model ignoring the tool.
        return error ai:Error(
            "DeepSeek's InvokeModel dialect is text-completion and does not support tools. " +
            "Use the Converse route (the module default), which does.");
    }

    map<json> body = {"prompt": deepSeekPrompt(system, messages)};
    setMaxTokens(body, params, "max_tokens");
    setTemperature(body, params);
    string[]? stops = params.stopSequences;
    if stop is string {
        stops = [stop]; // per-call stop overrides configured stopSequences
    }
    if stops is string[] && stops.length() > 0 {
        body["stop"] = stops;
    }
    map<json>? extra = additionalFieldsToJson(params?.additionalModelRequestFields);
    if extra is map<json> {
        foreach [string, json] [k, v] in extra.entries() {
            body[k] = v;
        }
    }
    return body;
}

// R1's instruction template, with DeepSeek's full-width delimiters (not ASCII pipes):
//   <｜begin▁of▁sentence｜><｜User｜>{prompt}<｜Assistant｜><think>\n
// AWS documents only one turn; the system prompt and later turns follow DeepSeek's own
// chat template.
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-deepseek.html
isolated function deepSeekPrompt(string? system, ResolvedMessage[] messages) returns string {
    string prompt = "<｜begin▁of▁sentence｜>";
    if system is string {
        prompt += system;
    }
    foreach ResolvedMessage m in messages {
        if m is ai:ChatAssistantMessage {
            prompt += string `<｜Assistant｜>${m.content ?: ""}`;
            continue;
        }
        string text = m is ai:ChatFunctionMessage ? (m.content ?: "") : partsText(m.parts);
        prompt += string `<｜User｜>${text}`;
    }
    // Hand the turn to the model, opening its reasoning channel as AWS's example does.
    prompt += "<｜Assistant｜><think>\n";
    return prompt;
}

// Decodes a DeepSeek text-completion response: `choices[].text` +
// `choices[].stop_reason`. This dialect returns no token counts and no id.
isolated function decodeDeepSeekInvoke(json response) returns DecodedResponse|ai:Error {
    map<json>|error rr = response.ensureType();
    if rr is error {
        return error ai:LlmInvalidResponseError("DeepSeek response was not a JSON object", rr);
    }
    map<json> r = rr;
    json[]? choices = arrField(r, "choices");
    if choices is () || choices.length() == 0 {
        return error ai:LlmInvalidResponseError("DeepSeek response had no choices");
    }
    map<json>|error choiceResult = choices[0].ensureType();
    if choiceResult is error {
        return error ai:LlmInvalidResponseError("DeepSeek choice was not an object", choiceResult);
    }
    map<json> choice = choiceResult;
    // `text`, not `message.content` — this is a completion, not a chat turn.
    // `stop_reason`, not `finish_reason`.
    string stopReason = strField(choice, "stop_reason") ?: "stop";
    string text = deepSeekAnswer(strField(choice, "text") ?: "", stopReason);
    return {
        message: {role: ai:ASSISTANT, content: text == "" ? () : text},
        // AWS documents no usage for this dialect; `usage` stays populated.
        usage: {inputTokens: 0, outputTokens: 0},
        stopReason,
        responseId: (),
        guardrailAction: invokeGuardrailAction(r) // body field
    };
}

const DEEPSEEK_THINK_END = "</think>";

// The answer after `</think>`; the prompt opens `<think>`, so the reasoning comes
// first. Cut off before `</think>`, there is no answer yet (verified live 2026-10-09).
isolated function deepSeekAnswer(string completion, string stopReason) returns string {
    int? end = completion.lastIndexOf(DEEPSEEK_THINK_END);
    if end is int {
        return completion.substring(end + DEEPSEEK_THINK_END.length()).trim();
    }
    return finishReason(stopReason) == FINISH_LENGTH ? "" : completion;
}
