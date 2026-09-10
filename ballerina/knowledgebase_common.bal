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

// The shared spine `BedrockManagedKnowledgeBase` is built over: two agent-plane
// transports, find-or-create, data-source resolution, chunking-strategy detection,
// and the document/knowledge-base wire calls both `ingest()` and `deleteByFilter()`
// need. `BedrockVectorKnowledgeBase` (knowledgebase_vector.bal) is built over the
// same spine, with its own request bodies where the self-managed API shape differs.

// Bedrock's `_source_uri` metadata attribute — injected on every retrieval result,
// holding the document's `customDocumentIdentifier.id` (CUSTOM sources) or S3 object
// URI (S3 sources). NOT in either service model: undocumented and non-contractual,
// confirmed only by calling the live API against a MANAGED knowledge base with a
// CUSTOM data source (2026-08-14). It is what makes `deleteByFilter`'s probe
// possible at all — Bedrock has no metadata-based delete and no way to read a
// document's metadata back any other way.
const string SOURCE_URI_METADATA_KEY = "_source_uri";

// The public class names, threaded into every error message raised from a file both
// classes share. Without this a `BedrockVectorKnowledgeBase` user gets errors naming
// `BedrockManagedKnowledgeBase` — a class they are not using.
const string MANAGED_KB_PROVIDER = "BedrockManagedKnowledgeBase";
const string VECTOR_KB_PROVIDER = "BedrockVectorKnowledgeBase";

// `deleteByFilter`'s enumeration query text. Its CONTENT is irrelevant and this is
// not a tuning knob — it exists solely because `Retrieve` REJECTS an empty query:
// `{"text": ""}`, `{"text": " "}` and an omitted `text` all return 400 "Text input is
// required." (The service model's `KnowledgeBaseQueryTextString` declares `min: 0`,
// which the live API contradicts.)
//
// A17: this constant PREVIOUSLY also carried the reasoning for a per-document PINNED
// probe (`_source_uri == id` ANDed onto the query, taking the single pinned result
// off the scoring path). That algorithm is gone — see `resolveDataSourceDeletes` —
// replaced by two PAGED enumerations per data source that page through every result
// via `nextToken` up to `KB_DELETE_ENUMERATION_MAX_PAGES`, so no individual result's
// relevance score matters to correctness the way a single pinned probe's did.
const string FILTER_PROBE_QUERY = "PLACE HOLDER";

// A17: page cap for the filtered enumeration `resolveDataSourceDeletes` runs per data
// source (100 pages x 100 results/page = 10 000 results). If the
// filtered pass hits this cap the CONFIRMED-MATCH set may be incomplete, so a data
// source that hits it has NOTHING deleted from it, reported rather than silently
// under-deleting.
const int KB_DELETE_ENUMERATION_MAX_PAGES = 100;

// How many documents `observePinKey` samples before deciding a data source has no
// usable pin key. More than one because a data source can hold both pinnable and
// unpinnable documents; small because it only has to find ONE carrying a key.
const int KB_PIN_KEY_SAMPLE_SIZE = 10;

// A18 — the caller metadata key that pins a document on a CUSTOM data source.
//
// Bedrock injects NO per-document metadata key there (A17's root cause): the observed
// attributes are `x-amz-bedrock-kb-chunk-id`, which is per CHUNK, and
// `x-amz-bedrock-kb-data-source-id`, which is per DATA SOURCE. Neither identifies a
// document. What does is the caller's own `id`: `documentIdFor` DERIVES
// `customDocumentIdentifier.id` from `ai:Metadata.id`, so for anything this module
// ingested the two agree by construction, and the value is filterable because
// `metadataToDocumentMetadata` sends it as an `IN_LINE_ATTRIBUTE`.
const string KB_DOCUMENT_ID_METADATA_KEY = "id";



// `ListKnowledgeBases`/`ListDataSources`/`ListKnowledgeBaseDocuments` share one
// `MaxResults` shape declaring `max: 1000` — but the LIVE `ListKnowledgeBaseDocuments`
// API rejects anything over 100 ("maxResults must be less than or equal to 100"),
// contradicting the service model. Applied to all three list calls here
// defensively, since they share the shape.
const int KB_LIST_PAGE_SIZE = 100;

// `IngestKnowledgeBaseDocuments`/`DeleteKnowledgeBaseDocuments`/
// `GetKnowledgeBaseDocuments` all cap their array parameter at 10 elements
// (`KnowledgeBaseDocuments`/`DocumentIdentifiers`, both `max: 10`).
const int KB_DOCUMENT_BATCH_SIZE = 10;

// Poll interval for knowledge base / data source / document status.
const decimal KB_POLL_INTERVAL_SECONDS = 3;

// `CreateDataSource` returns 200 with an AVAILABLE status on the managed-KB path in
// the common case, but it is NOT synchronous: AWS documents the status as
// transitioning CREATING -> AVAILABLE, and a create can return 200 with a real
// `dataSourceId` for a payload the service then rejects, surfacing only as
// `status: FAILED` + `failureReasons` on a later `GetDataSource`. `pollDataSourceAvailable`
// is therefore live code, and `validateResolvedDataSource` re-reads the status even
// when the create response said AVAILABLE.
const decimal DEFAULT_DATA_SOURCE_READY_TIMEOUT = 60;

// Document statuses that are retrievable (usable in `retrieve()` results and safe
// to enumerate for `deleteByFilter()`).
final readonly & string[] KB_DOC_USABLE_STATUSES = ["INDEXED", "PARTIALLY_INDEXED", "METADATA_PARTIALLY_INDEXED"];
// Terminal statuses that are NOT usable.
//
// `NOT_FOUND` is DELIBERATELY ABSENT. It is a tombstone only AFTER a delete; during
// an ingest poll it means "accepted, not yet visible to the read path", and
// `KB_DOC_POLL_TRANSIENT_STATUSES` below polls through it, so it can never reach the
// outcome map this list classifies.
final readonly & string[] KB_DOC_FAILED_STATUSES = ["FAILED", "METADATA_UPDATE_FAILED", "IGNORED"];
// Statuses `ingest()`'s poll keeps WAITING through, rather than treating as terminal:
// the three genuinely in-flight ones, plus `NOT_FOUND`.
//
// `NOT_FOUND` is the addition, and it is the difference between a correct ingest and
// a non-deterministic false failure. `IngestKnowledgeBaseDocuments` is accepted with
// a 202; a `GetKnowledgeBaseDocuments` issued immediately afterwards can answer
// `NOT_FOUND` for a document that has been accepted but is not yet visible to the
// read path. Treating that as terminal exits the poll on its first iteration and
// reports "N of N document(s) failed to index (NOT_FOUND)" for documents that go on
// to index successfully — read-after-write timing, nothing else.
//
// Polling through it costs nothing when the document really is absent: the deadline
// still bounds the wait, and the timeout names the ids.
final readonly & string[] KB_DOC_POLL_TRANSIENT_STATUSES = ["PENDING", "STARTING", "IN_PROGRESS", "NOT_FOUND"];
// Per-document statuses in a `DeleteKnowledgeBaseDocuments` response that mean the
// delete was accepted: the two delete-in-flight states, plus `NOT_FOUND` — already
// gone is exactly the outcome the caller asked for.
//
// There is NO `DELETE_UNSUCCESSFUL` in `DocumentStatus` (that value belongs to the
// knowledge base / data source status enums), so a failed delete surfaces as the
// document simply keeping a non-delete status. Anything outside this set is
// therefore reported rather than assumed successful.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_KnowledgeBaseDocumentDetail.html
final readonly & string[] KB_DOC_DELETE_ACCEPTED_STATUSES = ["DELETING", "DELETE_IN_PROGRESS", "NOT_FOUND"];

// Which bedrock-agent-runtime search branch `retrieve()` uses. Fixed to managed —
// `vectorSearchConfiguration`'s knobs (`overrideSearchType`, `implicitFilterConfiguration`)
// are meaningless against a Bedrock-owned vector store.
const int KB_MAX_RESULTS_PER_CALL = 100;

// ============================================================================
// Spine resolution.
// ============================================================================

# Everything `BedrockManagedKnowledgeBase`'s methods read: two agent-plane
# transports (control on `bedrock-agent`, data on `bedrock-agent-runtime`), the
# resolved knowledge base / data source ids, and the detected chunking strategy.
# Module-private — the resolver's output, mirroring `Route`/`Endpoint`.
#
# + controlTransport - `bedrock-agent` (create/list/get KB & data source, ingest/list/get/delete documents)
# + dataTransport - `bedrock-agent-runtime` (retrieve)
# + knowledgeBaseId - The resolved knowledge base id
# + dataSourceId - The resolved `CUSTOM` data source id
# + chunkingStrategy - The resolved data source's actual chunking strategy
type KbSpine record {|
    BedrockTransport controlTransport;
    BedrockTransport dataTransport;
    string knowledgeBaseId;
    string dataSourceId;
    ChunkingStrategy chunkingStrategy;
|};

// The shared construction spine: transports -> find-or-create -> data-source
// resolution -> chunking detection. Every failure surfaces here, before any method
// is callable.
isolated function resolveKbSpine(string providerName, KnowledgeBaseCredentials credentials, string region,
        aws:EndpointConfig? endpointConfig, string|KnowledgeBaseDefinition knowledgeBase,
        string? dataSourceIdOverride, http:ClientConfiguration? httpConfig, RetryConfig? retryConfig,
        RerankingModelType? rerankingModelType = ())
        returns KbSpine|ai:Error {
    do {
        check guardRegion(region);
        check guardEmbeddingModelAgainstReranker(knowledgeBase, rerankingModelType);
        Endpoint controlEp = check buildAgentEndpoint(AGENT_CONTROL, region, endpointConfig);
        Endpoint dataEp = check buildAgentEndpoint(AGENT_DATA, region, endpointConfig);
        // One provider, both planes.
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

# Outcome of resolving `string|KnowledgeBaseDefinition` to a concrete knowledge
# base. `createdDataSourceId` is set ONLY when a new knowledge base (and its
# `CUSTOM` data source) was just created — in every other case (a bare id, or an
# existing knowledge base found by name) data-source resolution still has to run.
#
# + knowledgeBaseId - The attached or newly created knowledge base id
# + createdDataSourceId - The `CUSTOM` data source id, when this call just created it
type KbAttachResult record {|
    string knowledgeBaseId;
    string? createdDataSourceId;
|};

// `string` -> verify and attach (no writes). `KnowledgeBaseDefinition` -> find by
// name; exactly one match attaches, no match creates (knowledge base + its `CUSTOM`
// data source), more than one match is a construction error — `CreateKnowledgeBase`
// has no upsert, and while knowledge base NAMES ARE UNIQUE PER ACCOUNT (measured
// live 2026-09-08: a sequential duplicate-name create is rejected with a 409), a
// race window at AWS's own layer means more than one can still exist — see A10
// below. Guessing which one was meant would risk attaching to the wrong one.
isolated function resolveKnowledgeBase(BedrockTransport controlTransport, string|KnowledgeBaseDefinition knowledgeBase)
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
    // No match: create the knowledge base, wait for it to leave CREATING, then
    // create its CUSTOM data source and wait for that too — two asynchronously
    // provisioned resources, not one, is the real cost of this path.
    //
    // A10 has TWO distinct race windows here, both from the same read-then-write
    // (list-by-name, see nothing, create):
    //   - SEQUENTIAL: `createKnowledgeBaseRecoveringFromConflict` recovers from a 409
    //     by attaching to the one existing match (§2a) — this branch never creates a
    //     duplicate.
    //   - GENUINELY CONCURRENT: two `init()` calls already in flight, sharing the
    //     SAME deterministic `clientToken`, were measured BOTH accepted live
    //     2026-09-08 — the token collapses retries, not requests already in flight.
    //     Undetectable until after this call's own create is ACTIVE, so it is
    //     checked below, after `pollKnowledgeBaseActive` (§2b).
    KbCreateOutcome created = check createKnowledgeBaseRecoveringFromConflict(controlTransport, knowledgeBase);
    if created.recovered {
        return {knowledgeBaseId: created.knowledgeBaseId, createdDataSourceId: ()};
    }
    string kbId = created.knowledgeBaseId;
    check pollKnowledgeBaseActive(controlTransport, kbId, knowledgeBase.readyTimeout);
    string dsId = check createCustomDataSource(controlTransport, kbId, knowledgeBase.dataSource);

    // §2b: now that this call's own create is ACTIVE, re-list by name. AWS's
    // idempotency token cannot serialize two requests already in flight, so a
    // genuinely concurrent race can still have produced more than one knowledge base
    // under this name even though this call's own create looked clean throughout.
    check guardAgainstConcurrentDuplicate(controlTransport, knowledgeBase.name, kbId);
    return {knowledgeBaseId: kbId, createdDataSourceId: dsId};
}

// The message for "more than one knowledge base already carries this name" —
// shared by the ordinary find-by-name path above and the §2a conflict-recovery path.
isolated function nameAmbiguityMessage(string name, string[] candidates) returns string
    => string `${candidates.length()} knowledge bases are named '${name}' ` +
        string `(${string:'join(", ", ...candidates)}) — construction cannot tell which one was meant. ` +
        "Pass the knowledge base id directly instead of a definition.";

// Both that the knowledge base is ACTIVE and that it is actually a MANAGED one.
//
// The type check is not pedantry. EVERY behaviour this class depends on was measured
// against Bedrock's own vector store, on the `managedSearchConfiguration` branch:
// `retrieve()` sends that branch unconditionally, and `deleteByFilter`'s whole
// soundness argument rests on a pinned `_source_uri` filter taking the query off the
// scoring path (see `FILTER_PROBE_QUERY` for those measurements). A `VECTOR`
// knowledge base queries a CUSTOMER-owned store (OpenSearch Serverless, Pinecone,
// pgvector, ...) through a different branch and a different ranking engine, where
// none of that was measured and the pinned probe may score normally — which would
// put `deleteByFilter` back to silently under-deleting. Refuse at construction
// rather than half-work at runtime.
// Returns the fetched knowledge base so the attach-by-definition comparison can
// reuse it rather than issuing a second identical `GetKnowledgeBase`.
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
    // Absent type is tolerated: it is required in the service model, so a missing one
    // means an unexpected response shape rather than a non-managed knowledge base,
    // and failing construction over it would be a false positive.
    if kbType != "" && kbType != "MANAGED" {
        return error ai:Error(
            string `Knowledge base '${kbId}' is of type '${kbType}', but BedrockManagedKnowledgeBase ` +
            "supports only 'MANAGED' knowledge bases (the ones where Bedrock owns the vector store). " +
            "A 'VECTOR' knowledge base is backed by your own vector store and is served by a different " +
            "search branch, so retrieve() and deleteByFilter() are not valid against it. Use " +
            "BedrockVectorKnowledgeBase for a 'VECTOR' knowledge base.");
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

// A caller-supplied embedding model and Bedrock's managed reranker are mutually
// exclusive: "If you create a knowledge base with a custom embedding model, the
// managed reranker is not available for that knowledge base."
// https://docs.aws.amazon.com/bedrock/latest/userguide/kb-managed-create.html
//
// Both choices are permanent — `embeddingModelType` cannot be changed after creation
// — so this has to fail at construction. Discovering it from a failed `retrieve()`
// would mean the knowledge base was already built with the wrong combination and has
// to be rebuilt. Only checkable on the CREATE path: attaching by id says nothing
// about how the knowledge base was configured.
isolated function guardEmbeddingModelAgainstReranker(string|KnowledgeBaseDefinition knowledgeBase,
        RerankingModelType? rerankingModelType) returns ai:Error? {
    if knowledgeBase is string || rerankingModelType != RERANKING_MANAGED {
        return;
    }
    if knowledgeBase?.embeddingModel is ManagedEmbeddingModel {
        return error ai:Error(
            "'rerankingModelType' is RERANKING_MANAGED and 'knowledgeBase.embeddingModel' is set, but AWS " +
            "makes the managed reranker unavailable on a knowledge base created with a caller-supplied " +
            "embedding model. Both are permanent at creation time, so pick one: drop 'embeddingModel' to " +
            "keep managed reranking, or use RERANKING_NONE (or leave 'rerankingModelType' unset) to keep " +
            "your own embedding model.");
    }
}

// The `CreateKnowledgeBase` request body. Pure, so the embedding-model and KMS
// branches are testable without AWS.
//
// MANAGED needs no `storageConfiguration` at all — Bedrock owns the vector store.
// The embedding model is the caller's choice, and AWS is strict about which fields
// accompany which type: "When using MANAGED, you must not specify embeddingModelArn
// or embeddingModelConfiguration. When using CUSTOM, both fields are required."
// https://docs.aws.amazon.com/bedrock/latest/userguide/kb-managed-create.html
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_ManagedKnowledgeBaseConfiguration.html
isolated function createKnowledgeBaseRequestBody(KnowledgeBaseDefinition def) returns map<json> {
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
        roleArn: def.roleArn,
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

# Outcome of `createKnowledgeBaseRecoveringFromConflict` — distinguishes an ordinary
# create from an A10 §2a recovery, so the caller knows whether a `CUSTOM` data source
# still needs to be created (a recovery attached to something that already has one).
#
# + knowledgeBaseId - The created id, or, on recovery, the id of the existing match
# + recovered - `true` when this is a §2a 409-recovery attach rather than a fresh create
type KbCreateOutcome record {|
    string knowledgeBaseId;
    boolean recovered;
|};

// A10 §2a: `CreateKnowledgeBase`'s deterministic `clientToken` (see
// `idempotencyToken`) collapses a RETRIED identical create, but a SEQUENTIAL
// duplicate — a different `init()` call that already created a knowledge base under
// this name — is answered with a 409 `ConflictException`. AWS enforces name
// uniqueness (measured live 2026-09-08: "KnowledgeBase with name ... already
// exists."), so this is fully recoverable: re-resolve the name exactly as the
// ordinary attach-by-name path does (`verifyKnowledgeBaseUsable` +
// `assertDefinitionMatches`), so A9's definition check is never bypassed by this
// recovery path. Zero or more than one match surfaces the ORIGINAL 409 unchanged —
// neither case is resolvable from here (no match: the 409 raced against a delete
// that has not been observed; more than one: a genuinely concurrent creation, §2b's
// territory instead, which this function cannot distinguish from here).
isolated function createKnowledgeBaseRecoveringFromConflict(BedrockTransport controlTransport,
        KnowledgeBaseDefinition def) returns KbCreateOutcome|ai:Error {
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
        // The original 409's message text, unchanged — this module cannot resolve
        // zero or an ambiguous number of matches on its own.
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

// A10 §2b: the reconcile-and-report check run once THIS call's own create is ACTIVE.
// AWS's idempotency token cannot serialize two requests already in flight sharing it
// — measured live 2026-09-08, two genuinely concurrent `init()` calls both succeeded
// — so more than one knowledge base can still carry this name even though this
// call's own create looked completely clean. Deterministic winner selection (the
// lexicographically smallest id) means every racer that hits this check computes the
// SAME winner from the SAME candidate set without coordinating, so the account
// converges on one agreed survivor. NEVER deletes: this module has no HTTP DELETE
// verb, and issuing one from a constructor that may lack `bedrock:DeleteKnowledgeBase`
// would be worse than the duplicate — the caller runs the named cleanup command
// manually. Reports unconditionally (regardless of whether THIS call's own creation
// turned out to be the winner or an orphan): the alternative — staying silent
// whenever this call happened to win — would leave that caller's account and quota
// polluted with an orphan it is never told about.
isolated function guardAgainstConcurrentDuplicate(BedrockTransport controlTransport, string name, string thisCallsKbId)
        returns ai:Error? {
    string[] matches = check listKnowledgeBaseIdsByName(controlTransport, name);
    if matches.length() <= 1 {
        return;
    }
    return error ai:Error(concurrentDuplicateMessage(name, matches, thisCallsKbId));
}

// Pure so the winner/orphan computation is table-testable without AWS.
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
        string `issues 'DeleteKnowledgeBase'); clean them up manually: ${string:'join("; ", ...cleanupCommands)}`;
}

// ~83s was measured for a VECTOR knowledge base to leave CREATING — a customer-owned
// store has to be provisioned there. That figure does NOT hold for a MANAGED
// knowledge base (Bedrock's own store): measured 2026-09-07, `CreateKnowledgeBase`
// reached ACTIVE in under 5s (`readyTimeout: 5` did not fire at all; `readyTimeout:
// 0.001` returned in 4.3s still CREATING). Either way this can take too long to block
// silently, hence the caller-controlled `readyTimeout` rather than a fixed wait.
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
// Data-source creation (when the module creates the knowledge base) and resolution
// (when it attaches to an existing one).
// ============================================================================

// A managed knowledge base REJECTS a bare `{"type": "CUSTOM"}` data source with
// "Unsupported data source type for MANAGED knowledge base type." — the console's
// "Custom" source is really `MANAGED_KNOWLEDGE_BASE_CONNECTOR` with the real type
// nested in `connectorParameters` (established by calling the live API; not
// documented). A self-managed (VECTOR) knowledge base takes the plain form instead
// — see `createVectorDataSourceRequestBody` in knowledgebase_vector_common.bal.
// The `CreateDataSource` request body. Pure, so the two things the live API demands
// — `connectorParameters.version`, and the ABSENCE of `vectorIngestionConfiguration`
// — are assertable without AWS.
isolated function createDataSourceRequestBody(DataSourceDefinition def) returns map<json>|ai:Error {
    map<json> body = {
        name: def.name,
        dataSourceConfiguration: {
            'type: "MANAGED_KNOWLEDGE_BASE_CONNECTOR",
            managedKnowledgeBaseConnectorConfiguration: {
                // `version` is REQUIRED — omitting it returns 400 "The 'version'
                // field is required in connector parameters." (measured), and AWS
                // documents it as "a required version field set to 1".
                // https://docs.aws.amazon.com/bedrock/latest/userguide/kb-managed-connect-ds.html
                connectorParameters: {'type: "CUSTOM", version: "1"}
            }
        }
        // NO `vectorIngestionConfiguration`. Two separate reasons:
        //   - `parsingConfiguration`: managed knowledge bases only support
        //     SMART_PARSING, which is also the default, so sending it is noise.
        //   - `chunkingConfiguration`: REJECTED outright on a service-managed
        //     embedding model — "A chunking strategy cannot be specified with a
        //     managed embedding model. Omit chunkingConfiguration to use the
        //     default." (measured for NONE, FIXED_SIZE and SEMANTIC alike). AWS's
        //     own docs contradict this and even show a `DEFAULT` strategy value that
        //     the API rejects as invalid.
        //
        // Whether a CALLER-SUPPLIED embedding model (`ManagedEmbeddingModel`) lifts
        // the chunking restriction is UNVERIFIED — the test needs the knowledge
        // base's role to hold `bedrock:InvokeModel` on the embedding model. If it
        // does, this is where a `chunkingConfiguration` would be added, guarded on
        // `def?.embeddingModel is ManagedEmbeddingModel`, and `ChunkingStrategy`
        // becomes reachable through this path.
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
    // Scoped by knowledge base id: the KB-level token collapses two racing creates
    // onto ONE knowledge base, but both racers then go on to create its data source.
    // Without a token here that leaves two CUSTOM data sources on one knowledge base,
    // which makes `resolveCustomDataSource` permanently ambiguous.
    body["clientToken"] = idempotencyToken({kbId, dataSource: body});
    string path = string `/knowledgebases/${kbId}/datasources/`;
    TransportResponse response = check controlTransport.executeRequest("PUT", path, body);
    map<json> dataSource = asMap(asMap(response.body)["dataSource"] ?: {});
    string? id = stringField(dataSource, "dataSourceId");
    if id is () {
        return error ai:Error("CreateDataSource response carried no 'dataSourceId'");
    }
    // Measured SYNCHRONOUS in the common case on the managed-KB path (200 AVAILABLE
    // in the very response above, across four probes) — but AWS documents it as
    // ASYNCHRONOUS, "the data source status transitions from CREATING to AVAILABLE",
    // and that holds only for the CUSTOM connector this module creates. On a MANAGED
    // knowledge base `CreateDataSource` is genuinely asynchronous: it can return this
    // same 200 with a real `dataSourceId` for a payload the service goes on to
    // reject, surfacing only as `status: FAILED` + `failureReasons` on a LATER
    // `GetDataSource`. The poll below is THEREFORE LIVE CODE, not dead: it is what
    // catches that failure at construction instead of at the first `ingest()`. Do
    // not remove it because the create response usually already says AVAILABLE.
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

// Resolves the single `CUSTOM` data source `ingest()`/`deleteByFilter()` write to.
// `DataSourceSummary` carries no type at all, so this costs one `GetDataSource` per
// data source on the knowledge base.
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
        return error ai:Error(
            string `Knowledge base '${kbId}' has no 'CUSTOM' data source: 'ingest()'/'deleteByFilter()' have ` +
            "nowhere to write. Add a CUSTOM (direct-ingestion) data source in the AWS console, or pass a " +
            "'KnowledgeBaseDefinition' instead of a bare id so this class creates one.");
    }
    return error ai:Error(
        string `Knowledge base '${kbId}' has ${candidates.length()} 'CUSTOM' data sources ` +
        string `(${string:'join(", ", ...candidates)}) — ambiguous. Pass 'dataSourceId' explicitly.`);
}

// The data source's EFFECTIVE type: `dataSourceConfiguration.type` directly, except
// when it is `MANAGED_KNOWLEDGE_BASE_CONNECTOR` — the wrapper every managed-KB data
// source uses — in which case the real type is nested inside `connectorParameters`.
//
// OBSERVED ON THE LIVE API, NOT DOCUMENTED: the service model declares
// `connectorParameters` a free-form `Document` (arbitrary JSON) on BOTH the write and
// read paths, but the live `GetDataSource`/`ListDataSources` response returns it as a
// JSON-ENCODED STRING, not an object — asymmetric with what `CreateDataSource`
// accepts. Both shapes are handled here so a future AWS fix does not silently break
// this.
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

// The single `GetDataSource` every construction path already had to make, now doing
// three jobs at once: it fails construction on a data source that is FAILED or is not
// a CUSTOM connector, and reads the RESOLVED data source's actual `chunkingStrategy`
// back — never assumed — so `ManagedKnowledgeBaseConfig.chunker`'s default can be
// picked safely: `ai:DISABLE` when Bedrock chunks server-side, `ai:AUTO` when the
// strategy is `NONE`. All three fail before any ingest or retrieve I/O.
//
// UNRESOLVED (see the `ChunkingStrategy` doc comment for the full write-up): a
// managed knowledge base may never report `chunkingConfiguration` at all. Measured
// 2026-08-14, `GetDataSource` on a console-created managed data source returned
// `vectorIngestionConfiguration: {parsingConfiguration: {parsingStrategy:
// SMART_PARSING}}` and nothing else — despite the console exposing a chunking
// selector for that same data source. That data source was created with "Default
// chunking", so the omission may just mean "nothing explicit was set"; it has NOT
// been tested whether a data source created with an explicit strategy echoes one
// back. If it never does, the `NONE` branch below is unreachable on data sources
// this module did not create, and such callers must pass an `ai:Chunker`
// explicitly. The fallback below is chosen to fail in the safe direction either way.
isolated function validateResolvedDataSource(BedrockTransport controlTransport, string kbId, string dsId)
        returns ChunkingStrategy|ai:Error {
    map<json> dataSource = check getDataSource(controlTransport, kbId, dsId);

    // Re-read the status even when a create response already said AVAILABLE.
    // `CreateDataSource` can answer 200 with a real `dataSourceId` for a payload the
    // service then rejects; the rejection surfaces only here, as FAILED plus
    // `failureReasons`. Discovering it at construction beats discovering it as an
    // unexplained ingest failure later.
    string status = stringField(dataSource, "status") ?: "";
    if status == "FAILED" || status == "DELETE_UNSUCCESSFUL" {
        return error ai:Error(
            string `Data source '${dsId}' on knowledge base '${kbId}' is not usable: status is ` +
            string `'${status}'. ${failureReasonsOf(dataSource)}`);
    }

    // An EXPLICIT `dataSourceId` never went through `resolveCustomDataSource`, so
    // this is the only place its type is checked. `ingest()` submits documents with
    // `dataSourceType: "CUSTOM"`, so a data source that is anything else fails at the
    // first `ingest()` with an error that points nowhere near the misconfiguration.
    string effectiveType = effectiveDataSourceType(dataSource);
    if effectiveType != "CUSTOM" {
        return error ai:Error(
            string `Data source '${dsId}' on knowledge base '${kbId}' is of type '${effectiveType}', but ` +
            "'ingest()'/'deleteByFilter()' write through the CUSTOM (direct-ingestion) connector only. " +
            "Pass the id of a CUSTOM data source, or omit 'dataSourceId' to have it resolved.");
    }

    map<json> vectorIngestion = asMap(dataSource["vectorIngestionConfiguration"] ?: {});
    map<json> chunking = asMap(vectorIngestion["chunkingConfiguration"] ?: {});
    // Absent 'chunkingConfiguration' means Bedrock applies its own default, which is
    // FIXED_SIZE — never silently treat a missing field as NONE, or an explicit
    // 'ai:Chunker' would double-chunk without any construction-time warning.
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
// Document operations — ingest / list / get / delete. Shared by `ingest()` and
// `deleteByFilter()` in knowledgebase_managed.bal.
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

// `DeleteKnowledgeBaseDocuments` answers with a per-document status, and discarding
// it makes a partial delete read as a clean success. Returns the documents the
// service did NOT confirm as deleted, described for an error message; the caller
// decides how to report them.
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

// The value a document is keyed by across both data source types this module can
// delete from — `custom.id` or `s3.uri`, exactly as `listDeletableDocuments` builds
// `DeletableDocument.sourceValue`.
isolated function documentSourceValueOf(map<json> detail) returns string?
    => sourceValueOfIdentifier(detail["identifier"] ?: {});

isolated function sourceValueOfIdentifier(json identifier) returns string? {
    map<json> m = asMap(identifier);
    string? id = stringField(asMap(m["custom"] ?: {}), "id");
    return id is string ? id : stringField(asMap(m["s3"] ?: {}), "uri");
}

# The final (terminal) outcome of one submitted document: its last-seen status and,
# on failure, the reason Bedrock reported.
#
# + status - The terminal `DocumentStatus` (see `KB_DOC_USABLE_STATUSES`/`KB_DOC_FAILED_STATUSES`)
# + statusReason - Bedrock's explanation, present mainly alongside `IGNORED`
type DocumentOutcome record {|
    string status;
    string? statusReason;
|};

// Polls `GetKnowledgeBaseDocuments` until every id in `ids` reaches a terminal
// status, or `timeoutSeconds` elapses. Indexing latency VARIES BY AN ORDER OF
// MAGNITUDE — measured 2026-09-07, a single small document reached a terminal status
// in under 1s on one attempt and was still PENDING after 5.6s on another. Do not tune
// against a fixed figure; hence the caller-controlled timeout rather than a fixed
// short one.
//
// EVERY submitted id is accounted for, and the loop is driven off the SUBMITTED ids
// rather than off whatever the response happened to contain. Two distinct ways a
// document can go unconfirmed, both of which previously read as success:
//
//   - the response reports `NOT_FOUND` (accepted but not yet visible — see
//     `KB_DOC_POLL_TRANSIENT_STATUSES`), and
//   - the response OMITS the id entirely, in which case iterating the response's own
//     entries silently drops it: it is never re-queued and no outcome is recorded, so
//     the loop exits and `ingest()` reports success for a document it never saw.
//
// Both stay pending until they resolve or the deadline names them.
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
            return error ai:Error(
                string `Timed out after ${timeoutSeconds}s waiting for ${pending.length()} document(s) to ` +
                string `reach a terminal status. Still unconfirmed (indexing, or accepted but not yet ` +
                string `visible to 'GetKnowledgeBaseDocuments'): ${string:'join(", ", ...pending)}. Increase ` +
                "'ingestTimeout' — indexing latency varies by an order of magnitude; do not tune against " +
                "a fixed figure.");
        }
        runtime:sleep(KB_POLL_INTERVAL_SECONDS);
    }
    return outcomes;
}

// Two documents in one `ingest()` call that resolve to the SAME
// `customDocumentIdentifier.id` are not two documents to Bedrock: it upserts by that
// id, so the second silently replaces the first and `ingest()` reports success for
// content that is no longer there. Client-side chunking no longer produces this (see
// `documentIdFor`), but two caller-supplied documents sharing an `ai:Metadata.id`
// still can.
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
    return error ai:Error(
        string `${duplicates.length()} document id(s) appear more than once in this ingest call ` +
        string `(${string:'join(", ", ...duplicates)}). Bedrock upserts by 'customDocumentIdentifier.id', ` +
        "so the later document would silently overwrite the earlier one. Give each document a distinct " +
        "'ai:Metadata.id', or ingest them in separate calls if the overwrite is intended.");
}

# One enumerated, retrievable document that `deleteByFilter` can potentially delete.
#
# + sourceValue - `customDocumentIdentifier.id` (CUSTOM) or the S3 object URI (S3) — also what `_source_uri` holds
# + identifier - The ready-to-send `DocumentIdentifier` for `DeleteKnowledgeBaseDocuments`
type DeletableDocument record {|
    string sourceValue;
    json identifier;
|};

// Enumerates the documents on one data source that are both retrievable
// (`KB_DOC_USABLE_STATUSES`) and deletable (`dataSourceType` is `CUSTOM` or `S3` —
// `DocumentIdentifier` has no other members). `ListKnowledgeBaseDocuments` is
// exhaustive but carries no metadata, which is why `deleteByFilter` still has to
// probe each one through `Retrieve` — see knowledgebase_managed.bal.
isolated function listDeletableDocuments(BedrockTransport controlTransport, string kbId, string dsId,
        string dataSourceType) returns DeletableDocument[]|ai:Error {
    DeletableDocument[] docs = [];
    foreach map<json> detail in check listKnowledgeBaseDocuments(controlTransport, kbId, dsId) {
        string status = stringField(detail, "status") ?: "";
        if KB_DOC_USABLE_STATUSES.indexOf(status) is () {
            // Skip NOT_FOUND tombstones, FAILED, and anything still in flight —
            // none of these are reachable through Retrieve to probe against.
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

// One `Retrieve` round trip on the MANAGED search branch. `filter` is an
// already-built `RetrievalFilter` JSON value (see knowledgebase_filter.bal) or `()`
// to search unfiltered. Returns the raw `retrievalResults[]` plus a `nextToken` for
// the caller to page with.
isolated function callRetrieve(BedrockTransport dataTransport, string kbId, string query, json? filter,
        int numberOfResults, RerankingModelType? reranking, string? nextToken)
        returns [json[], string?]|ai:Error {
    map<json> managedSearch = {numberOfResults};
    // `filter is json` would NOT reject nil — `()` is a member of `json` — and would
    // put `"filter": null` into `managedSearchConfiguration` on every unfiltered
    // retrieve. AWS tolerates it today, but it is not the documented request shape.
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

// The source-value identity of a retrieval result, or `()` when it carries none.
// Checks the injected source-uri metadata attribute first — spelled differently per
// knowledge base type, hence the `sourceUriKey` parameter — then the two DOCUMENTED,
// contractual identity members: `location.customDocumentLocation.id` and
// `location.s3Location.uri` are declared in the service model, unlike the metadata
// key, so identity does not rest on the undocumented attribute alone. These mirror
// exactly how `listDeletableDocuments` builds `DeletableDocument.sourceValue`, which
// is what this is compared against everywhere it is used (A17,
// `resolveDataSourceDeletes`).
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
    // `KnowledgeBaseRetrievalResult.documentId` is deliberately NOT accepted as proof
    // of identity. AWS documents it as "the unique identifier of the document. Use
    // with GetDocumentContent" — a service-side id with no documented equality to
    // `customDocumentIdentifier.id` or to an S3 URI. Treating it as equal would admit
    // an identity AWS never promised, and a false positive here DELETES a document
    // that may not match the filter, which is the exact direction this check exists
    // to prevent. The two `location` members above already cover both data source
    // types that `DocumentIdentifier` can even express.
}

// Does this retrieval result belong to `documentId`? A thin wrapper over
// `retrievalResultSourceValue` — kept as its own function (rather than inlined at
// every call site) because it is exercised directly by tests pinned to this exact
// signature.
isolated function retrievalResultIdentifies(json result, string documentId, string sourceUriKey) returns boolean
    => retrievalResultSourceValue(result, sourceUriKey) == documentId;

// ============================================================================
// A17 — deleteByFilter's two-enumeration algorithm, shared by both classes.
//
// Replaces the old per-document PINNED probe (`userFilter AND sourceUriKey == id`,
// one to two `Retrieve` calls PER CANDIDATE DOCUMENT). On a self-managed knowledge
// base whose data source is CUSTOM, Bedrock does not emit the source-uri metadata
// attribute at all, so every pinned probe returned zero results and nothing was ever
// deleted — the pin was the join key between "an id from `ListKnowledgeBaseDocuments`"
// and "a document in the vector index", and CUSTOM sources on VECTOR knowledge bases
// have no attribute that plays that role.
//
// The fix changes the SHAPE of the match rather than hunting for a substitute key:
// two PAGED enumerations per data source (filtered and unfiltered), each a small,
// bounded number of `Retrieve` round trips regardless of how many documents the
// knowledge base holds, replacing 2*N round trips for N documents. See
// `resolveDataSourceDeletes` for the classification this produces.
// ============================================================================

// The function shape both classes' retrieve call sites share once reduced to what
// the enumeration needs: no reranking (it imposes its own relevance cut, which is
// exactly the kind of cutoff the reachability pass exists to see past), and no
// `overrideSearchType`/`rerankingModelType` shortcuts either — see
// `managedDeleteRetrieve` (below) and `vectorDeleteRetrieve`
// (knowledgebase_vector_common.bal), the two values ever passed for this parameter.
type DeleteRetrieveCaller isolated function (BedrockTransport dataTransport, string kbId, json? filter,
        int numberOfResults, string? nextToken) returns [json[], string?]|ai:Error;

// The MANAGED adapter for `DeleteRetrieveCaller` — the vector counterpart,
// `vectorDeleteRetrieve`, lives in knowledgebase_vector_common.bal next to
// `callVectorRetrieve`.
isolated function managedDeleteRetrieve(BedrockTransport dataTransport, string kbId, json? filter,
        int numberOfResults, string? nextToken) returns [json[], string?]|ai:Error
    => callRetrieve(dataTransport, kbId, FILTER_PROBE_QUERY, filter, numberOfResults, (), nextToken);

# One paged `Retrieve` enumeration's result: every document identity seen, and
# whether `KB_DELETE_ENUMERATION_MAX_PAGES` was hit before pagination finished
# naturally (`nextToken` came back `()`).
#
# + identities - Every `retrievalResultSourceValue` seen across every page, as a set
# + truncated - `true` when the page cap was hit — the set above may be INCOMPLETE
type DeleteEnumeration record {|
    map<()> identities;
    boolean truncated;
|};

// Pages a `Retrieve` call (filtered or unfiltered, per `filter`) to exhaustion or
// `KB_DELETE_ENUMERATION_MAX_PAGES`, collecting every result's source-value identity.
// `numberOfResults` is `KB_MAX_RESULTS_PER_CALL` (100) per page — Bedrock's own
// maximum — to minimise the number of round trips.
isolated function enumerateDeleteIdentities(BedrockTransport dataTransport, string kbId, json? filter,
        string sourceUriKey, DeleteRetrieveCaller retrieveCaller) returns DeleteEnumeration|ai:Error {
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
            string? sourceValue = retrievalResultSourceValue(result, sourceUriKey);
            if sourceValue is string {
                identities[sourceValue] = ();
            }
        }
        nextToken = respNextToken;
        if nextToken is () {
            // A20: `nextToken is ()` does NOT mean "you have seen everything" — on
            // this API it means "no more pages are offered", and `Retrieve` does not
            // offer any. It answers one relevance-bounded call of at most
            // `numberOfResults`, so a FULL page is the cap binding the result set,
            // not the result set ending. Treating that as exhaustion is what let a
            // 180-sibling family lose exactly 100 members while this reported
            // `truncated: false` — the survivors were scattered across the whole
            // index range (`#0`,`#1`,`#3` deleted, `#2`,`#4`,`#5` kept), which is the
            // signature of one ranked call rather than a missed page.
            return {identities, truncated: results.length() >= KB_MAX_RESULTS_PER_CALL};
        }
    }
}

// A17: the NEGATIVE CONTROL for the "does this store honour metadata filters" check.
//
// `matched == reachable` has TWO causes, and refusing on it alone would punish the
// innocent one: (a) the store ignored the filter, so the filtered pass degenerated
// into the unfiltered one, and (b) the filter is honoured and legitimately selects
// EVERY reachable document — `deleteByFilter({tenant == "acme"})` on a knowledge base
// where every document is in fact `acme`, which is an ordinary single-tenant cleanup,
// not an anomaly. Telling them apart needs one more observation, and this sentinel
// filter provides it: a value no document can carry, on the source-uri key.
//
//   store honours filters -> zero results  -> case (b), the caller's filter is real
//   store ignores filters -> some results  -> case (a), refuse
//
// This holds for a CUSTOM data source too, where Bedrock emits no source-uri
// attribute at all (A17's root cause): a filter on an absent key matches nothing when
// filters are applied, and is discarded along with every other filter when they are
// not. One extra `Retrieve` for one result, run ONLY on the ambiguous path.
const string FILTER_CONTROL_SENTINEL = "ballerina-ai-aws-bedrock-no-such-document-cf1d7a2e";

isolated function storeIgnoresMetadataFilters(BedrockTransport dataTransport, string kbId, string sourceUriKey,
        DeleteRetrieveCaller retrieveCaller) returns boolean|ai:Error {
    json controlFilter = {'equals: {key: sourceUriKey, value: FILTER_CONTROL_SENTINEL}};
    [json[], string?] [results, _] = check retrieveCaller(dataTransport, kbId, controlFilter, 1, ());
    return results.length() > 0;
}

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
#
# + toDelete - `DocumentIdentifier`s ready for `DeleteKnowledgeBaseDocuments`
# + indeterminate - Candidates that could not be confirmed to match or not match the
#                    filter, already formatted as `"sourceValue (data source dsId)"`
# + refusalReason - Set instead of touching this data source at all — either
#                    enumeration hit the page cap, or the store does not appear to
#                    honour metadata filters. `toDelete`/`indeterminate` are both
#                    empty when this is set: NOTHING is deleted from this data source.
type DataSourceDeleteResult record {|
    json[] toDelete;
    string[] indeterminate;
    string? refusalReason;
    # Explanations that are not per-document and not a refusal — currently the A20
    # cap note, which tells the caller WHY a large pin group could not be finished
    # and that calling again continues it.
    string[] notes = [];
|};

// Resolves one data source's candidates to a delete set (A17/A18).
//
// TWO STAGES, and the split is the whole design:
//
//  1. ONE paged FILTERED enumeration confirms matches cheaply. A candidate whose
//     identity appears there matched the caller's filter on a call that carried it,
//     so deleting it is sound.
//  2. Every candidate the enumeration did NOT confirm is resolved INDIVIDUALLY, by
//     a probe pinned to that one document.
//
// Stage 2 exists because `Retrieve` is not an enumeration primitive. AWS documents it
// as returning "the most relevant results", and A18 measured the consequence: a fully
// paged UNFILTERED `Retrieve` reached 6 of a managed knowledge base's 9 usable
// documents. So "the unfiltered pass saw it and the filtered pass did not, therefore
// the filter excluded it" is not a valid inference — it was the silent under-delete
// this class exists to prevent. A pinned probe makes no such inference: pinning to one
// document narrows the candidate set to one, so what `Retrieve` chose to rank never
// enters the answer.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_Retrieve.html
//
// `sourceUriKey` and `retrieveCaller` are what let both knowledge base classes share
// this one implementation — see `SOURCE_URI_METADATA_KEY`/`managedDeleteRetrieve` and
// `VECTOR_SOURCE_URI_METADATA_KEY`/`vectorDeleteRetrieve`.
isolated function resolveDataSourceDeletes(BedrockTransport dataTransport, string kbId, string dsId,
        json? userFilter, DeletableDocument[] candidates, string sourceUriKey,
        DeleteRetrieveCaller retrieveCaller) returns DataSourceDeleteResult|ai:Error {
    // The FAST PATH trusts the store to have applied the filter, because a filtered
    // enumeration that was silently unfiltered would return every document with a
    // correct identity on each — and every candidate would land in `matched`, turning
    // `deleteByFilter` into "delete everything". The pinned probes in stage 2 are
    // immune to that (their identity check rejects a result that is not the pinned
    // document), but this stage is not, so the control probe gates it.
    if userFilter !is () {
        boolean|ai:Error ignoresFilters =
            storeIgnoresMetadataFilters(dataTransport, kbId, sourceUriKey, retrieveCaller);
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

    DeleteEnumeration matchedEnum =
        check enumerateDeleteIdentities(dataTransport, kbId, userFilter, sourceUriKey, retrieveCaller);
    // The fast path truncating is NOT an error and must not refuse the data source:
    // any data source with more than `KB_MAX_RESULTS_PER_CALL` matches truncates here
    // by definition. An identity it confirmed is still a sound delete, and a candidate
    // it missed simply falls through to a pin group, which resolves it individually.
    // Truncation here costs round trips, not correctness.

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

    // Which metadata key can pin a document HERE is OBSERVED, never assumed — A17 was
    // exactly the cost of assuming. `x-amz-bedrock-kb-source-uri` is absent on a
    // CUSTOM data source (confirmed live), where the caller's own `id` attribute is
    // the pin instead, because `documentIdFor` DERIVES the document id from
    // `ai:Metadata.id` and so guarantees the two agree for anything this module
    // ingested.
    string? pinKey = check observePinKey(dataTransport, kbId, sourceUriKey, retrieveCaller);
    string[] indeterminate = [];
    if pinKey is () {
        foreach DeletableDocument candidate in unresolved {
            indeterminate.push(string `${candidate.sourceValue} (data source ${dsId})`);
        }
        return {toDelete, indeterminate, refusalReason: ()};
    }

    // Candidates one pinned filter would select share one pair of probes. With an
    // `ai:Metadata.id` pin that is a whole fan-out family at once, which is what keeps
    // a 30-chunk document from costing 60 round trips; with a source-uri pin every
    // group is a single document. Either way the VERDICT is per document and exact.
    map<DeletableDocument[]> groups = {};
    foreach DeletableDocument candidate in unresolved {
        string key = pinGroupKeyFor(candidate.sourceValue, pinKey);
        DeletableDocument[] group = groups[key] ?: [];
        group.push(candidate);
        groups[key] = group;
    }
    int truncatedGroups = 0;
    foreach [string, DeletableDocument[]] [pinValue, group] in groups.entries() {
        [json[], string[], boolean] [groupDeletes, groupIndeterminate, groupTruncated] =
            check resolvePinGroup(dataTransport, kbId, dsId, userFilter, group, pinValue, pinKey, sourceUriKey,
                retrieveCaller);
        toDelete.push(...groupDeletes);
        indeterminate.push(...groupIndeterminate);
        if groupTruncated {
            truncatedGroups += 1;
        }
    }

    // A20: say WHY those candidates are unresolved, and that the call makes progress.
    // `Retrieve` cannot enumerate a set larger than its own cap and offers no
    // `nextToken`, so a pin group above the cap is not resolvable in one call. The
    // confirmed matches ARE deleted, which shrinks the group, so the documents that
    // were cut off surface within the cap next time: repeating the same
    // `deleteByFilter` converges instead of stalling.
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

// A data source touched not at all: nothing deleted, nothing blamed on a document.
isolated function dataSourceRefusal(string dsId, string reason) returns DataSourceDeleteResult
    => {
        toDelete: [],
        indeterminate: [],
        notes: [],
        refusalReason: string `data source '${dsId}': ${reason} — nothing was deleted from this data source.`
    };

// Picks the metadata key that can pin one document on THIS data source, by looking at
// what a result actually carries rather than assuming a key is emitted.
//
// `sourceUriKey` first: Bedrock injects it on a managed knowledge base and for an S3
// data source, and it holds exactly the `sourceValue` `listDeletableDocuments` builds.
// `KB_DOCUMENT_ID_METADATA_KEY` second: on a CUSTOM data source Bedrock injects NO
// per-document key at all (A17's root cause — the observed attributes are a per-CHUNK
// id and a per-DATA-SOURCE id, neither of which identifies a document), but
// `documentIdFor` derives the document id from `ai:Metadata.id`, so the caller's own
// `id` attribute pins it.
//
// `()` means neither is present — a document ingested without an `ai:Metadata.id` by
// something other than this module. Unpinnable is reported, never guessed at.
isolated function observePinKey(BedrockTransport dataTransport, string kbId, string sourceUriKey,
        DeleteRetrieveCaller retrieveCaller) returns string?|ai:Error {
    // A SAMPLE, not one result: a data source can hold a mix, and documents ingested
    // without an `ai:Metadata.id` carry neither key (one live knowledge base held ~95
    // of them alongside pinnable ones). Sampling a single document would let one of
    // those decide "unpinnable" for the whole data source, making every candidate
    // indeterminate. Any sampled document carrying a key proves the key is in use.
    [json[], string?] [results, _] =
        check retrieveCaller(dataTransport, kbId, (), KB_PIN_KEY_SAMPLE_SIZE, ());
    foreach json result in results {
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

// Resolves one PIN GROUP: every candidate that a single pinned filter selects.
//
//   the group's filtered probe returned this exact identity  -> DELETE_MATCH
//   only the group's unfiltered probe returned it            -> DELETE_SKIP
//   neither returned it                                      -> DELETE_INDETERMINATE
//
// The unfiltered probe is what makes a skip sound: it proves the pin reaches that
// exact document, so the filtered probe's silence is attributable to the filter and
// nothing else.
//
// IDENTITY IS EXACT. An earlier version accepted any document whose id shared a
// `<parent>#<ordinal>` prefix with the candidate, reasoning that a fan-out family
// shares one metadata record and therefore one filter verdict. That destroyed data
// (A19): `fanOutParentOf` strips everything from `#`, so a document ingested under
// the BARE id `7` looked like a member of the `7#0`...`7#29` family, and a probe that
// returned a genuine family member deleted the unrelated bare-id document with it —
// silently, since the returned error named other documents entirely. Nor would
// restricting the widening to candidates that themselves carry a `#` be safe:
// re-ingesting `id: 7` as 10 chunks upserts `7#0`...`7#9` and STRANDS `7#10`...`7#29`
// carrying the previous ingest's metadata, so even same-prefix siblings can disagree
// about a filter. Prefix is not evidence of shared metadata, and only shared metadata
// justified the widening.
//
// What the widening actually worked around was a fixed 10-result window. Paging the
// probe removes that need at the root: the pin bounds the result set to the group, so
// paging terminates on the group's own size and every member is seen exactly.
isolated function resolvePinGroup(BedrockTransport dataTransport, string kbId, string dsId, json? userFilter,
        DeletableDocument[] group, string pinValue, string pinKey, string sourceUriKey,
        DeleteRetrieveCaller retrieveCaller) returns [json[], string[], boolean]|ai:Error {
    json pin = pinnedFilter(pinKey, pinValue);
    json filtered = userFilter is () ? pin : {andAll: [userFilter, pin]};

    DeleteEnumeration matchedProbe =
        check enumerateDeleteIdentities(dataTransport, kbId, filtered, sourceUriKey, retrieveCaller);
    boolean allMatched = true;
    foreach DeletableDocument candidate in group {
        if !matchedProbe.identities.hasKey(candidate.sourceValue) {
            allMatched = false;
            break;
        }
    }
    // The second probe is skipped when the first already accounted for everyone —
    // nothing is left for it to explain.
    DeleteEnumeration reachableProbe = allMatched
        ? {identities: {}, truncated: false}
        : check enumerateDeleteIdentities(dataTransport, kbId, pin, sourceUriKey, retrieveCaller);

    // A20: a probe that came back FULL was cut to the cap by relevance, so absence
    // from its results is not evidence of anything. "Reached without the filter and
    // not with it" only means "the filter excluded it" when both probes actually saw
    // the whole group — otherwise the candidate is unresolved, not excluded.
    boolean truncated = matchedProbe.truncated || reachableProbe.truncated;

    json[] toDelete = [];
    string[] indeterminate = [];
    foreach DeletableDocument candidate in group {
        if matchedProbe.identities.hasKey(candidate.sourceValue) {
            // Exactly identified under the caller's filter — sound regardless of
            // whether the probe saw the rest of the group.
            toDelete.push(candidate.identifier);
        } else if truncated || !reachableProbe.identities.hasKey(candidate.sourceValue) {
            indeterminate.push(string `${candidate.sourceValue} (data source ${dsId})`);
        }
        // else: both probes saw the whole group, reached this document without the
        // filter and not with it — the filter excluded it.
    }
    return [toDelete, indeterminate, truncated];
}

// The pin group a candidate belongs to: every document one pinned filter selects.
//
// A source-uri pin is per-document, so each candidate is its own group. An
// `ai:Metadata.id` pin selects everything sharing that id — a fan-out family, plus any
// bare-id document carrying it — so those share one group and one pair of probes.
// Grouping is only ever an efficiency: membership decides which probe answers for a
// candidate, never whether the candidate matched. That is decided by exact identity
// inside `resolvePinGroup`.
isolated function pinGroupKeyFor(string sourceValue, string pinKey) returns string
    => pinKey == KB_DOCUMENT_ID_METADATA_KEY ? fanOutParentOf(sourceValue) : sourceValue;

// `"540801#37"` -> `"540801"`; an id that never fanned out is its own parent.
// Mirrors `documentIdFor`'s `<parent>#<ordinal>` construction.
isolated function fanOutParentOf(string sourceValue) returns string {
    int? hash = sourceValue.indexOf("#");
    return hash is int ? sourceValue.substring(0, hash) : sourceValue;
}

// The `pinKey == sourceValue` leaf.
//
// `KB_DOCUMENT_ID_METADATA_KEY` holds `ai:Metadata.id`, an `int`, which Bedrock stores
// as a NUMBER and returns as a decimal — so the leaf must carry a NUMBER, not the
// string form of one, or it matches nothing. A fan-out id (`<parent>#<ordinal>`) pins
// on its parent, which is the value the metadata actually holds.
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

// A deterministic `clientToken` for `CreateKnowledgeBase`/`CreateDataSource`.
//
// Find-or-create is a read-then-write: `resolveKnowledgeBase` lists by name, sees no
// match, then creates. Two concurrent `init()` calls sharing a new name both see no
// match and both create — observed live producing TWO knowledge bases, both reporting
// success. Knowledge base NAMES ARE UNIQUE PER ACCOUNT (measured live 2026-09-08: a
// SEQUENTIAL duplicate-name create is rejected with a 409 — see
// `createKnowledgeBaseRecoveringFromConflict`, A10 §2a), but AWS's own enforcement has
// a race window at the layer below this token, which is how two can exist anyway — see
// `guardAgainstConcurrentDuplicate`, A10 §2b. Until either resolves it, each duplicate
// makes every subsequent attach-by-name ambiguous and burns its own quota slot.
//
// AWS's answer to the RETRY case is the idempotency token: "If this token matches a
// previous request, Amazon Bedrock ignores the request, but does not return an error."
// Deriving it from the request body makes two identical creates collapse to one, while
// a genuinely DIFFERENT definition still gets its own token and its own resource. It
// does NOT collapse two requests already in flight concurrently — that is what §2a/§2b
// exist to catch afterwards.
//
// `ClientToken` is min 33 / max 256 characters, pattern `[a-zA-Z0-9](-*[a-zA-Z0-9]){0,256}`;
// a 64-character lowercase hex digest satisfies all three.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CreateKnowledgeBase.html
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CreateDataSource.html
isolated function idempotencyToken(json canonical) returns string
    => crypto:hashSha256(canonical.toJsonString().toBytes()).toBase16();

// ============================================================================
// Attach-by-definition verification.
// ============================================================================

// A name match attaches to a knowledge base the caller DESCRIBED but did not create.
// Only the name was ever used to find it, so every other field of the definition —
// `roleArn`, the embedding model, the KMS key, a self-managed store's
// `storageConfiguration` — was previously discarded: constructing with the correct
// name but a `roleArn` from an entirely different account succeeded silently, leaving
// the real role in effect and giving the caller no way to learn that the definition it
// passed is not the definition in force.
//
// The comparison is driven by the CREATE BODY this module would have sent, so it is
// exactly the set of fields the module claims to control, and any field the module
// learns to send is compared automatically. Semantics are "expected is a subset of
// actual": only the leaves the definition actually specifies are checked, so an extra
// field AWS returns is never a false mismatch.
//
// `name` (matched by definition), `description` (a mutable, non-behavioural label) and
// the data-source definition (a separate resource, validated separately by
// `validateResolvedDataSource`) are deliberately NOT compared.
isolated function assertDefinitionMatches(string kbId, map<json> expectedCreateBody, map<json> actual)
        returns ai:Error? {
    string[] differences = [];
    foreach string comparable in ["roleArn", "knowledgeBaseConfiguration", "storageConfiguration"] {
        json expected = expectedCreateBody[comparable] ?: ();
        if expected is () {
            continue;
        }
        differences.push(...jsonDiffPaths(expected, actual[comparable] ?: (), comparable));
    }
    if differences.length() == 0 {
        return;
    }
    return error ai:Error(
        string `Knowledge base '${kbId}' matches the definition's name, but ${differences.length()} field(s) ` +
        string `of the existing knowledge base differ from the definition: ` +
        string:'join("; ", ...differences) +
        ". These are fixed at creation time, so the definition passed is not the one in effect. Pass the " +
        "knowledge base id directly to attach to it as it is, or correct the definition.");
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

// JSON has one number type; Ballerina has three. `1024` sent as an `int` and echoed
// back as a `decimal` is the same value, and reporting it as a mismatch would make
// `assertDefinitionMatches` fail on every knowledge base carrying `dimensions`.
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
