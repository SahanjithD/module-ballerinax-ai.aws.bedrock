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
    # + config - Data source override, chunking, ingest/retrieve tuning, HTTP/retry settings
    # + return - `nil` on success; otherwise an `ai:Error`
    public isolated function init(
            @display {label: "Knowledge Base"} string|KnowledgeBaseDefinition knowledgeBase,
            @display {label: "AWS Credentials"} KnowledgeBaseCredentials credentials,
            @display {label: "Region"} aws:Region|string region,
            @display {label: "Configuration"} *ManagedKnowledgeBaseConfig config)
            returns ai:Error? {
        KbSpine spine = check resolveKbSpine("BedrockManagedKnowledgeBase", credentials, region,
            config?.endpoint, knowledgeBase, config?.dataSourceId, config?.httpConfig, config?.retryConfig,
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
    # + documents - The documents or chunks to index; only text content is supported
    # + return - An `ai:Error` if any document fails to submit or to index; `nil` otherwise
    public isolated function ingest(ai:Chunk[]|ai:Document[]|ai:Document documents) returns ai:Error? {
        (ai:Chunk|ai:Document)[] items = documents is ai:Chunk[]|ai:Document[] ? documents : [documents];
        (ai:Chunk|ai:Document)[] chunked = check self.applyChunker(items);

        string[] documentIds = [];
        json[] wireDocuments = [];
        foreach ai:Chunk|ai:Document item in chunked {
            [json, string] [wireDoc, id] = check chunkToKnowledgeBaseDocument(item);
            wireDocuments.push(wireDoc);
            documentIds.push(id);
        }

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
        if maxLimit != -1 && maxLimit <= 0 {
            return error ai:Error("'maxLimit' must be a positive integer, or -1 for no limit");
        }
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
                matches.push(check retrievalResultToQueryMatch(result));
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
    # every data source and probes each one against `filters` through `Retrieve`.
    # Costs one `Retrieve` call per document — a maintenance operation, not
    # something to put on a request path. Only `CUSTOM`/`S3` data sources support
    # deletion; documents on other data source types (SharePoint, Confluence,
    # Drive, Web, ...) are named in the returned error rather than silently
    # skipped, and deletes that can be made still happen even when some data
    # sources cannot be reached.
    #
    # + filters - The metadata filters used to identify which documents to delete
    # + return - An `ai:Error` naming any undeletable data sources; `nil` otherwise
    public isolated function deleteByFilter(ai:MetadataFilters filters) returns ai:Error? {
        json? userFilter = check metadataFiltersToRetrievalFilter(filters);

        map<json>[] dataSourceSummaries = check listDataSources(self.controlTransport, self.knowledgeBaseId);
        string[] undeletableDataSources = [];
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
            json[] matchesForThisSource = [];
            foreach DeletableDocument candidate in candidates {
                json probeFilter = withSourceUriFilter(userFilter, candidate.sourceValue);
                // Pinned to one document, so a zero-hit result means the filter
                // genuinely excluded it — never that the floor hid it.
                if check retrieveHasMatch(self.dataTransport, self.knowledgeBaseId, probeFilter) {
                    matchesForThisSource.push(candidate.identifier);
                }
            }
            if matchesForThisSource.length() > 0 {
                toDeleteByDataSource[dsId] = matchesForThisSource;
            }
        }

        foreach [string, json[]] [dsId, identifiers] in toDeleteByDataSource.entries() {
            foreach json[] batch in partitionJson(identifiers, KB_DOCUMENT_BATCH_SIZE) {
                map<json>[] _ = check deleteDocumentsBatch(self.controlTransport, self.knowledgeBaseId, dsId, batch);
            }
        }

        if undeletableDataSources.length() == 0 {
            return;
        }
        return error ai:Error(
            string `deleteByFilter deleted every match it could reach, but ` +
            string `${undeletableDataSources.length()} data source(s) are not deletable through this API — ` +
            string `only CUSTOM/S3 support 'DeleteKnowledgeBaseDocuments': ` +
            string:'join(", ", ...undeletableDataSources));
    }

    private isolated function applyChunker((ai:Chunk|ai:Document)[] items) returns (ai:Chunk|ai:Document)[]|ai:Error {
        ai:Chunker|ai:AUTO|ai:DISABLE chunker = self.chunker;
        if chunker is ai:DISABLE {
            return items;
        }
        (ai:Chunk|ai:Document)[] chunked = [];
        foreach ai:Chunk|ai:Document item in items {
            ai:Chunker chunkerToUse = chunker is ai:Chunker ? chunker : guessChunkerForKb(item);
            chunked.push(...check chunkerToUse.chunk(item));
        }
        return chunked;
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
