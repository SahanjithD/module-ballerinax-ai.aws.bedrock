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

# A Bedrock managed knowledge base (`KnowledgeBaseConfiguration.type = MANAGED` —
# Bedrock owns the vector store) exposed through `ai:KnowledgeBase`.
#
# Pass an existing knowledge base id to attach to it, or a `KnowledgeBaseDefinition`
# to find-or-create one by name. `ingest()`/`retrieve()`/`deleteByFilter()` need the
# knowledge base to have a `CUSTOM` (direct-ingestion) data source; a definition
# creates one, and attaching by id fails construction, naming why, if it lacks one.
#
# Self-managed (customer vector store, `type = VECTOR`) knowledge bases are not
# supported here — use `BedrockVectorKnowledgeBase` for those.
public distinct isolated client class BedrockManagedKnowledgeBase {
    *ai:KnowledgeBase;

    private final BedrockTransport controlTransport;
    private final BedrockTransport dataTransport;
    private final string knowledgeBaseId;
    private final string dataSourceId;
    private final ai:Chunker|ai:AUTO|ai:DISABLE chunker;
    private final decimal ingestTimeout;
    private final int? numberOfResults;
    private final RerankingModelType? rerankingModelType;

    # + knowledgeBase - An existing knowledge base id/ARN, or a `KnowledgeBaseDefinition` to find-or-create by name
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
            @display {label: "Knowledge Base"} string|KnowledgeBaseDefinition knowledgeBase,
            @display {label: "AWS Credentials"} KnowledgeBaseCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Endpoint Configuration"} aws:EndpointConfig? endpoint = (),
            @display {label: "Configuration"} *ManagedKnowledgeBaseConfig config)
            returns ai:Error? {
        check validateManagedRetrievalConfig(config);
        KbSpine spine = check resolveKbSpine(MANAGED_KB_PROVIDER, credentials, region,
            endpoint, knowledgeBase, config?.dataSourceId, config?.httpConfig, config?.retryConfig,
            config?.rerankingModelType);
        self.controlTransport = spine.controlTransport;
        self.dataTransport = spine.dataTransport;
        self.knowledgeBaseId = spine.knowledgeBaseId;
        self.dataSourceId = spine.dataSourceId;
        self.chunker = check resolveChunker(config?.chunker, spine.chunkingStrategy);
        self.ingestTimeout = config.ingestTimeout;
        self.numberOfResults = config?.numberOfResults;
        self.rerankingModelType = config?.rerankingModelType;
    }

    # Ingests documents into the `CUSTOM` data source, chunking client-side first
    # when the data source's `chunkingStrategy` is `NONE` (detected at construction —
    # see `ManagedKnowledgeBaseConfig.chunker`).
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

    # Retrieves relevant chunks. Searches across every data source on the knowledge
    # base, not just the `CUSTOM` one `ingest()` writes to, so results include
    # anything AWS's own connectors synced in.
    #
    # + query - The text query to search for
    # + maxLimit - The maximum number of items to return, or `-1` for no limit (subject to Bedrock's own relevance cutoff)
    # + filters - Optional metadata filters
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

    # Deletes documents matching `filters`.
    #
    # Bedrock has no metadata-based delete, so this enumerates every document on
    # every data source (`ListKnowledgeBaseDocuments`) and, per data source, runs TWO
    # PAGED `Retrieve` enumerations — filtered by `filters`, then unfiltered — to
    # classify every candidate as a confirmed match, genuinely excluded, or
    # indeterminate. See `resolveDataSourceDeletes` (knowledgebase_common.bal) for the
    # algorithm (A17).
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
    # Only `CUSTOM`/`S3` data sources support deletion; documents on other data
    # source types (SharePoint, Confluence, Drive, Web, ...) are named in the
    # returned error rather than silently skipped, and deletes that can be made still
    # happen even when some documents or data sources cannot be reached.
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
                dsId, userFilter, candidates, SOURCE_URI_METADATA_KEY, managedDeleteRetrieve);
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

// Resolves `ManagedKnowledgeBaseConfig.chunker`'s default from the DETECTED
// data-source chunking strategy — `ai:DISABLE` when Bedrock chunks server-side
// (every strategy but NONE), `ai:AUTO` when it is NONE. An explicit `ai:Chunker`
// against a server-chunking data source is a construction error: Bedrock would
// re-split whatever is submitted, silently overwriting the chunker's own boundaries.
isolated function resolveChunker(ai:Chunker|ai:AUTO|ai:DISABLE? configured, ChunkingStrategy detected)
        returns ai:Chunker|ai:AUTO|ai:DISABLE|ai:Error {
    boolean serverChunks = detected != NONE;
    if configured is () {
        return serverChunks ? ai:DISABLE : ai:AUTO;
    }
    if serverChunks && configured !is ai:DISABLE {
        return error ai:Error(
            string `The resolved data source chunks server-side (chunkingStrategy '${detected}'), so an ` +
            "explicit 'chunker' (an 'ai:Chunker' or 'ai:AUTO') would double-chunk — Bedrock re-splits " +
            "whatever is submitted, overwriting the boundaries the chunker just computed. Pass " +
            "'chunker = ai:DISABLE', or recreate the data source with 'chunkingStrategy = NONE' to chunk " +
            "client-side.");
    }
    return configured;
}

// Duplicated from `ai:VectorKnowledgeBase`'s private `guessChunker`, which is
// module-private in the `ai` package and so cannot be reused directly — the same
// duplication the Azure knowledge base precedent carries.
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

# One document ready to submit, with the position of the chunk within its parent when
# this module produced it client-side.
#
# + item - The chunk or document to encode
# + chunkOrdinal - 0-based position within the parent's chunks, or `()` when the item
#                  was passed through as the caller gave it
type KbIngestItem record {|
    ai:Chunk|ai:Document item;
    int? chunkOrdinal;
|};

// Client-side chunking, shared by both classes.
//
// `chunkOrdinal` is set only where it is NEEDED: on the chunks of a parent that fanned
// out into more than one. Ballerina's chunkers copy the parent's metadata — `id`
// included — onto every chunk, and Bedrock upserts by `customDocumentIdentifier.id`,
// so without a per-chunk id a 20-chunk document submits 20 documents under one id and
// keeps exactly one. See `documentIdFor`.
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
            // A 1:1 chunking keeps the caller's own id — see `documentIdFor`.
            prepared.push({item: chunks[0], chunkOrdinal: ()});
            continue;
        }
        foreach int i in 0 ..< chunks.length() {
            prepared.push({item: chunks[i], chunkOrdinal: i});
        }
    }
    return prepared;
}

// `Retrieve` REJECTS an empty query: `{"text": ""}`, `{"text": " "}` and an omitted
// `text` all return 400 "Text input is required." (The service model's
// `KnowledgeBaseQueryTextString` declares `min: 0`, which the live API contradicts.)
// Caught here so a trivial caller mistake never costs a signed round trip.
isolated function guardRetrieveQuery(string query) returns ai:Error? {
    if query.trim().length() == 0 {
        return error ai:Error("'query' must be a non-empty, non-whitespace string — Bedrock's 'Retrieve' " +
            "rejects an empty query with 'Text input is required.'");
    }
    return;
}

// The guard both `deleteByFilter` implementations run before touching anything.
//
// A filter set that constrains nothing makes every per-document probe "does this
// document exist" — every one hits, and the whole knowledge base is deleted.
// `ai:KnowledgeBase.deleteByFilter` takes filters as a REQUIRED argument, so a caller
// assembling them from a collection that happened to be empty would get silent total
// deletion. Refuse instead: "delete everything" must be explicit, never a degenerate
// case.
//
// Both conditions are checked. The nil test catches an empty group; the leaf count
// answers the question the nil test is really asking — did the caller constrain
// anything at all? — without depending on how the wire encoder folds nested empty
// groups. Total deletion is not a case to protect against with one check.
isolated function guardDeleteFilter(json? userFilter, ai:MetadataFilters filters) returns ai:Error? {
    if userFilter is () || filterLeafCount(filters) == 0 {
        return error ai:Error(
            "deleteByFilter requires at least one metadata filter — an 'ai:MetadataFilters' with no " +
            "leaf predicates matches every document, which would delete the entire knowledge base. " +
            "Pass a filter that selects the documents to remove.");
    }
    return;
}

// The shared tail of `deleteByFilter`: everything that could not be confirmed, in one
// error, after every delete that COULD be made has been made.
isolated function deleteByFilterOutcome(string[] indeterminate, string[] notDeleted,
        string[] undeletableDataSources, string[] refused = []) returns ai:Error? {
    string[] problems = [];
    if indeterminate.length() > 0 {
        problems.push(string `${indeterminate.length()} document(s) could not be confirmed to match or not ` +
            string `match the filter (the enumeration did not identify them): ` +
            string:'join(", ", ...indeterminate));
    }
    if notDeleted.length() > 0 {
        problems.push(string `${notDeleted.length()} document(s) matched the filter but were not confirmed ` +
            string `deleted by 'DeleteKnowledgeBaseDocuments': ${string:'join(", ", ...notDeleted)}`);
    }
    if undeletableDataSources.length() > 0 {
        problems.push(string `${undeletableDataSources.length()} data source(s) are not deletable through ` +
            string `this API — only CUSTOM/S3 support 'DeleteKnowledgeBaseDocuments': ` +
            string:'join(", ", ...undeletableDataSources));
    }
    // A17: a data source refused outright — enumeration truncation, or a store that
    // does not appear to honour metadata filters — contributes NOTHING to `toDelete`,
    // so it is reported here rather than folded into `indeterminate`.
    if refused.length() > 0 {
        problems.push(string:'join("; ", ...refused));
    }
    if problems.length() == 0 {
        return;
    }
    return error ai:Error(
        string `deleteByFilter deleted every confirmed match, but: ${string:'join("; ", ...problems)}`);
}

// Rejects retrieve-time configuration Bedrock would reject, before any I/O. The
// vector class's `validateVectorRetrievalConfig` is the same bound on the same
// service-side shape, `KnowledgeBaseVectorSearchConfigurationNumberOfResultsInteger`
// (min 1, max 100).
isolated function validateManagedRetrievalConfig(ManagedKnowledgeBaseConfig config) returns ai:Error? {
    int? numberOfResults = config?.numberOfResults;
    if numberOfResults is int && (numberOfResults < 1 || numberOfResults > KB_MAX_RESULTS_PER_CALL) {
        return error ai:Error(
            string `'numberOfResults' must be between 1 and ${KB_MAX_RESULTS_PER_CALL}, got ${numberOfResults}`);
    }
    return;
}
