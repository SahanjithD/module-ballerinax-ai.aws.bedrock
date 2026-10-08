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

// Public surface for `ManagedKnowledgeBase`: configuration, the
// find-or-create definition, and the chunking-strategy enum. See
// knowledgebase_common.bal for the resolution spine and knowledgebase_managed.bal
// for the public class.

// Set on `CreateDataSource` and fixed for the life of the data source.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_ChunkingConfiguration.html

# How Bedrock splits ingested documents into chunks.
public enum ChunkingStrategy {
    # Fixed-size chunks. The default
    FIXED_SIZE,
    # Large parent chunks with smaller child chunks
    HIERARCHICAL,
    # Chunks by grouping semantically similar content
    SEMANTIC,
    # One chunk per document; chunk client-side with an `ai:Chunker`
    NONE
}

// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_ManagedSearchConfiguration.html

# Reranking model used for retrieval.
public enum RerankingModelType {
    # No reranking
    RERANKING_NONE = "NONE",
    # Bedrock's managed reranking model
    RERANKING_MANAGED = "MANAGED"
}

// The `CUSTOM` direct-ingestion data source created alongside a knowledge base in
// the find-or-create (`KnowledgeBaseDefinition`) path.

# The data source created with a new knowledge base.
public type DataSourceDefinition record {|
    # Data source name
    string name;
    # Data source description
    string description?;
|};

// Replaces Bedrock's service-managed embedding model. `embeddingModelType` cannot be
// changed after creation. Choosing one also opts out of the managed reranker
// (`RERANKING_MANAGED`) and bills the model separately from the knowledge base.
// AWS supports Amazon Titan Text Embeddings V2, Cohere Embed English v3, Cohere Embed
// Multilingual v3, Cohere Embed v4, and Amazon Nova Multimodal Embeddings here, and
// requires 1024 dimensions and FLOAT32.
// https://docs.aws.amazon.com/bedrock/latest/userguide/kb-managed-create.html#kb-managed-embedding-models

# Your own embedding model for a new managed knowledge base.
public type ManagedEmbeddingModel record {|
    # Embedding model ARN
    string embeddingModelArn;
    # Vector dimensions. Must be 1024
    int dimensions = 1024;
    # Vector data type. Must be `FLOAT32`
    string embeddingDataType = "FLOAT32";
|};

// `init` searches `ListKnowledgeBases` for an exact name match: one match attaches to
// it, no match creates it, more than one is a construction error. `name` must match
// `([0-9a-zA-Z][_-]?){1,100}`. Leaving `embeddingModel` unset uses Bedrock's
// service-managed model (no extra cost, chunking fixed at 300 tokens / 20% overlap);
// setting it is permanent — read `ManagedEmbeddingModel` first.

# A managed knowledge base to find or create by name.
public type KnowledgeBaseDefinition record {|
    # Knowledge base name, also used to find an existing one
    string name;
    # IAM role Bedrock assumes to manage the knowledge base
    string roleArn;
    # Knowledge base description
    string description?;
    # The data source created with the knowledge base
    DataSourceDefinition dataSource = {name: "ballerina-custom-source"};
    # Your own embedding model. Defaults to Bedrock's managed model
    ManagedEmbeddingModel embeddingModel?;
    # KMS key ARN for the vector store. Defaults to an AWS-owned key
    string kmsKeyArn?;
    # Seconds to wait for a new knowledge base to become ready
    decimal readyTimeout = 300;
|};

// `dataSourceId` is resolved automatically when omitted, which requires exactly one
// `CUSTOM` data source on the knowledge base. `chunker` left unset is detected from the
// data source's actual `chunkingStrategy` (`ai:DISABLE` unless it is `NONE`, in which
// case `ai:AUTO`); an explicit `ai:Chunker` against a server-chunking data source is a
// construction error. `httpConfig`/`retryConfig` are shared by both agent-plane clients.

# Configuration for `ManagedKnowledgeBase`.
public type ManagedKnowledgeBaseConfig record {|
    # The `CUSTOM` data source to use. Detected when unset
    string dataSourceId?;
    # Client-side chunker. Detected from the data source when unset
    ai:Chunker|ai:AUTO|ai:DISABLE chunker?;
    # Seconds to wait for documents to be indexed
    decimal ingestTimeout = 300;
    # Default number of results per retrieval (1-100)
    int numberOfResults?;
    # Reranking model for retrieval
    RerankingModelType rerankingModelType?;
    # HTTP client configuration
    http:ClientConfiguration httpConfig?;
    # Retry configuration
    RetryConfig retryConfig?;
|};
