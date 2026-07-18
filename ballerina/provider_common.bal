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
import ballerina/ai.observe;
import ballerina/http;

// Shared facade machinery (CLAUDE.md §3): every vendor provider is a thin class
// over these. `runChat` is the whole `chat()` body; `buildInferenceParams`
// assembles the resolved `InferenceParams`; `commonExtraHeaders` builds the
// route-specific headers common to all vendors. Only the model enum, config
// extras (folded into `additionalModelRequestFields`), and Invoke-codec choice
// differ per vendor.

// The full `chat()` implementation, shared by every vendor facade (design §3, §7).
// Opens an observe span and closes it on every path (§3.2).
isolated function runChat(string providerName, ApiFamily family, string wireModelId,
        readonly & ModelCodec codec, BedrockTransport transport, map<string> & readonly extraHeaders,
        readonly & InferenceParams params, ai:ChatMessage[]|ai:ChatUserMessage messages,
        ai:ChatCompletionFunctions[] tools, string? stop) returns ai:ChatAssistantMessage|ai:Error {
    ai:ChatMessage[] msgs;
    if messages is ai:ChatUserMessage {
        msgs = [messages];
    } else {
        msgs = messages;
    }

    observe:ChatSpan span = observe:createChatSpan(wireModelId);
    span.addProvider(providerName);
    if stop is string {
        span.addStopSequence(stop);
    }
    span.addTemperature(params.temperature);
    span.addInputMessages(messagesForSpan(msgs));
    if tools.length() > 0 {
        span.addTools(tools);
    }

    [ai:ChatSystemMessage?, ai:ChatMessage[]] [system, rest] = hoistSystem(msgs);
    RequestCodec encode = codec.encode;
    json|ai:Error encoded = encode(system, rest, tools, stop, params);
    if encoded is ai:Error {
        span.close(encoded);
        return encoded;
    }
    json body = family == MANTLE ? injectModel(encoded, wireModelId) : encoded;

    TransportResponse|ai:Error response = transport.execute(body, extraHeaders);
    if response is ai:Error {
        span.close(response);
        return response;
    }

    ResponseCodec decode = codec.decode;
    DecodedResponse|ai:Error decoded = decode(response.body);
    if decoded is ai:Error {
        span.close(decoded);
        return decoded;
    }
    // Surface the request id from the response headers (§9.5).
    augmentFromHeaders(decoded, response.headers);

    span.addInputTokenCount(decoded.usage.inputTokens);
    span.addOutputTokenCount(decoded.usage.outputTokens);
    // A fired guardrail must never be silently dropped (§9.5) — that is the whole
    // reason `decode` returns a record rather than a bare message (§3.2, §7).
    //
    // The `ai:ModelProvider` contract has nowhere to put this: `chat()` returns an
    // `ai:ChatAssistantMessage`, which carries no guardrail field, and turning an
    // intervention into an error would break callers who guardrail every request by
    // policy and expect the blocked-content message back. So the signal goes to the
    // span's finish reason — the one channel that both survives to the caller's
    // observability backend and is already keyed on "why did generation stop".
    //
    // Converse already reports `guardrail_intervened` as its stopReason, so this
    // only changes behaviour on the Invoke route, where the body field is the
    // only source.
    if decoded.guardrailAction == INTERVENED && decoded.stopReason != "guardrail_intervened" {
        span.addFinishReason("guardrail_intervened");
    } else {
        span.addFinishReason(decoded.stopReason);
    }
    string? responseId = decoded.responseId;
    if responseId is string {
        span.addResponseId(responseId);
    }
    span.addOutputMessages(decoded.message);
    span.close();
    return decoded.message;
}

// Assembles the resolved `InferenceParams` once at construction (design §6, §7).
// `additionalModelRequestFields` already carries any vendor extras the facade
// folded in (Claude `top_k`/`thinking`, Nova `reasoningConfig`, Qwen thinking…).
isolated function buildInferenceParams(int? maxTokens, decimal? temperature, decimal? topP,
        string[]? stopSequences, json additionalModelRequestFields,
        string[]? additionalModelResponseFieldPaths, ServiceTier? serviceTier,
        boolean? latencyOptimized, map<string>? requestMetadata, GuardrailConfig? guardrail)
        returns readonly & InferenceParams {
    InferenceParams params = {
        temperature: temperature ?: DEFAULT_TEMPERATURE,
        maxTokens: maxTokens ?: DEFAULT_MAX_TOKEN_COUNT
    };
    if topP is decimal {
        params.topP = topP;
    }
    if stopSequences is string[] {
        params.stopSequences = stopSequences;
    }
    if additionalModelRequestFields != () {
        params.additionalModelRequestFields = additionalModelRequestFields;
    }
    if additionalModelResponseFieldPaths is string[] {
        params.additionalModelResponseFieldPaths = additionalModelResponseFieldPaths;
    }
    if serviceTier is ServiceTier {
        params.serviceTier = serviceTier;
    }
    if latencyOptimized is boolean {
        params.latencyOptimized = latencyOptimized;
    }
    if requestMetadata is map<string> {
        params.requestMetadata = requestMetadata;
    }
    if guardrail is GuardrailConfig {
        params.guardrail = guardrail;
    }
    return params.cloneReadOnly();
}

// Route-specific headers common to all vendors (design §9.5): Invoke guardrail
// headers. Vendor facades merge their own Mantle headers on top (§7.3).
isolated function commonExtraHeaders(Route route, GuardrailConfig? guardrail, BedrockCredentials creds)
        returns map<string> {
    map<string> headers = {};
    if route.family == INVOKE && guardrail is GuardrailConfig {
        headers["X-Amzn-Bedrock-GuardrailIdentifier"] = guardrail.guardrailIdentifier;
        headers["X-Amzn-Bedrock-GuardrailVersion"] = guardrail.guardrailVersion;
        string? trace = guardrail.trace;
        if trace is string {
            headers["X-Amzn-Bedrock-Trace"] = trace.toUpperAscii();
        }
    }
    addMantleApiKeyHeader(headers, route, creds);
    return headers;
}

// `x-api-key` for a Mantle entry that declares X_API_KEY (design §14 open item #1).
//
// Shared, not per-vendor: `authHeader` is per-model TABLE data, so any vendor's
// entry — or a user's `routeOverrides` — may declare X_API_KEY. This previously
// lived in the Anthropic facade alone, which meant the same data was honoured there
// and silently ignored everywhere else.
//
// NOTE (§14 open item #1, unresolved): which header Mantle wants for Anthropic
// models is genuinely ambiguous — AWS's documented curl uses `x-api-key`, while
// Anthropic's SDK sends `Authorization: Bearer`, and no first-party source states
// the wire header. We therefore HEDGE rather than guess: the transport always sets
// `Authorization: Bearer` for a BearerToken, and X_API_KEY entries additionally send
// `x-api-key`. Both carry the same key, so whichever the service reads, it succeeds.
// This is deliberate, not redundancy to tidy away — one live call settles it, after
// which this can select rather than hedge.
//
// Only a BearerToken can populate it: with SigV4 credentials there is no api key,
// and the signature alone must authenticate the request.
isolated function addMantleApiKeyHeader(map<string> headers, Route route, BedrockCredentials creds) {
    MantleEntry? entry = route.mantleEntry;
    if route.family == MANTLE && entry is MantleEntry && entry.authHeader == X_API_KEY
            && creds is BearerToken {
        headers["x-api-key"] = creds.apiKey;
    }
}

// Guardrail-on-Mantle construction guard, shared by every facade (design §9.5).
isolated function guardMantleGuardrail(ApiFamily family, GuardrailConfig? guardrail) returns ai:Error? {
    if family == MANTLE && guardrail is GuardrailConfig {
        return error ai:Error("Guardrails are not supported on the Mantle route; " +
            "apply the standalone ApplyGuardrail API instead (design §9.5)");
    }
}

// The shared construction spine (design §5, §6): resolve → guard → endpoint →
// codec → transport. Every failure AWS cannot diagnose surfaces here, before any
// I/O (principle 7). Returns the resolved route (for header/param assembly), the
// codec, and the transport.
isolated function resolveSpine(string providerName, BedrockCredentials credentials, string model,
        string region, RouteConfig routeConfig, string? signingServiceName,
        http:ClientConfiguration? httpConfig, RetryConfig? retryConfig, GuardrailConfig? guardrail)
        returns [Route, readonly & ModelCodec, BedrockTransport]|ai:Error {
    do {
        Route route = check resolveRoute(model, region, routeConfig); // L1, pure — §5
        check guardMantleGuardrail(route.family, guardrail);          // principle 7 — §9.5
        Endpoint ep = check buildEndpoint(route);                     // L2 — §9.1-9.2
        readonly & ModelCodec codec = check selectCodec(route, routeConfig.modelSchema);
        BedrockTransport transport =
            check new (credentials, route.region, ep, signingServiceName, httpConfig, retryConfig);
        return [route, codec, transport];
    } on fail error e {
        if e is ai:Error {
            return e;
        }
        return error ai:Error(string `Failed to initialize ${providerName}: ${e.message()}`, e);
    }
}

// Folds a vendor's extra request fields into `additionalModelRequestFields`
// (design §9.3). Returns `()` when there is nothing to forward.
isolated function foldRequestFields(json base, map<json> extras) returns json {
    map<json> merged = {};
    if base is map<json> {
        foreach [string, json] [k, v] in base.entries() {
            merged[k] = v;
        }
    }
    foreach [string, json] [k, v] in extras.entries() {
        merged[k] = v;
    }
    return merged.length() > 0 ? merged : ();
}

// Injects the bare model id into a Mantle request body (design §7.3). Converse/
// Invoke carry the model id in the URL path instead (§9.1).
isolated function injectModel(json body, string modelId) returns json {
    if body is map<json> {
        map<json> withModel = body.clone();
        withModel["model"] = modelId;
        return withModel;
    }
    return body;
}

// Simplified message projection for the observe span (avoids `Prompt` objects,
// which are not `anydata`).
isolated function messagesForSpan(ai:ChatMessage[] messages) returns json {
    json[] out = [];
    foreach ai:ChatMessage m in messages {
        if m is ai:ChatUserMessage|ai:ChatSystemMessage {
            out.push({role: m.role, content: contentToString(m.content)});
        } else if m is ai:ChatAssistantMessage {
            out.push({role: m.role, content: m.content});
        } else {
            out.push({role: m.role, content: m.content, name: m.name});
        }
    }
    return out;
}
