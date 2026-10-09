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
import ballerina/crypto;
import ballerina/http;
import ballerina/lang.runtime;
import ballerina/time;
import ballerinax/aws;
import ballerinax/aws.auth;

// Shared by `ManagedKnowledgeBase` and `SelfManagedKnowledgeBase`: the agent-plane
// transports, find-or-create, data-source resolution and the document wire calls.

// Injected on every retrieval result: the document's custom id or S3 URI. Not in the
// service model; observed on the live API. `deleteByFilter` relies on it, because
// Bedrock cannot read a document's metadata back any other way.
const string SOURCE_URI_METADATA_KEY = "_source_uri";

// The data source a managed knowledge base result came from. The self-managed spelling
// is `VECTOR_DATA_SOURCE_ID_METADATA_KEY`.
// https://docs.aws.amazon.com/bedrock/latest/userguide/kb-test-config.html
const string MANAGED_DATA_SOURCE_ID_METADATA_KEY = "_data_source_id";

// Class names for error messages raised from code both classes share.
const string MANAGED_KB_PROVIDER = "ManagedKnowledgeBase";
const string VECTOR_KB_PROVIDER = "SelfManagedKnowledgeBase";

// `Retrieve` rejects an empty query ("Text input is required."), so enumeration sends
// this placeholder. Its content does not matter.
const string FILTER_PROBE_QUERY = "PLACE HOLDER";

// Page cap for `deleteByFilter`'s filtered enumeration (100 x 100 results). A data
// source that hits it has nothing deleted, rather than being under-deleted.
const int KB_DELETE_ENUMERATION_MAX_PAGES = 100;

// How many document ids a `deleteByFilter` error lists before switching to a count.
const int KB_REPORTED_ID_SAMPLE = 10;

// Documents `observePinKey` samples; a data source can mix pinnable and unpinnable ones.
const int KB_PIN_KEY_SAMPLE_SIZE = 10;

// The caller metadata key that identifies a document on a `CUSTOM` data source, where
// Bedrock injects no per-document key. `documentIdFor` derives the document id from
// `ai:Metadata.id`, so the two always agree for documents this module ingested.
const string KB_DOCUMENT_ID_METADATA_KEY = "id";



// The live `ListKnowledgeBaseDocuments` rejects more than 100, although the service
// model allows 1000; used for all three list calls, which share that shape.
const int KB_LIST_PAGE_SIZE = 100;

// Ingest, delete and get document calls take at most 10 documents each.
const int KB_DOCUMENT_BATCH_SIZE = 10;

const decimal KB_POLL_INTERVAL_SECONDS = 3;

// `CreateDataSource` can answer 200 and fail later (status FAILED on a later
// `GetDataSource`), so construction polls until the data source is AVAILABLE.
const decimal DEFAULT_DATA_SOURCE_READY_TIMEOUT = 60;

// Retrievable statuses: usable in `retrieve()` and safe to enumerate for deletes.
final readonly & string[] KB_DOC_USABLE_STATUSES = ["INDEXED", "PARTIALLY_INDEXED", "METADATA_PARTIALLY_INDEXED"];
// Terminal statuses that are not usable. `NOT_FOUND` is not here: during an ingest
// poll it means "not visible yet" (see `KB_DOC_POLL_TRANSIENT_STATUSES`).
final readonly & string[] KB_DOC_FAILED_STATUSES = ["FAILED", "METADATA_UPDATE_FAILED", "IGNORED"];
// Statuses the ingest poll waits through. `NOT_FOUND` is included because a document
// just accepted with a 202 can read as `NOT_FOUND` for a moment; the deadline still
// bounds the wait.
final readonly & string[] KB_DOC_POLL_TRANSIENT_STATUSES = ["PENDING", "STARTING", "IN_PROGRESS", "NOT_FOUND"];
// Statuses that mean a delete was accepted. `NOT_FOUND` counts: the document is gone.
// Anything else is reported rather than assumed deleted.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_KnowledgeBaseDocumentDetail.html
final readonly & string[] KB_DOC_DELETE_ACCEPTED_STATUSES = ["DELETING", "DELETE_IN_PROGRESS", "NOT_FOUND"];

const int KB_MAX_RESULTS_PER_CALL = 100;

// ============================================================================
// Spine resolution.
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

// Builds the transports, then finds or creates the knowledge base and resolves its
// data source and chunking, so every failure surfaces at construction.
isolated function resolveKbSpine(string providerName, KnowledgeBaseAuthConfig credentials, string region,
        aws:EndpointConfig? endpointConfig, string|ManagedKnowledgeBaseDefinition knowledgeBase,
        string? dataSourceIdOverride, http:ClientConfiguration? httpConfig, RetryConfig? retryConfig,
        RerankingModelType? rerankingModelType = ())
        returns KbSpine|ai:Error {
    do {
        check guardRegion(region);
        check guardEmbeddingModelAgainstReranker(knowledgeBase, rerankingModelType);
        Endpoint controlEp = check buildAgentEndpoint(AGENT_CONTROL, region, endpointConfig);
        Endpoint dataEp = check buildAgentEndpoint(AGENT_DATA, region, endpointConfig);
        auth:CredentialProvider|BearerToken resolved = check resolveCredentials(credentials);
        BedrockTransport controlTransport =
            check new (resolved, region, controlEp, httpConfig, retryConfig, true);
        BedrockTransport dataTransport =
            check new (resolved, region, dataEp, httpConfig, retryConfig, true);

        KbAttachResult attach = check resolveKnowledgeBase(controlTransport, knowledgeBase);
        string dataSourceId;
        if dataSourceIdOverride is string {
            dataSourceId = dataSourceIdOverride;
        } else if attach.createdDataSourceId is string {
            dataSourceId = <string>attach.createdDataSourceId;
        } else {
            dataSourceId = check resolveCustomDataSource(controlTransport, attach.knowledgeBaseId);
        }
        ChunkingStrategy strategy = check validateResolvedDataSource(controlTransport,
            attach.knowledgeBaseId, dataSourceId);
        return {
            controlTransport,
            dataTransport,
            knowledgeBaseId: attach.knowledgeBaseId,
            dataSourceId,
            chunkingStrategy: strategy
        };
    } on fail error e {
        if e is ai:Error {
            return e;
        }
        return error ai:Error(string `Failed to initialize ${providerName}: ${e.message()}`, e);
    }
}

// ============================================================================
// Find-or-create.
// ============================================================================

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

// An id attaches without writing. A definition is found by name: one match attaches,
// none creates the knowledge base and its `CUSTOM` data source, more than one is an
// error rather than a guess.
isolated function resolveKnowledgeBase(BedrockTransport controlTransport, string|ManagedKnowledgeBaseDefinition knowledgeBase)
        returns KbAttachResult|ai:Error {
    if knowledgeBase is string {
        map<json> _ = check verifyKnowledgeBaseUsable(controlTransport, knowledgeBase);
        return {knowledgeBaseId: knowledgeBase, createdDataSourceId: ()};
    }
    string[] candidates = check listKnowledgeBaseIdsByName(controlTransport, knowledgeBase.name);
    if candidates.length() == 1 {
        map<json> existing = check verifyKnowledgeBaseUsable(controlTransport, candidates[0]);
        check assertDefinitionMatches(candidates[0], createKnowledgeBaseRequestBody(knowledgeBase), existing);
        return {knowledgeBaseId: candidates[0], createdDataSourceId: ()};
    }
    if candidates.length() > 1 {
        return error ai:Error(nameAmbiguityMessage(knowledgeBase.name, candidates));
    }
    // No match: create the knowledge base and its data source. A concurrent `init()`
    // can still create a duplicate under the same name, so that is checked once this
    // knowledge base is ACTIVE.
    KbCreateOutcome created = check createKnowledgeBaseRecoveringFromConflict(controlTransport, knowledgeBase);
    if created.recovered {
        return {knowledgeBaseId: created.knowledgeBaseId, createdDataSourceId: ()};
    }
    string kbId = created.knowledgeBaseId;
    check pollKnowledgeBaseActive(controlTransport, kbId, knowledgeBase.readyTimeout);
    string dsId = check createCustomDataSource(controlTransport, kbId, knowledgeBase.dataSource);

    // Re-list by name now that this create is ACTIVE, to catch a concurrent duplicate.
    check guardAgainstConcurrentDuplicate(controlTransport, knowledgeBase.name, kbId);
    return {knowledgeBaseId: kbId, createdDataSourceId: dsId};
}

isolated function nameAmbiguityMessage(string name, string[] candidates) returns string
    => string `${candidates.length()} knowledge bases are named '${name}' ` +
        string `(${string:'join(", ", ...candidates)}) — construction cannot tell which one was meant. ` +
        "Pass the knowledge base id directly instead of a definition.";

// Checks the knowledge base is ACTIVE and MANAGED. A `VECTOR` one goes through a
// different retrieval branch, so it belongs to `SelfManagedKnowledgeBase`. Returns the
// knowledge base so the definition check can reuse it.
isolated function verifyKnowledgeBaseUsable(BedrockTransport controlTransport, string kbId)
        returns map<json>|ai:Error {
    map<json> kb = check getKnowledgeBase(controlTransport, kbId);
    string status = stringField(kb, "status") ?: "";
    if status != "ACTIVE" {
        return error ai:Error(
            string `Knowledge base '${kbId}' is not usable: status is '${status}' (expected 'ACTIVE'). ` +
            "Wait for it to finish provisioning, or check the AWS console for failure details.");
    }
    string kbType = stringField(asMap(kb["knowledgeBaseConfiguration"] ?: {}), "type") ?: "";
    // A missing type means an unexpected response shape, not a different knowledge
    // base type, so it is not treated as a mismatch.
    if kbType != "" && kbType != "MANAGED" {
        return errorWithDetail(
            string `Knowledge base '${kbId}' is of type '${kbType}'; ManagedKnowledgeBase supports only ` +
            "'MANAGED' knowledge bases. Use SelfManagedKnowledgeBase for a 'VECTOR' knowledge base.",
            "A 'VECTOR' knowledge base is backed by your own vector store and is served by a different " +
            "search branch, so retrieve() and deleteByFilter() are not valid against it.");
    }
    return kb;
}

isolated function listKnowledgeBaseIdsByName(BedrockTransport controlTransport, string name) returns string[]|ai:Error {
    string[] ids = [];
    string? nextToken = ();
    while true {
        map<json> body = {maxResults: KB_LIST_PAGE_SIZE};
        if nextToken is string {
            body["nextToken"] = nextToken;
        }
        TransportResponse response = check controlTransport.executeRequest("POST", "/knowledgebases/", body);
        map<json> respBody = asMap(response.body);
        json summariesJson = respBody["knowledgeBaseSummaries"] ?: [];
        if summariesJson is json[] {
            foreach json s in summariesJson {
                map<json> summary = asMap(s);
                if stringField(summary, "name") == name {
                    string? id = stringField(summary, "knowledgeBaseId");
                    if id is string {
                        ids.push(id);
                    }
                }
            }
        }
        nextToken = stringField(respBody, "nextToken");
        if nextToken is () {
            break;
        }
    }
    return ids;
}

isolated function getKnowledgeBase(BedrockTransport controlTransport, string kbId) returns map<json>|ai:Error {
    string path = string `/knowledgebases/${kbId}`;
    TransportResponse response = check controlTransport.executeRequest("GET", path, ());
    return asMap(asMap(response.body)["knowledgeBase"] ?: {});
}

// A custom embedding model and the managed reranker cannot be combined, and both are
// fixed at creation, so this fails at construction.
// https://docs.aws.amazon.com/bedrock/latest/userguide/kb-managed-create.html
isolated function guardEmbeddingModelAgainstReranker(string|ManagedKnowledgeBaseDefinition knowledgeBase,
        RerankingModelType? rerankingModelType) returns ai:Error? {
    if knowledgeBase is string || rerankingModelType != RERANKING_MANAGED {
        return;
    }
    if knowledgeBase?.embeddingModel is ManagedEmbeddingModel {
        return errorWithDetail(
            "'rerankingModelType' RERANKING_MANAGED cannot be used with 'knowledgeBase.embeddingModel'. " +
            "Drop 'embeddingModel', or use RERANKING_NONE.",
            "AWS makes the managed reranker unavailable on a knowledge base created with a caller-supplied " +
            "embedding model, and both are permanent at creation time.");
    }
}

// The `CreateKnowledgeBase` request body. MANAGED takes no `storageConfiguration`;
// `embeddingModelArn` and its configuration go only with a `CUSTOM` embedding model.
// https://docs.aws.amazon.com/bedrock/latest/userguide/kb-managed-create.html
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_ManagedKnowledgeBaseConfiguration.html
isolated function createKnowledgeBaseRequestBody(ManagedKnowledgeBaseDefinition def) returns map<json> {
    ManagedEmbeddingModel? embeddingModel = def?.embeddingModel;
    map<json> managedConfig;
    if embeddingModel is ManagedEmbeddingModel {
        managedConfig = {
            embeddingModelType: "CUSTOM",
            embeddingModelArn: embeddingModel.embeddingModelArn,
            embeddingModelConfiguration: {
                bedrockEmbeddingModelConfiguration: {
                    dimensions: embeddingModel.dimensions,
                    embeddingDataType: embeddingModel.embeddingDataType
                }
            }
        };
    } else {
        managedConfig = {embeddingModelType: "MANAGED"};
    }
    string? kmsKeyArn = def?.kmsKeyArn;
    if kmsKeyArn is string {
        managedConfig["serverSideEncryptionConfiguration"] = {kmsKeyArn};
    }
    map<json> body = {
        name: def.name,
        roleArn: def.serviceRoleArn,
        knowledgeBaseConfiguration: {
            'type: "MANAGED",
            managedKnowledgeBaseConfiguration: managedConfig
        }
    };
    string? description = def.description;
    if description is string {
        body["description"] = description;
    }
    return body;
}

# Outcome of `createKnowledgeBaseRecoveringFromConflict`. After a 409 recovery the
# knowledge base already has its data source, so none is created.
type KbCreateOutcome record {|
    # The created id, or, on recovery, the id of the existing match
    string knowledgeBaseId;
    # `true` when a 409 led to attaching rather than creating
    boolean recovered;
|};

// Creates the knowledge base. A 409 means another call already created one under this
// name; it is attached to after the same checks as an ordinary find-by-name. No match
// or several matches return the original 409.
isolated function createKnowledgeBaseRecoveringFromConflict(BedrockTransport controlTransport,
        ManagedKnowledgeBaseDefinition def) returns KbCreateOutcome|ai:Error {
    map<json> body = createKnowledgeBaseRequestBody(def);
    body["clientToken"] = idempotencyToken(body);
    TransportResponse|ConflictError|ai:Error response =
        controlTransport.executeRequestDetectingConflict("PUT", "/knowledgebases/", body);
    if response is ConflictError {
        string[] candidates = check listKnowledgeBaseIdsByName(controlTransport, def.name);
        if candidates.length() == 1 {
            map<json> existing = check verifyKnowledgeBaseUsable(controlTransport, candidates[0]);
            check assertDefinitionMatches(candidates[0], createKnowledgeBaseRequestBody(def), existing);
            return {knowledgeBaseId: candidates[0], recovered: true};
        }
        return error ai:Error(response.message());
    }
    if response is ai:Error {
        return response;
    }
    map<json> kb = asMap(asMap(response.body)["knowledgeBase"] ?: {});
    string? id = stringField(kb, "knowledgeBaseId");
    if id is () {
        return error ai:Error("CreateKnowledgeBase response carried no 'knowledgeBaseId'");
    }
    return {knowledgeBaseId: id, recovered: false};
}

// Once this create is ACTIVE, reports any other knowledge base with the same name.
// Every racer picks the same survivor (the smallest id). Never deletes: the caller
// runs the cleanup named in the error.
isolated function guardAgainstConcurrentDuplicate(BedrockTransport controlTransport, string name, string thisCallsKbId)
        returns ai:Error? {
    string[] matches = check listKnowledgeBaseIdsByName(controlTransport, name);
    if matches.length() <= 1 {
        return;
    }
    return error ai:Error(concurrentDuplicateMessage(name, matches, thisCallsKbId));
}

isolated function concurrentDuplicateMessage(string name, string[] matches, string thisCallsKbId) returns string {
    string[] sorted = matches.sort();
    string winner = sorted[0];
    string[] cleanupCommands = [];
    foreach string id in sorted {
        if id == winner {
            continue;
        }
        cleanupCommands.push(string `aws bedrock-agent delete-knowledge-base --knowledge-base-id ${id}`);
    }
    string mine = thisCallsKbId == winner
        ? " this call's own create is the winner, but the account is still polluted by the other(s)."
        : " this call's own create is among the orphans.";
    return string `A concurrent 'init()' race produced ${matches.length()} knowledge bases named '${name}' ` +
        string `(${string:'join(", ", ...sorted)}).${mine} AWS's create idempotency token collapses ` +
        "retries of an identical request, but not two requests already in flight concurrently, so this " +
        string `module can only detect the race after the fact, never prevent it. Treat '${winner}' ` +
        "(the lexicographically smallest id) as the surviving knowledge base — every racer computes the " +
        "same winner, so the account converges on it. The other(s) were NOT deleted (this module never " +
        string `issues 'DeleteKnowledgeBase'); clean them up manually: ${string:'join("; ", ...cleanupCommands)}. ` +
        // Until cleanup runs, every later `init()` with this name fails too.
        "Until then, every 'init()' passing a 'ManagedKnowledgeBaseDefinition' with this name will fail, " +
        "because the name no longer identifies one knowledge base. 'ManagedKnowledgeBaseDefinition' is a " +
        "find-or-create convenience suited to a single instance or a first-time setup; if more than " +
        "one process can start at once, provision the knowledge base once and pass its ID to 'init()' " +
        "instead — that path creates nothing and cannot race.";
}

// Polls until ACTIVE or `readyTimeout`. A managed knowledge base usually takes a few
// seconds; a self-managed one can take over a minute.
isolated function pollKnowledgeBaseActive(BedrockTransport controlTransport, string kbId, decimal timeoutSeconds)
        returns ai:Error? {
    time:Utc deadline = time:utcAddSeconds(time:utcNow(), timeoutSeconds);
    while true {
        map<json> kb = check getKnowledgeBase(controlTransport, kbId);
        string status = stringField(kb, "status") ?: "";
        if status == "ACTIVE" {
            return;
        }
        if status == "FAILED" || status == "DELETE_UNSUCCESSFUL" || status == "UPDATE_UNSUCCESSFUL" {
            return error ai:Error(
                string `Knowledge base '${kbId}' failed to become ACTIVE (status '${status}'): ` +
                failureReasonsOf(kb));
        }
        if time:utcDiffSeconds(deadline, time:utcNow()) <= 0d {
            return error ai:Error(
                string `Timed out after ${timeoutSeconds}s waiting for knowledge base '${kbId}' to become ` +
                string `ACTIVE (still '${status}'). Increase 'readyTimeout', or check the AWS console.`);
        }
        runtime:sleep(KB_POLL_INTERVAL_SECONDS);
    }
}

isolated function failureReasonsOf(map<json> details) returns string {
    json reasonsJson = details["failureReasons"] ?: [];
    if reasonsJson is json[] && reasonsJson.length() > 0 {
        return string:'join("; ", ...reasonsJson.map(r => r.toString()));
    }
    return "no failure reason reported";
}

// ============================================================================
// Data sources: created with a new knowledge base, or resolved on an existing one.
// ============================================================================

// The `CreateDataSource` body. A managed knowledge base rejects a plain `CUSTOM` type:
// the console's "Custom" source is `MANAGED_KNOWLEDGE_BASE_CONNECTOR` with the type in
// `connectorParameters` (observed on the live API).
isolated function createDataSourceRequestBody(DataSourceDefinition def) returns map<json>|ai:Error {
    map<json> body = {
        name: def.name,
        dataSourceConfiguration: {
            'type: "MANAGED_KNOWLEDGE_BASE_CONNECTOR",
            managedKnowledgeBaseConnectorConfiguration: {
                // `version` is required.
                // https://docs.aws.amazon.com/bedrock/latest/userguide/kb-managed-connect-ds.html
                connectorParameters: {'type: "CUSTOM", version: "1"}
            }
        }
        // No `vectorIngestionConfiguration`: managed knowledge bases only parse with
        // SMART_PARSING (the default), and reject `chunkingConfiguration` with a
        // managed embedding model.
    };
    string? description = def.description;
    if description is string {
        body["description"] = description;
    }
    return body;
}

isolated function createCustomDataSource(BedrockTransport controlTransport, string kbId, DataSourceDefinition def)
        returns string|ai:Error {
    map<json> body = check createDataSourceRequestBody(def);
    // Scoped to the knowledge base, so two racing creates do not leave two `CUSTOM`
    // data sources on it.
    body["clientToken"] = idempotencyToken({kbId, dataSource: body});
    string path = string `/knowledgebases/${kbId}/datasources/`;
    TransportResponse response = check controlTransport.executeRequest("PUT", path, body);
    map<json> dataSource = asMap(asMap(response.body)["dataSource"] ?: {});
    string? id = stringField(dataSource, "dataSourceId");
    if id is () {
        return error ai:Error("CreateDataSource response carried no 'dataSourceId'");
    }
    // Usually AVAILABLE already, but a rejected payload can still answer 200 and show
    // up as FAILED later, so the poll stays.
    string status = stringField(dataSource, "status") ?: "";
    if status != "AVAILABLE" {
        check pollDataSourceAvailable(controlTransport, kbId, id, DEFAULT_DATA_SOURCE_READY_TIMEOUT);
    }
    return id;
}

isolated function pollDataSourceAvailable(BedrockTransport controlTransport, string kbId, string dsId,
        decimal timeoutSeconds) returns ai:Error? {
    time:Utc deadline = time:utcAddSeconds(time:utcNow(), timeoutSeconds);
    while true {
        map<json> dataSource = check getDataSource(controlTransport, kbId, dsId);
        string status = stringField(dataSource, "status") ?: "";
        if status == "AVAILABLE" {
            return;
        }
        if status == "FAILED" || status == "DELETE_UNSUCCESSFUL" {
            return error ai:Error(
                string `Data source '${dsId}' on knowledge base '${kbId}' failed to become AVAILABLE ` +
                string `(status '${status}')`);
        }
        if time:utcDiffSeconds(deadline, time:utcNow()) <= 0d {
            return error ai:Error(
                string `Timed out after ${timeoutSeconds}s waiting for data source '${dsId}' to become ` +
                "AVAILABLE. Increase 'readyTimeout', or check the AWS console.");
        }
        runtime:sleep(KB_POLL_INTERVAL_SECONDS);
    }
}

isolated function getDataSource(BedrockTransport controlTransport, string kbId, string dsId)
        returns map<json>|ai:Error {
    string path = string `/knowledgebases/${kbId}/datasources/${dsId}`;
    TransportResponse response = check controlTransport.executeRequest("GET", path, ());
    return asMap(asMap(response.body)["dataSource"] ?: {});
}

isolated function listDataSources(BedrockTransport controlTransport, string kbId) returns map<json>[]|ai:Error {
    map<json>[] summaries = [];
    string? nextToken = ();
    string path = string `/knowledgebases/${kbId}/datasources/`;
    while true {
        map<json> body = {maxResults: KB_LIST_PAGE_SIZE};
        if nextToken is string {
            body["nextToken"] = nextToken;
        }
        TransportResponse response = check controlTransport.executeRequest("POST", path, body);
        map<json> respBody = asMap(response.body);
        json items = respBody["dataSourceSummaries"] ?: [];
        if items is json[] {
            foreach json item in items {
                summaries.push(asMap(item));
            }
        }
        nextToken = stringField(respBody, "nextToken");
        if nextToken is () {
            break;
        }
    }
    return summaries;
}

// Finds the knowledge base's single `CUSTOM` data source. Summaries carry no type, so
// this reads each data source.
isolated function resolveCustomDataSource(BedrockTransport controlTransport, string kbId) returns string|ai:Error {
    map<json>[] summaries = check listDataSources(controlTransport, kbId);
    string[] candidates = [];
    foreach map<json> summary in summaries {
        string? dsId = stringField(summary, "dataSourceId");
        if dsId is () {
            continue;
        }
        map<json> dataSource = check getDataSource(controlTransport, kbId, dsId);
        if effectiveDataSourceType(dataSource) == "CUSTOM" {
            candidates.push(dsId);
        }
    }
    if candidates.length() == 1 {
        return candidates[0];
    }
    if candidates.length() == 0 {
        return errorWithDetail(
            string `Knowledge base '${kbId}' has no 'CUSTOM' data source. Add one in the AWS console, or ` +
            "pass a 'ManagedKnowledgeBaseDefinition' so this class creates one.",
            "ingest() and deleteByFilter() write through a CUSTOM (direct-ingestion) data source.");
    }
    return error ai:Error(
        string `Knowledge base '${kbId}' has ${candidates.length()} 'CUSTOM' data sources ` +
        string `(${string:'join(", ", ...candidates)}) — ambiguous. Pass 'dataSourceId' explicitly.`);
}

// The data source's real type: `connectorParameters.type` inside a
// `MANAGED_KNOWLEDGE_BASE_CONNECTOR`. The live API returns `connectorParameters` as a
// JSON string, although the service model declares an object; both are handled.
isolated function effectiveDataSourceType(map<json> dataSource) returns string {
    map<json> config = asMap(dataSource["dataSourceConfiguration"] ?: {});
    string wireType = stringField(config, "type") ?: "";
    if wireType != "MANAGED_KNOWLEDGE_BASE_CONNECTOR" {
        return wireType;
    }
    map<json> managed = asMap(config["managedKnowledgeBaseConnectorConfiguration"] ?: {});
    json connectorParams = managed["connectorParameters"] ?: {};
    map<json> parsedParams = {};
    if connectorParams is string {
        json|error parsed = connectorParams.fromJsonString();
        if parsed is map<json> {
            parsedParams = parsed;
        }
    } else if connectorParams is map<json> {
        parsedParams = connectorParams;
    }
    return stringField(parsedParams, "type") ?: wireType;
}

// ============================================================================
// Chunking-strategy detection.
// ============================================================================

// Checks the data source is AVAILABLE and `CUSTOM`, and reads its chunking strategy,
// which picks the default `chunker`: `ai:DISABLE` when Bedrock chunks, `ai:AUTO` when
// the strategy is `NONE`. A missing strategy is treated as Bedrock's FIXED_SIZE.
isolated function validateResolvedDataSource(BedrockTransport controlTransport, string kbId, string dsId)
        returns ChunkingStrategy|ai:Error {
    map<json> dataSource = check getDataSource(controlTransport, kbId, dsId);

    // Re-read even if the create said AVAILABLE: a rejected payload shows up here.
    string status = stringField(dataSource, "status") ?: "";
    if status == "FAILED" || status == "DELETE_UNSUCCESSFUL" {
        return error ai:Error(
            string `Data source '${dsId}' on knowledge base '${kbId}' is not usable: status is ` +
            string `'${status}'. ${failureReasonsOf(dataSource)}`);
    }

    // An explicit `dataSourceId` is only type-checked here, and `ingest()` sends
    // `CUSTOM` documents.
    string effectiveType = effectiveDataSourceType(dataSource);
    if effectiveType != "CUSTOM" {
        return errorWithDetail(
            string `Data source '${dsId}' on knowledge base '${kbId}' is of type '${effectiveType}', not ` +
            "CUSTOM. Pass the id of a CUSTOM data source, or omit 'dataSourceId'.",
            "ingest() and deleteByFilter() write through the CUSTOM (direct-ingestion) connector only.");
    }

    map<json> vectorIngestion = asMap(dataSource["vectorIngestionConfiguration"] ?: {});
    map<json> chunking = asMap(vectorIngestion["chunkingConfiguration"] ?: {});
    // No chunking configuration means Bedrock's FIXED_SIZE default, never NONE.
    string strategy = stringField(chunking, "chunkingStrategy") ?: "FIXED_SIZE";
    match strategy {
        "NONE" => {
            return NONE;
        }
        "HIERARCHICAL" => {
            return HIERARCHICAL;
        }
        "SEMANTIC" => {
            return SEMANTIC;
        }
        _ => {
            return FIXED_SIZE;
        }
    }
}

// ============================================================================
// Document operations, shared by `ingest()` and `deleteByFilter()`.
// ============================================================================

isolated function ingestDocumentsBatch(BedrockTransport controlTransport, string kbId, string dsId,
        json[] documents) returns map<json>[]|ai:Error {
    string path = string `/knowledgebases/${kbId}/datasources/${dsId}/documents`;
    map<json> body = {documents};
    TransportResponse response = check controlTransport.executeRequest("PUT", path, body);
    return documentDetailsOf(response.body);
}

isolated function getDocumentsBatch(BedrockTransport controlTransport, string kbId, string dsId, string[] ids)
        returns map<json>[]|ai:Error {
    json[] identifiers = ids.map(id => <json>{dataSourceType: "CUSTOM", custom: {id}});
    string path = string `/knowledgebases/${kbId}/datasources/${dsId}/documents/getDocuments`;
    map<json> body = {documentIdentifiers: identifiers};
    TransportResponse response = check controlTransport.executeRequest("POST", path, body);
    return documentDetailsOf(response.body);
}

isolated function deleteDocumentsBatch(BedrockTransport controlTransport, string kbId, string dsId,
        json[] identifiers) returns map<json>[]|ai:Error {
    string path = string `/knowledgebases/${kbId}/datasources/${dsId}/documents/deleteDocuments`;
    map<json> body = {documentIdentifiers: identifiers};
    TransportResponse response = check controlTransport.executeRequest("POST", path, body);
    return documentDetailsOf(response.body);
}

// Returns the documents the service did not confirm as deleted, for the caller's error.
isolated function deleteDocuments(BedrockTransport controlTransport, string kbId, string dsId,
        json[] identifiers) returns string[]|ai:Error {
    string[] notDeleted = [];
    foreach json[] batch in partitionJson(identifiers, KB_DOCUMENT_BATCH_SIZE) {
        map<json>[] details = check deleteDocumentsBatch(controlTransport, kbId, dsId, batch);
        map<string> statusBySource = {};
        foreach map<json> detail in details {
            string? sourceValue = documentSourceValueOf(detail);
            if sourceValue is string {
                statusBySource[sourceValue] = stringField(detail, "status") ?: "";
            }
        }
        foreach json identifier in batch {
            string sourceValue = sourceValueOfIdentifier(identifier) ?: identifier.toJsonString();
            string? status = statusBySource[sourceValue];
            if status is () {
                notDeleted.push(string `${sourceValue} (no status returned)`);
            } else if KB_DOC_DELETE_ACCEPTED_STATUSES.indexOf(status) is () {
                notDeleted.push(string `${sourceValue} (${status})`);
            }
        }
    }
    return notDeleted;
}

isolated function listKnowledgeBaseDocuments(BedrockTransport controlTransport, string kbId, string dsId)
        returns map<json>[]|ai:Error {
    map<json>[] details = [];
    string? nextToken = ();
    string path = string `/knowledgebases/${kbId}/datasources/${dsId}/documents`;
    while true {
        map<json> body = {maxResults: KB_LIST_PAGE_SIZE};
        if nextToken is string {
            body["nextToken"] = nextToken;
        }
        TransportResponse response = check controlTransport.executeRequest("POST", path, body);
        map<json> respBody = asMap(response.body);
        foreach map<json> detail in documentDetailsOf(respBody) {
            details.push(detail);
        }
        nextToken = stringField(respBody, "nextToken");
        if nextToken is () {
            break;
        }
    }
    return details;
}

isolated function documentDetailsOf(json body) returns map<json>[] {
    json items = asMap(body)["documentDetails"] ?: [];
    map<json>[] details = [];
    if items is json[] {
        foreach json item in items {
            details.push(asMap(item));
        }
    }
    return details;
}

isolated function documentIdOf(map<json> detail) returns string? {
    map<json> identifier = asMap(detail["identifier"] ?: {});
    return stringField(asMap(identifier["custom"] ?: {}), "id");
}

// A document's key: `custom.id` or `s3.uri`, as `listDeletableDocuments` builds it.
isolated function documentSourceValueOf(map<json> detail) returns string?
    => sourceValueOfIdentifier(detail["identifier"] ?: {});

isolated function sourceValueOfIdentifier(json identifier) returns string? {
    map<json> m = asMap(identifier);
    string? id = stringField(asMap(m["custom"] ?: {}), "id");
    return id is string ? id : stringField(asMap(m["s3"] ?: {}), "uri");
}

# The final (terminal) outcome of one submitted document: its last-seen status and,
# on failure, the reason Bedrock reported.
type DocumentOutcome record {|
    # The terminal `DocumentStatus` (see `KB_DOC_USABLE_STATUSES`/`KB_DOC_FAILED_STATUSES`)
    string status;
    # Bedrock's explanation, present mainly alongside `IGNORED`
    string? statusReason;
|};

// Polls until every submitted id is terminal or the timeout passes. Driven by the
// submitted ids, so an id that reads `NOT_FOUND` or is missing from the response stays
// pending instead of passing as success.
isolated function pollDocumentsTerminal(BedrockTransport controlTransport, string kbId, string dsId,
        string[] ids, decimal timeoutSeconds) returns map<DocumentOutcome>|ai:Error {
    map<DocumentOutcome> outcomes = {};
    string[] pending = ids.clone();
    time:Utc deadline = time:utcAddSeconds(time:utcNow(), timeoutSeconds);
    while pending.length() > 0 {
        string[] stillPending = [];
        foreach string[] batch in partitionStrings(pending, KB_DOCUMENT_BATCH_SIZE) {
            map<json>[] details = check getDocumentsBatch(controlTransport, kbId, dsId, batch);
            map<string> statusById = {};
            map<string?> reasonById = {};
            foreach map<json> detail in details {
                string? id = documentIdOf(detail);
                if id is string {
                    statusById[id] = stringField(detail, "status") ?: "";
                    reasonById[id] = stringField(detail, "statusReason");
                }
            }
            foreach string id in batch {
                string? status = statusById[id];
                if status is () || KB_DOC_POLL_TRANSIENT_STATUSES.indexOf(status) is int {
                    stillPending.push(id);
                    continue;
                }
                outcomes[id] = {status, statusReason: reasonById[id] ?: ()};
            }
        }
        pending = stillPending;
        if pending.length() == 0 {
            break;
        }
        if time:utcDiffSeconds(deadline, time:utcNow()) <= 0d {
            return errorWithDetail(
                string `Timed out after ${timeoutSeconds}s waiting for ${pending.length()} document(s) to be ` +
                string `indexed: ${string:'join(", ", ...pending)}. Increase 'ingestTimeout'.`,
                "These are still indexing, or accepted but not yet visible to 'GetKnowledgeBaseDocuments'. " +
                "Indexing latency varies by an order of magnitude; do not tune against a fixed figure.");
        }
        runtime:sleep(KB_POLL_INTERVAL_SECONDS);
    }
    return outcomes;
}

// Bedrock upserts by document id, so two documents with the same id in one call would
// silently keep only the second.
isolated function assertDistinctDocumentIds(string[] documentIds) returns ai:Error? {
    map<int> seen = {};
    string[] duplicates = [];
    foreach string id in documentIds {
        int count = (seen[id] ?: 0) + 1;
        seen[id] = count;
        if count == 2 {
            duplicates.push(id);
        }
    }
    if duplicates.length() == 0 {
        return;
    }
    return errorWithDetail(
        string `${duplicates.length()} document id(s) appear more than once in this ingest call ` +
        string `(${string:'join(", ", ...duplicates)}). Give each document a distinct 'ai:Metadata.id'.`,
        "Bedrock upserts by 'customDocumentIdentifier.id', so the later document would silently overwrite " +
        "the earlier one. Ingest them in separate calls if the overwrite is intended.");
}

# One enumerated, retrievable document that `deleteByFilter` can potentially delete.
type DeletableDocument record {|
    # `customDocumentIdentifier.id` (CUSTOM) or the S3 object URI (S3) — also what `_source_uri` holds
    string sourceValue;
    # The ready-to-send `DocumentIdentifier` for `DeleteKnowledgeBaseDocuments`
    json identifier;
|};

// The data source's documents that are retrievable and deletable (`CUSTOM` or `S3`).
isolated function listDeletableDocuments(BedrockTransport controlTransport, string kbId, string dsId,
        string dataSourceType) returns DeletableDocument[]|ai:Error {
    DeletableDocument[] docs = [];
    foreach map<json> detail in check listKnowledgeBaseDocuments(controlTransport, kbId, dsId) {
        string status = stringField(detail, "status") ?: "";
        if KB_DOC_USABLE_STATUSES.indexOf(status) is () {
            // Not reachable through Retrieve.
            continue;
        }
        map<json> identifier = asMap(detail["identifier"] ?: {});
        if dataSourceType == "CUSTOM" {
            string? id = stringField(asMap(identifier["custom"] ?: {}), "id");
            if id is string {
                docs.push({sourceValue: id, identifier: {dataSourceType: "CUSTOM", custom: {id}}});
            }
        } else if dataSourceType == "S3" {
            string? uri = stringField(asMap(identifier["s3"] ?: {}), "uri");
            if uri is string {
                docs.push({sourceValue: uri, identifier: {dataSourceType: "S3", s3: {uri}}});
            }
        }
    }
    return docs;
}

// ============================================================================
// Retrieve (bedrock-agent-runtime).
// ============================================================================

// One `Retrieve` call on the managed search branch. Returns the results and the next
// page token.
isolated function callRetrieve(BedrockTransport dataTransport, string kbId, string query, json? filter,
        int numberOfResults, RerankingModelType? reranking, string? nextToken)
        returns [json[], string?]|ai:Error {
    map<json> managedSearch = {numberOfResults};
    // `()` is a `json` value, so `filter is json` would send `"filter": null`.
    if filter !is () {
        managedSearch["filter"] = filter;
    }
    if reranking is RerankingModelType {
        managedSearch["rerankingModelType"] = reranking;
    }
    map<json> body = {
        retrievalQuery: {text: query},
        retrievalConfiguration: {managedSearchConfiguration: managedSearch}
    };
    if nextToken is string {
        body["nextToken"] = nextToken;
    }
    string path = string `/knowledgebases/${kbId}/retrieve`;
    TransportResponse response = check dataTransport.executeRequest("POST", path, body);
    map<json> respBody = asMap(response.body);
    json resultsJson = respBody["retrievalResults"] ?: [];
    json[] results = resultsJson is json[] ? resultsJson : [];
    return [results, stringField(respBody, "nextToken")];
}

// A retrieval result's source value: the source-uri attribute, else the documented
// `location.customDocumentLocation.id` or `location.s3Location.uri`. Matches
// `DeletableDocument.sourceValue`.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_KnowledgeBaseRetrievalResult.html
isolated function retrievalResultSourceValue(json result, string sourceUriKey) returns string? {
    map<json> resultMap = asMap(result);
    string? viaMetadataKey = stringField(asMap(resultMap["metadata"] ?: {}), sourceUriKey);
    if viaMetadataKey is string {
        return viaMetadataKey;
    }
    map<json> location = asMap(resultMap["location"] ?: {});
    string? viaCustomLocation = stringField(asMap(location["customDocumentLocation"] ?: {}), "id");
    if viaCustomLocation is string {
        return viaCustomLocation;
    }
    return stringField(asMap(location["s3Location"] ?: {}), "uri");
    // `documentId` is not used: AWS does not say it equals the custom id or S3 URI, and
    // a wrong match here would delete the wrong document.
}

isolated function retrievalResultIdentifies(json result, string documentId, string sourceUriKey) returns boolean
    => retrievalResultSourceValue(result, sourceUriKey) == documentId;

// ============================================================================
// deleteByFilter, shared by both classes.
// ============================================================================

// Both classes' retrieve calls reduced to what enumeration needs: no reranking.

# A paged, unranked `Retrieve` call, as `deleteByFilter`'s enumeration makes it.
type DeleteRetrieveCaller isolated function (BedrockTransport dataTransport, string kbId, json? filter,
        int numberOfResults, string? nextToken) returns [json[], string?]|ai:Error;

// The managed `DeleteRetrieveCaller`; `vectorDeleteRetrieve` is the self-managed one.
isolated function managedDeleteRetrieve(BedrockTransport dataTransport, string kbId, json? filter,
        int numberOfResults, string? nextToken) returns [json[], string?]|ai:Error
    => callRetrieve(dataTransport, kbId, FILTER_PROBE_QUERY, filter, numberOfResults, (), nextToken);

# One paged `Retrieve` enumeration's result: every document identity seen, and
# whether `KB_DELETE_ENUMERATION_MAX_PAGES` was hit before pagination finished
# naturally (`nextToken` came back `()`).
type DeleteEnumeration record {|
    # Every `retrievalResultSourceValue` seen across every page, as a set
    map<()> identities;
    # `true` when the page cap was hit — the set above may be INCOMPLETE
    boolean truncated;
|};

// Pages a `Retrieve` (filtered or not) up to `KB_DELETE_ENUMERATION_MAX_PAGES`,
// collecting each result's source value.
isolated function enumerateDeleteIdentities(BedrockTransport dataTransport, string kbId, json? filter,
        string sourceUriKey, DeleteRetrieveCaller retrieveCaller, DataSourceScope scope)
        returns DeleteEnumeration|ai:Error {
    map<()> identities = {};
    string? nextToken = ();
    int page = 0;
    while true {
        page += 1;
        if page > KB_DELETE_ENUMERATION_MAX_PAGES {
            return {identities, truncated: true};
        }
        [json[], string?] [results, respNextToken] =
            check retrieveCaller(dataTransport, kbId, filter, KB_MAX_RESULTS_PER_CALL, nextToken);
        foreach json result in results {
            // Document ids are unique per data source, not per knowledge base.
            if !belongsToDataSource(result, scope) {
                continue;
            }
            string? sourceValue = retrievalResultSourceValue(result, sourceUriKey);
            if sourceValue is string {
                identities[sourceValue] = ();
            }
        }
        nextToken = respNextToken;
        if nextToken is () {
            // `Retrieve` returns one relevance-ranked set, so a full page means the
            // cap was hit, not that every document was seen.
            return {identities, truncated: results.length() >= KB_MAX_RESULTS_PER_CALL};
        }
    }
}

// A filter value no document carries. If a store returns results for it, it ignores
// metadata filters and `deleteByFilter` refuses. This tells "the filter selects every
// document" apart from "the filter was ignored".
const string FILTER_CONTROL_SENTINEL = "ballerina-ai-aws-bedrock-no-such-document-cf1d7a2e";

isolated function storeIgnoresMetadataFilters(BedrockTransport dataTransport, string kbId, string sourceUriKey,
        DeleteRetrieveCaller retrieveCaller, DataSourceScope scope) returns boolean|ai:Error {
    json controlFilter = check combineFilters((),
            [{'equals: {key: sourceUriKey, value: FILTER_CONTROL_SENTINEL}}, dataSourceLeaf(scope)]);
    [json[], string?] [results, _] = check retrieveCaller(dataTransport, kbId, controlFilter, 1, ());
    return results.length() > 0;
}

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

// Resolves one data source's candidates to a delete set. A filtered enumeration
// confirms matches; every candidate it misses is probed on its own, because
// `Retrieve` returns only the most relevant results, so "not in the filtered results"
// does not prove the filter excluded it.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_Retrieve.html
isolated function resolveDataSourceDeletes(BedrockTransport dataTransport, string kbId, string dsId,
        json? userFilter, DeletableDocument[] candidates, string sourceUriKey, string dataSourceIdKey,
        DeleteRetrieveCaller retrieveCaller) returns DataSourceDeleteResult|ai:Error {
    // `Retrieve` searches the whole knowledge base and ids are unique only per data
    // source, so every call is filtered to this data source and every result is
    // checked again: that filter has been reported to leak.
    // https://repost.aws/questions/QU08ymRXIITDe4xuwGmFFuAA/bedrock-data-sources-mixed-up
    DataSourceScope scope = {key: dataSourceIdKey, id: dsId};
    // A store that ignores filters would make the filtered enumeration match
    // everything, so the control probe runs first.
    if userFilter !is () {
        boolean|ai:Error ignoresFilters =
            storeIgnoresMetadataFilters(dataTransport, kbId, sourceUriKey, retrieveCaller, scope);
        if ignoresFilters is ai:Error {
            return dataSourceRefusal(dsId,
                string `the check for whether the vector store honours metadata filters could not be ` +
                string `completed (${ignoresFilters.message()})`);
        }
        if ignoresFilters {
            return dataSourceRefusal(dsId,
                "the vector store does not appear to be honouring metadata filters (a filter matching no " +
                "possible document still returned results)");
        }
    }

    DeleteEnumeration matchedEnum = check enumerateDeleteIdentities(dataTransport, kbId,
            check combineFilters(userFilter, [dataSourceLeaf(scope)]), sourceUriKey, retrieveCaller, scope);
    // A truncated enumeration is fine here: what it confirmed is still a sound delete,
    // and what it missed is probed individually.

    json[] toDelete = [];
    DeletableDocument[] unresolved = [];
    foreach DeletableDocument candidate in candidates {
        if matchedEnum.identities.hasKey(candidate.sourceValue) {
            toDelete.push(candidate.identifier);
        } else {
            unresolved.push(candidate);
        }
    }
    if unresolved.length() == 0 {
        return {toDelete, indeterminate: [], refusalReason: ()};
    }

    // The key that can pin a document is observed, not assumed: a `CUSTOM` data source
    // has no source-uri attribute, so `ai:Metadata.id` pins it instead.
    string? pinKey = check observePinKey(dataTransport, kbId, sourceUriKey, retrieveCaller, scope);
    UnresolvedCandidate[] indeterminate = [];
    if pinKey is () {
        foreach DeletableDocument candidate in unresolved {
            indeterminate.push({sourceValue: candidate.sourceValue, dataSourceId: dsId,
                reason: UNRESOLVED_NO_PIN_KEY});
        }
        return {toDelete, indeterminate, refusalReason: ()};
    }

    // A document ingested without `ai:Metadata.id` got a UUID id and cannot be pinned;
    // that is known from the id, so no probe is spent on it.
    DeletableDocument[] pinnable = [];
    foreach DeletableDocument candidate in unresolved {
        if pinKey == KB_DOCUMENT_ID_METADATA_KEY && int:fromString(fanOutParentOf(candidate.sourceValue)) is error {
            indeterminate.push({sourceValue: candidate.sourceValue, dataSourceId: dsId,
                reason: UNRESOLVED_NO_DOCUMENT_ID});
        } else {
            pinnable.push(candidate);
        }
    }

    // Candidates one pinned filter selects share a pair of probes; the verdict is still
    // per document.
    map<DeletableDocument[]> groups = {};
    foreach DeletableDocument candidate in pinnable {
        string key = pinGroupKeyFor(candidate.sourceValue, pinKey);
        DeletableDocument[] group = groups[key] ?: [];
        group.push(candidate);
        groups[key] = group;
    }
    int truncatedGroups = 0;
    foreach [string, DeletableDocument[]] [pinValue, group] in groups.entries() {
        [json[], UnresolvedCandidate[], boolean] [groupDeletes, groupIndeterminate, groupTruncated] =
            check resolvePinGroup(dataTransport, kbId, scope, userFilter, group, pinValue, pinKey, sourceUriKey,
                retrieveCaller);
        toDelete.push(...groupDeletes);
        indeterminate.push(...groupIndeterminate);
        if groupTruncated {
            truncatedGroups += 1;
        }
    }

    // A group over the `Retrieve` cap cannot finish in one call. Matches are deleted,
    // so calling again makes progress.
    string[] notes = [];
    if truncatedGroups > 0 {
        notes.push(string `data source '${dsId}': ${truncatedGroups} group(s) of documents sharing one ` +
            string `metadata id exceeded the ${KB_MAX_RESULTS_PER_CALL}-result 'Retrieve' cap, so the ` +
            "documents beyond it could not be checked against the filter and are listed above as " +
            "unconfirmed. The confirmed matches WERE deleted — repeat the same 'deleteByFilter' call to " +
            "continue with the rest.");
    }
    return {toDelete, indeterminate, refusalReason: (), notes};
}

isolated function dataSourceRefusal(string dsId, string reason) returns DataSourceDeleteResult
    => {
        toDelete: [],
        indeterminate: [],
        notes: [],
        refusalReason: string `data source '${dsId}': ${reason} — nothing was deleted from this data source.`
    };

// The metadata key that pins one document on this data source: the source-uri key if
// results carry it, else `KB_DOCUMENT_ID_METADATA_KEY`. `()` when neither is present.
isolated function observePinKey(BedrockTransport dataTransport, string kbId, string sourceUriKey,
        DeleteRetrieveCaller retrieveCaller, DataSourceScope scope) returns string?|ai:Error {
    // Several documents, not one: a data source can mix pinnable and unpinnable ones.
    [json[], string?] [results, _] =
        check retrieveCaller(dataTransport, kbId, dataSourceLeaf(scope), KB_PIN_KEY_SAMPLE_SIZE, ());
    foreach json result in results {
        // Only this data source's results: another can use a different pin.
        if !belongsToDataSource(result, scope) {
            continue;
        }
        map<json> metadata = asMap(asMap(result)["metadata"] ?: {});
        if metadata.hasKey(sourceUriKey) {
            return sourceUriKey;
        }
        if metadata.hasKey(KB_DOCUMENT_ID_METADATA_KEY) {
            return KB_DOCUMENT_ID_METADATA_KEY;
        }
    }
    return ();
}

// Resolves one pin group (all candidates one pinned filter selects):
//
//   the filtered probe returned this exact identity -> DELETE_MATCH
//   only the unfiltered probe returned it            -> DELETE_SKIP
//   neither returned it                              -> DELETE_INDETERMINATE
//
// Identity is exact: a shared `<parent>#` prefix is not proof of shared metadata.
isolated function resolvePinGroup(BedrockTransport dataTransport, string kbId, DataSourceScope scope,
        json? userFilter, DeletableDocument[] group, string pinValue, string pinKey, string sourceUriKey,
        DeleteRetrieveCaller retrieveCaller) returns [json[], UnresolvedCandidate[], boolean]|ai:Error {
    string dsId = scope.id;
    json pin = pinnedFilter(pinKey, pinValue);
    json dsLeaf = dataSourceLeaf(scope);
    json filtered = check combineFilters(userFilter, [pin, dsLeaf]);
    json reachable = check combineFilters((), [pin, dsLeaf]);

    DeleteEnumeration matchedProbe =
        check enumerateDeleteIdentities(dataTransport, kbId, filtered, sourceUriKey, retrieveCaller, scope);
    boolean allMatched = true;
    foreach DeletableDocument candidate in group {
        if !matchedProbe.identities.hasKey(candidate.sourceValue) {
            allMatched = false;
            break;
        }
    }
    // Skipped when the first probe already found every member.
    DeleteEnumeration reachableProbe = allMatched
        ? {identities: {}, truncated: false}
        : check enumerateDeleteIdentities(dataTransport, kbId, reachable, sourceUriKey, retrieveCaller, scope);

    // A full probe was cut off by relevance, so absence from it proves nothing.
    boolean truncated = matchedProbe.truncated || reachableProbe.truncated;

    json[] toDelete = [];
    UnresolvedCandidate[] indeterminate = [];
    foreach DeletableDocument candidate in group {
        if matchedProbe.identities.hasKey(candidate.sourceValue) {
            // Matched under the caller's filter.
            toDelete.push(candidate.identifier);
        } else if truncated {
            indeterminate.push({sourceValue: candidate.sourceValue, dataSourceId: dsId,
                reason: UNRESOLVED_GROUP_TOO_LARGE});
        } else if !reachableProbe.identities.hasKey(candidate.sourceValue) {
            indeterminate.push({sourceValue: candidate.sourceValue, dataSourceId: dsId,
                reason: UNRESOLVED_UNREACHABLE});
        }
        // else: reached without the filter but not with it, so the filter excluded it.
    }
    return [toDelete, indeterminate, truncated];
}

# The one data source a `deleteByFilter` works on, and the metadata key that names it
# on a retrieval result (it differs between managed and self-managed knowledge bases).
type DataSourceScope record {|
    # The reserved data-source-id metadata attribute
    string key;
    # The data source id
    string id;
|};

// The `equals` leaf that restricts a `Retrieve` to the scoped data source.
isolated function dataSourceLeaf(DataSourceScope scope) returns json
    => {'equals: {key: scope.key, value: scope.id}};

// A result without the attribute is not assumed to belong: that would delete from the
// wrong data source.
isolated function belongsToDataSource(json result, DataSourceScope scope) returns boolean
    => stringField(asMap(asMap(result)["metadata"] ?: {}), scope.key) == scope.id;

// AWS caps a `RetrievalFilter` group at 5 members and allows one level of nesting.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_RetrievalFilter.html
const int MAX_FILTER_GROUP_MEMBERS = 5;

// ANDs the caller's filter with this module's leaves within AWS's limits: an `andAll`
// is flattened rather than nested. A filter that still does not fit is refused.
isolated function combineFilters(json? userFilter, json[] leaves) returns json|ai:Error {
    if userFilter is () {
        return leaves.length() == 1 ? leaves[0] : {andAll: leaves};
    }
    json[] members = [];
    json? andAll = asMap(userFilter)["andAll"];
    if andAll is json[] {
        members.push(...andAll);
    } else {
        members.push(userFilter);
    }
    members.push(...leaves);
    if members.length() <= MAX_FILTER_GROUP_MEMBERS {
        return {andAll: members};
    }
    // Too wide to flatten: keep the caller's group whole, legal only if its members
    // are all leaves.
    if andAll is json[] && andAll.every(m => asMap(m)["andAll"] is () && asMap(m)["orAll"] is ()) {
        return {andAll: [userFilter, ...leaves]};
    }
    return error ai:Error(string `This filter is too complex for 'deleteByFilter': it must fit in ` +
        string `${MAX_FILTER_GROUP_MEMBERS - leaves.length()} top-level conditions, or use only simple conditions.`);
}

// The pin group for a candidate. A source-uri pin is per document; an `ai:Metadata.id`
// pin selects a whole fan-out family. Grouping only saves calls; the verdict is per
// document.
isolated function pinGroupKeyFor(string sourceValue, string pinKey) returns string
    => pinKey == KB_DOCUMENT_ID_METADATA_KEY ? fanOutParentOf(sourceValue) : sourceValue;

// `"540801#37"` -> `"540801"`; an id that never fanned out is its own parent.
// Mirrors `documentIdFor`'s `<parent>#<ordinal>` construction.
isolated function fanOutParentOf(string sourceValue) returns string {
    int? hash = sourceValue.indexOf("#");
    return hash is int ? sourceValue.substring(0, hash) : sourceValue;
}

// The `pinKey == sourceValue` leaf. `ai:Metadata.id` is stored as a number, so the leaf
// carries a number; a fan-out id pins on its parent.
isolated function pinnedFilter(string pinKey, string sourceValue) returns json {
    if pinKey != KB_DOCUMENT_ID_METADATA_KEY {
        return {'equals: {key: pinKey, value: sourceValue}};
    }
    int|error parentId = int:fromString(fanOutParentOf(sourceValue));
    return parentId is int
        ? {'equals: {key: pinKey, value: parentId}}
        : {'equals: {key: pinKey, value: sourceValue}};
}

// ============================================================================
// Idempotent creation.
// ============================================================================

// A `clientToken` derived from the request body, so a retried identical create
// collapses into one. It does not stop two creates already in flight; the 409 recovery
// and the duplicate check handle those. A 64-character hex digest fits its pattern.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CreateKnowledgeBase.html
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CreateDataSource.html
isolated function idempotencyToken(json canonical) returns string
    => crypto:hashSha256(canonical.toJsonString().toBytes()).toBase16();

// ============================================================================
// Attach-by-definition verification.
// ============================================================================

// A name match attaches to a knowledge base the caller described but did not create, so
// the fields the module would have sent (role, embedding model, KMS key, storage) must
// match it. Only the leaves the definition sets are compared; `name`, `description` and
// the data source are not.
isolated function assertDefinitionMatches(string kbId, map<json> expectedCreateBody, map<json> actual)
        returns ai:Error? {
    string[] differences = [];
    foreach string comparable in ["roleArn", "knowledgeBaseConfiguration", "storageConfiguration"] {
        json expected = expectedCreateBody[comparable] ?: ();
        if expected is () {
            continue;
        }
        string label = comparable == "roleArn" ? "serviceRoleArn" : comparable;
        differences.push(...jsonDiffPaths(expected, actual[comparable] ?: (), label));
    }
    if differences.length() == 0 {
        return;
    }
    return errorWithDetail(
        string `Knowledge base '${kbId}' matches the definition's name, but ${differences.length()} field(s) ` +
        string `differ: ${string:'join("; ", ...differences)}. Pass the knowledge base id to attach to it ` +
        "as it is, or correct the definition.",
        "These fields are fixed at creation time, so the definition passed is not the one in effect.");
}

// Paths where `expected`'s leaves disagree with `actual`. Numeric-aware, so an `int`
// the module sent and a `decimal` AWS echoes back are not reported as a difference.
isolated function jsonDiffPaths(json expected, json actual, string path) returns string[] {
    if expected is map<json> {
        if actual !is map<json> {
            return [string `${path} (definition sets it, knowledge base has ${actual.toJsonString()})`];
        }
        string[] differences = [];
        foreach [string, json] [key, value] in expected.entries() {
            differences.push(...jsonDiffPaths(value, actual[key] ?: (), string `${path}.${key}`));
        }
        return differences;
    }
    if expected is json[] {
        if actual !is json[] || actual.length() != expected.length() {
            return [string `${path} (definition has ${expected.toJsonString()}, knowledge base has ` +
                string `${actual.toJsonString()})`];
        }
        string[] differences = [];
        foreach int i in 0 ..< expected.length() {
            differences.push(...jsonDiffPaths(expected[i], actual[i], string `${path}[${i}]`));
        }
        return differences;
    }
    if jsonScalarEquals(expected, actual) {
        return [];
    }
    return [string `${path} (definition says ${expected.toJsonString()}, knowledge base has ` +
        string `${actual.toJsonString()})`];
}

// `1024` sent as an `int` comes back as a `decimal`; that is not a mismatch.
isolated function jsonScalarEquals(json expected, json actual) returns boolean {
    if expected is int|float|decimal && actual is int|float|decimal {
        return <decimal>expected == <decimal>actual;
    }
    return expected == actual;
}

// ============================================================================
// Small pure helpers.
// ============================================================================

isolated function asMap(json j) returns map<json> => j is map<json> ? j : {};

isolated function stringField(map<json> m, string key) returns string? {
    json v = m[key] ?: ();
    return v is string ? v : ();
}

isolated function partitionStrings(string[] items, int batchSize) returns string[][] {
    string[][] batches = [];
    int index = 0;
    while index < items.length() {
        int end = index + batchSize;
        if end > items.length() {
            end = items.length();
        }
        batches.push(items.slice(index, end));
        index = end;
    }
    return batches;
}

isolated function partitionJson(json[] items, int batchSize) returns json[][] {
    json[][] batches = [];
    int index = 0;
    while index < items.length() {
        int end = index + batchSize;
        if end > items.length() {
            end = items.length();
        }
        batches.push(items.slice(index, end));
        index = end;
    }
    return batches;
}
