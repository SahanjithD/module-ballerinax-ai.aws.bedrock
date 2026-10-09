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

// Shared embedding code. Batching lives here because the wire limits differ (Titan 1,
// Cohere 96).

// Embeddings are InvokeModel only. A cross-region prefix is still stripped for lookup,
// since Cohere Embed v4 has `us.` ids.
isolated function resolveEmbeddingSpine(string providerName, BedrockAuthConfig credentials,
        string model, string region, aws:EndpointConfig? endpointConfig, string familyPrefix,
        string exampleId, http:ClientConfiguration? httpConfig, RetryConfig? retryConfig)
        returns [string, BedrockTransport]|ai:Error {
    do {
        // Embeddings take a bare model id, never an ARN, so the region can only come
        // from the argument — there is no ARN segment to fall back on.
        check guardRegion(region);
        // v1: ARNs are out of scope — an ARN carries no vendor prefix, so no converter
        // can be resolved from it.
        if isArn(model) {
            return error ai:Error("provisioned-model ARNs are not supported for embeddings; " +
                "pass the base model id");
        }
        [string, string?] [bareId, geoPrefix] = normalizeModelId(model);
        if !bareId.startsWith(familyPrefix) {
            return error ai:Error(string `'${model}' is not a ${providerName} model; supported ids ` +
                string `start with '${familyPrefix}' (e.g. '${exampleId}')`);
        }
        // Embeddings: InvokeModel only — no Converse equivalent, no streaming.
        Route route = {
            endpoint: RUNTIME,
            api: INVOKE,
            bareModelId: bareId,
            geoPrefix,
            effectiveModelId: applyGeoPrefix(bareId, geoPrefix), // CRIS restored on the wire
            region,
            partition: partitionForRegion(region),
            mantleEntry: ()
        };
        Endpoint ep = check buildEndpoint(route, endpointConfig);
        BedrockTransport transport =
            check new (check resolveCredentials(credentials), route.region, ep, httpConfig, retryConfig);
        return [route.effectiveModelId, transport];
    } on fail error e {
        if e is ai:Error {
            return e;
        }
        return error ai:Error(string `Failed to initialize ${providerName}: ${e.message()}`, e);
    }
}

// `batchEmbed`: splits the texts into wire-sized windows and puts the results back in
// input order.
isolated function runBatchEmbed(string wireModelId,
        readonly & EmbeddingConverter converter, ModelTransport transport,
        readonly & EmbeddingParams params, ai:Chunk[] chunks) returns ai:Embedding[]|ai:Error {
    observe:EmbeddingSpan span = observe:createEmbeddingSpan(wireModelId);
    span.addProvider(BEDROCK_PROVIDER_NAME);

    // The scope boundary is the contract's, not ours: ai:Chunk carries text.
    if !isAllTextChunks(chunks) {
        ai:Error err = error ai:Error(
            "Unsupported chunk type. Expected elements of type 'ai:TextChunk|ai:TextDocument'.");
        span.close(err);
        return err;
    }
    string[] texts = chunks.map(chunk => chunk.content.toString());
    span.addInputContent(texts);

    ai:Embedding[] result = [];
    int totalTokens = 0;
    boolean sawTokens = false;
    int index = 0;
    // Titan (maxBatchSize 1) → n windows; Cohere (96) → ceil(n/96) windows.
    foreach string[] window in partitionTexts(texts, converter.maxBatchSize) {
        EncodeEmbedRequest encode = converter.encode;
        json|ai:Error body = encode(window, params);
        if body is ai:Error {
            span.close(body);
            return body;
        }
        TransportResponse|ai:Error response = transport.execute(body);
        if response is ai:Error {
            span.close(response);
            return response;
        }
        DecodeEmbedResponse decode = converter.decode;
        DecodedEmbedding|ai:Error decoded = decode(response.body);
        if decoded is ai:Error {
            span.close(decoded);
            return decoded;
        }
        if decoded.embeddings.length() != window.length() {
            ai:Error err = error ai:LlmInvalidResponseError(
                string `expected ${window.length()} embedding(s), got ${decoded.embeddings.length()}`);
            span.close(err);
            return err;
        }
        // ORDER IS THE CONTRACT — reassemble by absolute index.
        foreach int offset in 0 ..< decoded.embeddings.length() {
            result[index + offset] = decoded.embeddings[offset];
        }
        int? tokens = decoded.inputTokenCount;
        if tokens is int {
            totalTokens += tokens;
            sawTokens = true;
        }
        index += window.length();
    }

    span.addResponseModel(wireModelId);
    // Cohere reports no token count — guard the span call.
    if sawTokens {
        span.addInputTokenCount(totalTokens);
    }
    span.close();
    return result;
}

// `embed` is just `batchEmbed([chunk])[0]` — exactly one code path.
isolated function runEmbed(string wireModelId, readonly & EmbeddingConverter converter,
        ModelTransport transport, readonly & EmbeddingParams params, ai:Chunk chunk)
        returns ai:Embedding|ai:Error {
    ai:Embedding[] embeddings =
        check runBatchEmbed(wireModelId, converter, transport, params, [chunk]);
    if embeddings.length() == 0 {
        return error ai:LlmInvalidResponseError("No embedding was generated for the provided chunk");
    }
    return embeddings[0];
}

// Splits texts into wire-sized windows, one request each.
isolated function partitionTexts(string[] texts, int maxBatchSize) returns string[][] {
    string[][] windows = [];
    int index = 0;
    while index < texts.length() {
        int end = index + maxBatchSize;
        if end > texts.length() {
            end = texts.length();
        }
        windows.push(texts.slice(index, end));
        index = end;
    }
    return windows;
}

// `true` when every chunk carries text.
isolated function isAllTextChunks(ai:Chunk[] chunks) returns boolean
    => chunks.every(chunk => chunk is ai:TextChunk|ai:TextDocument);

// Converts a JSON number array to an `ai:Vector` (`float[]`).
isolated function toVector(json[] raw) returns ai:Vector|ai:Error {
    float[] vector = [];
    foreach json value in raw {
        if value is float {
            vector.push(value);
        } else if value is int {
            vector.push(<float>value);
        } else if value is decimal {
            vector.push(<float>value);
        } else {
            return error ai:LlmInvalidResponseError("embedding contained a non-numeric value");
        }
    }
    return vector;
}
