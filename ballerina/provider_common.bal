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

// Shared facade machinery: every vendor provider is a thin class
// over these. `runChat` is the whole `chat()` body; `buildInferenceParams`
// assembles the resolved `InferenceParams`; `buildRouteHeaders` builds every
// route-specific header. Only the model enum, the API-family subtype, the config
// extras and the params assembly differ per vendor.

// The full `chat()` implementation, shared by every vendor facade.
// Opens an observe span and closes it on every path.
isolated function runChat(string providerName, ApiFamily api, string wireModelId,
        readonly & ModelConverter converter, BedrockTransport transport, map<string> & readonly extraHeaders,
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
    decimal? spanTemperature = params?.temperature;
    if spanTemperature is decimal {
        // Only report a temperature the caller actually set — recording an invented
        // default would misreport what went on the wire.
        span.addTemperature(spanTemperature);
    }
    if tools.length() > 0 {
        span.addTools(tools);
    }

    // Resolve BEFORE encoding: flattens each prompt to parts and fetches any image
    // URL, so the encoders below stay pure. Any image on a dialect that cannot carry
    // one fails here, before the request is built.
    [string?, ResolvedMessage[]]|ai:Error resolved = resolveMessages(msgs);
    if resolved is ai:Error {
        span.close(resolved);
        return resolved;
    }
    [string?, ResolvedMessage[]] [system, rest] = resolved;
    // Recorded from the RESOLVED form so images become a placeholder. The raw form
    // would put the whole image — potentially megabytes of user data — into the span
    // and ship it to whatever telemetry backend is configured.
    span.addInputMessages(messagesForSpan(system, rest));
    RequestEncoder encode = converter.encode;
    json|ai:Error encoded = encode(system, rest, tools, stop, params);
    if encoded is ai:Error {
        span.close(encoded);
        return encoded;
    }
    // Converse and InvokeModel name the model in the URL; the three vendor-native
    // shapes name it in the body, on both endpoints.
    json body = isPathAddressed(api) ? encoded : injectModel(encoded, wireModelId);

    TransportResponse|ai:Error response = transport.execute(body, extraHeaders);
    if response is ai:Error {
        span.close(response);
        return response;
    }

    ResponseDecoder decode = converter.decode;
    DecodedResponse|ai:Error decoded = decode(response.body);
    if decoded is ai:Error {
        span.close(decoded);
        return decoded;
    }
    // Surface the request id from the response headers.
    augmentFromHeaders(decoded, response.headers);

    span.addInputTokenCount(decoded.usage.inputTokens);
    span.addOutputTokenCount(decoded.usage.outputTokens);
    // A fired guardrail must never be silently dropped — that is the whole
    // reason `decode` returns a record rather than a bare message.
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

// Assembles the resolved `InferenceParams` once at construction.
// `additionalModelRequestFields` already carries any vendor extras the facade
// folded in (Claude `thinking`, Nova `reasoningConfig`, Qwen thinking…).
isolated function buildInferenceParams(int? maxTokens, decimal? temperature,
        string[]? stopSequences, AdditionalRequestFields? additionalModelRequestFields,
        ServiceTier? serviceTier,
        boolean? latencyOptimized, GuardrailConfig? guardrail,
        ThinkingConfig? thinking = (), Effort? effort = (), ReasoningEffort? reasoningEffort = ())
        returns readonly & InferenceParams {
    InferenceParams params = {};
    // `?:` here was a trap: `maxTokens` DEFAULTS to `DEFAULT_MAX_TOKEN_COUNT` on every
    // `init`, so the only way a caller could ask for it to be omitted was to pass `()`
    // explicitly — and this line coerced that straight back to the default, making the
    // field impossible to suppress. That is a hard 400 on models that reject it:
    // OpenAI deprecated Chat Completions' `max_tokens` in favour of
    // `max_completion_tokens` and marks it "not compatible with o-series models", and
    // GPT-6 refuses it outright. Same reasoning as `temperature` below.
    // https://github.com/openai/openai-openapi/blob/master/openapi.yaml (CreateChatCompletionRequest.max_tokens)
    if maxTokens is int {
        params.maxTokens = maxTokens;
    }
    // No default: an unset temperature stays unset all the way to the wire, so the
    // model applies its own. `?:` here would make it impossible for a caller to
    // OMIT the field, which is a hard 400 on every sampling-deprecated model — see
    // `setTemperature` in converter_common.bal.
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
    // Claude-only today, hence defaulted: the other six vendors never pass them.
    if thinking is ThinkingConfig {
        params.thinking = thinking;
    }
    if effort is Effort {
        params.effort = effort;
    }
    // OpenAI-only today. First-class rather than folded into the passthrough because
    // its wire shape is dialect-dependent — see `InferenceParams.reasoningEffort`.
    if reasoningEffort is ReasoningEffort {
        params.reasoningEffort = reasoningEffort;
    }
    return params.cloneReadOnly();
}

// Every route-specific request header, for every vendor and both endpoints.
//
// Shared rather than per-vendor because each rule here tracks the resolved SHAPE, not
// the model's vendor: the Anthropic Messages version header belongs to anything on
// `/anthropic/v1/messages`, and the guardrail headers belong to InvokeModel and Chat
// Completions whoever built the model.
isolated function buildRouteHeaders(Route route, GuardrailConfig? guardrail, BedrockCredentials creds,
        InferenceParams? params = ()) returns map<string> {
    map<string> headers = {};
    // The OpenAI-compatible Chat Completions path reuses the INVOKEMODEL header
    // convention for guardrails rather than the Converse body field — AWS documents
    // `X-Amzn-Bedrock-GuardrailIdentifier` / `-GuardrailVersion` / `-Trace` as
    // `extra_headers` on that path.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html
    if route.api == INVOKE || route.api == CHAT_COMPLETIONS {
        if guardrail is GuardrailConfig {
            headers["X-Amzn-Bedrock-GuardrailIdentifier"] = guardrail.guardrailIdentifier;
            headers["X-Amzn-Bedrock-GuardrailVersion"] = guardrail.guardrailVersion;
        }
    }
    // The request-option headers are InvokeModel's alone; Chat Completions does not
    // document them.
    if route.api == INVOKE {
        addInvokeRequestOptionHeaders(headers, params);
    }
    if route.api == MESSAGES {
        // Required on the native Messages path, and a DIFFERENT value and mechanism
        // from InvokeModel's `anthropic_version: bedrock-2023-05-31` BODY field. Both
        // conventions are live on bedrock-runtime at once, one per shape.
        // https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html
        headers["anthropic-version"] = "2023-06-01";
    }
    addNativeApiKeyHeader(headers, route, creds);
    return headers;
}

// `serviceTier` and `latencyOptimized` on the Invoke route.
//
// These are NOT Converse-only knobs, which is what "read by the Converse converter
// and nothing else" made them look like. `InvokeModel` carries both as REQUEST
// HEADERS — the same two settings, a different transport slot — so on Invoke the
// right answer is to send them, not to refuse them and not to drop them:
//
//   X-Amzn-Bedrock-Service-Tier:              priority | default | flex | reserved
//   X-Amzn-Bedrock-PerformanceConfig-Latency: standard | optimized
//
// Both header names and both value sets are the API reference's own.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModel.html
//
// `standard` is the latency default, so an unset or `false` flag sends nothing —
// matching what the Converse converter emits for the same input.
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

// Refuses, at construction, any inference parameter the resolved route cannot put on
// the wire.
//
// THE POINT IS THAT IT IS ONE FUNCTION. Every knob here is route-specific, every
// provider exposes all of them on one flat config, and the failure mode when a knob
// meets a route that cannot carry it is silence: the constructor accepts it, the
// encoder does not read it, AWS returns a perfectly ordinary 200, and the caller has
// no way to tell a dropped field from an honoured one. A caller who sets
// `latencyOptimized` is asking to pay differently; answering 200 without doing it is
// the module lying about what it sent.
//
// One spine now serves both `chat()` and `generate()` — the provider class fixes the
// endpoint, so there is no second route to check against.
isolated function validateParamsForRoute(string providerName, ApiFamily api,
        readonly & ModelConverter converter, InferenceParams params) returns ai:Error? {
    DialectSupport supports = converter.supports;
    string dialect = converter.dialect;

    if params?.stopSequences is string[] && !supports.stopSequences {
        return error ai:Error(
            string `${providerName}: 'stopSequences' is not supported on the ${dialect} route — that ` +
            "dialect has no stop-sequence parameter in its request schema, so the model would run past " +
            "the text you asked it to stop at and bill you for the tokens. Remove 'stopSequences', or " +
            "select a CONVERSE or INVOKE model with 'api'.");
    }
    if params?.thinking is ThinkingConfig && !supports.thinking {
        return error ai:Error(
            string `${providerName}: 'thinking' is not supported on the ${dialect} route. Remove it, or ` +
            "select a api that carries it with 'api'.");
    }
    if params?.effort is Effort && !supports.effort {
        return error ai:Error(
            string `${providerName}: 'effort' is not supported on the ${dialect} route. Remove it, or ` +
            "select a api that carries it with 'api'.");
    }
    if params?.reasoningEffort is ReasoningEffort && !supports.reasoningEffort {
        return error ai:Error(
            string `${providerName}: 'reasoningEffort' is not supported on the ${dialect} route. Remove ` +
            "it, or select a api that carries it with 'api'.");
    }

    // `serviceTier`/`latencyOptimized` are a ROUTE-FAMILY capability, not a dialect
    // one — a Converse body field, an InvokeModel request header, and nothing at all
    // on Mantle.
    if apiCarriesRequestOptions(api) {
        return;
    }
    string[] unsupported = [];
    if params?.serviceTier is ServiceTier {
        unsupported.push("serviceTier");
    }
    // `true` only. `latencyOptimized = false` asks for `standard`, which IS what an
    // unset flag already produces on every route — refusing it would reject a call
    // that is asking for exactly what it is going to get. A tier, by contrast, is
    // always an explicit choice away from the baseline, so any value is refused.
    if params?.latencyOptimized == true {
        unsupported.push("latencyOptimized");
    }
    if unsupported.length() == 0 {
        return;
    }
    // DELIBERATELY NOT GUESSED. The OpenAI- and Anthropic-compatible surfaces on
    // bedrock-mantle do have a `service_tier` BODY field, but its value vocabulary is
    // the vendor's (`auto|default|flex|fast|priority|ultrafast` in OpenAI's schema),
    // not Bedrock's `ServiceTier` (`default|priority|flex|reserved`) — two first-party
    // sources, one field name, different value sets, and no statement anywhere about
    // which one bedrock-mantle honours. Emitting `ServiceTier` there would be a guess
    // that fails silently if wrong (a tier you are not billed for). Refuse, and point
    // at the passthrough for a caller who knows their model's vocabulary.
    // There is no latency-optimization concept on bedrock-mantle at all.
    return error ai:Error(
        string `${providerName}: ${string:'join(", ", ...unsupported)} ` +
        string `${unsupported.length() == 1 ? "is" : "are"} not supported on the ${api} api — ` +
        "the vendor-compatible surfaces have no Bedrock request-option headers, and they spell service " +
        "tiers with the VENDOR's value set rather than Bedrock's, so this module will not guess a " +
        "mapping. Use the CONVERSE or INVOKE api to set them as Bedrock defines them, or send " +
        "the vendor's own spelling verbatim through 'additionalModelRequestFields'.");
}

// Which shapes carry `serviceTier`/`latencyOptimized`: Converse as body fields,
// InvokeModel as request headers. The three vendor-native shapes document neither.
isolated function apiCarriesRequestOptions(ApiFamily api) returns boolean
    => api == CONVERSE || api == INVOKE;

// `x-api-key` for a Mantle path that authenticates with it (the Anthropic Messages
// surface). Derived from the path via `usesApiKeyHeader`, not stored per model.
//
// Shared, not per-vendor: this previously lived in the Anthropic facade alone, which
// meant the same rule was honoured there and silently ignored everywhere else.
//
// RESOLVED (verified live 2026-08-03): Anthropic's Mantle surface
// REJECTS a request that carries BOTH `Authorization` and `x-api-key` — it returns
// 401 `authentication_error: "request must not include both 'authorization' and
// 'x-api-key' headers"`. Either header ALONE returns 200, so the per-model
// path now SELECTS the header rather than hedging with both. AWS's documented
// curl uses `x-api-key`, so a Messages path sends exactly that, and the transport
// SUPPRESSES its default `Authorization: Bearer` whenever x-api-key is present
// (see the BearerToken branch in transport.bal). Do NOT re-add a second header here:
// the old "both carry the same key, so whichever the service reads it succeeds"
// assumption is known-false and was the exact cause of the 401.
//
// Only a BearerToken can populate it: with SigV4 credentials there is no api key,
// and the signature alone must authenticate the request.
isolated function addNativeApiKeyHeader(map<string> headers, Route route, BedrockCredentials creds) {
    if usesApiKeyHeader(route.api) && creds is BearerToken {
        headers["x-api-key"] = creds.apiKey;
    }
}

// Empty-region construction guard, shared by every facade. `region` is a required
// parameter, so this fires only on an explicitly empty string — an empty region would
// otherwise build the host `bedrock-runtime..amazonaws.com` and surface as an opaque
// DNS failure. Nothing in this module reads the environment: no `ballerinax`
// connector defaults a parameter from `os:getEnv`, and the AWS environment lookup
// belongs to the SDK, behind `auth:DEFAULT_CREDENTIALS`.
isolated function guardRegion(string region) returns ai:Error? {
    if region == "" {
        return error ai:Error("No AWS region: pass a non-empty 'region' (an 'aws:Region' " +
            "constant such as 'aws:US_EAST_1', or a region string), or use a model ARN " +
            "that carries its own region.");
    }
    // Reject anything that is not a bare lowercase region token. Without this, two
    // ordinary typos become failures that name neither the field nor the mistake:
    // a trailing space is percent-encoded into the hostname and surfaces as a
    // connection error against `bedrock-runtime.us-east-1%20.amazonaws.com`, and an
    // uppercase region reaches SigV4 intact and comes back as a 403 "Credential
    // should be scoped to a valid region" — which reads as a broken login.
    //
    // Deliberately a SHAPE check, not an allowlist: AWS adds regions faster than this
    // module ships, so anything lowercase-alphanumeric with hyphens is let through
    // and AWS decides. Only characters no region has ever contained are refused.
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

// Guardrail-support construction guard, shared by every facade.
//
// Guardrails are a `bedrock-runtime` feature and are not uniform even there. Three
// cases, all refused before any I/O so the message names the mistake instead of the
// caller discovering it as silently-unguarded traffic:
//
//  - bedrock-mantle: no guardrail support at all. AWS's feature-availability table
//    marks Guardrails supported on bedrock-runtime and unsupported on bedrock-mantle.
//    https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html
//  - Responses API, either endpoint: stated verbatim — "Guardrails don't apply to the
//    Responses API. To apply a guardrail to a GPT model on this endpoint, call the
//    Converse API instead."
//    https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html
//  - Anthropic Messages on bedrock-runtime: UNVERIFIED. AWS documents guardrail
//    parameters for Converse (body field), InvokeModel (headers) and Chat Completions
//    (headers), but no page states whether the `X-Amzn-Bedrock-Guardrail*` headers are
//    honoured on the `/anthropic/v1/messages` route. POLICY CHOICE, recorded so a
//    reviewer can overrule it: refuse rather than send. A guardrail that is accepted
//    and quietly not applied is the dangerous direction for a safety control — the
//    caller believes traffic is screened when it is not. Reversible the moment AWS
//    documents it either way.
isolated function guardGuardrailSupport(BedrockEndpoint endpoint, ApiFamily api,
        GuardrailConfig? guardrail) returns ai:Error? {
    if guardrail !is GuardrailConfig {
        return;
    }
    // Defence in depth: unreachable today, because the six Mantle classes take a
    // `CommonMantleConfig` with no `guardrail` field and pass `()` here. Kept so that
    // adding the field back, or a future Mantle class that forwards one, fails loudly
    // instead of silently sending guardrail headers the endpoint ignores.
    if endpoint == MANTLE {
        return error ai:Error("Guardrails are not supported on the bedrock-mantle endpoint. Use the " +
            "matching BedrockRuntime*ModelProvider, or apply the standalone ApplyGuardrail API " +
            "on bedrock-runtime.");
    }
    if api == RESPONSES {
        return error ai:Error("Guardrails do not apply to the Responses API. Use the CONVERSE api " +
            "to guardrail this model, or apply the standalone ApplyGuardrail API.");
    }
    if api == MESSAGES {
        return error ai:Error("Guardrails are not sent on the Anthropic Messages path: AWS documents " +
            "guardrail parameters for Converse, InvokeModel and Chat Completions, but not for " +
            "'/anthropic/v1/messages', so this module will not send them where it cannot confirm " +
            "they are honoured. Use the CONVERSE or INVOKE api, or apply the standalone " +
            "ApplyGuardrail API.");
    }
}

// The shared construction spine: resolve → guard → endpoint →
// converter → transport. Every failure AWS cannot diagnose surfaces here, before any
// I/O. Returns the resolved route (for header/param assembly), the
// converter, and the transport.
isolated function resolveSpine(string providerName, BedrockCredentials credentials,
        Route|error resolved, aws:EndpointConfig? endpointConfig,
        http:ClientConfiguration? httpConfig, RetryConfig? retryConfig, GuardrailConfig? guardrail)
        returns [Route, readonly & ModelConverter, BedrockTransport]|ai:Error {
    do {
        Route route = check resolved; // L1, pure — resolved by the calling class
        // Validate the RESOLVED region, not the argument: an ARN's region segment
        // legitimately supplies it, so an ARN model with no `region` and no AWS_REGION
        // in the environment is well-formed and must not be rejected.
        check guardRegion(route.region);
        check guardGuardrailSupport(route.endpoint, route.api, guardrail);
        Endpoint ep = check buildEndpoint(route, endpointConfig);   // L2, pure
        readonly & ModelConverter converter = check selectConverter(route);
        // CREDENTIALS LAST among the fallible steps. Resolving them can reach the
        // network — IMDSv2, STS AssumeRole, SSO — so doing it here rather than at the
        // top of each provider `init` is what makes "construction errors fire before
        // any I/O" literally true: a bad region, a `custom-model/` ARN, a CRIS prefix
        // on a Mantle class or `fips` on Mantle now all fail without a round trip.
        auth:CredentialProvider|BearerToken resolvedCredentials = check resolveCredentials(credentials);
        BedrockTransport transport =
            check new (resolvedCredentials, route.region, ep, httpConfig, retryConfig);
        return [route, converter, transport];
    } on fail error e {
        if e is ai:Error {
            return e;
        }
        return error ai:Error(string `Failed to initialize ${providerName}: ${e.message()}`, e);
    }
}

// `AdditionalRequestFields` -> a JSON object ready for a request body.
//
// `AdditionalRequestFields` is `record {}`, whose rest type is `anydata` and is
// therefore NOT assignable to `json`. Every wire boundary funnels through here so
// that conversion exists exactly once. `toJson` is TOTAL — it deep-converts anydata
// values that are not already json instead of failing — so this returns no error.
isolated function additionalFieldsToJson(AdditionalRequestFields? fields) returns map<json>? {
    if fields is () {
        return ();
    }
    json converted = fields.toJson();
    return converted is map<json> && converted.length() > 0 ? converted : ();
}

// Folds a vendor's extra request fields into `additionalModelRequestFields`.
// Returns `()` when there is nothing to forward.
isolated function foldRequestFields(AdditionalRequestFields? base, map<json> extras)
        returns AdditionalRequestFields? {
    AdditionalRequestFields merged = {};
    if base is AdditionalRequestFields {
        foreach [string, anydata] [k, v] in base.entries() {
            merged[k] = v;
        }
    }
    foreach [string, json] [k, v] in extras.entries() {
        merged[k] = v;
    }
    return merged.length() > 0 ? merged : ();
}

// Injects the wire model id into a request body. Used by the three vendor-native
// shapes on BOTH endpoints; Converse and InvokeModel name the model in the URL path
// instead. The id is the route's `effectiveModelId`, so it is CRIS-prefixed on
// bedrock-runtime and the Mantle-side id on bedrock-mantle.
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
//
// Image parts are REDACTED to `[image <mime>, <n> bytes]`. A span is shipped to the
// caller's telemetry backend, so putting the payload there would both bloat every
// trace and export user image data to a system that was never meant to hold it.
isolated function messagesForSpan(string? system, ResolvedMessage[] messages) returns json {
    json[] out = [];
    if system is string {
        out.push({role: ai:SYSTEM, content: system});
    }
    foreach ResolvedMessage m in messages {
        if m is ResolvedUserMessage {
            out.push({role: m.role, content: partsForSpan(m.parts)});
        } else if m is ai:ChatAssistantMessage {
            out.push({role: m.role, content: m.content});
        } else {
            out.push({role: m.role, content: m.content, name: m.name});
        }
    }
    return out;
}

// The Claude thinking-budget rules AWS enforces with a 400. Checked before any I/O so
// the message names the actual mistake instead of surfacing as an opaque
// ValidationException.
// https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-extended-thinking.html
// `maxTokens` is `()` when the caller suppressed the field; there is then no ceiling
// on this side to compare the budget against, so that one check is skipped and the
// model enforces its own.
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
