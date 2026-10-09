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

import ballerinax/aws;
import ballerinax/aws.auth;

// Code every provider class shares: `chat()`, parameter and header assembly, and the
// construction checks.

// OpenTelemetry's `gen_ai.provider.name` value for AWS Bedrock.
// https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/
const BEDROCK_PROVIDER_NAME = "aws.bedrock";

isolated function runChat(ApiFamily api, string wireModelId,
        readonly & ModelConverter converter, ModelTransport transport, map<string> & readonly extraHeaders,
        readonly & InferenceParams params, ai:ChatMessage[]|ai:ChatUserMessage messages,
        ai:ChatCompletionFunctions[] tools, string? stop) returns ai:ChatAssistantMessage|ai:Error {
    ai:ChatMessage[] msgs;
    if messages is ai:ChatUserMessage {
        msgs = [messages];
    } else {
        msgs = messages;
    }

    observe:ChatSpan span = observe:createChatSpan(wireModelId);
    span.addProvider(BEDROCK_PROVIDER_NAME);
    if stop is string {
        span.addStopSequence(stop);
    }
    decimal? spanTemperature = params?.temperature;
    if spanTemperature is decimal {
        // Only a temperature the caller set; no invented default.
        span.addTemperature(spanTemperature);
    }
    if tools.length() > 0 {
        span.addTools(tools);
    }

    // Flattens prompts and fetches image URLs first, so the encoders stay pure.
    [string?, ResolvedMessage[]]|ai:Error resolved = resolveMessages(msgs);
    if resolved is ai:Error {
        span.close(resolved);
        return resolved;
    }
    [string?, ResolvedMessage[]] [system, rest] = resolved;
    // From the resolved form, so images are recorded as a placeholder, not their bytes.
    span.addInputMessages(messagesForSpan(system, rest));
    RequestEncoder encode = converter.encode;
    json|ai:Error encoded = encode(system, rest, tools, stop, params);
    if encoded is ai:Error {
        span.close(encoded);
        return encoded;
    }
    DecodedResponse|ai:Error decoded = sendAndDecode(span, api, wireModelId, converter, transport,
            extraHeaders, encoded);
    if decoded is ai:Error {
        span.close(decoded);
        return decoded;
    }
    span.addOutputMessages(decoded.message);
    span.addOutputType(observe:TEXT);
    span.close();
    return decoded.message;
}

isolated function sendAndDecode(observe:LlmSpan? span, ApiFamily api, string wireModelId,
        readonly & ModelConverter converter, ModelTransport transport, map<string> & readonly extraHeaders,
        json encoded) returns DecodedResponse|ai:Error {
    // Converse and InvokeModel name the model in the URL; the others in the body.
    json body = isPathAddressed(api) ? encoded : injectModel(encoded, wireModelId);
    TransportResponse response = check transport.execute(body, extraHeaders);
    ResponseDecoder decode = converter.decode;
    DecodedResponse decoded = check decode(response.body);
    augmentFromHeaders(decoded, response.headers);
    if span is observe:LlmSpan {
        recordResponse(span, decoded);
    }
    return decoded;
}

isolated function recordResponse(observe:LlmSpan span, DecodedResponse decoded) {
    span.addInputTokenCount(decoded.usage.inputTokens);
    span.addOutputTokenCount(decoded.usage.outputTokens);
    // A fired guardrail goes to the finish reason: `ai:ChatAssistantMessage` has no
    // field for it, and an error would break callers who expect the blocked reply.
    // On InvokeModel the body field is the only signal, so it wins.
    span.addFinishReason(decoded.guardrailAction == INTERVENED ? FINISH_CONTENT_FILTER
            : finishReason(decoded.stopReason));
    string? responseId = decoded.responseId;
    if responseId is string {
        span.addResponseId(responseId);
    }
}

isolated function errorWithDetail(string message, string detail) returns ai:Error
    => error ai:Error(message, error(detail));

// Vendor extras are already folded into `additionalModelRequestFields`.
isolated function buildInferenceParams(int? maxTokens, decimal? temperature,
        string[]? stopSequences, AdditionalRequestFields? additionalModelRequestFields,
        ServiceTier? serviceTier,
        boolean? latencyOptimized, GuardrailConfig? guardrail,
        ThinkingConfig? thinking = (), Effort? effort = (), ReasoningEffort? reasoningEffort = ())
        returns readonly & InferenceParams {
    InferenceParams params = {};
    // `maxTokens = ()` leaves the field out; some models reject it.
    if maxTokens is int {
        params.maxTokens = maxTokens;
    }
    // No default: an unset temperature is left out and the model's own applies.
    if temperature is decimal {
        params.temperature = temperature;
    }
    if stopSequences is string[] {
        params.stopSequences = stopSequences;
    }
    if additionalModelRequestFields != () {
        params.additionalModelRequestFields = additionalModelRequestFields;
    }
    if serviceTier is ServiceTier {
        params.serviceTier = serviceTier;
    }
    if latencyOptimized is boolean {
        params.latencyOptimized = latencyOptimized;
    }
    if guardrail is GuardrailConfig {
        params.guardrail = guardrail;
    }
    // Anthropic only.
    if thinking is ThinkingConfig {
        params.thinking = thinking;
    }
    if effort is Effort {
        params.effort = effort;
    }
    // OpenAI only; its wire shape depends on the API.
    if reasoningEffort is ReasoningEffort {
        params.reasoningEffort = reasoningEffort;
    }
    return params.cloneReadOnly();
}

// The rules follow the API, not the vendor.
isolated function buildRouteHeaders(Route route, GuardrailConfig? guardrail, BedrockAuthConfig creds,
        InferenceParams? params = ()) returns map<string> {
    map<string> headers = {};
    // Chat Completions takes guardrails as the InvokeModel headers.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html
    if route.api == INVOKE || route.api == CHAT_COMPLETIONS {
        if guardrail is GuardrailConfig {
            headers["X-Amzn-Bedrock-GuardrailIdentifier"] = guardrail.guardrailIdentifier;
            headers["X-Amzn-Bedrock-GuardrailVersion"] = guardrail.guardrailVersion;
        }
    }
    // Only InvokeModel documents the request-option headers.
    if route.api == INVOKE {
        addInvokeRequestOptionHeaders(headers, params);
    }
    if route.api == MESSAGES {
        // A header here, unlike InvokeModel's `anthropic_version` body field.
        // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html
        headers["anthropic-version"] = "2023-06-01";
    }
    addNativeApiKeyHeader(headers, route, creds);
    return headers;
}

// An unset or `false` latency flag sends nothing, since `standard` is the default.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModel.html
isolated function addInvokeRequestOptionHeaders(map<string> headers, InferenceParams? params) {
    if params is () {
        return;
    }
    ServiceTier? tier = params?.serviceTier;
    if tier is ServiceTier {
        headers["X-Amzn-Bedrock-Service-Tier"] = tier;
    }
    if params?.latencyOptimized == true {
        headers["X-Amzn-Bedrock-PerformanceConfig-Latency"] = "optimized";
    }
}

// Refuses at construction any parameter the route cannot send. Otherwise AWS answers
// 200 and the caller cannot tell an ignored field from an honoured one.
isolated function validateParamsForRoute(string providerName, ApiFamily api,
        readonly & ModelConverter converter, InferenceParams params) returns ai:Error? {
    DialectSupport supports = converter.supports;
    string dialect = converter.dialect;

    if params?.stopSequences is string[] && !supports.stopSequences {
        return errorWithDetail(
            string `${providerName}: 'stopSequences' is not supported on the ${dialect} API. Remove it, ` +
            "or use the CONVERSE or INVOKE API.",
            "That dialect has no stop-sequence parameter in its request schema, so the model would run " +
            "past the text you asked it to stop at and bill you for the tokens.");
    }
    if params?.thinking is ThinkingConfig && !supports.thinking {
        return error ai:Error(
            string `${providerName}: 'thinking' is not supported on the ${dialect} API. Remove it, or ` +
            "choose an API that carries it with 'apiType'.");
    }
    if params?.effort is Effort && !supports.effort {
        return error ai:Error(
            string `${providerName}: 'effort' is not supported on the ${dialect} API. Remove it, or ` +
            "choose an API that carries it with 'apiType'.");
    }
    if params?.reasoningEffort is ReasoningEffort && !supports.reasoningEffort {
        return error ai:Error(
            string `${providerName}: 'reasoningEffort' is not supported on the ${dialect} API. Remove ` +
            "it, or choose an API that carries it with 'apiType'.");
    }

    // Converse and InvokeModel carry these; the other APIs do not.
    if apiCarriesRequestOptions(api) {
        return;
    }
    string[] unsupported = [];
    if params?.serviceTier is ServiceTier {
        unsupported.push("serviceTier");
    }
    // `false` asks for the default and is allowed; any tier is an explicit change.
    if params?.latencyOptimized == true {
        unsupported.push("latencyOptimized");
    }
    if unsupported.length() == 0 {
        return;
    }
    // Not mapped to a body field: the vendor APIs spell tiers with their own values.
    return errorWithDetail(
        string `${providerName}: ${string:'join(", ", ...unsupported)} ` +
        string `${unsupported.length() == 1 ? "is" : "are"} not supported on the ${api} API. Use the ` +
        "CONVERSE or INVOKE API, or send the vendor's own field through 'additionalModelRequestFields'.",
        "The vendor-compatible APIs have no Bedrock request-option headers, and they spell service " +
        "tiers with the vendor's value set rather than Bedrock's, so this module will not guess a mapping.");
}

isolated function apiCarriesRequestOptions(ApiFamily api) returns boolean
    => api == CONVERSE || api == INVOKE;

// The Messages API takes the API key as `x-api-key`, so the transport sends no Bearer
// header with it.
isolated function addNativeApiKeyHeader(map<string> headers, Route route, BedrockAuthConfig creds) {
    if usesApiKeyHeader(route.api) && creds is BearerToken {
        headers["x-api-key"] = creds.apiKey;
    }
}

// Refuses an empty region, which would otherwise surface as a DNS failure.
isolated function guardRegion(string region) returns ai:Error? {
    if region == "" {
        return error ai:Error("No AWS region: pass a non-empty 'region' (an 'aws:Region' " +
            "constant such as 'aws:US_EAST_1', or a region string), or use a model ARN " +
            "that carries its own region.");
    }
    // A shape check, not an allowlist, so new regions work. A trailing space or upper
    // case otherwise fails as a confusing connection error or a 403.
    foreach string:Char c in region {
        if c == " " || c == "\t" || c == "\n" || c == "\r" {
            return error ai:Error(string `Invalid AWS region '${region}': it contains whitespace. ` +
                string `Pass a bare region such as 'us-east-1'.`);
        }
        if c != "-" && !(c >= "a" && c <= "z") && !(c >= "0" && c <= "9") {
            return error ai:Error(string `Invalid AWS region '${region}': regions are lowercase ` +
                string `and contain only letters, digits and hyphens. Pass a bare region such as ` +
                string `'us-east-1', or an 'aws:Region' constant.`);
        }
    }
}

// Refuses a guardrail where it would not be applied:
//  - Responses: "Guardrails don't apply to the Responses API."
//    https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html
//  - Anthropic Messages: AWS does not say whether the guardrail headers apply there,
//    and a guardrail silently not applied is the dangerous outcome.
isolated function guardGuardrailSupport(ApiFamily api, GuardrailConfig? guardrail) returns ai:Error? {
    if guardrail !is GuardrailConfig {
        return;
    }
    if api == RESPONSES {
        return error ai:Error("Guardrails are not supported on the Responses API. Use the CONVERSE " +
            "API, or call the ApplyGuardrail API.");
    }
    if api == MESSAGES {
        return errorWithDetail("Guardrails are not supported on the Anthropic Messages API. Use the " +
            "CONVERSE or INVOKE API, or call the ApplyGuardrail API.",
            "AWS documents guardrail parameters for Converse, InvokeModel and Chat Completions, but not " +
            "for '/anthropic/v1/messages', so this module will not send them where it cannot confirm " +
            "they are honoured.");
    }
}

isolated function resolveSpine(string providerName, BedrockAuthConfig credentials,
        Route|error resolved, aws:EndpointConfig? endpointConfig,
        http:ClientConfiguration? httpConfig, RetryConfig? retryConfig, GuardrailConfig? guardrail)
        returns [Route, readonly & ModelConverter, BedrockTransport]|ai:Error {
    do {
        Route route = check resolved;
        // Checks the resolved region: an ARN supplies its own.
        check guardRegion(route.region);
        check guardGuardrailSupport(route.api, guardrail);
        Endpoint ep = check buildEndpoint(route, endpointConfig);
        readonly & ModelConverter converter = check selectConverter(route);
        // Last, because resolving credentials can reach the network (IMDS, STS, SSO).
        auth:CredentialProvider|BearerToken resolvedCredentials = check resolveCredentials(credentials);
        BedrockTransport transport =
            check new (resolvedCredentials, route.region, ep, httpConfig, retryConfig, false, INFERENCE_TIMEOUT);
        return [route, converter, transport];
    } on fail error e {
        if e is ai:Error {
            return e;
        }
        return error ai:Error(string `Failed to initialize ${providerName}: ${e.message()}`, e);
    }
}

isolated function additionalFieldsToJson(AdditionalRequestFields? fields) returns map<json>? {
    if fields is () || fields.length() == 0 {
        return ();
    }
    return fields.clone();
}

isolated function foldRequestFields(AdditionalRequestFields? base, map<json> extras)
        returns AdditionalRequestFields? {
    AdditionalRequestFields merged = {};
    if base is AdditionalRequestFields {
        foreach [string, json] [k, v] in base.entries() {
            merged[k] = v;
        }
    }
    foreach [string, json] [k, v] in extras.entries() {
        merged[k] = v;
    }
    return merged.length() > 0 ? merged : ();
}

isolated function injectModel(json body, string modelId) returns json {
    if body is map<json> {
        map<json> withModel = body.clone();
        withModel["model"] = modelId;
        return withModel;
    }
    return body;
}

// Images become `[image <mime>, <n> bytes]`, so their bytes never reach telemetry.
isolated function messagesForSpan(string? system, ResolvedMessage[] messages) returns json {
    json[] out = [];
    if system is string {
        out.push({role: ai:SYSTEM, content: system});
    }
    foreach ResolvedMessage m in messages {
        if m is ResolvedUserMessage {
            out.push({role: m.role, content: partsForSpan(m.parts)});
        } else if m is ai:ChatAssistantMessage {
            // The tool calls are the assistant's turn in an agent loop.
            ai:FunctionCall[]? toolCalls = m.toolCalls;
            out.push(toolCalls is ai:FunctionCall[]
                ? {role: m.role, content: m.content, toolCalls: toolCalls.toJson()}
                : {role: m.role, content: m.content});
        } else {
            out.push({role: m.role, content: m.content, name: m.name, id: m.id});
        }
    }
    return out;
}

// AWS enforces these with a 400. With `maxTokens = ()` there is no ceiling to check.
// https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-extended-thinking.html
isolated function validateThinking(ThinkingConfig thinking, int? maxTokens) returns ai:Error? {
    int? budget = thinking?.budgetTokens;
    if thinking.mode != ENABLED {
        if budget is int {
            return error ai:Error(string `'budgetTokens' is only valid with 'mode = ENABLED'; mode is ` +
                string `'${thinking.mode}'. Adaptive thinking is steered with 'effort' instead.`);
        }
        return;
    }
    if budget is () {
        return error ai:Error("'mode = ENABLED' requires 'budgetTokens' — manual extended thinking " +
            "has no default budget. Use 'mode = ADAPTIVE' to let the model decide.");
    }
    if budget < MIN_THINKING_BUDGET_TOKENS {
        return error ai:Error(string `'budgetTokens' must be at least ` +
            string `${MIN_THINKING_BUDGET_TOKENS}; got ${budget}.`);
    }
    if maxTokens is int && budget >= maxTokens {
        return error ai:Error(string `'budgetTokens' (${budget}) must be less than 'maxTokens' ` +
            string `(${maxTokens}) — the thinking budget is drawn from the same ceiling.`);
    }
}

// The finish reasons on the trace, whatever API answered. OpenAI's names, as used by
// OpenTelemetry's `gen_ai.response.finish_reasons`.
const FINISH_STOP = "stop";
const FINISH_LENGTH = "length";
const FINISH_TOOL_CALLS = "tool_calls";
const FINISH_CONTENT_FILTER = "content_filter";
const FINISH_ERROR = "error";

// Maps one API's stop reason to the shared set; an unknown value is kept.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html
// https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons
isolated function finishReason(string stopReason) returns string {
    match stopReason {
        "end_turn"|"stop_sequence"|"stop"|"completed" => {
            return FINISH_STOP;
        }
        "max_tokens"|"length"|"model_length"|"max_output_tokens"|"model_context_window_exceeded" => {
            return FINISH_LENGTH;
        }
        "tool_use"|"tool_calls"|"function_call" => {
            return FINISH_TOOL_CALLS;
        }
        "guardrail_intervened"|"content_filtered"|"content_filter"|"refusal" => {
            return FINISH_CONTENT_FILTER;
        }
        "malformed_model_output"|"malformed_tool_use"|"failed"|"error" => {
            return FINISH_ERROR;
        }
    }
    return stopReason;
}
