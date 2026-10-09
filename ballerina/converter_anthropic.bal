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

// Anthropic Messages, for two routes: InvokeModel (`anthropic_version` body field) and
// the Messages API (`anthropic-version` header). The response is the same.

isolated function encodeInvokeAnthropic(string? system, ResolvedMessage[] messages,
        ai:ChatCompletionFunctions[] tools, string? stop, InferenceParams params) returns json|ai:Error
    => encodeAnthropicMessages(system, messages, tools, stop, params, true);

// No body version field: the `anthropic-version` header carries it.
isolated function encodeMantleMessages(string? system, ResolvedMessage[] messages,
        ai:ChatCompletionFunctions[] tools, string? stop, InferenceParams params) returns json|ai:Error
    => encodeAnthropicMessages(system, messages, tools, stop, params, false);

isolated function encodeAnthropicMessages(string? system, ResolvedMessage[] messages,
        ai:ChatCompletionFunctions[] tools, string? stop, InferenceParams params,
        boolean bedrockInvoke) returns json|ai:Error {
    json[] wire = [];
    foreach ResolvedMessage m in messages {
        wire.push(anthropicMessage(m));
    }
    map<json> body = {"messages": wire};
    setMaxTokens(body, params, "max_tokens");
    setTemperature(body, params);
    if bedrockInvoke {
        // REQUIRED for Invoke-Anthropic; LiteLLM injects the same default.
        body["anthropic_version"] = "bedrock-2023-05-31";
    }
    // Per-call `stop` overrides configured stopSequences outright.
    string[]? stops = params.stopSequences;
    if stop is string {
        stops = [stop];
    }
    if stops is string[] && stops.length() > 0 {
        body["stop_sequences"] = stops;
    }
    if system is string {
        body["system"] = system; // top-level, never a message
    }
    if tools.length() > 0 {
        json[] toolDefs = [];
        foreach ai:ChatCompletionFunctions t in tools {
            toolDefs.push({name: t.name, description: t.description, input_schema: toolParameters(t)});
        }
        body["tools"] = toolDefs;
    }
    // `output_config` sits beside `thinking`, never inside it.
    ThinkingConfig? thinking = params?.thinking;
    if thinking is ThinkingConfig {
        body["thinking"] = thinkingBody(thinking);
    }
    Effort? effort = params?.effort;
    if effort is Effort {
        body["output_config"] = {"effort": effort};
    }
    // The caller's passthrough, merged at the top level (e.g. `top_k`, `anthropic_beta`,
    // `cache_control`). Keys the caller names override the module's.
    map<json>? extra = additionalFieldsToJson(params?.additionalModelRequestFields);
    if extra is map<json> {
        foreach [string, json] [k, v] in extra.entries() {
            body[k] = v;
        }
    }
    return body;
}

isolated function thinkingBody(ThinkingConfig thinking) returns json {
    map<json> out = {"type": thinking.mode};
    int? budget = thinking?.budgetTokens;
    if budget is int {
        out["budget_tokens"] = budget;
    }
    return out;
}

// Images are base64: Bedrock does not take a URL.
// https://platform.claude.com/docs/en/build-with-claude/vision
isolated function anthropicMessage(ResolvedMessage m) returns json {
    if m is ResolvedUserMessage {
        return {role: "user", content: anthropicContentBlocks(m.parts)};
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
    // ai:FUNCTION result → Anthropic user-role tool_result block.
    return {
        role: "user",
        content: [{"type": "tool_result", "tool_use_id": m.id ?: m.name, "content": m.content ?: ""}]
    };
}

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
    // On InvokeModel a fired guardrail is a body field; absent on Mantle.
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
        guardrailAction
    };
}
