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

// Amazon Nova on the InvokeModel route (design §7.2). Nova is Converse-shaped but
// the request body REQUIRES `"schemaVersion": "messages-v1"` — omit it and the
// request fails validation. The response shape matches Converse, so `decode` is
// shared with the Converse codec.

// Encodes a Nova InvokeModel request body (design §7.2). Reuses Converse message/
// tool mapping and prepends the mandatory `schemaVersion`.
isolated function encodeNovaInvoke(ai:ChatSystemMessage? system, ai:ChatMessage[] messages,
        ai:ChatCompletionFunctions[] tools, string? stop, InferenceParams params) returns json|ai:Error {
    json[] wire = [];
    foreach ai:ChatMessage m in messages {
        wire.push(converseMessage(m)); // Nova uses the Converse content-block shape
    }

    map<json> inferenceConfig = {"maxTokens": params.maxTokens, "temperature": params.temperature};
    string[]? stops = params.stopSequences;
    if stop is string {
        stops = [stop];
    }
    if stops is string[] && stops.length() > 0 {
        inferenceConfig["stopSequences"] = stops;
    }

    // §7.2: mandatory schema version; validation fails without it.
    map<json> body = {"schemaVersion": "messages-v1", "messages": wire, "inferenceConfig": inferenceConfig};
    if system is ai:ChatSystemMessage {
        body["system"] = [{"text": contentToString(system.content)}]; // top-level, never a message (§7.1)
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
    // Nova reasoningConfig etc. ride additionalModelRequestFields (§9.3).
    json extra = params?.additionalModelRequestFields;
    if extra is map<json> {
        foreach [string, json] [k, v] in extra.entries() {
            body[k] = v;
        }
    }
    return body;
}
