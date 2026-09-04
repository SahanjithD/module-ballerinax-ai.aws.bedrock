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

# Amazon Titan text embeddings on AWS Bedrock (InvokeModel only).
#
# NOTE: Titan's `inputText` is a single string, so there is no batch input at all —
# `batchEmbed` of n chunks is n sequential round trips. That is Bedrock's
# constraint, not ours; for large corpora AWS's own recommendation is an
# asynchronous batch-inference job, which is outside the `ai:EmbeddingProvider`
# contract.
public distinct isolated client class TitanEmbeddingProvider {
    *ai:EmbeddingProvider;

    private final string wireModelId;
    private final readonly & EmbeddingConverter converter;
    private final BedrockTransport transport;
    private final readonly & EmbeddingParams params;

    # + model - A Titan embedding id, or a raw id for a model AWS ships before we update the enum
    # + credentials - AWS credential source. Pass `auth:DEFAULT_CREDENTIALS` for the full
    #                 AWS chain (env vars, EKS IRSA, SSO, shared config, EC2 IMDSv2), an
    #                 `auth:StaticAuthConfig`/`auth:AssumeRoleConfig`/... for an explicit
    #                 source, or a `BearerToken` for a Bedrock API key
    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + config - `dimensions`, `normalize`, retry, and HTTP settings
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Model"} TitanEmbeddingModel|string model,
            @display {label: "AWS Credentials"} BedrockCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Embedding Configuration"} *TitanEmbeddingConfig config)
            returns ai:Error? {
        [string, BedrockTransport] [wireModelId, transport] =
            check resolveEmbeddingSpine("TitanEmbeddingProvider", credentials, model, region, config?.endpoint,
                TITAN_EMBED_PREFIX, TITAN_EMBED_TEXT_V2,
                config?.httpConfig, config?.retryConfig);

        self.wireModelId = wireModelId;
        self.converter = TITAN_EMBED_CONVERTER;
        self.transport = transport;

        EmbeddingParams params = {};
        int? dimensions = config?.dimensions;
        if dimensions is int {
            // Fail at construction, not per call. Titan V2
            // accepts exactly three widths; V1 has no such parameter at all.
            // https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-titan-embed-text.html
            // Normalize first: `wireModelId` may carry a CRIS geo prefix, and a raw
            // `startsWith` would skip this guard for a prefixed id.
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
        => runEmbed("Amazon", self.wireModelId, self.converter, self.transport, self.params, chunk);

    # Converts a batch of chunks into vector embeddings, preserving input order.
    #
    # + chunks - The chunks to convert; each must be an `ai:TextChunk` or `ai:TextDocument`
    # + return - The embeddings in input order, or an `ai:Error`
    isolated remote function batchEmbed(ai:Chunk[] chunks) returns ai:Embedding[]|ai:Error
        => runBatchEmbed("Amazon", self.wireModelId, self.converter, self.transport, self.params, chunks);
}
