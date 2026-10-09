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

// Public types for `SelfManagedKnowledgeBase`, whose vector store is the caller's.
// Kept apart from knowledgebase_types.bal: the two types share no configuration record.

// ============================================================================
// Field mappings: one record per backend, as in the service model, because they
// differ (Pinecone and Neptune have no `vectorField`; RDS adds a primary key).
// ============================================================================

// OpenSearch Serverless and Managed Cluster declare identical shapes.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_OpenSearchServerlessFieldMapping.html

# Field names in an Amazon OpenSearch vector index.
public type OpenSearchFieldMapping record {|
    # Field holding the vector embeddings
    string vectorField;
    # Field holding the raw text chunk
    string textField;
    # Field holding the metadata Bedrock manages
    string metadataField;
|};

// Pinecone stores the vector itself, so there is no `vectorField`.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_PineconeFieldMapping.html

# Field names in a Pinecone index.
public type PineconeFieldMapping record {|
    # Field holding the raw text chunk
    string textField;
    # Field holding the metadata Bedrock manages
    string metadataField;
|};

// No `vectorField`, like Pinecone.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_NeptuneAnalyticsFieldMapping.html

# Field names in a Neptune Analytics graph.
public type NeptuneAnalyticsFieldMapping record {|
    # Field holding the raw text chunk
    string textField;
    # Field holding the metadata Bedrock manages
    string metadataField;
|};

// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_MongoDbAtlasFieldMapping.html

# Field names in a MongoDB Atlas collection.
public type MongoDbAtlasFieldMapping record {|
    # Field holding the vector embeddings
    string vectorField;
    # Field holding the raw text chunk
    string textField;
    # Field holding the metadata Bedrock manages
    string metadataField;
|};

// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_RedisEnterpriseCloudFieldMapping.html

# Field names in a Redis Enterprise Cloud index.
public type RedisEnterpriseCloudFieldMapping record {|
    # Field holding the vector embeddings
    string vectorField;
    # Field holding the raw text chunk
    string textField;
    # Field holding the metadata Bedrock manages
    string metadataField;
|};

// `customMetadataField` holds your metadata as one `jsonb` value, which metadata
// filtering needs; otherwise add one column per attribute.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_RdsFieldMapping.html

# Column names in an Amazon Aurora PostgreSQL table.
public type RdsFieldMapping record {|
    # Primary key column
    string primaryKeyField;
    # Column holding the vector embeddings
    string vectorField;
    # Column holding the raw text chunk
    string textField;
    # Column holding the metadata Bedrock manages
    string metadataField;
    # `jsonb` column holding your metadata, needed for metadata filtering
    string customMetadataField?;
|};

// ============================================================================
// Storage configurations, one per backend, told apart by `'type`. Each names a store
// that must already exist: the API cannot create one.
// https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base-create.html
// ============================================================================

// Metadata filtering needs the `faiss` engine, not `nmslib`.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_OpenSearchServerlessConfiguration.html

# An Amazon OpenSearch Serverless vector store.
public type OpenSearchServerlessStorage record {|
    # Storage type
    readonly "OPENSEARCH_SERVERLESS" 'type = "OPENSEARCH_SERVERLESS";
    # ARN of the vector search collection
    string collectionArn;
    # Name of the vector index in the collection
    string vectorIndexName;
    # Field names in the index
    OpenSearchFieldMapping fieldMapping;
|};

// Needs a public-access domain and engine 2.13+.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_OpenSearchManagedClusterConfiguration.html

# An Amazon OpenSearch Service managed cluster vector store.
public type OpenSearchManagedClusterStorage record {|
    # Storage type
    readonly "OPENSEARCH_MANAGED_CLUSTER" 'type = "OPENSEARCH_MANAGED_CLUSTER";
    # Endpoint of the OpenSearch domain
    string domainEndpoint;
    # ARN of the OpenSearch domain
    string domainArn;
    # Name of the vector index in the domain
    string vectorIndexName;
    # Field names in the index
    OpenSearchFieldMapping fieldMapping;
|};

// Semantic search and float vectors only, with up to 1 KB / 35 keys of metadata per
// vector. Name the index by `indexArn`, or by `vectorBucketArn` plus `indexName`.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_S3VectorsConfiguration.html

# An Amazon S3 Vectors vector store.
public type S3VectorsStorage record {|
    # Storage type
    readonly "S3_VECTORS" 'type = "S3_VECTORS";
    # ARN of the vector bucket. Use with `indexName`
    string vectorBucketArn?;
    # ARN of the vector index
    string indexArn?;
    # Name of the vector index. Use with `vectorBucketArn`
    string indexName?;
|};

// Must be in the same AWS account as the knowledge base.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_RdsConfiguration.html

# An Amazon Aurora PostgreSQL vector store.
public type RdsStorage record {|
    # Storage type
    readonly "RDS" 'type = "RDS";
    # ARN of the Aurora DB cluster
    string resourceArn;
    # ARN of the Secrets Manager secret holding the database credentials
    string credentialsSecretArn;
    # Database name
    string databaseName;
    # Table holding the vectors
    string tableName;
    # Column names in the table
    RdsFieldMapping fieldMapping;
|};

// The vector index is created with the graph, and its dimension must match the model.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_NeptuneAnalyticsConfiguration.html

# An Amazon Neptune Analytics vector store.
public type NeptuneAnalyticsStorage record {|
    # Storage type
    readonly "NEPTUNE_ANALYTICS" 'type = "NEPTUNE_ANALYTICS";
    # ARN of the Neptune Analytics graph
    string graphArn;
    # Field names in the graph
    NeptuneAnalyticsFieldMapping fieldMapping;
|};

// The secret holds the Pinecone API key under `apiKey`.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_PineconeConfiguration.html

# A Pinecone vector store.
public type PineconeStorage record {|
    # Storage type
    readonly "PINECONE" 'type = "PINECONE";
    # Endpoint URL of the Pinecone index
    string connectionString;
    # ARN of the Secrets Manager secret holding the Pinecone API key
    string credentialsSecretArn;
    # Namespace to write to. Defaults to the default namespace
    string namespace?;
    # Field names in the index
    PineconeFieldMapping fieldMapping;
|};

// Needs TLS; the secret holds `username`, `password`, `serverCertificate`,
// `clientPrivateKey` and `clientCertificate`.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_RedisEnterpriseCloudConfiguration.html

# A Redis Enterprise Cloud vector store.
public type RedisEnterpriseCloudStorage record {|
    # Storage type
    readonly "REDIS_ENTERPRISE_CLOUD" 'type = "REDIS_ENTERPRISE_CLOUD";
    # Public endpoint URL of the database
    string endpoint;
    # Name of the vector index
    string vectorIndexName;
    # ARN of the Secrets Manager secret holding the credentials and certificates
    string credentialsSecretArn;
    # Field names in the index
    RedisEnterpriseCloudFieldMapping fieldMapping;
|};

// Metadata filters must be set up in the Atlas vector index first. `textIndexName` is
// needed for hybrid search.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_MongoDbAtlasConfiguration.html

# A MongoDB Atlas vector store.
public type MongoDbAtlasStorage record {|
    # Storage type
    readonly "MONGO_DB_ATLAS" 'type = "MONGO_DB_ATLAS";
    # Endpoint URL of the Atlas cluster
    string endpoint;
    # Database name
    string databaseName;
    # Collection name
    string collectionName;
    # Name of the Atlas vector search index
    string vectorIndexName;
    # ARN of the Secrets Manager secret holding `username` and `password`
    string credentialsSecretArn;
    # VPC endpoint service name, when connecting over AWS PrivateLink
    string endpointServiceName?;
    # Name of the Atlas text search index, needed for hybrid search
    string textIndexName?;
    # Field names in the collection
    MongoDbAtlasFieldMapping fieldMapping;
|};

# An existing vector store backing a self-managed knowledge base.
public type StorageConfiguration OpenSearchServerlessStorage|OpenSearchManagedClusterStorage|
    S3VectorsStorage|RdsStorage|NeptuneAnalyticsStorage|PineconeStorage|
    RedisEnterpriseCloudStorage|MongoDbAtlasStorage;

// ============================================================================
// Embedding model, search type, reranking.
// ============================================================================

// S3 Vectors takes only `EMBEDDING_FLOAT32`; `EMBEDDING_BINARY` is OpenSearch only.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_BedrockEmbeddingModelConfiguration.html

# Vector data type for the embedding model.
public enum EmbeddingDataType {
    # Floating-point vectors. The default
    EMBEDDING_FLOAT32 = "FLOAT32",
    # Binary vectors. OpenSearch only
    EMBEDDING_BINARY = "BINARY"
}

// `dimensions` must match the vector index, or ingestion fails.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_BedrockEmbeddingModelConfiguration.html

# Embedding model settings for a self-managed knowledge base.
public type VectorEmbeddingModelConfig record {|
    # Vector dimensions. Must match the vector index
    int dimensions?;
    # Vector data type
    EmbeddingDataType embeddingDataType?;
|};

// Hybrid search is not available on S3 Vectors, Neptune Analytics, Pinecone or Redis.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_KnowledgeBaseVectorSearchConfiguration.html

# Search strategy used for retrieval.
public enum SearchType {
    # Vector and keyword search combined. Not supported on every backend
    SEARCH_HYBRID = "HYBRID",
    # Vector search only
    SEARCH_SEMANTIC = "SEMANTIC"
}

// Reranking can return fewer results than `numberOfResults`.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_VectorSearchBedrockRerankingConfiguration.html

# Reranking settings for retrieval.
public type VectorRerankingConfig record {|
    # ARN of the Bedrock reranker model
    string modelArn;
    # Number of results to return after reranking (1-100)
    int numberOfRerankedResults?;
|};

// ============================================================================
// Definition and configuration.
// ============================================================================

// Fixed for the life of the data source. `HIERARCHICAL` and `SEMANTIC` need settings
// this record does not have; create such a data source in the AWS console.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_ChunkingConfiguration.html

# The data source created with a new self-managed knowledge base.
public type VectorDataSourceDefinition record {|
    # Data source name
    string name;
    # Data source description
    string description?;
    # How Bedrock chunks documents: `FIXED_SIZE` or `NONE`
    ChunkingStrategy chunkingStrategy = FIXED_SIZE;
    # Approximate tokens per chunk, for `FIXED_SIZE`
    int maxTokens = 300;
    # Percentage overlap between chunks, for `FIXED_SIZE`
    int overlapPercentage = 20;
|};

// The vector store must already exist. The service role needs access to it and
// `bedrock:InvokeModel` on the embedding model. `name` must match
// `([0-9a-zA-Z][_-]?){1,100}`.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CreateKnowledgeBase.html

# A self-managed knowledge base to find or create by name.
public type SelfManagedKnowledgeBaseDefinition record {|
    # Knowledge base name, also used to find an existing one
    string name;
    # Knowledge base description
    string description?;
    # ARN of the IAM role Bedrock uses to manage this knowledge base
    @display {label: "Service Role ARN"}
    string serviceRoleArn;
    # The data source created with the knowledge base
    VectorDataSourceDefinition dataSource = {name: "ballerina-custom-source"};
    # ARN of the embedding model
    @display {label: "Embedding Model ARN"}
    string embeddingModelArn;
    # Embedding model settings. Defaults to the model's own
    VectorEmbeddingModelConfig embeddingModel?;
    # The existing vector store to use
    StorageConfiguration storageConfiguration;
    # Seconds to wait for a new knowledge base to become ready
    decimal readyTimeout = 300;
|};

// Bedrock's own `numberOfResults` default is 5.

# Configuration for `SelfManagedKnowledgeBase`.
public type SelfManagedKnowledgeBaseConfig record {|
    # Seconds to wait for documents to be indexed
    decimal ingestTimeout = 300;
    # Default number of results per retrieval (1-100)
    int numberOfResults?;
    # Search strategy for retrieval. Chosen by Bedrock when unset
    SearchType overrideSearchType?;
    # HTTP client configuration
    http:ClientConfiguration httpConfig?;
    # Retry configuration
    RetryConfig retryConfig?;
|};

// `implicitFilterConfiguration` is not exposed: it needs a model and a schema of every
// filterable attribute, and the `ai` contract has nothing to map it to.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_ImplicitFilterConfiguration.html
