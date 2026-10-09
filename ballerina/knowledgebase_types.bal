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

// ============================================================================
// Module-private: knowledge base internals.
// ============================================================================

# Everything `ManagedKnowledgeBase`'s methods read: two agent-plane
# transports (control on `bedrock-agent`, data on `bedrock-agent-runtime`), the
# resolved knowledge base / data source ids, and the detected chunking strategy.
# Module-private — the resolver's output, mirroring `Route`/`Endpoint`.
type KbSpine record {|
    # `bedrock-agent` (create/list/get KB & data source, ingest/list/get/delete documents)
    BedrockTransport controlTransport;
    # `bedrock-agent-runtime` (retrieve)
    BedrockTransport dataTransport;
    # The resolved knowledge base id
    string knowledgeBaseId;
    # The resolved `CUSTOM` data source id
    string dataSourceId;
    # The resolved data source's actual chunking strategy
    ChunkingStrategy chunkingStrategy;
|};

# Outcome of resolving `string|ManagedKnowledgeBaseDefinition` to a concrete knowledge
# base. `createdDataSourceId` is set ONLY when a new knowledge base (and its
# `CUSTOM` data source) was just created — in every other case (a bare id, or an
# existing knowledge base found by name) data-source resolution still has to run.
type KbAttachResult record {|
    # The attached or newly created knowledge base id
    string knowledgeBaseId;
    # The `CUSTOM` data source id, when this call just created it
    string? createdDataSourceId;
|};

# Outcome of `createKnowledgeBaseRecoveringFromConflict`. After a 409 recovery the
# knowledge base already has its data source, so none is created.
type KbCreateOutcome record {|
    # The created id, or, on recovery, the id of the existing match
    string knowledgeBaseId;
    # `true` when a 409 led to attaching rather than creating
    boolean recovered;
|};

# The final (terminal) outcome of one submitted document: its last-seen status and,
# on failure, the reason Bedrock reported.
type DocumentOutcome record {|
    # The terminal `DocumentStatus` (see `KB_DOC_USABLE_STATUSES`/`KB_DOC_FAILED_STATUSES`)
    string status;
    # Bedrock's explanation, present mainly alongside `IGNORED`
    string? statusReason;
|};

# One enumerated, retrievable document that `deleteByFilter` can potentially delete.
type DeletableDocument record {|
    # `customDocumentIdentifier.id` (CUSTOM) or the S3 object URI (S3) — also what `_source_uri` holds
    string sourceValue;
    # The ready-to-send `DocumentIdentifier` for `DeleteKnowledgeBaseDocuments`
    json identifier;
|};

// Both classes' retrieve calls reduced to what enumeration needs: no reranking.
# A paged, unranked `Retrieve` call, as `deleteByFilter`'s enumeration makes it.
type DeleteRetrieveCaller isolated function (BedrockTransport dataTransport, string kbId, json? filter,
        int numberOfResults, string? nextToken) returns [json[], string?]|ai:Error;

# One paged `Retrieve` enumeration's result: every document identity seen, and
# whether `KB_DELETE_ENUMERATION_MAX_PAGES` was hit before pagination finished
# naturally (`nextToken` came back `()`).
type DeleteEnumeration record {|
    # Every `retrievalResultSourceValue` seen across every page, as a set
    map<()> identities;
    # `true` when the page cap was hit — the set above may be INCOMPLETE
    boolean truncated;
|};

# Why a candidate could not be decided. A reason rather than a message, so the error
# can group candidates by cause.
enum UnresolvedReason {
    # This data source exposes no metadata key that identifies a document, so nothing
    # here can be pinned. Structural: it applies to every candidate equally.
    UNRESOLVED_NO_PIN_KEY,
    # The pin key is `ai:Metadata.id`, and this document was ingested WITHOUT one —
    # `documentIdFor` gave it a UUID — so it carries no `id` attribute for the pin to
    # match. Known from the document id alone, before any probe.
    UNRESOLVED_NO_DOCUMENT_ID,
    # Pinnable, but neither probe returned it.
    UNRESOLVED_UNREACHABLE,
    # Its pin group exceeded the `Retrieve` cap, so it was not checked.
    UNRESOLVED_GROUP_TOO_LARGE
}

# One candidate `deleteByFilter` could not decide about.
type UnresolvedCandidate record {|
    # The document id, as `listDeletableDocuments` built it
    string sourceValue;
    # The data source it lives on
    string dataSourceId;
    # Why it could not be decided
    UnresolvedReason reason;
|};

# The three-way outcome of resolving one delete candidate.
# See `probeCandidate`, which produces it.
enum DeleteCandidateOutcome {
    # Confirmed to match: safe to delete.
    DELETE_MATCH,
    # The pin reached this exact document without the filter and not with it, so the
    # FILTER excluded it — leave it alone, soundly and silently.
    DELETE_SKIP,
    # The pin did not reach it at all, so nothing can be concluded about the filter —
    # reported to the caller rather than assumed either way.
    DELETE_INDETERMINATE
}

# What `resolveDataSourceDeletes` found for one data source.
type DataSourceDeleteResult record {|
    # `DocumentIdentifier`s ready for `DeleteKnowledgeBaseDocuments`
    json[] toDelete;
    # Candidates that could not be confirmed to match or not match the filter
    UnresolvedCandidate[] indeterminate;
    # Why nothing was deleted from this data source: enumeration hit the page cap, or the
    # store does not honour metadata filters. When set, the other two lists are empty.
    string? refusalReason;
    # Notes for the caller, e.g. that a large pin group was cut off and calling again
    # continues it.
    string[] notes = [];
|};

# The one data source a `deleteByFilter` works on, and the metadata key that names it
# on a retrieval result (it differs between managed and self-managed knowledge bases).
type DataSourceScope record {|
    # The reserved data-source-id metadata attribute
    string key;
    # The data source id
    string id;
|};

# One document ready to submit, with the position of the chunk within its parent when
# this module produced it client-side.
type KbIngestItem record {|
    # The chunk or document to encode
    ai:Chunk|ai:Document item;
    # 0-based position within the parent's chunks, or `()` when the item was passed through as the caller gave it
    int? chunkOrdinal;
|};
