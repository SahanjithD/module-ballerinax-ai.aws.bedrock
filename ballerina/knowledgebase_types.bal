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
import ballerinax/aws.auth;
import ballerinax/aws;

// Public surface for `BedrockManagedKnowledgeBase`: configuration, the
// find-or-create definition, and the chunking-strategy enum. See
// knowledgebase_common.bal for the resolution spine and knowledgebase_managed.bal
// for the public class.

# Credentials for the two Bedrock agent planes. SigV4 only, deliberately excluding
# `BearerToken`: Bedrock API keys cannot be used with the Agents for Amazon Bedrock
# APIs (`bedrock-agent`/`bedrock-agent-runtime`), which back knowledge bases.
# https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-use.html
public type KnowledgeBaseCredentials auth:AuthConfig;

# How Bedrock splits ingested documents into retrievable chunks. Set on
# `CreateDataSource` and fixed for the life of the data source.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_ChunkingConfiguration.html
public enum ChunkingStrategy {
    # Splits each document into chunks of the approximate size set by
    # `maxTokens`/`overlapPercentage`. The default.
    FIXED_SIZE,
    # Two-layer chunking: large parent chunks, smaller child chunks derived from them.
    HIERARCHICAL,
    # Chunks by grouping semantically similar content.
    SEMANTIC,
    # Treats each document as exactly one chunk, leaving chunking to the client via
    # an `ai:Chunker`.
    NONE
}

# Reranking model selection for `retrieve()` on a managed knowledge base.
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_ManagedSearchConfiguration.html
public enum RerankingModelType {
    # No reranking pass.
    RERANKING_NONE = "NONE",
    # Bedrock's own managed reranking model.
    RERANKING_MANAGED = "MANAGED"
}

# The `CUSTOM` direct-ingestion data source created alongside a knowledge base in
# the find-or-create (`KnowledgeBaseDefinition`) path.
public type DataSourceDefinition record {|
    # Data source name.
    string name;
    # Data source description.
    string description?;
|};

# A caller-supplied Bedrock embedding model for a knowledge base created through
# `KnowledgeBaseDefinition`, replacing Bedrock's service-managed one.
#
# `embeddingModelType` cannot be changed after creation. Choosing one also opts out
# of the managed reranker (`RERANKING_MANAGED`) and bills the model separately from
# the knowledge base.
# https://docs.aws.amazon.com/bedrock/latest/userguide/kb-managed-create.html#kb-managed-embedding-models
public type ManagedEmbeddingModel record {|
    # Embedding model ARN. AWS supports Amazon Titan Text Embeddings V2, Cohere Embed
    # English v3, Cohere Embed Multilingual v3, Cohere Embed v4, and Amazon Nova
    # Multimodal Embeddings on a managed knowledge base.
    string embeddingModelArn;
    # Vector dimensions. AWS requires 1024 on a managed knowledge base.
    int dimensions = 1024;
    # Vector data type. AWS requires float32 on a managed knowledge base.
    string embeddingDataType = "FLOAT32";
|};

# A knowledge base to find-or-create by name, with all content flowing through this
# module. `init` searches `ListKnowledgeBases` for an exact name match: one match
# attaches to it, no match creates it, more than one is a construction error.
public type KnowledgeBaseDefinition record {|
    # Knowledge base name. Must match `([0-9a-zA-Z][_-]?){1,100}`. Also the
    # find-or-create lookup key.
    string name;
    # IAM role Bedrock assumes to manage the knowledge base.
    string roleArn;
    # Knowledge base description.
    string description?;
    # The `CUSTOM` direct-ingestion data source created alongside the knowledge base.
    DataSourceDefinition dataSource = {name: "ballerina-custom-source"};
    # Embedding model. Leave unset for Bedrock's service-managed model (no extra
    # cost, chunking fixed at 300 tokens / 20% overlap). Set to use your own model;
    # read `ManagedEmbeddingModel` first, the choice is permanent.
    ManagedEmbeddingModel embeddingModel?;
    # Customer-managed KMS key for the managed vector store. Unset uses an AWS-owned
    # key.
    string kmsKeyArn?;
    # How long `init` waits for the knowledge base and data source to leave their
    # transient `CREATING` states.
    decimal readyTimeout = 300;
|};

# Configuration for `BedrockManagedKnowledgeBase`.
public type ManagedKnowledgeBaseConfig record {|
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
    # Default `numberOfResults` for `retrieve()` (1-100).
    int numberOfResults?;
    # Reranking model for `retrieve()`. Unset leaves it to Bedrock's own default.
    RerankingModelType rerankingModelType?;
    # Underlying HTTP client configuration, shared by both agent-plane clients.
    http:ClientConfiguration httpConfig?;
    # Retry policy, shared by both agent-plane clients.
    RetryConfig retryConfig?;
    # Endpoint resolution options: `fips`, `dualstack`, and a `customEndpoint`
    # override. The host is derived from the region and the resolved route when this
    # is unset, which is correct in every partition — set it only for PrivateLink
    # without private DNS, an egress gateway, or a local mock. A `customEndpoint` is
    # a GLOBAL override with the same semantics as the AWS SDK's `AWS_ENDPOINT_URL`:
    # it applies to every service the client talks to.
    aws:EndpointConfig endpoint?;
|};
