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
// knowledge base needs a `CUSTOM` data source; a definition creates one. Self-managed
// (VECTOR) knowledge bases belong to `SelfManagedKnowledgeBase`.

# A Bedrock knowledge base whose vector store is managed by Bedrock.
@display {label: "Bedrock Managed Knowledge Base"}
public distinct isolated client class ManagedKnowledgeBase {
    *ai:KnowledgeBase;

    private final BedrockTransport controlTransport;
    private final BedrockTransport dataTransport;
    private final string knowledgeBaseId;
    private final string dataSourceId;
    private final ai:Chunker|ai:AUTO|ai:DISABLE chunker;
    private final decimal ingestTimeout;
    private final int? numberOfResults;
    private final RerankingModelType? rerankingModelType;

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
    # + rerankingModelType - Reranking model for retrieval. No reranking when unset
    # + endpoint - FIPS, dual-stack or custom-endpoint options. Derived from the region when unset
    # + config - Ingestion, retrieval and transport options
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Knowledge Base"} string|ManagedKnowledgeBaseDefinition knowledgeBase,
            @display {label: "Authentication"} KnowledgeBaseAuthConfig auth,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Data Source ID"} string? dataSourceId = (),
            @display {label: "Chunker"} ai:Chunker|ai:AUTO|ai:DISABLE? chunker = (),
            @display {label: "Reranking Model"} RerankingModelType? rerankingModelType = (),
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Configuration"} *ManagedKnowledgeBaseConfig config)
            returns ai:Error? {
        check validateManagedRetrievalConfig(config);
        KbSpine spine = check resolveKbSpine(MANAGED_KB_PROVIDER, auth, region,
            endpoint, knowledgeBase, dataSourceId, config?.httpConfig, config?.retryConfig,
            rerankingModelType);
        self.controlTransport = spine.controlTransport;
        self.dataTransport = spine.dataTransport;
        self.knowledgeBaseId = spine.knowledgeBaseId;
        self.dataSourceId = spine.dataSourceId;
        self.chunker = check resolveChunker(chunker, spine.chunkingStrategy);
        self.ingestTimeout = config.ingestTimeout;
        self.numberOfResults = config?.numberOfResults;
        self.rerankingModelType = rerankingModelType;
    }

    // A document split into several chunks submits `<id>#0`, `<id>#1`, and so on.

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
                check chunkToKnowledgeBaseDocument(MANAGED_KB_PROVIDER, item.item, item.chunkOrdinal);
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

    // Searches every data source on the knowledge base. Bedrock's relevance cut-off
    // still applies with `maxLimit = -1`.

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
            [json[], string?] [results, respNextToken] = check callRetrieve(self.dataTransport,
                self.knowledgeBaseId, query, userFilter, perCall, self.rerankingModelType, nextToken);
            foreach json result in results {
                matches.push(check retrievalResultToQueryMatch(MANAGED_KB_PROVIDER, result));
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

    // Bedrock has no delete-by-metadata, so each listed document is checked against the
    // filter through `Retrieve` (see `resolveDataSourceDeletes`).

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
            self.dataSourceId, userFilter, candidates, SOURCE_URI_METADATA_KEY, MANAGED_DATA_SOURCE_ID_METADATA_KEY, managedDeleteRetrieve);
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

// The chunker: `ai:DISABLE` when Bedrock chunks, `ai:AUTO` when the strategy is `NONE`.
// A chunker against a data source that chunks itself is refused, as Bedrock would split
// the chunks again.
isolated function resolveChunker(ai:Chunker|ai:AUTO|ai:DISABLE? configured, ChunkingStrategy detected)
        returns ai:Chunker|ai:AUTO|ai:DISABLE|ai:Error {
    boolean serverChunks = detected != NONE;
    if configured is () {
        return serverChunks ? ai:DISABLE : ai:AUTO;
    }
    if serverChunks && configured !is ai:DISABLE {
        return errorWithDetail(
            string `The data source chunks server-side (chunkingStrategy '${detected}'), so 'chunker' must ` +
            "be 'ai:DISABLE'. To chunk client-side, use a data source with 'chunkingStrategy = NONE'.",
            "Bedrock re-splits whatever is submitted, overwriting the boundaries the chunker computed.");
    }
    return configured;
}

// A copy of `ai:VectorKnowledgeBase`'s private `guessChunker`.
isolated function guessChunkerForKb(ai:Document|ai:Chunk doc) returns ai:Chunker {
    string? mimeType = doc.metadata?.mimeType;
    if mimeType == "text/markdown" {
        return new ai:MarkdownChunker();
    }
    if mimeType == "text/html" {
        return new ai:HtmlChunker();
    }
    string? fileName = doc.metadata?.fileName;
    if fileName is string {
        if fileName.endsWith(".md") {
            return new ai:MarkdownChunker();
        }
        if fileName.endsWith(".html") {
            return new ai:HtmlChunker();
        }
    }
    return new ai:GenericRecursiveChunker();
}

// Chunks of a split document get `<id>#<n>` ids: chunkers copy the parent's `id`, and
// Bedrock would keep only one of them.
isolated function applyKbChunker(ai:Chunker|ai:AUTO|ai:DISABLE chunker, (ai:Chunk|ai:Document)[] items)
        returns KbIngestItem[]|ai:Error {
    if chunker is ai:DISABLE {
        return from ai:Chunk|ai:Document item in items
            select {item, chunkOrdinal: ()};
    }
    KbIngestItem[] prepared = [];
    foreach ai:Chunk|ai:Document item in items {
        ai:Chunker chunkerToUse = chunker is ai:Chunker ? chunker : guessChunkerForKb(item);
        ai:Chunk[] chunks = check chunkerToUse.chunk(item);
        if chunks.length() == 1 {
            // One chunk keeps the caller's id.
            prepared.push({item: chunks[0], chunkOrdinal: ()});
            continue;
        }
        foreach int i in 0 ..< chunks.length() {
            prepared.push({item: chunks[i], chunkOrdinal: i});
        }
    }
    return prepared;
}

isolated function guardRetrieveQuery(string query) returns ai:Error? {
    if query.trim().length() == 0 {
        return error ai:Error("'query' must be a non-empty, non-whitespace string — Bedrock's 'Retrieve' " +
            "rejects an empty query with 'Text input is required.'");
    }
    return;
}

// An empty filter would delete every document.
isolated function guardDeleteFilter(json? userFilter, ai:MetadataFilters filters) returns ai:Error? {
    if userFilter is () || filterLeafCount(filters) == 0 {
        return errorWithDetail(
            "deleteByFilter requires at least one metadata filter. Pass a filter that selects the " +
            "documents to remove.",
            "An 'ai:MetadataFilters' with no leaf predicates matches every document, which would delete " +
            "the entire knowledge base.");
    }
    return;
}

// Called after every possible delete, so one error reports everything left.
isolated function deleteByFilterOutcome(UnresolvedCandidate[] indeterminate, string[] notDeleted,
        string[] refused = []) returns ai:Error? {
    string[] problems = [];
    problems.push(...unresolvedProblems(indeterminate));
    if notDeleted.length() > 0 {
        problems.push(string `${notDeleted.length()} document(s) matched the filter but were not confirmed ` +
            string `deleted by 'DeleteKnowledgeBaseDocuments': ${string:'join(", ", ...notDeleted)}`);
    }
    // A data source refused outright (it ignores filters) is reported on its own.
    if refused.length() > 0 {
        problems.push(string:'join("; ", ...refused));
    }
    if problems.length() == 0 {
        return;
    }
    return error ai:Error(
        string `deleteByFilter deleted every confirmed match, but: ${string:'join("; ", ...problems)}`);
}

// One line per cause with a count, a reason and a few ids, rather than every id: the
// undecidable set belongs to the knowledge base and can be large.
isolated function unresolvedProblems(UnresolvedCandidate[] unresolved) returns string[] {
    if unresolved.length() == 0 {
        return [];
    }
    map<UnresolvedCandidate[]> byReason = {};
    foreach UnresolvedCandidate candidate in unresolved {
        UnresolvedCandidate[] bucket = byReason[candidate.reason] ?: [];
        bucket.push(candidate);
        byReason[candidate.reason] = bucket;
    }
    string[] problems = [];
    foreach [string, UnresolvedCandidate[]] [reason, bucket] in byReason.entries() {
        problems.push(string `${bucket.length()} document(s) could not be checked against the filter — ` +
            string `${unresolvedCause(<UnresolvedReason>reason)}: ${sampleOfIds(bucket)}`);
    }
    return problems;
}

isolated function unresolvedCause(UnresolvedReason reason) returns string {
    match reason {
        UNRESOLVED_NO_DOCUMENT_ID => {
            return "they were ingested without an 'ai:Metadata.id', so this knowledge base holds no " +
                "attribute that identifies them and no metadata filter can select one. Re-ingest them " +
                "with an 'ai:Metadata.id' to make them deletable by filter";
        }
        UNRESOLVED_NO_PIN_KEY => {
            return "this data source exposes no metadata attribute that identifies a document, so none " +
                "of them can be matched individually. Ingesting with an 'ai:Metadata.id' provides one";
        }
        UNRESOLVED_GROUP_TOO_LARGE => {
            return string `more than ${KB_MAX_RESULTS_PER_CALL} documents share one 'ai:Metadata.id', ` +
                "which is more than one 'Retrieve' call can return. The confirmed matches WERE deleted, " +
                "so repeating this same call continues with the rest";
        }
    }
    return "the knowledge base did not return them under their own identity, so whether they match is " +
        "unknown; they were left in place";
}

isolated function sampleOfIds(UnresolvedCandidate[] candidates) returns string {
    string[] shown = [];
    foreach UnresolvedCandidate candidate in candidates {
        if shown.length() >= KB_REPORTED_ID_SAMPLE {
            break;
        }
        shown.push(string `${candidate.sourceValue} (data source ${candidate.dataSourceId})`);
    }
    string listed = string:'join(", ", ...shown);
    int remainder = candidates.length() - shown.length();
    return remainder > 0 ? string `${listed}, and ${remainder} more` : listed;
}

isolated function validateManagedRetrievalConfig(ManagedKnowledgeBaseConfig config) returns ai:Error? {
    int? numberOfResults = config?.numberOfResults;
    if numberOfResults is int && (numberOfResults < 1 || numberOfResults > KB_MAX_RESULTS_PER_CALL) {
        return error ai:Error(
            string `'numberOfResults' must be between 1 and ${KB_MAX_RESULTS_PER_CALL}, got ${numberOfResults}`);
    }
    return;
}
