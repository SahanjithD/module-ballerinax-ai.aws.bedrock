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

// CohereEmbeddingProvider.

const string COHERE_EMBED_PREFIX = "cohere.embed";

# Cohere Embed on AWS Bedrock (InvokeModel only).
#
# **`inputType` is the retrieval-quality landmine.** Cohere requires `input_type`
# on every request, and the `ai:EmbeddingProvider` contract has nowhere to express
# it per call — so it is fixed at construction. Embed your corpus with
# `SEARCH_DOCUMENT` and your queries with `SEARCH_QUERY`, constructing one provider
# per role. Getting it backwards degrades retrieval **silently** — no error, just
# worse results.
#
# ```ballerina
# final ai:EmbeddingProvider ingest = check new CohereEmbeddingProvider(
#     creds, COHERE_EMBED_ENGLISH_V3, "us-east-1", inputType = SEARCH_DOCUMENT);
# final ai:EmbeddingProvider query = check new CohereEmbeddingProvider(
#     creds, COHERE_EMBED_ENGLISH_V3, "us-east-1", inputType = SEARCH_QUERY);
# ```
public distinct isolated client class CohereEmbeddingProvider {
    *ai:EmbeddingProvider;

    private final string wireModelId;
    private final readonly & EmbeddingConverter converter;
    private final BedrockTransport transport;
    private final readonly & EmbeddingParams params;

    # + credentials - Static keys, STS, or a Bedrock API key
    # + model - A Cohere Embed id, or a raw id for a model AWS ships before we update the enum
    # + region - The AWS region; also the SigV4 signing scope, which a custom
    #            `serviceUrl` does NOT change
    # + serviceUrl - Endpoint origin. The default template resolves to
    #                `bedrock-runtime.{region}.{domain}` — embeddings are InvokeModel-only.
    #                Pass a concrete URL for a FIPS, dual-stack or PrivateLink host
    # + config - `inputType` (**see the class docs**), `truncate`, `dimensions`, retry, HTTP settings
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Model"} CohereEmbeddingModel|string model,
            @display {label: "Region"} string region,
            @display {label: "Service URL"} string serviceUrl = DEFAULT_SERVICE_URL,
            @display {label: "Embedding Configuration"} *CohereEmbeddingConfig config)
            returns ai:Error? {
        [string, BedrockTransport] [wireModelId, transport] =
            check resolveEmbeddingSpine("CohereEmbeddingProvider", credentials, model, region, serviceUrl,
                COHERE_EMBED_PREFIX, COHERE_EMBED_ENGLISH_V3,
                config?.httpConfig, config?.retryConfig);

        self.wireModelId = wireModelId;
        // Two request shapes under one vendor prefix; the id is the only
        // discriminator (see converter_embed_cohere.bal).
        boolean isV4 = usesCohereEmbedV4(wireModelId);
        self.converter = isV4 ? COHERE_EMBED_V4_CONVERTER : COHERE_EMBED_V3_CONVERTER;
        self.transport = transport;

        // `inputType` always has a value (defaults to SEARCH_DOCUMENT) — Cohere
        // requires it on every request.
        EmbeddingParams params = {inputType: config.inputType};
        Truncate? truncate = config?.truncate;
        if truncate is Truncate {
            params.truncate = truncate;
        }
        int? dimensions = config?.dimensions;
        if dimensions is int {
            // Fail at construction, not per call. Silently
            // dropping this would be worse than a 400: the caller would index a
            // corpus at the wrong width and only discover it at query time.
            if !isV4 {
                return error ai:Error(
                    string `'dimensions' is not supported by Cohere Embed v3 ('${wireModelId}') — the ` +
                    string `model has no output-size parameter and always returns 1024-dimension ` +
                    string `vectors. Use 'cohere.embed-v4:0' if you need a configurable width.`);
            }
            if dimensions != 256 && dimensions != 512 && dimensions != 1024 && dimensions != 1536 {
                return error ai:Error(
                    string `Cohere Embed v4 accepts 'dimensions' of 256, 512, 1024 or 1536; got ${dimensions}.`);
            }
            params.dimensions = dimensions;
        }
        AdditionalRequestFields? additional = config?.additionalModelRequestFields;
        if additional != () {
            params.additionalModelRequestFields = additional;
        }
        self.params = params.cloneReadOnly();
    }

    # Converts the given chunk into a vector embedding.
    #
    # + chunk - The chunk to convert; must be an `ai:TextChunk` or `ai:TextDocument`
    # + return - The embedding vector, or an `ai:Error`
    isolated remote function embed(ai:Chunk chunk) returns ai:Embedding|ai:Error
        => runEmbed("Cohere", self.wireModelId, self.converter, self.transport, self.params, chunk);

    # Converts a batch of chunks into vector embeddings, preserving input order.
    # Batches of up to 96 texts per request.
    #
    # + chunks - The chunks to convert; each must be an `ai:TextChunk` or `ai:TextDocument`
    # + return - The embeddings in input order, or an `ai:Error`
    isolated remote function batchEmbed(ai:Chunk[] chunks) returns ai:Embedding[]|ai:Error
        => runBatchEmbed("Cohere", self.wireModelId, self.converter, self.transport, self.params, chunks);
}
