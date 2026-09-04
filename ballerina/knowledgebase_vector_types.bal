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

// Public surface for `BedrockVectorKnowledgeBase` — the SELF-MANAGED knowledge base
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

# Field mapping for an Amazon OpenSearch vector index — Serverless and Managed
# Cluster declare identical shapes.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_OpenSearchServerlessFieldMapping.html
public type OpenSearchFieldMapping record {|
    # Field holding the vector embeddings.
    string vectorField;
    # Field holding the raw text chunk.
    string textField;
    # Field holding the metadata Bedrock manages.
    string metadataField;
|};

# Field mapping for a Pinecone index. No `vectorField` — Pinecone stores the vector
# natively rather than in a named field.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_PineconeFieldMapping.html
public type PineconeFieldMapping record {|
    # Field holding the raw text chunk.
    string textField;
    # Field holding the metadata Bedrock manages.
    string metadataField;
|};

# Field mapping for a Neptune Analytics graph. Like Pinecone, no `vectorField`.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_NeptuneAnalyticsFieldMapping.html
public type NeptuneAnalyticsFieldMapping record {|
    # Field holding the raw text chunk.
    string textField;
    # Field holding the metadata Bedrock manages.
    string metadataField;
|};

# Field mapping for a MongoDB Atlas collection.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_MongoDbAtlasFieldMapping.html
public type MongoDbAtlasFieldMapping record {|
    # Field holding the vector embeddings.
    string vectorField;
    # Field holding the raw text chunk.
    string textField;
    # Field holding the metadata Bedrock manages.
    string metadataField;
|};

# Field mapping for a Redis Enterprise Cloud index.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_RedisEnterpriseCloudFieldMapping.html
public type RedisEnterpriseCloudFieldMapping record {|
    # Field holding the vector embeddings.
    string vectorField;
    # Field holding the raw text chunk.
    string textField;
    # Field holding the metadata Bedrock manages.
    string metadataField;
|};

# Column mapping for an Amazon Aurora/RDS table. The only backend with a primary key
# and an optional custom-metadata column.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_RdsFieldMapping.html
public type RdsFieldMapping record {|
    # Primary key column.
    string primaryKeyField;
    # Column holding the vector embeddings.
    string vectorField;
    # Column holding the raw text chunk.
    string textField;
    # Column holding the metadata Bedrock manages.
    string metadataField;
    # Column holding your metadata attributes as a single `jsonb` value, needed for
    # metadata filtering. Without it, add one typed column per attribute instead.
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

# Amazon OpenSearch Serverless.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_OpenSearchServerlessConfiguration.html
public type OpenSearchServerlessStorage record {|
    # Discriminator. Always emitted on the wire.
    readonly "OPENSEARCH_SERVERLESS" 'type = "OPENSEARCH_SERVERLESS";
    # ARN of the vector search collection.
    string collectionArn;
    # Name of the vector index inside the collection. Requires the `faiss` engine —
    # metadata filtering does not work with `nmslib`.
    string vectorIndexName;
    # Names of the fields Bedrock reads and writes.
    OpenSearchFieldMapping fieldMapping;
|};

# Amazon OpenSearch Service Managed Cluster. Requires a public-access domain
# (VPC-bound domains are not supported) and engine 2.13+ for a k-NN index.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_OpenSearchManagedClusterConfiguration.html
public type OpenSearchManagedClusterStorage record {|
    # Discriminator. Always emitted on the wire.
    readonly "OPENSEARCH_MANAGED_CLUSTER" 'type = "OPENSEARCH_MANAGED_CLUSTER";
    # Endpoint of the OpenSearch domain.
    string domainEndpoint;
    # ARN of the OpenSearch domain.
    string domainArn;
    # Name of the vector index inside the domain.
    string vectorIndexName;
    # Names of the fields Bedrock reads and writes.
    OpenSearchFieldMapping fieldMapping;
|};

# Amazon S3 Vectors — the cheapest backend. Semantic search only (no
# `SEARCH_HYBRID`), floating-point vectors only, and limited custom metadata
# (1 KB / 35 keys per vector).
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_S3VectorsConfiguration.html
public type S3VectorsStorage record {|
    # Discriminator. Always emitted on the wire.
    readonly "S3_VECTORS" 'type = "S3_VECTORS";
    # ARN of the S3 vector bucket. Pair with `indexName`.
    string vectorBucketArn?;
    # ARN of the vector index. An alternative to `vectorBucketArn` + `indexName`.
    string indexArn?;
    # Name of the vector index inside the bucket. Pair with `vectorBucketArn`.
    string indexName?;
|};

# Amazon Aurora PostgreSQL (RDS). The cluster must live in the same AWS account as
# the knowledge base.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_RdsConfiguration.html
public type RdsStorage record {|
    # Discriminator. Always emitted on the wire.
    readonly "RDS" 'type = "RDS";
    # ARN of the Aurora DB cluster.
    string resourceArn;
    # ARN of the Secrets Manager secret holding the database credentials.
    string credentialsSecretArn;
    # Database name.
    string databaseName;
    # Table holding the vectors.
    string tableName;
    # Names of the columns Bedrock reads and writes.
    RdsFieldMapping fieldMapping;
|};

# Amazon Neptune Analytics (GraphRAG). The vector search index can only be created
# when the graph is created, and its dimension must match the embedding model.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_NeptuneAnalyticsConfiguration.html
public type NeptuneAnalyticsStorage record {|
    # Discriminator. Always emitted on the wire.
    readonly "NEPTUNE_ANALYTICS" 'type = "NEPTUNE_ANALYTICS";
    # ARN of the Neptune Analytics graph.
    string graphArn;
    # Names of the fields Bedrock reads and writes.
    NeptuneAnalyticsFieldMapping fieldMapping;
|};

# Pinecone. Using it means authorizing AWS to access a third-party service on your
# behalf.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_PineconeConfiguration.html
public type PineconeStorage record {|
    # Discriminator. Always emitted on the wire.
    readonly "PINECONE" 'type = "PINECONE";
    # Endpoint URL of the index management page.
    string connectionString;
    # ARN of the Secrets Manager secret holding the Pinecone API key, under the key
    # `apiKey`.
    string credentialsSecretArn;
    # Namespace new data is written to. Unset writes to the default namespace.
    string namespace?;
    # Names of the fields Bedrock reads and writes.
    PineconeFieldMapping fieldMapping;
|};

# Redis Enterprise Cloud. TLS must be enabled, and the Secrets Manager secret needs
# `username`, `password`, `serverCertificate`, `clientPrivateKey`,
# `clientCertificate`.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_RedisEnterpriseCloudConfiguration.html
public type RedisEnterpriseCloudStorage record {|
    # Discriminator. Always emitted on the wire.
    readonly "REDIS_ENTERPRISE_CLOUD" 'type = "REDIS_ENTERPRISE_CLOUD";
    # Public endpoint URL of the database.
    string endpoint;
    # Name of the vector index.
    string vectorIndexName;
    # ARN of the Secrets Manager secret holding the credentials and certificates.
    string credentialsSecretArn;
    # Names of the fields Bedrock reads and writes.
    RedisEnterpriseCloudFieldMapping fieldMapping;
|};

# MongoDB Atlas. Metadata filtering requires filters to be configured explicitly in
# the Atlas vector index first — it does not work by default.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_MongoDbAtlasConfiguration.html
public type MongoDbAtlasStorage record {|
    # Discriminator. Always emitted on the wire.
    readonly "MONGO_DB_ATLAS" 'type = "MONGO_DB_ATLAS";
    # Endpoint URL of the Atlas cluster.
    string endpoint;
    # Database name in the cluster.
    string databaseName;
    # Collection name in the database.
    string collectionName;
    # Name of the Atlas vector search index.
    string vectorIndexName;
    # ARN of the Secrets Manager secret holding `username` and `password`.
    string credentialsSecretArn;
    # Name of the VPC endpoint service connected to the cluster, when reaching Atlas
    # over AWS PrivateLink.
    string endpointServiceName?;
    # Name of the Atlas text search index. Required for `SEARCH_HYBRID` on this
    # backend.
    string textIndexName?;
    # Names of the fields Bedrock reads and writes.
    MongoDbAtlasFieldMapping fieldMapping;
|};

# The customer-provisioned vector store backing a self-managed knowledge base.
# Every member must already exist — this module never creates one.
public type StorageConfiguration OpenSearchServerlessStorage|OpenSearchManagedClusterStorage|
    S3VectorsStorage|RdsStorage|NeptuneAnalyticsStorage|PineconeStorage|
    RedisEnterpriseCloudStorage|MongoDbAtlasStorage;

// ============================================================================
// Embedding model, search type, reranking.
// ============================================================================

# Vector data type for the embedding model.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_BedrockEmbeddingModelConfiguration.html
public enum EmbeddingDataType {
    # Floating-point vectors. The default, and the only type S3 Vectors supports.
    EMBEDDING_FLOAT32 = "FLOAT32",
    # Binary vectors — cheaper and less precise. Supported only on OpenSearch
    # Serverless and Managed Cluster (2.16+).
    EMBEDDING_BINARY = "BINARY"
}

# Tuning for the embedding model on a self-managed knowledge base.
#
# `dimensions` must match the dimension the vector index was created with —
# Bedrock does not reconcile them, and a mismatch fails ingestion.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_BedrockEmbeddingModelConfiguration.html
public type VectorEmbeddingModelConfig record {|
    # Vector dimensions (0-4096). Must equal the vector index's dimension.
    int dimensions?;
    # Vector data type. Read `EmbeddingDataType` before setting `EMBEDDING_BINARY`.
    EmbeddingDataType embeddingDataType?;
|};

# Search strategy override for `retrieve()`. Leave unset unless you know your
# backend supports the value — Bedrock otherwise picks a strategy suited to the
# store.
#
# AWS sources disagree on where `SEARCH_HYBRID` is supported (OpenSearch
# Serverless at minimum; the user guide also names RDS and MongoDB with a
# filterable text field). It is unavailable on S3 Vectors, Neptune Analytics,
# Pinecone, and Redis.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_KnowledgeBaseVectorSearchConfiguration.html
public enum SearchType {
    # Combine vector embeddings with raw-text search. Backend-dependent, see above.
    SEARCH_HYBRID = "HYBRID",
    # Vector embeddings only. Available on every backend.
    SEARCH_SEMANTIC = "SEMANTIC"
}

# Reranking for `retrieve()` on a self-managed knowledge base — the only way to
# rerank on this class, since `vectorSearchConfiguration` has no `RerankingModelType`
# shortcut.
#
# Reranking applies its own relevance cut, so it can return fewer results than
# `numberOfResults` asked for.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_VectorSearchBedrockRerankingConfiguration.html
public type VectorRerankingConfig record {|
    # ARN of the Bedrock reranker model.
    string modelArn;
    # How many results to return after reranking (1-100). Unset leaves it to Bedrock.
    int numberOfRerankedResults?;
|};

// ============================================================================
// Definition and configuration.
// ============================================================================

# The `CUSTOM` direct-ingestion data source created alongside a self-managed
# knowledge base.
#
# Separate from `DataSourceDefinition` (the managed one): a managed knowledge base
# rejects `chunkingConfiguration` on a service-managed embedding model, so that
# record carries no chunking fields, while a self-managed one always supplies its
# own embedding model and so has chunking configurable here.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_ChunkingConfiguration.html
public type VectorDataSourceDefinition record {|
    # Data source name.
    string name;
    # Data source description.
    string description?;
    # How Bedrock chunks documents submitted through this data source. Fixed for the
    # life of the data source. Only `FIXED_SIZE` and `NONE` are accepted here —
    # `HIERARCHICAL` and `SEMANTIC` need a tuning sub-object this record cannot
    # express; create such a data source in the AWS console instead. Set `NONE` to
    # chunk client-side with an `ai:Chunker`.
    ChunkingStrategy chunkingStrategy = FIXED_SIZE;
    # `FIXED_SIZE` tuning: approximate tokens per chunk (1-8192). Ignored on other
    # strategies.
    int maxTokens = 300;
    # `FIXED_SIZE` tuning: percentage overlap between adjacent chunks (1-99 — Bedrock
    # rejects 0; use `chunkingStrategy = NONE` for no chunking at all). Ignored on
    # other strategies.
    int overlapPercentage = 20;
|};

# A self-managed knowledge base to find-or-create by name, with all content flowing
# through this module.
#
# The vector store named by `storageConfiguration` must already exist — the Bedrock
# API has no equivalent of the console's "Quick create a new vector store". Provision
# it with Terraform/CDK/the console first, then pass its ARNs here.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CreateKnowledgeBase.html
public type VectorKnowledgeBaseDefinition record {|
    # Knowledge base name. Must match `([0-9a-zA-Z][_-]?){1,100}`. Also the
    # find-or-create lookup key.
    string name;
    # IAM role Bedrock assumes to manage the knowledge base. Needs permissions on
    # the vector store as well as on Bedrock — see `kb-permissions` in the AWS
    # user guide for the backend-specific action list.
    string roleArn;
    # Knowledge base description.
    string description?;
    # ARN of the embedding model. Required — there is no service-managed embedding
    # model on this path. `roleArn` must hold `bedrock:InvokeModel` on it.
    string embeddingModelArn;
    # Embedding model tuning. Leave unset for the model's own defaults.
    VectorEmbeddingModelConfig embeddingModel?;
    # The customer-provisioned vector store. Must already exist.
    StorageConfiguration storageConfiguration;
    # The `CUSTOM` direct-ingestion data source created alongside the knowledge base.
    VectorDataSourceDefinition dataSource = {name: "ballerina-custom-source"};
    # How long `init` waits for the knowledge base and data source to leave their
    # transient `CREATING` states.
    decimal readyTimeout = 300;
|};

# Configuration for `BedrockVectorKnowledgeBase`.
public type VectorKnowledgeBaseConfig record {|
    # The `CUSTOM` data source to ingest into / delete from. Resolved automatically
    # when omitted, which requires exactly one `CUSTOM` data source on the knowledge
    # base.
    string dataSourceId?;
    # Client-side chunking before `ingest()`. Leave unset to detect it from the data
    # source's actual `chunkingStrategy` (`ai:DISABLE` unless it is `NONE`, in which
    # case `ai:AUTO`). Passing an explicit `ai:Chunker` against a server-chunking
    # data source is a construction error.
    ai:Chunker|ai:AUTO|ai:DISABLE chunker?;
    # How long `ingest()` polls for submitted documents to reach a terminal state.
    decimal ingestTimeout = 300;
    # Default `numberOfResults` for `retrieve()` (1-100). Bedrock's own default is 5.
    int numberOfResults?;
    # Search strategy override. Leave unset — read `SearchType` first, support is
    # backend-dependent.
    SearchType overrideSearchType?;
    # Reranking for `retrieve()`. Unset applies no reranking.
    VectorRerankingConfig rerankingConfiguration?;
    # Underlying HTTP client configuration, shared by both agent-plane clients.
    http:ClientConfiguration httpConfig?;
    # Retry policy, shared by both agent-plane clients.
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
