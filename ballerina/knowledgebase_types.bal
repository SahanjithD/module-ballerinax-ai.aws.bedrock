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

import ballerina/http;
import ballerinax/aws.auth;

// Bedrock API keys cannot be used with the agent APIs behind knowledge bases.
// https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-use.html

# Authentication for a Bedrock knowledge base: AWS credentials only, no API key.
public type KnowledgeBaseAuthConfig auth:AuthConfig;

// Fixed for the life of the data source.
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

# The data source created with a new knowledge base.
public type DataSourceDefinition record {|
    # Data source name
    string name;
    # Data source description
    string description?;
|};

// Fixed at creation. Rules out the managed reranker and is billed separately. AWS
// requires 1024 dimensions and FLOAT32.
// https://docs.aws.amazon.com/bedrock/latest/userguide/kb-managed-create.html#kb-managed-embedding-models

# Your own embedding model for a new managed knowledge base.
public type ManagedEmbeddingModel record {|
    # ARN of the embedding model
    @display {label: "Embedding Model ARN"}
    string embeddingModelArn;
    # Vector dimensions. Must be 1024
    int dimensions = 1024;
    # Vector data type. Must be `FLOAT32`
    string embeddingDataType = "FLOAT32";
|};

// `name` must match `([0-9a-zA-Z][_-]?){1,100}`. Without `embeddingModel`, Bedrock's own
// model is used (300-token chunks, 20% overlap). `serviceRoleArn` is sent as `roleArn`.

# A managed knowledge base to find or create by name.
public type ManagedKnowledgeBaseDefinition record {|
    # Knowledge base name, also used to find an existing one
    string name;
    # Knowledge base description
    string description?;
    # ARN of the IAM role Bedrock uses to manage this knowledge base
    @display {label: "Service Role ARN"}
    string serviceRoleArn;
    # The data source created with the knowledge base
    DataSourceDefinition dataSource = {name: "ballerina-custom-source"};
    # Your own embedding model. Defaults to Bedrock's managed model
    ManagedEmbeddingModel embeddingModel?;
    # ARN of your own AWS KMS key to encrypt the knowledge base's stored data.
    # Unset uses a key AWS owns and manages
    @display {label: "KMS Key ARN"}
    string kmsKeyArn?;
    # Seconds to wait for a new knowledge base to become ready
    decimal readyTimeout = 300;
|};

# Configuration for `ManagedKnowledgeBase`.
public type ManagedKnowledgeBaseConfig record {|
    # Seconds to wait for documents to be indexed
    decimal ingestTimeout = 300;
    # Default number of results per retrieval (1-100)
    int numberOfResults?;
    # HTTP client configuration
    http:ClientConfiguration httpConfig?;
    # Retry configuration
    RetryConfig retryConfig?;
|};
