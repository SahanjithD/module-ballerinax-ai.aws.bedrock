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

// OpenAI Responses wire format on Mantle (design §7.3, §9.1). GPT-5.5/5.4 are
// Mantle-only and use `/openai/v1/responses`. System text is the `instructions`
// field; turns are `input` items; the model reply is in `output` items.

// Encodes an OpenAI Responses request body (design §7.3).
isolated function encodeResponses(ai:ChatSystemMessage? system, ai:ChatMessage[] messages,
        ai:ChatCompletionFunctions[] tools, string? stop, InferenceParams params) returns json|ai:Error {
    json[] input = [];
    foreach ai:ChatMessage m in messages {
        input.push(responsesInputItem(m));
    }
    // The Responses dialect has NO stop-sequence parameter — it is absent from the
    // request schema entirely (unlike Chat Completions' `stop`), so there is nothing
    // to map onto. Accepting one silently would let the model run past the caller's
    // stop text: wrong output, and billed tokens they asked us not to spend.
    // https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_create_params.py
    string[]? configuredStops = params.stopSequences;
    if stop is string || (configuredStops is string[] && configuredStops.length() > 0) {
        return error ai:LlmInvalidGenerationError(
            "Stop sequences are not supported on the bedrock-mantle Responses route: the OpenAI " +
            "Responses API has no stop-sequence parameter. Remove 'stop'/'stopSequences', or use a " +
            "Converse/Invoke model.");
    }

    map<json> body = {"input": input, "max_output_tokens": params.maxTokens, "temperature": params.temperature};
    if system is ai:ChatSystemMessage {
        body["instructions"] = contentToString(system.content); // system → instructions (§7.1)
    }
    if tools.length() > 0 {
        json[] toolDefs = [];
        foreach ai:ChatCompletionFunctions t in tools {
            toolDefs.push({"type": "function", "name": t.name, "description": t.description, "parameters": toolParameters(t)});
        }
        body["tools"] = toolDefs;
    }
    json extra = params?.additionalModelRequestFields;
    if extra is map<json> {
        foreach [string, json] [k, v] in extra.entries() {
            body[k] = v;
        }
    }
    return body;
}

// Maps one `ai:ChatMessage` to a Responses `input` item.
isolated function responsesInputItem(ai:ChatMessage m) returns json {
    if m is ai:ChatUserMessage {
        return {"role": "user", "content": [{"type": "input_text", "text": contentToString(m.content)}]};
    }
    if m is ai:ChatAssistantMessage {
        return {"role": "assistant", "content": [{"type": "output_text", "text": m.content ?: ""}]};
    }
    if m is ai:ChatFunctionMessage {
        return {"type": "function_call_output", "call_id": m.id ?: m.name, "output": m.content ?: ""};
    }
    return {"role": "user", "content": [{"type": "input_text", "text": contentToString(m.content)}]};
}

// Decodes an OpenAI Responses response (design §7). Always populates `usage` and
// `stopReason`.
isolated function decodeResponses(json response) returns DecodedResponse|ai:Error {
    map<json>|error rr = response.ensureType();
    if rr is error {
        return error ai:LlmInvalidResponseError("Responses payload was not a JSON object", rr);
    }
    map<json> r = rr;

    string text = "";
    ai:FunctionCall[] toolCalls = [];
    json[]? output = arrField(r, "output");
    if output is json[] {
        foreach json item in output {
            if item is map<json> {
                string? itemType = strField(item, "type");
                if itemType == "function_call" {
                    map<json> args = {};
                    string? argStr = strField(item, "arguments");
                    if argStr is string {
                        json|error parsed = argStr.fromJsonString();
                        if parsed is map<json> {
                            args = parsed;
                        }
                    }
                    toolCalls.push({name: strField(item, "name") ?: "", arguments: args, id: strField(item, "call_id")});
                } else {
                    // message item → collect output_text blocks.
                    json[]? content = arrField(item, "content");
                    if content is json[] {
                        foreach json block in content {
                            if block is map<json> {
                                text += strField(block, "text") ?: "";
                            }
                        }
                    }
                }
            }
        }
    }

    int inputTokens = 0;
    int outputTokens = 0;
    map<json>? usage = mapField(r, "usage");
    if usage is map<json> {
        inputTokens = intField(usage, "input_tokens") ?: 0;
        outputTokens = intField(usage, "output_tokens") ?: 0;
    }
    ai:ChatAssistantMessage message = {role: ai:ASSISTANT, content: text == "" ? () : text};
    if toolCalls.length() > 0 {
        message.toolCalls = toolCalls;
    }
    return {
        message,
        usage: {inputTokens, outputTokens},
        stopReason: strField(r, "status") ?: "completed",
        responseId: strField(r, "id"),
        guardrailAction: (),
        additionalModelResponseFields: ()
    };
}
