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

// Attach by knowledge base id, or find or create one by name with a definition. The
// vector store must already exist. `ingest()` also needs `bedrock:StartIngestionJob`
// and `bedrock:IngestKnowledgeBaseDocuments`, and the service role needs access to
// the store.
// https://docs.aws.amazon.com/bedrock/latest/userguide/kb-permissions.html

# A Bedrock knowledge base backed by your own vector store.
@display {label: "Bedrock Self-Managed Knowledge Base"}
public distinct isolated client class SelfManagedKnowledgeBase {
    *ai:KnowledgeBase;

    private final BedrockTransport controlTransport;
    private final BedrockTransport dataTransport;
    private final string knowledgeBaseId;
    private final string dataSourceId;
    private final ai:Chunker|ai:AUTO|ai:DISABLE chunker;
    private final decimal ingestTimeout;
    private final int? numberOfResults;
    private final SearchType? overrideSearchType;
    // `readonly &` so an isolated class can hold it in a `final` field.
    private final readonly & VectorRerankingConfig? rerankingConfiguration;

    // `auth` is SigV4 only: Bedrock API keys are not accepted for knowledge bases. A
    // `customEndpoint` applies to every service this client calls.

    # + knowledgeBase - An existing knowledge base id or ARN, or a definition to find or create by name
    # + auth - AWS credentials; `auth:DEFAULT_CREDENTIALS` uses the default chain
    // An unset `dataSourceId` needs exactly one `CUSTOM` data source. An unset
    // `chunker` follows the data source: `ai:AUTO` when its strategy is `NONE`, else
    // `ai:DISABLE`. A chunker against a data source that chunks itself is refused.

    # + region - AWS region, e.g. `aws:US_EAST_1`
    # + dataSourceId - ID of the `CUSTOM` data source to use. Found automatically when unset
    # + chunker - Client-side chunker. Chosen from the data source's chunking when unset
    # + rerankingConfiguration - Reranking for retrieval. No reranking when unset
    # + endpoint - FIPS, dual-stack or custom-endpoint options. Derived from the region when unset
    # + config - Ingestion, retrieval and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Knowledge Base"} string|SelfManagedKnowledgeBaseDefinition knowledgeBase,
            @display {label: "Authentication"} KnowledgeBaseAuthConfig auth,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Data Source ID"} string? dataSourceId = (),
            @display {label: "Chunker"} ai:Chunker|ai:AUTO|ai:DISABLE? chunker = (),
            @display {label: "Reranking"} VectorRerankingConfig? rerankingConfiguration = (),
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Configuration"} *SelfManagedKnowledgeBaseConfig config)
            returns ai:Error? {
        KbSpine spine = check resolveVectorKbSpine(VECTOR_KB_PROVIDER, auth, region, endpoint,
            knowledgeBase, dataSourceId, {numberOfResults: config?.numberOfResults, rerankingConfiguration},
            config?.httpConfig, config?.retryConfig);
        self.controlTransport = spine.controlTransport;
        self.dataTransport = spine.dataTransport;
        self.knowledgeBaseId = spine.knowledgeBaseId;
        self.dataSourceId = spine.dataSourceId;
        self.chunker = check resolveChunker(chunker, spine.chunkingStrategy);
        self.ingestTimeout = config.ingestTimeout;
        self.numberOfResults = config?.numberOfResults;
        self.overrideSearchType = config?.overrideSearchType;
        self.rerankingConfiguration = rerankingConfiguration is VectorRerankingConfig
            ? rerankingConfiguration.cloneReadOnly() : ();
    }

    // Chunks client-side when the data source does not chunk, then waits until every
    // document is indexed or `ingestTimeout` passes. Document ids come from
    // `ai:Metadata.id`; a document split into several chunks submits `<id>#0`,
    // `<id>#1`, and so on. Two documents with the same id in one call are refused.

    # Ingests documents into the knowledge base.
    #
    # + documents - The documents or chunks to ingest; only text content is supported
    # + return - An `ai:Error` if ingestion fails, otherwise `nil`
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

    // Searches every data source on the knowledge base. Which filter operators work
    // depends on the vector store; see the README.

    # Retrieves relevant chunks for the given query.
    #
    # + query - The text query to search for
    # + maxLimit - The maximum number of items to return, or `-1` for no limit
    # + filters - Optional metadata filters to apply during retrieval
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

    // Bedrock has no delete-by-metadata, so this lists the data source's documents and
    // checks each against the filter through `Retrieve` (see `resolveDataSourceDeletes`).
    // A maintenance operation, not one for a request path. `filters` must constrain
    // something, so deleting everything is never an accident. Only this class's data
    // source is touched.

    # Deletes documents that match the given metadata filters.
    #
    # + filters - The metadata filters identifying the documents to delete
    # + return - An `ai:Error` naming anything not deleted or confirmed, otherwise `nil`
    public isolated function deleteByFilter(ai:MetadataFilters filters) returns ai:Error? {
        json? userFilter = check metadataFiltersToRetrievalFilter(filters);
        check guardDeleteFilter(userFilter, filters);

        // Only this class's data source: ids are unique per data source, and an S3
        // source would re-sync anything deleted.
        DeletableDocument[] candidates = check listDeletableDocuments(self.controlTransport,
                self.knowledgeBaseId, self.dataSourceId, "CUSTOM");
        if candidates.length() == 0 {
            return;
        }
        DataSourceDeleteResult result = check resolveDataSourceDeletes(self.dataTransport, self.knowledgeBaseId,
            self.dataSourceId, userFilter, candidates, VECTOR_SOURCE_URI_METADATA_KEY, VECTOR_DATA_SOURCE_ID_METADATA_KEY, vectorDeleteRetrieve);
        string[] refused = [...result.notes];
        string? refusalReason = result.refusalReason;
        if refusalReason is string {
            refused.push(refusalReason);
            return deleteByFilterOutcome([], [], refused);
        }
        string[] notDeleted = result.toDelete.length() == 0 ? [] :
            check deleteDocuments(self.controlTransport, self.knowledgeBaseId, self.dataSourceId, result.toDelete);
        return deleteByFilterOutcome(result.indeterminate, notDeleted, refused);
    }

}
