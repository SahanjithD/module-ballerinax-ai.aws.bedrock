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

// TitanEmbeddingProvider.

const string TITAN_EMBED_PREFIX = "amazon.titan-embed";

// Titan takes one text per call, so `batchEmbed` of n chunks is n requests.

# Amazon Titan text embeddings on AWS Bedrock.
@display {label: "Bedrock Titan Embedding Provider"}
public distinct isolated client class TitanEmbeddingProvider {
    *ai:EmbeddingProvider;

    private final string wireModelId;
    private final readonly & EmbeddingConverter converter;
    private final BedrockTransport transport;
    private final readonly & EmbeddingParams params;

    # + model - A Titan embedding model id, or any id string the endpoint serves
    # + auth - AWS credentials or a Bedrock API key; `auth:DEFAULT_CREDENTIALS` uses the default chain
    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + endpoint - FIPS, dual-stack or custom-endpoint options. Derived from the region when unset
    # + config - Vector size, normalization and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} TitanEmbeddingModelNames|string model,
            @display {label: "Authentication"} BedrockAuthConfig auth,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Embedding Configuration"} *TitanEmbeddingConfig config)
            returns ai:Error? {
        [string, BedrockTransport] [wireModelId, transport] =
            check resolveEmbeddingSpine("TitanEmbeddingProvider", auth, model, region, endpoint,
                TITAN_EMBED_PREFIX, TITAN_EMBED_TEXT_V2,
                config?.httpConfig, config?.retryConfig);

        self.wireModelId = wireModelId;
        self.converter = TITAN_EMBED_CONVERTER;
        self.transport = transport;

        EmbeddingParams params = {};
        int? dimensions = config?.dimensions;
        if dimensions is int {
            // At construction. V2 takes three widths; V1 none. The id may carry a
            // cross-region prefix.
            // https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-titan-embed-text.html
            if isTitanEmbedV1(wireModelId) {
                return error ai:Error(
                    string `'dimensions' is not supported by Titan Embed V1 ('${wireModelId}'), which ` +
                    string `always returns 1536-dimension vectors. Use 'amazon.titan-embed-text-v2:0'.`);
            }
            if dimensions != 256 && dimensions != 512 && dimensions != 1024 {
                return error ai:Error(
                    string `Titan Embed V2 accepts 'dimensions' of 256, 512 or 1024; got ${dimensions}.`);
            }
            params.dimensions = dimensions;
        }
        boolean? normalize = config?.normalize;
        if normalize is boolean {
            params.normalize = normalize;
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
        => runEmbed(self.wireModelId, self.converter, self.transport, self.params, chunk);

    # Converts a batch of chunks into vector embeddings, preserving input order.
    #
    # + chunks - The chunks to convert; each must be an `ai:TextChunk` or `ai:TextDocument`
    # + return - The embeddings in input order, or an `ai:Error`
    isolated remote function batchEmbed(ai:Chunk[] chunks) returns ai:Embedding[]|ai:Error
        => runBatchEmbed(self.wireModelId, self.converter, self.transport, self.params, chunks);
}
