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

// Anthropic Messages wire format — shared by two routes (design §7.2, §7.3):
//   * Invoke-Anthropic: `anthropic_version: bedrock-2023-05-31` BODY field.
//   * Mantle Messages:  `anthropic-version: 2023-06-01` HEADER (added by the
//     transport), NO body version field. Different value AND mechanism (§7.3).
// The response shape is identical, so `decode` is shared.

// Invoke-Anthropic encoder — includes the mandatory `anthropic_version` body
// field (design §7.2).
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-anthropic-claude-messages.html
isolated function encodeInvokeAnthropic(ai:ChatSystemMessage? system, ai:ChatMessage[] messages,
        ai:ChatCompletionFunctions[] tools, string? stop, InferenceParams params) returns json|ai:Error
    => encodeAnthropicMessages(system, messages, tools, stop, params, true);

// Mantle Messages encoder — NO body version field (the header carries it — §7.3).
isolated function encodeMantleMessages(ai:ChatSystemMessage? system, ai:ChatMessage[] messages,
        ai:ChatCompletionFunctions[] tools, string? stop, InferenceParams params) returns json|ai:Error
    => encodeAnthropicMessages(system, messages, tools, stop, params, false);

// Builds an Anthropic Messages request body. `bedrockInvoke` toggles the required
// `anthropic_version` body field (design §7.2 vs §7.3).
isolated function encodeAnthropicMessages(ai:ChatSystemMessage? system, ai:ChatMessage[] messages,
        ai:ChatCompletionFunctions[] tools, string? stop, InferenceParams params,
        boolean bedrockInvoke) returns json|ai:Error {
    json[] wire = [];
    foreach ai:ChatMessage m in messages {
        wire.push(anthropicMessage(m));
    }
    map<json> body = {
        "max_tokens": params.maxTokens,
        "temperature": params.temperature,
        "messages": wire
    };
    if bedrockInvoke {
        // REQUIRED for Invoke-Anthropic; LiteLLM injects the same default (§7.2).
        body["anthropic_version"] = "bedrock-2023-05-31";
    }
    // Per-call `stop` overrides configured stopSequences outright (design §7).
    string[]? stops = params.stopSequences;
    if stop is string {
        stops = [stop];
    }
    if stops is string[] && stops.length() > 0 {
        body["stop_sequences"] = stops;
    }
    if system is ai:ChatSystemMessage {
        body["system"] = contentToString(system.content); // top-level, never a message (§7.1)
    }
    if tools.length() > 0 {
        json[] toolDefs = [];
        foreach ai:ChatCompletionFunctions t in tools {
            toolDefs.push({name: t.name, description: t.description, input_schema: toolParameters(t)});
        }
        body["tools"] = toolDefs;
    }
    return body;
}

// Maps one `ai:ChatMessage` to an Anthropic Messages content block (design §7.1).
isolated function anthropicMessage(ai:ChatMessage m) returns json {
    if m is ai:ChatUserMessage {
        return {role: "user", content: [{"type": "text", "text": contentToString(m.content)}]};
    }
    if m is ai:ChatAssistantMessage {
        json[] blocks = [];
        string? c = m.content;
        if c is string && c != "" {
            blocks.push({"type": "text", "text": c});
        }
        ai:FunctionCall[]? toolCalls = m.toolCalls;
        if toolCalls is ai:FunctionCall[] {
            foreach ai:FunctionCall fc in toolCalls {
                blocks.push({"type": "tool_use", "id": fc.id ?: fc.name, "name": fc.name, "input": fc.arguments ?: {}});
            }
        }
        return {role: "assistant", content: blocks};
    }
    if m is ai:ChatFunctionMessage {
        // ai:FUNCTION result → Anthropic user-role tool_result block (§7.1).
        return {
            role: "user",
            content: [{"type": "tool_result", "tool_use_id": m.id ?: m.name, "content": m.content ?: ""}]
        };
    }
    // A ChatSystemMessage would have been hoisted (§7.1); handle defensively.
    return {role: "user", content: [{"type": "text", "text": contentToString(m.content)}]};
}

// Decodes an Anthropic Messages response (Invoke-Anthropic and Mantle Messages
// share this shape — design §7). Always populates `usage` and `stopReason` (§7).
isolated function decodeAnthropicMessages(json response) returns DecodedResponse|ai:Error {
    map<json>|error rr = response.ensureType();
    if rr is error {
        return error ai:LlmInvalidResponseError("Anthropic Messages response was not a JSON object", rr);
    }
    map<json> r = rr;
    string text = "";
    ai:FunctionCall[] toolCalls = [];
    json[]? content = arrField(r, "content");
    if content is json[] {
        foreach json blk in content {
            if blk is map<json> {
                string? blkType = strField(blk, "type");
                if blkType == "text" {
                    text += strField(blk, "text") ?: "";
                } else if blkType == "tool_use" {
                    toolCalls.push({
                        name: strField(blk, "name") ?: "",
                        arguments: mapField(blk, "input") ?: {},
                        id: strField(blk, "id")
                    });
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
    // On the InvokeModel route a fired guardrail is a response-BODY field, not a
    // header (design §9.5; InvokeModel API reference Example 4):
    // "amazon-bedrock-guardrailAction": "INTERVENED | NONE". Absent on Mantle.
    GuardrailAction? guardrailAction = ();
    string? action = strField(r, "amazon-bedrock-guardrailAction");
    if action is string {
        guardrailAction = action.toUpperAscii() == "INTERVENED" ? INTERVENED : NONE;
    }
    ai:ChatAssistantMessage message = {role: ai:ASSISTANT, content: text == "" ? () : text};
    if toolCalls.length() > 0 {
        message.toolCalls = toolCalls;
    }
    return {
        message,
        usage: {inputTokens, outputTokens},
        stopReason: strField(r, "stop_reason") ?: "end_turn",
        responseId: strField(r, "id"),
        guardrailAction,
        additionalModelResponseFields: ()
    };
}
