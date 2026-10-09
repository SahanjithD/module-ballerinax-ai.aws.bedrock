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
import ballerina/http;

// Embeddings are InvokeModel only, so there is no API choice; the transport, signing
// and retries are shared with the model providers.

// https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-titan-embed-text.html

# Amazon Titan text embedding model IDs.
public enum TitanEmbeddingModelNames {
    TITAN_EMBED_TEXT_V2 = "amazon.titan-embed-text-v2:0",
    TITAN_EMBED_TEXT_V1 = "amazon.titan-embed-text-v1"
}

// https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-embed.html

# Cohere Embed model IDs.
public enum CohereEmbeddingModelNames {
    COHERE_EMBED_ENGLISH_V3 = "cohere.embed-english-v3",
    COHERE_EMBED_MULTILINGUAL_V3 = "cohere.embed-multilingual-v3",
    COHERE_EMBED_V4 = "cohere.embed-v4:0"
}

// Cohere requires `input_type` on every request. Getting it wrong silently
// degrades retrieval — there is no error, just worse results.

# How Cohere should treat the input: `SEARCH_DOCUMENT` for the corpus, `SEARCH_QUERY` for queries.
public enum CohereInputType {
    SEARCH_DOCUMENT = "search_document",
    SEARCH_QUERY = "search_query",
    CLASSIFICATION = "classification",
    CLUSTERING = "clustering"
}

// Members are prefixed because a bare `NONE` would collide with `GuardrailAction`.

# How Cohere truncates over-long inputs.
public enum Truncate {
    TRUNCATE_NONE = "NONE",
    TRUNCATE_START = "START",
    TRUNCATE_END = "END"
}

# Titan-specific embedding configuration.
public type TitanEmbeddingConfig record {|
    // `int` rather than `256|512|1024`: V1 takes no `dimensions`, so the construction
    // check is needed anyway, and a `configurable int` would not assign to a union.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-titan-embed-text.html
    # Output vector size: 256, 512 or 1024 (Titan V2 only). Defaults to 1024
    int dimensions?;
    # Whether to L2-normalize the returned vector
    boolean normalize?;
    # Extra fields sent verbatim in the request body
    AdditionalRequestFields additionalModelRequestFields?;
    # Retry settings
    RetryConfig retryConfig?;
    # HTTP client settings, such as timeouts and proxy
    http:ClientConfiguration httpConfig?;
|};

// `inputType` lives ONLY here, which is why the model provider's "inputType set
// on Titan → error" check is gone: with the vendor split it is unrepresentable.

# Cohere-specific embedding configuration.
public type CohereEmbeddingConfig record {|
    // Required by Cohere. Unset, it follows how `ai:VectorKnowledgeBase` calls the
    // provider: `embed()` for queries, `batchEmbed()` for documents.
    # Input type for every call. Unset: queries for `embed`, documents for `batchEmbed`
    CohereInputType inputType?;
    # How over-long inputs are truncated
    Truncate truncate?;
    // `int` for the same reason as Titan's. Embed v3 always returns 1024.
    // https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-embed-v4.html
    # Output vector size: 256, 512, 1024 or 1536 (Embed v4 only). Defaults to 1536
    int dimensions?;
    # Extra fields sent verbatim in the request body
    AdditionalRequestFields additionalModelRequestFields?;
    # Retry settings
    RetryConfig retryConfig?;
    # HTTP client settings, such as timeouts and proxy
    http:ClientConfiguration httpConfig?;
|};

# Resolved embedding parameters, fixed at construction.
# Module-private: built at construction and consumed only by the internal converters.
type EmbeddingParams record {|
    # Output vector size.
    int dimensions?;
    # Titan only.
    boolean normalize?;
    # Cohere only — required on the wire.
    CohereInputType inputType?;
    # Cohere only.
    Truncate truncate?;
    # Escape-hatch passthrough, mirroring the model provider's passthrough.
    AdditionalRequestFields additionalModelRequestFields?;
|};

# What an embedding decode produces. Cohere returns no token count, so
# `inputTokenCount` can be `()`.
type DecodedEmbedding record {|
    # One embedding per input text, in input order.
    ai:Embedding[] embeddings;
    # Titan: `inputTextTokenCount`. Cohere: absent → `()`.
    int? inputTokenCount;
    # Cohere: `id`. Titan: absent → `()`.
    string? responseId;
|};

# Encodes a window of texts into a request body.
# Module-private converter plumbing.
type EncodeEmbedRequest isolated function (string[] texts, EmbeddingParams params)
    returns json|ai:Error;

# Decodes an embedding response. Module-private converter plumbing.
type DecodeEmbedResponse isolated function (json response) returns DecodedEmbedding|ai:Error;

# An embedding converter. `maxBatchSize` is the wire limit: 1 for Titan, 96 for Cohere.
type EmbeddingConverter record {|
    # Texts per request the wire allows — Titan 1, Cohere 96. One window == one call.
    int maxBatchSize;
    # Texts → request body.
    EncodeEmbedRequest encode;
    # Wire JSON → `DecodedEmbedding`.
    DecodeEmbedResponse decode;
|};
