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

// Converse codec — the model-agnostic normalized surface (design §5, §9.3).
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html

// Encodes a Converse request body. `system` is the top-level `system` field, never
// a message (§7.1). Forwards the §9.3 passthrough verbatim.
isolated function encodeConverse(ai:ChatSystemMessage? system, ai:ChatMessage[] messages,
        ai:ChatCompletionFunctions[] tools, string? stop, InferenceParams params) returns json|ai:Error {
    json[] wire = [];
    foreach ai:ChatMessage m in messages {
        wire.push(converseMessage(m));
    }

    map<json> inferenceConfig = {"maxTokens": params.maxTokens, "temperature": params.temperature};
    decimal? topP = params.topP;
    if topP is decimal {
        inferenceConfig["topP"] = topP;
    }
    // Per-call `stop` overrides configured stopSequences outright (design §7).
    string[]? stops = params.stopSequences;
    if stop is string {
        stops = [stop];
    }
    if stops is string[] && stops.length() > 0 {
        inferenceConfig["stopSequences"] = stops;
    }

    map<json> body = {"messages": wire, "inferenceConfig": inferenceConfig};

    if system is ai:ChatSystemMessage {
        body["system"] = [{"text": contentToString(system.content)}]; // §7.1
    }
    if tools.length() > 0 {
        json[] toolSpecs = [];
        foreach ai:ChatCompletionFunctions t in tools {
            toolSpecs.push({
                "toolSpec": {"name": t.name, "description": t.description, "inputSchema": {"json": toolParameters(t)}}
            });
        }
        body["toolConfig"] = {"tools": toolSpecs};
    }

    // ---- §9.3 passthrough — forwarded verbatim; mandatory for top_k/thinking/reasoning ----
    json additionalRequest = params?.additionalModelRequestFields;
    if additionalRequest != () {
        body["additionalModelRequestFields"] = additionalRequest;
    }
    string[]? responsePaths = params.additionalModelResponseFieldPaths;
    if responsePaths is string[] && responsePaths.length() > 0 {
        body["additionalModelResponseFieldPaths"] = responsePaths;
    }
    map<string>? metadata = params.requestMetadata;
    if metadata is map<string> {
        body["requestMetadata"] = metadata;
    }
    ServiceTier? tier = params.serviceTier;
    if tier is ServiceTier {
        body["serviceTier"] = tier.toString().toLowerAscii();
    }
    // Guardrail is a Converse BODY field (design §9.5).
    GuardrailConfig? guardrail = params.guardrail;
    if guardrail is GuardrailConfig {
        map<json> gc = {
            "guardrailIdentifier": guardrail.guardrailIdentifier,
            "guardrailVersion": guardrail.guardrailVersion
        };
        string? trace = guardrail.trace;
        if trace is string {
            // Converse guardrailConfig.trace is lowercase (`enabled`|`disabled`).
            gc["trace"] = trace.toLowerAscii();
        }
        body["guardrailConfig"] = gc;
    }
    return body;
}

// Maps one `ai:ChatMessage` to a Converse content block (design §7.1).
isolated function converseMessage(ai:ChatMessage m) returns json {
    if m is ai:ChatUserMessage {
        return {"role": "user", "content": [{"text": contentToString(m.content)}]};
    }
    if m is ai:ChatAssistantMessage {
        json[] blocks = [];
        string? c = m.content;
        if c is string && c != "" {
            blocks.push({"text": c});
        }
        ai:FunctionCall[]? toolCalls = m.toolCalls;
        if toolCalls is ai:FunctionCall[] {
            foreach ai:FunctionCall fc in toolCalls {
                blocks.push({"toolUse": {"toolUseId": fc.id ?: fc.name, "name": fc.name, "input": fc.arguments ?: {}}});
            }
        }
        return {"role": "assistant", "content": blocks};
    }
    if m is ai:ChatFunctionMessage {
        // ai:FUNCTION result → Converse toolResult block (§7.1).
        return {
            "role": "user",
            "content": [{"toolResult": {"toolUseId": m.id ?: m.name, "content": [{"text": m.content ?: ""}]}}]
        };
    }
    // Defensive: a hoisted-away system message.
    return {"role": "user", "content": [{"text": contentToString(m.content)}]};
}

// Decodes a Converse response (design §7, §9.5). Always populates `usage` and
// `stopReason`; maps `guardrail_intervened` to `INTERVENED` (§9.5).
isolated function decodeConverse(json response) returns DecodedResponse|ai:Error {
    map<json>|error rr = response.ensureType();
    if rr is error {
        return error ai:LlmInvalidResponseError("Converse response was not a JSON object", rr);
    }
    map<json> r = rr;
    string text = "";
    ai:FunctionCall[] toolCalls = [];

    map<json>? output = mapField(r, "output");
    if output is map<json> {
        map<json>? message = mapField(output, "message");
        if message is map<json> {
            json[]? content = arrField(message, "content");
            if content is json[] {
                foreach json blk in content {
                    if blk is map<json> {
                        string? txt = strField(blk, "text");
                        if txt is string {
                            text += txt;
                        }
                        map<json>? toolUse = mapField(blk, "toolUse");
                        if toolUse is map<json> {
                            toolCalls.push({
                                name: strField(toolUse, "name") ?: "",
                                arguments: mapField(toolUse, "input") ?: {},
                                id: strField(toolUse, "toolUseId")
                            });
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
        inputTokens = intField(usage, "inputTokens") ?: 0;
        outputTokens = intField(usage, "outputTokens") ?: 0;
    }

    string stopReason = strField(r, "stopReason") ?: "end_turn";
    ai:ChatAssistantMessage message = {role: ai:ASSISTANT, content: text == "" ? () : text};
    if toolCalls.length() > 0 {
        message.toolCalls = toolCalls;
    }
    return {
        message,
        usage: {inputTokens, outputTokens},
        stopReason,
        responseId: (), // Converse returns the request id in a header, not the body
        guardrailAction: stopReason == "guardrail_intervened" ? INTERVENED : (), // §9.5
        additionalModelResponseFields: r["additionalModelResponseFields"]
    };
}
