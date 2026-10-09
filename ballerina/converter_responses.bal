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

// OpenAI Responses. The system prompt is `instructions`, turns are
// `input` items, and the reply is in `output` items.

isolated function encodeResponses(string? system, ResolvedMessage[] messages,
        ai:ChatCompletionFunctions[] tools, string? stop, InferenceParams params) returns json|ai:Error {
    // UNVERIFIED: image support on the /openai/v1/responses path is not stated
    // by any first-party source. Refuse rather than guess — see README.
    check rejectImagesIn(messages, "the OpenAI Responses dialect", true);
    json[] input = [];
    foreach ResolvedMessage m in messages {
        input.push(...responsesInputItems(m));
    }
    // Responses has no stop-sequence parameter, so a per-call `stop` is refused rather
    // than ignored. A configured one is refused at construction.
    // https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_create_params.py
    string[]? configuredStops = params.stopSequences;
    if stop is string || (configuredStops is string[] && configuredStops.length() > 0) {
        return error ai:LlmInvalidGenerationError(
            "Stop sequences are not supported on the OpenAI Responses API, which has no stop-sequence " +
            "parameter. Remove 'stop'/'stopSequences', or use the CONVERSE or INVOKE API.");
    }

    map<json> body = {"input": input};
    setMaxTokens(body, params, "max_output_tokens");
    setTemperature(body, params);
    if system is string {
        body["instructions"] = system; // system → instructions
    }
    if tools.length() > 0 {
        json[] toolDefs = [];
        foreach ai:ChatCompletionFunctions t in tools {
            toolDefs.push({"type": "function", "name": t.name, "description": t.description, "parameters": toolParameters(t)});
        }
        body["tools"] = toolDefs;
    }
    // Nested `reasoning: {effort}`; a top-level `reasoning_effort` is a 400 here.
    // https://github.com/openai/openai-python/blob/main/src/openai/types/shared_params/reasoning.py
    ReasoningEffort? reasoningEffort = params?.reasoningEffort;
    if reasoningEffort is ReasoningEffort {
        body["reasoning"] = {"effort": reasoningEffort};
    }
    // `store` defaults to true, and AWS then keeps the data for 30 days. The full history
    // is resent every turn, so nothing needs storing. Set before the passthrough, so a
    // caller can still send `"store": true`.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html
    body["store"] = false;
    map<json>? extra = additionalFieldsToJson(params?.additionalModelRequestFields);
    if extra is map<json> {
        foreach [string, json] [k, v] in extra.entries() {
            body[k] = v;
        }
    }
    return body;
}

// Each tool call becomes a `function_call` item; its tool result is matched on `call_id`.
isolated function responsesInputItems(ResolvedMessage m) returns json[] {
    if m is ResolvedUserMessage {
        return [{"role": "user", "content": responsesContentParts(m.parts)}];
    }
    if m is ai:ChatAssistantMessage {
        json[] items = [];
        string? content = m.content;
        if content is string && content != "" {
            items.push({"role": "assistant", "content": [{"type": "output_text", "text": content}]});
        }
        ai:FunctionCall[]? toolCalls = m.toolCalls;
        if toolCalls is ai:FunctionCall[] {
            foreach ai:FunctionCall fc in toolCalls {
                items.push({
                    "type": "function_call",
                    "call_id": fc.id ?: fc.name,
                    "name": fc.name,
                    "arguments": (fc.arguments ?: {}).toJsonString()
                });
            }
        }
        // A bare assistant turn (no text, no calls) still needs an item so it is not
        // silently dropped from the transcript.
        if items.length() == 0 {
            items.push({"role": "assistant", "content": [{"type": "output_text", "text": ""}]});
        }
        return items;
    }
    return [{"type": "function_call_output", "call_id": m.id ?: m.name, "output": m.content ?: ""}];
}

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
                } else if itemType == "message" {
                    // Only `output_text` from `message` items: `reasoning` items and
                    // `refusal` blocks also have `text`, which would leak into the reply.
                    // https://platform.openai.com/docs/api-reference/responses/object
                    json[]? content = arrField(item, "content");
                    if content is json[] {
                        foreach json block in content {
                            if block is map<json> && strField(block, "type") == "output_text" {
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
        stopReason: responsesStopReason(r),
        responseId: strField(r, "id"),
        guardrailAction: ()
    };
}

// `status` is `completed`, `incomplete` or `failed`; an incomplete response names its
// reason (`max_output_tokens`, `content_filter`) in `incomplete_details.reason`.
// https://platform.openai.com/docs/api-reference/responses/object
isolated function responsesStopReason(map<json> r) returns string {
    string status = strField(r, "status") ?: "completed";
    map<json>? details = mapField(r, "incomplete_details");
    string? reason = details is map<json> ? strField(details, "reason") : ();
    return status == "incomplete" && reason is string ? reason : status;
}
