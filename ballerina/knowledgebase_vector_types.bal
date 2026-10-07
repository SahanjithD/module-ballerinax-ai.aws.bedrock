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

// Public surface for `VectorKnowledgeBase` — the SELF-MANAGED knowledge base
// (`KnowledgeBaseConfiguration.type = VECTOR`), where the vector store belongs to the
// caller rather than to Bedrock. See knowledgebase_vector_common.bal for the
// resolution spine and knowledgebase_vector.bal for the public class.
//
// Deliberately kept separate from knowledgebase_types.bal: the two knowledge base
// types share no configuration record. MANAGED has no `storageConfiguration` and no
// `embeddingModelArn`; VECTOR requires both, has no `rerankingModelType` shortcut,
// and gains `overrideSearchType`.

// ============================================================================
// Field mappings.
//
// One record per backend, mirroring the service model 1:1 even where two backends
// currently agree. They are NOT interchangeable — `PineconeFieldMapping` and
// `NeptuneAnalyticsFieldMapping` have NO `vectorField`, and `RdsFieldMapping` adds
// `primaryKeyField` plus an optional `customMetadataField`. A single shared record
// would either reject valid Pinecone/Neptune configurations or send fields AWS
// rejects. Required members below are the `required` arrays in the `bedrock-agent`
// service model (botocore `service-2.json`), cross-checked against each type's own
// API reference page.
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

// No `vectorField` — Pinecone stores the vector natively rather than in a named field.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_PineconeFieldMapping.html

# Field names in a Pinecone index.
public type PineconeFieldMapping record {|
    # Field holding the raw text chunk
    string textField;
    # Field holding the metadata Bedrock manages
    string metadataField;
|};

// Like Pinecone, no `vectorField`.
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

// The only backend with a primary key and an optional custom-metadata column.
// `customMetadataField` holds the caller's metadata attributes as a single `jsonb`
// value, needed for metadata filtering; without it, add one typed column per attribute.
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
// Storage configurations — one per vector store backend.
//
// A closed tagged union discriminated by the singleton `'type` field, so
// `storageConfigurationJson` is an exhaustive match the compiler checks.
// `StorageConfiguration.type` is `Required: Yes` in the API reference even though
// the user-guide example omits it, so it is always emitted.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_StorageConfiguration.html
//
// NOTE ON PROVISIONING: none of these can be created by this module. The Bedrock
// API accepts only a storage configuration naming an ALREADY EXISTING store — the
// console's "Quick create a new vector store" is console-only ("If you prefer to
// let Amazon Bedrock create and manage a vector store for you, use the console",
// https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base-create.html).
// ============================================================================

// The vector index requires the `faiss` engine — metadata filtering does not work
// with `nmslib`.
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

// Requires a public-access domain (VPC-bound domains are not supported) and engine
// 2.13+ for a k-NN index.
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

// The cheapest backend. Semantic search only (no `SEARCH_HYBRID`), floating-point
// vectors only, and limited custom metadata (1 KB / 35 keys per vector). Identify the
// index by `indexArn`, or by `vectorBucketArn` + `indexName`.
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

// The cluster must live in the same AWS account as the knowledge base.
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

// GraphRAG. The vector search index can only be created when the graph is created,
// and its dimension must match the embedding model.
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

// Using it means authorizing AWS to access a third-party service on your behalf. The
// secret stores the Pinecone API key under the key `apiKey`. `connectionString` is the
// endpoint URL of the index management page.
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

// TLS must be enabled, and the Secrets Manager secret needs `username`, `password`,
// `serverCertificate`, `clientPrivateKey`, `clientCertificate`.
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

// Metadata filtering requires filters to be configured explicitly in the Atlas vector
// index first — it does not work by default. `endpointServiceName` is for reaching
// Atlas over AWS PrivateLink; `textIndexName` is required for `SEARCH_HYBRID` here.
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

// Every member must already exist — this module never creates one.

# An existing vector store backing a self-managed knowledge base.
public type StorageConfiguration OpenSearchServerlessStorage|OpenSearchManagedClusterStorage|
    S3VectorsStorage|RdsStorage|NeptuneAnalyticsStorage|PineconeStorage|
    RedisEnterpriseCloudStorage|MongoDbAtlasStorage;

// ============================================================================
// Embedding model, search type, reranking.
// ============================================================================

// `EMBEDDING_FLOAT32` is the only type S3 Vectors supports. `EMBEDDING_BINARY` is
// cheaper and less precise, and supported only on OpenSearch Serverless and Managed
// Cluster (2.16+).
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_BedrockEmbeddingModelConfiguration.html

# Vector data type for the embedding model.
public enum EmbeddingDataType {
    # Floating-point vectors. The default
    EMBEDDING_FLOAT32 = "FLOAT32",
    # Binary vectors. OpenSearch only
    EMBEDDING_BINARY = "BINARY"
}

// `dimensions` (0-4096) must match the dimension the vector index was created with —
// Bedrock does not reconcile them, and a mismatch fails ingestion.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_BedrockEmbeddingModelConfiguration.html

# Embedding model settings for a self-managed knowledge base.
public type VectorEmbeddingModelConfig record {|
    # Vector dimensions. Must match the vector index
    int dimensions?;
    # Vector data type
    EmbeddingDataType embeddingDataType?;
|};

// Leave unset unless the backend is known to support the value — Bedrock otherwise
// picks a strategy suited to the store.
//
// AWS sources disagree on where `SEARCH_HYBRID` is supported (OpenSearch
// Serverless at minimum; the user guide also names RDS and MongoDB with a
// filterable text field). It is unavailable on S3 Vectors, Neptune Analytics,
// Pinecone, and Redis.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_KnowledgeBaseVectorSearchConfiguration.html

# Search strategy used for retrieval.
public enum SearchType {
    # Vector and keyword search combined. Not supported on every backend
    SEARCH_HYBRID = "HYBRID",
    # Vector search only
    SEARCH_SEMANTIC = "SEMANTIC"
}

// The only way to rerank on this class, since `vectorSearchConfiguration` has no
// `RerankingModelType` shortcut. Reranking applies its own relevance cut, so it can
// return fewer results than `numberOfResults` asked for.
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

// Separate from `DataSourceDefinition` (the managed one): a managed knowledge base
// rejects `chunkingConfiguration` on a service-managed embedding model, so that
// record carries no chunking fields, while a self-managed one always supplies its
// own embedding model and so has chunking configurable here.
//
// `chunkingStrategy` is fixed for the life of the data source. Only `FIXED_SIZE` and
// `NONE` are accepted — `HIERARCHICAL` and `SEMANTIC` need a tuning sub-object this
// record cannot express; create such a data source in the AWS console instead.
// `maxTokens` (1-8192) and `overlapPercentage` (1-99 — Bedrock rejects 0) apply to
// `FIXED_SIZE` only.
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

// The vector store named by `storageConfiguration` must already exist — the Bedrock
// API has no equivalent of the console's "Quick create a new vector store". Provision
// it with Terraform/CDK/the console first, then pass its ARNs here.
//
// `name` must match `([0-9a-zA-Z][_-]?){1,100}`. `roleArn` needs permissions on the
// vector store as well as on Bedrock (see `kb-permissions` in the AWS user guide), and
// `bedrock:InvokeModel` on `embeddingModelArn`. There is no service-managed embedding
// model on this path, so `embeddingModelArn` is required.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CreateKnowledgeBase.html

# A self-managed knowledge base to find or create by name.
public type VectorKnowledgeBaseDefinition record {|
    # Knowledge base name, also used to find an existing one
    string name;
    # IAM role Bedrock assumes to manage the knowledge base
    string roleArn;
    # Knowledge base description
    string description?;
    # ARN of the embedding model
    string embeddingModelArn;
    # Embedding model settings. Defaults to the model's own
    VectorEmbeddingModelConfig embeddingModel?;
    # The existing vector store to use
    StorageConfiguration storageConfiguration;
    # The data source created with the knowledge base
    VectorDataSourceDefinition dataSource = {name: "ballerina-custom-source"};
    # Seconds to wait for a new knowledge base to become ready
    decimal readyTimeout = 300;
|};

// `dataSourceId` is resolved automatically when omitted, which requires exactly one
// `CUSTOM` data source on the knowledge base. `chunker` left unset is detected from the
// data source's actual `chunkingStrategy` (`ai:DISABLE` unless it is `NONE`, in which
// case `ai:AUTO`); an explicit `ai:Chunker` against a server-chunking data source is a
// construction error. Bedrock's own `numberOfResults` default is 5. Leave
// `overrideSearchType` unset unless the backend supports it — see `SearchType`.
// `httpConfig`/`retryConfig` are shared by both agent-plane clients.

# Configuration for `VectorKnowledgeBase`.
public type VectorKnowledgeBaseConfig record {|
    # The `CUSTOM` data source to use. Detected when unset
    string dataSourceId?;
    # Client-side chunker. Detected from the data source when unset
    ai:Chunker|ai:AUTO|ai:DISABLE chunker?;
    # Seconds to wait for documents to be indexed
    decimal ingestTimeout = 300;
    # Default number of results per retrieval (1-100)
    int numberOfResults?;
    # Search strategy for retrieval. Chosen by Bedrock when unset
    SearchType overrideSearchType?;
    # Reranking for retrieval. No reranking when unset
    VectorRerankingConfig rerankingConfiguration?;
    # HTTP client configuration
    http:ClientConfiguration httpConfig?;
    # Retry configuration
    RetryConfig retryConfig?;
|};

// `implicitFilterConfiguration` is deliberately NOT exposed. It is a real member of
// `vectorSearchConfiguration` (a model generates a metadata filter from the user's
// prompt), but it requires a `modelArn` plus a 1-25 entry `MetadataAttributeSchema`
// array describing every filterable attribute, it has no counterpart anywhere in the
// `ai` module's contract, and how it composes with an explicit `filter` is not
// documented. Adding it later is additive — a new optional field on
// `VectorKnowledgeBaseConfig` — so nothing here forecloses it.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_ImplicitFilterConfiguration.html
