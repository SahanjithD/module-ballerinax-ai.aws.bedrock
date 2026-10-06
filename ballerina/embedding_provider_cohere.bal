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
import ballerinax/aws;

// CohereEmbeddingProvider.

const string COHERE_EMBED_PREFIX = "cohere.embed";

// `inputType` is fixed at construction and matters. Embed the corpus with
// `SEARCH_DOCUMENT` and queries with `SEARCH_QUERY`, using one provider per
// role — getting it backwards degrades retrieval silently, with no error.

# Cohere Embed text embeddings on AWS Bedrock.
@display {label: "Bedrock Cohere Embedding Provider"}
public distinct isolated client class CohereEmbeddingProvider {
    *ai:EmbeddingProvider;

    private final string wireModelId;
    private final readonly & EmbeddingConverter converter;
    private final BedrockTransport transport;
    private final readonly & EmbeddingParams params;

    # + model - A Cohere Embed model id, or any id string the endpoint serves
    # + credentials - AWS credentials, or `auth:DEFAULT_CREDENTIALS` for the default chain
    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + endpoint - FIPS, dual-stack or custom-endpoint options. Derived from the region when unset
    # + config - Input type, truncation, vector size and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} CohereEmbeddingModel|string model,
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Embedding Configuration"} *CohereEmbeddingConfig config)
            returns ai:Error? {
        [string, BedrockTransport] [wireModelId, transport] =
            check resolveEmbeddingSpine("CohereEmbeddingProvider", credentials, model, region, endpoint,
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

    // Sends up to 96 texts per request (Cohere's `texts` limit).
    # Converts a batch of chunks into vector embeddings, preserving input order.
    #
    # + chunks - The chunks to convert; each must be an `ai:TextChunk` or `ai:TextDocument`
    # + return - The embeddings in input order, or an `ai:Error`
    isolated remote function batchEmbed(ai:Chunk[] chunks) returns ai:Embedding[]|ai:Error
        => runBatchEmbed("Cohere", self.wireModelId, self.converter, self.transport, self.params, chunks);
}
