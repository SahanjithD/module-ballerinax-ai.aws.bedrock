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
import ballerina/ai.observe;
import ballerinax/aws;

# A Bedrock self-managed knowledge base (`KnowledgeBaseConfiguration.type = VECTOR`)
# — your own vector store rather than Bedrock's — exposed through `ai:KnowledgeBase`.
# This is the console's *Self-managed KB → Unstructured Vector Store KB*.
#
# Pass an existing knowledge base id to attach to it, or a
# `VectorKnowledgeBaseDefinition` to find-or-create one by name.
#
# The vector store named by `storageConfiguration` must already exist; this class
# never provisions one. `ingest()` additionally needs `bedrock:StartIngestionJob`
# and `bedrock:IngestKnowledgeBaseDocuments` on the caller's credentials, and the
# knowledge base's own `roleArn` needs permissions on the vector store itself.
# https://docs.aws.amazon.com/bedrock/latest/userguide/kb-permissions.html
public distinct isolated client class BedrockVectorKnowledgeBase {
    *ai:KnowledgeBase;

    private final BedrockTransport controlTransport;
    private final BedrockTransport dataTransport;
    private final string knowledgeBaseId;
    private final string dataSourceId;
    private final ai:Chunker|ai:AUTO|ai:DISABLE chunker;
    private final decimal ingestTimeout;
    private final int? numberOfResults;
    private final SearchType? overrideSearchType;
    // `readonly &` because the class is `isolated`: a plain mutable record could not
    // be held in a `final` field, nor read outside a `lock`. `SearchType` needs no
    // such treatment — it is an enum, and so already immutable.
    private final readonly & VectorRerankingConfig? rerankingConfiguration;

    # + knowledgeBase - An existing knowledge base id/ARN, or a `VectorKnowledgeBaseDefinition` to
    #                   find-or-create by name. The vector store it names must already exist
    # + credentials - AWS credential source. Pass `auth:DEFAULT_CREDENTIALS` for the full
    #                 AWS chain (env vars, EKS IRSA, SSO, shared config, EC2 IMDSv2), or an
    #                 explicit `auth:AuthConfig`. SigV4 only — Bedrock API keys are not
    #                 accepted on the agent planes
    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + endpoint - Endpoint resolution options (`fips`, `dualstack`, `customEndpoint`).
    #              The host is derived from the region when this is `()`, which is
    #              correct in every partition — set it only for PrivateLink without
    #              private DNS, an egress gateway, or a local mock. A `customEndpoint`
    #              is a GLOBAL override with the same semantics as the AWS SDK's
    #              `AWS_ENDPOINT_URL`: it applies to every service this client talks to
    # + config - Data source override, chunking, ingest/retrieve tuning, HTTP/retry settings
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Knowledge Base"} string|VectorKnowledgeBaseDefinition knowledgeBase,
            @display {label: "AWS Credentials"} KnowledgeBaseCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Configuration"} *VectorKnowledgeBaseConfig config)
            returns ai:Error? {
        KbSpine spine = check resolveVectorKbSpine(VECTOR_KB_PROVIDER, credentials, region, endpoint,
            knowledgeBase, config);
        self.controlTransport = spine.controlTransport;
        self.dataTransport = spine.dataTransport;
        self.knowledgeBaseId = spine.knowledgeBaseId;
        self.dataSourceId = spine.dataSourceId;
        self.chunker = check resolveChunker(config?.chunker, spine.chunkingStrategy);
        self.ingestTimeout = config.ingestTimeout;
        self.numberOfResults = config?.numberOfResults;
        self.overrideSearchType = config?.overrideSearchType;
        VectorRerankingConfig? reranking = config?.rerankingConfiguration;
        self.rerankingConfiguration = reranking is VectorRerankingConfig ? reranking.cloneReadOnly() : ();
    }

    # Ingests documents into the `CUSTOM` data source, chunking client-side first
    # when the data source's `chunkingStrategy` is `NONE` (detected at construction —
    # see `VectorKnowledgeBaseConfig.chunker`).
    #
    # Blocks until every document reaches a terminal status or `ingestTimeout`
    # elapses, so a `retrieve()` immediately afterward sees them.
    #
    # Bedrock upserts by document id, and this module derives that id from
    # `ai:Metadata.id` when the caller sets one. A document that this module chunks
    # into more than one piece therefore submits its chunks as `<id>#0`, `<id>#1`,
    # ...; a document that does not fan out keeps `<id>` unchanged. Two documents in
    # one call that resolve to the SAME id are rejected rather than silently
    # overwriting each other.
    #
    # + documents - The documents or chunks to index; only text content is supported
    # + return - An `ai:Error` if any document fails to submit or to index; `nil` otherwise
    public isolated function ingest(ai:Chunk[]|ai:Document[]|ai:Document documents) returns ai:Error? {
        observe:KnowledgeBaseIngestSpan span = observe:createKnowledgeBaseIngestSpan(self.knowledgeBaseId);
        span.addId(self.knowledgeBaseId);
        ai:Error? result = self.ingestInternal(documents, span);
        span.close(result);
        return result;
    }

    private isolated function ingestInternal(ai:Chunk[]|ai:Document[]|ai:Document documents,
            observe:KnowledgeBaseIngestSpan span) returns ai:Error? {
        (ai:Chunk|ai:Document)[] items = documents is ai:Chunk[]|ai:Document[] ? documents : [documents];
        KbIngestItem[] prepared = check applyKbChunker(self.chunker, items);
        span.addInputChunks(prepared.'map(item => item.item).toJson());

        string[] documentIds = [];
        json[] wireDocuments = [];
        foreach KbIngestItem item in prepared {
            [json, string] [wireDoc, id] =
                check chunkToKnowledgeBaseDocument(VECTOR_KB_PROVIDER, item.item, item.chunkOrdinal);
            wireDocuments.push(wireDoc);
            documentIds.push(id);
        }
        check assertDistinctDocumentIds(documentIds);

        foreach json[] batch in partitionJson(wireDocuments, KB_DOCUMENT_BATCH_SIZE) {
            map<json>[] _ = check ingestDocumentsBatch(self.controlTransport, self.knowledgeBaseId,
                self.dataSourceId, batch);
        }

        map<DocumentOutcome> outcomes = check pollDocumentsTerminal(self.controlTransport, self.knowledgeBaseId,
            self.dataSourceId, documentIds, self.ingestTimeout);
        string[] failed = [];
        foreach [string, DocumentOutcome] [id, outcome] in outcomes.entries() {
            if KB_DOC_FAILED_STATUSES.indexOf(outcome.status) is int {
                failed.push(string `${id} (${outcome.status}: ${outcome.statusReason ?: "no reason reported"})`);
            }
        }
        if failed.length() > 0 {
            return error ai:Error(
                string `${failed.length()} of ${documentIds.length()} document(s) failed to index: ` +
                string:'join("; ", ...failed));
        }
    }

    # Retrieves relevant chunks. Searches across every data source on the knowledge
    # base, not just the `CUSTOM` one `ingest()` writes to.
    #
    # + query - The text query to search for
    # + maxLimit - The maximum number of items to return, or `-1` for no limit (subject to your vector store's own relevance cutoff)
    # + filters - Optional metadata filters. Operator support is BACKEND-DEPENDENT — see the module README
    # + return - Matching chunks with similarity scores, or an `ai:Error`
    public isolated function retrieve(string query, int maxLimit = 10, ai:MetadataFilters? filters = ())
            returns ai:QueryMatch[]|ai:Error {
        observe:KnowledgeBaseRetrieveSpan span = observe:createKnowledgeBaseRetrieveSpan(self.knowledgeBaseId);
        span.addId(self.knowledgeBaseId);
        span.addInputQuery(query);
        span.addLimit(maxLimit);
        if filters is ai:MetadataFilters {
            span.addFilter(filters.toJson());
        }
        ai:QueryMatch[]|ai:Error matches = self.retrieveInternal(query, maxLimit, filters);
        if matches is ai:Error {
            span.close(matches);
            return matches;
        }
        span.addOutput(matches.toJson());
        span.close();
        return matches;
    }

    private isolated function retrieveInternal(string query, int maxLimit, ai:MetadataFilters? filters)
            returns ai:QueryMatch[]|ai:Error {
        if maxLimit != -1 && maxLimit <= 0 {
            return error ai:Error("'maxLimit' must be a positive integer, or -1 for no limit");
        }
        check guardRetrieveQuery(query);
        json? userFilter = ();
        if filters is ai:MetadataFilters {
            userFilter = check metadataFiltersToRetrievalFilter(filters);
        }

        int configuredCap = self.numberOfResults ?: KB_MAX_RESULTS_PER_CALL;
        int cap = configuredCap < KB_MAX_RESULTS_PER_CALL ? configuredCap : KB_MAX_RESULTS_PER_CALL;
        int perCall = maxLimit == -1 ? cap : (maxLimit < cap ? maxLimit : cap);

        ai:QueryMatch[] matches = [];
        string? nextToken = ();
        while true {
            [json[], string?] [results, respNextToken] = check callVectorRetrieve(self.dataTransport,
                self.knowledgeBaseId, query, userFilter, perCall, self.overrideSearchType,
                self.rerankingConfiguration, nextToken);
            foreach json result in results {
                matches.push(check retrievalResultToQueryMatch(VECTOR_KB_PROVIDER, result));
                if maxLimit != -1 && matches.length() >= maxLimit {
                    return matches.slice(0, maxLimit);
                }
            }
            nextToken = respNextToken;
            if nextToken is () {
                break;
            }
        }
        return matches;
    }

    # Deletes documents matching `filters`.
    #
    # Bedrock has no metadata-based delete, so this enumerates every document on
    # every data source (`ListKnowledgeBaseDocuments`) and, per data source, runs TWO
    # PAGED `Retrieve` enumerations — filtered by `filters`, then unfiltered — to
    # classify every candidate as a confirmed match, genuinely excluded, or
    # indeterminate. See `resolveDataSourceDeletes` (knowledgebase_common.bal) for the
    # algorithm (A17) — the same implementation `BedrockManagedKnowledgeBase` uses,
    # parameterised here by the self-managed reserved metadata key
    # (`VECTOR_SOURCE_URI_METADATA_KEY`, NOT the managed `_source_uri`) and the
    # `vectorSearchConfiguration` branch (`vectorDeleteRetrieve`).
    #
    # **Cost: two paged `Retrieve` enumerations PER DATA SOURCE** (a small, bounded
    # number of round trips regardless of how many documents the data source holds —
    # `KB_DELETE_ENUMERATION_MAX_PAGES` pages of 100 results each, at most), not one
    # to two round trips per document. A maintenance operation, not something to put
    # on a request path, but no longer scales with the knowledge base's size.
    #
    # `filters` must contain at least one leaf predicate: a filter set that
    # constrains nothing matches every document, and "delete everything" has to be
    # explicit rather than a degenerate case of an empty collection.
    #
    # Only `CUSTOM`/`S3` data sources support
    # deletion; documents on other data source types are named in the returned error
    # rather than silently skipped, and deletes that can be made still happen even
    # when some documents or data sources cannot be reached.
    #
    # + filters - The metadata filters used to identify which documents to delete;
    #             must contain at least one leaf predicate
    # + return - An `ai:Error` naming indeterminate documents, documents the service
    #            did not confirm deleted, undeletable data sources, or data sources
    #            refused outright (enumeration truncation, or a store that does not
    #            appear to honour metadata filters); `nil` otherwise
    public isolated function deleteByFilter(ai:MetadataFilters filters) returns ai:Error? {
        json? userFilter = check metadataFiltersToRetrievalFilter(filters);
        check guardDeleteFilter(userFilter, filters);

        map<json>[] dataSourceSummaries = check listDataSources(self.controlTransport, self.knowledgeBaseId);
        string[] undeletableDataSources = [];
        string[] indeterminate = [];
        string[] refused = [];
        map<json[]> toDeleteByDataSource = {};

        foreach map<json> summary in dataSourceSummaries {
            string? dsId = stringField(summary, "dataSourceId");
            if dsId is () {
                continue;
            }
            map<json> dataSource = check getDataSource(self.controlTransport, self.knowledgeBaseId, dsId);
            string effectiveType = effectiveDataSourceType(dataSource);
            if effectiveType != "CUSTOM" && effectiveType != "S3" {
                undeletableDataSources.push(string `${dsId} (${effectiveType})`);
                continue;
            }

            DeletableDocument[] candidates =
                check listDeletableDocuments(self.controlTransport, self.knowledgeBaseId, dsId, effectiveType);
            if candidates.length() == 0 {
                // Nothing to classify — skip the two enumeration round trips entirely.
                continue;
            }
            DataSourceDeleteResult result = check resolveDataSourceDeletes(self.dataTransport, self.knowledgeBaseId,
                dsId, userFilter, candidates, VECTOR_SOURCE_URI_METADATA_KEY, vectorDeleteRetrieve);
            refused.push(...result.notes);
            string? refusalReason = result.refusalReason;
            if refusalReason is string {
                refused.push(refusalReason);
                continue;
            }
            indeterminate.push(...result.indeterminate);
            if result.toDelete.length() > 0 {
                toDeleteByDataSource[dsId] = result.toDelete;
            }
        }

        string[] notDeleted = [];
        foreach [string, json[]] [dsId, identifiers] in toDeleteByDataSource.entries() {
            notDeleted.push(...check deleteDocuments(self.controlTransport, self.knowledgeBaseId, dsId,
                identifiers));
        }

        return deleteByFilterOutcome(indeterminate, notDeleted, undeletableDataSources, refused);
    }

}
