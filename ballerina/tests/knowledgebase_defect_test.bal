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
import ballerina/test;
import ballerina/time;

// Regression tests for the defects the live `bedrock-kb-tests` suite found. Each
// test names the behaviour, not the report's issue number, but the grouping follows
// the report so a reviewer can trace them.

// ============================================================================
// Typed `ai:Metadata` round trip.
//
// `ai:Metadata` is an open record with TYPED declared fields. Writing raw `json`
// into one is an inherent type violation that PANICS rather than returning an
// `ai:Error`, and Bedrock answers every numeric attribute as a `decimal` — so a
// document ingested with `metadata.id` could not be retrieved at all.
// ============================================================================

@test:Config {}
function testRetrievalMetadataNarrowsBedrockDecimalsIntoIntFields() returns error? {
    // Exactly what Bedrock returns for a document submitted with `id: 520001`,
    // `index: 3`, `prev: 2`: NUMBER attributes, decoded as decimals.
    json result = {
        content: {'type: "TEXT", text: "hello"},
        metadata: {"id": 520001d, "index": 3d, "prev": 2d, "_source_uri": "520001"},
        score: 0.42
    };
    ai:QueryMatch queryMatch = check retrievalResultToQueryMatch(MANAGED_KB_PROVIDER, result);
    ai:Metadata? metadata = queryMatch.chunk.metadata;
    test:assertTrue(metadata is ai:Metadata);
    if metadata is ai:Metadata {
        test:assertEquals(metadata.id, 520001);
        test:assertEquals(metadata.index, 3);
        test:assertEquals(metadata.prev, 2);
        // Bedrock's own injected attribute goes through the `json...` rest field
        // untouched — `deleteByFilter`'s probe depends on it.
        test:assertEquals(metadata["_source_uri"], "520001");
    }
}

@test:Config {}
function testRetrievalMetadataNarrowsIntoDecimalAndStringFields() returns error? {
    json result = {
        content: {'type: "TEXT", text: "hello"},
        metadata: {"fileSize": 4096, "fileName": "notes.md", "mimeType": "text/markdown"},
        score: 1
    };
    ai:QueryMatch queryMatch = check retrievalResultToQueryMatch(MANAGED_KB_PROVIDER, result);
    ai:Metadata metadata = <ai:Metadata>queryMatch.chunk.metadata;
    test:assertEquals(metadata.fileSize, 4096d);
    test:assertEquals(metadata.fileName, "notes.md");
    test:assertEquals(metadata.mimeType, "text/markdown");
}

@test:Config {}
function testRetrievalMetadataParsesTimestampsBackFromRfc3339() returns error? {
    json result = {
        content: {'type: "TEXT", text: "hello"},
        metadata: {"createdAt": "2026-08-14T10:30:00Z", "modifiedAt": "2026-08-15T11:00:00Z"},
        score: 1
    };
    ai:QueryMatch queryMatch = check retrievalResultToQueryMatch(MANAGED_KB_PROVIDER, result);
    ai:Metadata metadata = <ai:Metadata>queryMatch.chunk.metadata;
    time:Utc expected = check time:utcFromString("2026-08-14T10:30:00Z");
    test:assertEquals(metadata.createdAt, expected);
}

@test:Config {}
function testRetrievalMetadataRejectsALossyNarrowingWithAnErrorNotAPanic() {
    json result = {
        content: {'type: "TEXT", text: "hello"},
        // A NUMBER that is not an integer cannot become `ai:Metadata.id` (an `int`)
        // without loss. That must be a clean error — never a rounded value, and
        // never a panic.
        metadata: {"id": 3.7d},
        score: 1
    };
    ai:QueryMatch|ai:Error queryMatch = retrievalResultToQueryMatch(MANAGED_KB_PROVIDER, result);
    test:assertTrue(queryMatch is ai:Error);
    if queryMatch is ai:Error {
        test:assertTrue(queryMatch.message().includes("'id'"), queryMatch.message());
        test:assertTrue(queryMatch.message().includes("without loss"), queryMatch.message());
    }
}

@test:Config {}
function testCreatedAtIngestsAsAnRfc3339StringAndRoundTrips() returns error? {
    time:Utc created = check time:utcFromString("2026-08-14T10:30:00Z");
    ai:TextChunk chunk = {content: "body", metadata: {id: 7, createdAt: created}};

    // OUTBOUND: `time:Utc` is a tuple, so without the special case it lands in the
    // STRING_LIST branch and is rejected for holding a non-string element.
    [json, string] [wireDoc, _] = check chunkToKnowledgeBaseDocument(MANAGED_KB_PROVIDER, chunk);
    map<json> metadata = <map<json>>(<map<json>>wireDoc)["metadata"];
    json[] attributes = <json[]>metadata["inlineAttributes"];
    json? createdAttribute = ();
    foreach json attribute in attributes {
        if (<map<json>>attribute)["key"] == "createdAt" {
            createdAttribute = attribute;
        }
    }
    test:assertTrue(createdAttribute !is (), attributes.toJsonString());
    map<json> value = <map<json>>(<map<json>>createdAttribute)["value"];
    test:assertEquals(value["type"], "STRING");
    string emitted = <string>value["stringValue"];

    // INBOUND: and the same string parses back to the same instant.
    ai:QueryMatch queryMatch = check retrievalResultToQueryMatch(MANAGED_KB_PROVIDER,
        {content: {'type: "TEXT", text: "body"}, metadata: {"createdAt": emitted}, score: 1});
    test:assertEquals((<ai:Metadata>queryMatch.chunk.metadata).createdAt, created);
}

// ============================================================================
// `is json` does not reject nil.
// ============================================================================

@test:Config {}
function testADocumentWithNoMetadataOmitsTheMetadataFieldRatherThanSendingNull() returns error? {
    ai:TextChunk chunk = {content: "body"};
    [json, string] [wireDoc, _] = check chunkToKnowledgeBaseDocument(MANAGED_KB_PROVIDER, chunk);
    test:assertFalse((<map<json>>wireDoc).hasKey("metadata"), wireDoc.toJsonString());
}

@test:Config {}
function testNestedEmptyFilterGroupsCollapseToNilInsteadOfNullBearingAndAll() returns error? {
    ai:MetadataFilters nestedEmpty = {filters: [{filters: []}, {filters: []}]};
    json? mapped = check metadataFiltersToRetrievalFilter(nestedEmpty);
    test:assertTrue(mapped is (), (mapped ?: "nil").toJsonString());

    // A populated group alongside an empty one keeps only the real predicate, and
    // the one-element flattening still applies.
    ai:MetadataFilters mixed = {
        filters: [{filters: []}, {key: "tenant", operator: ai:EQUAL, value: "acme"}]
    };
    json? mappedMixed = check metadataFiltersToRetrievalFilter(mixed);
    test:assertEquals(mappedMixed, {'equals: {key: "tenant", value: "acme"}});
}

// ============================================================================
// Per-chunk document ids.
// ============================================================================

@test:Config {}
function testAFannedOutChunkGetsAPerChunkIdSoSiblingsDoNotOverwriteEachOther() returns error? {
    // Ballerina's chunkers copy the parent's metadata, `id` included, onto every
    // chunk; Bedrock upserts by `customDocumentIdentifier.id`. Without a per-chunk
    // id, 20 chunks submit as 20 documents under one id and 19 are lost.
    test:assertEquals(documentIdFor({id: 42}, 0), "42#0");
    test:assertEquals(documentIdFor({id: 42}, 19), "42#19");
    // A parent that produced exactly one chunk keeps the caller's own id — rewriting
    // it would orphan whatever was ingested under it before.
    test:assertEquals(documentIdFor({id: 42}, ()), "42");
}

@test:Config {}
function testClientSideChunkingAssignsOrdinalsOnlyWhereADocumentFannedOut() returns error? {
    string longBody = "";
    int i = 0;
    while i < 40 {
        longBody += string `Paragraph ${i} with enough filler text to force a split.` + "\n\n";
        i += 1;
    }
    ai:Chunker chunker = new ai:GenericRecursiveChunker(maxChunkSize = 200, maxOverlapSize = 40);
    ai:TextDocument longDocument = {content: longBody, metadata: {id: 42}};
    ai:TextDocument shortDocument = {content: "short", metadata: {id: 42}};

    KbIngestItem[] fannedOut = check applyKbChunker(chunker, [longDocument]);
    test:assertTrue(fannedOut.length() > 1, "fixture no longer fans out");
    foreach int j in 0 ..< fannedOut.length() {
        test:assertEquals(fannedOut[j].chunkOrdinal, j);
    }
    string[] ids = [];
    foreach KbIngestItem item in fannedOut {
        [json, string] [_, id] = check chunkToKnowledgeBaseDocument(MANAGED_KB_PROVIDER, item.item,
            item.chunkOrdinal);
        ids.push(id);
    }
    // The whole point: every chunk survives because every chunk has its own id.
    test:assertEquals(assertDistinctDocumentIds(ids), ());
    test:assertEquals(ids.length(), fannedOut.length());

    KbIngestItem[] single = check applyKbChunker(chunker, [shortDocument]);
    test:assertEquals(single.length(), 1);
    test:assertEquals(single[0].chunkOrdinal, ());

    // `ai:DISABLE` passes documents through untouched — never an ordinal.
    KbIngestItem[] passthrough = check applyKbChunker(ai:DISABLE, [longDocument]);
    test:assertEquals(passthrough.length(), 1);
    test:assertEquals(passthrough[0].chunkOrdinal, ());
}

@test:Config {}
function testTwoDocumentsSharingAnIdAreRejectedRatherThanSilentlyOverwritten() {
    ai:Error? result = assertDistinctDocumentIds(["42", "43", "42"]);
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        test:assertTrue(result.message().includes("42"), result.message());
        test:assertTrue(result.message().includes("overwrite"), result.message());
    }
}

// ============================================================================
// Errors name the class the caller is actually using.
// ============================================================================

@test:Config {}
function testSharedConversionErrorsNameTheCallingClass() {
    json imageResult = {content: {'type: "IMAGE"}, metadata: {}, score: 1};
    ai:QueryMatch|ai:Error fromVector = retrievalResultToQueryMatch(VECTOR_KB_PROVIDER, imageResult);
    test:assertTrue(fromVector is ai:Error);
    if fromVector is ai:Error {
        test:assertTrue(fromVector.message().includes(VECTOR_KB_PROVIDER), fromVector.message());
        test:assertFalse(fromVector.message().includes(MANAGED_KB_PROVIDER), fromVector.message());
    }

    ai:ImageDocument image = {content: "https://example.com/a.png"};
    [json, string]|ai:Error ingestFromVector = chunkToKnowledgeBaseDocument(VECTOR_KB_PROVIDER, image);
    test:assertTrue(ingestFromVector is ai:Error);
    if ingestFromVector is ai:Error {
        test:assertTrue(ingestFromVector.message().includes(VECTOR_KB_PROVIDER), ingestFromVector.message());
    }
}

// ============================================================================
// Construction-time guards (no I/O).
// ============================================================================

@test:Config {}
function testManagedNumberOfResultsIsBoundedAtConstruction() {
    test:assertTrue(validateManagedRetrievalConfig({numberOfResults: 0}) is ai:Error);
    test:assertTrue(validateManagedRetrievalConfig({numberOfResults: 101}) is ai:Error);
    test:assertEquals(validateManagedRetrievalConfig({numberOfResults: 1}), ());
    test:assertEquals(validateManagedRetrievalConfig({numberOfResults: 100}), ());
    test:assertEquals(validateManagedRetrievalConfig({}), ());

    ai:Error? rejected = validateManagedRetrievalConfig({numberOfResults: 101});
    if rejected is ai:Error {
        test:assertTrue(rejected.message().includes("between 1 and 100"), rejected.message());
    }
}

@test:Config {}
function testAnEmptyOrWhitespaceQueryIsRejectedBeforeTheNetwork() {
    test:assertTrue(guardRetrieveQuery("") is ai:Error);
    test:assertTrue(guardRetrieveQuery("   ") is ai:Error);
    test:assertTrue(guardRetrieveQuery("\t\n") is ai:Error);
    test:assertEquals(guardRetrieveQuery("what is the refund policy"), ());
}

@test:Config {}
function testDeleteByFilterRefusesAFilterSetThatConstrainsNothing() {
    // Both halves of the guard, on both shapes that reach it.
    test:assertTrue(guardDeleteFilter((), {filters: []}) is ai:Error);
    test:assertTrue(guardDeleteFilter({andAll: [(), ()]}, {filters: [{filters: []}, {filters: []}]}) is ai:Error);
    // A real predicate passes.
    test:assertEquals(
        guardDeleteFilter({'equals: {key: "tenant", value: "acme"}},
            {filters: [{key: "tenant", operator: ai:EQUAL, value: "acme"}]}),
        ());
}

// ============================================================================
// Attach-by-definition verification.
// ============================================================================

@test:Config {}
function testAttachingByDefinitionRejectsAKnowledgeBaseWhoseRoleArnDiffers() {
    KnowledgeBaseDefinition def = {
        name: "kb",
        roleArn: "arn:aws:iam::367134611783:role/service-role/RealKbRole"
    };
    map<json> actual = {
        knowledgeBaseId: "KB12345678",
        name: "kb",
        // A role from an entirely different account. This used to attach silently.
        roleArn: "arn:aws:iam::123456789012:role/service-role/DummyKbRole",
        knowledgeBaseConfiguration: {
            'type: "MANAGED",
            managedKnowledgeBaseConfiguration: {embeddingModelType: "MANAGED"}
        }
    };
    ai:Error? result = assertDefinitionMatches("KB12345678", createKnowledgeBaseRequestBody(def), actual);
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        test:assertTrue(result.message().includes("roleArn"), result.message());
        test:assertTrue(result.message().includes("DummyKbRole"), result.message());
    }
}

@test:Config {}
function testAttachingByDefinitionRejectsAMismatchedEmbeddingModel() {
    KnowledgeBaseDefinition def = {
        name: "kb",
        roleArn: "arn:aws:iam::367134611783:role/KbRole",
        embeddingModel: {embeddingModelArn: "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v2:0"}
    };
    map<json> actual = {
        name: "kb",
        roleArn: "arn:aws:iam::367134611783:role/KbRole",
        // The knowledge base uses Bedrock's service-managed model, not the caller's.
        // Both choices are permanent at creation time.
        knowledgeBaseConfiguration: {
            'type: "MANAGED",
            managedKnowledgeBaseConfiguration: {embeddingModelType: "MANAGED"}
        }
    };
    ai:Error? result = assertDefinitionMatches("KB12345678", createKnowledgeBaseRequestBody(def), actual);
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        test:assertTrue(result.message().includes("embeddingModelType"), result.message());
    }
}

@test:Config {}
function testAttachingByDefinitionAcceptsAMatchAndIgnoresCosmeticDrift() {
    KnowledgeBaseDefinition def = {
        name: "kb",
        roleArn: "arn:aws:iam::367134611783:role/KbRole",
        description: "the description in the definition"
    };
    map<json> actual = {
        name: "kb",
        roleArn: "arn:aws:iam::367134611783:role/KbRole",
        // A different description, and extra fields AWS returns that the definition
        // never mentions. Neither is a mismatch: the comparison is "the definition's
        // leaves are a subset of the knowledge base's".
        description: "something else entirely",
        status: "ACTIVE",
        knowledgeBaseConfiguration: {
            'type: "MANAGED",
            managedKnowledgeBaseConfiguration: {embeddingModelType: "MANAGED"}
        }
    };
    test:assertEquals(assertDefinitionMatches("KB12345678", createKnowledgeBaseRequestBody(def), actual), ());
}

@test:Config {}
function testDefinitionComparisonTreatsJsonNumbersOfDifferentBallerinaTypesAsEqual() {
    // JSON has one number type; Ballerina has three. `dimensions` sent as an `int`
    // and echoed back as a `decimal` is the same value.
    test:assertEquals(jsonDiffPaths({dimensions: 1024}, {dimensions: 1024d}, "cfg"), []);
    test:assertEquals(jsonDiffPaths({dimensions: 1024}, {dimensions: 512}, "cfg").length(), 1);
}

// ============================================================================
// Idempotent creation.
// ============================================================================

@test:Config {}
function testTheClientTokenIsDeterministicAndSatisfiesTheBedrockClientTokenShape() {
    KnowledgeBaseDefinition def = {name: "kb", roleArn: "arn:aws:iam::367134611783:role/KbRole"};
    string first = idempotencyToken(createKnowledgeBaseRequestBody(def));
    string second = idempotencyToken(createKnowledgeBaseRequestBody(def));
    // Two racing `init()` calls with the same definition must send the SAME token,
    // so AWS collapses the duplicate create instead of making two knowledge bases.
    test:assertEquals(first, second);

    // A genuinely different definition must NOT collapse onto the same resource.
    KnowledgeBaseDefinition other = {name: "kb", roleArn: "arn:aws:iam::367134611783:role/OtherRole"};
    test:assertNotEquals(first, idempotencyToken(createKnowledgeBaseRequestBody(other)));

    // ClientToken: min 33, max 256, pattern `[a-zA-Z0-9](-*[a-zA-Z0-9]){0,256}`.
    test:assertEquals(first.length(), 64);
    test:assertTrue(first.matches(re `[a-zA-Z0-9]+`), first);
}

// ============================================================================
// `DeleteKnowledgeBaseDocuments` per-document statuses.
// ============================================================================

const string DEFECT_KB_ID = "KBDEFECT01";
const string DEFECT_DS_ID = "DSDEFECT01";

isolated function defectDocDetail(string id, string status) returns json => {
    knowledgeBaseId: DEFECT_KB_ID,
    dataSourceId: DEFECT_DS_ID,
    identifier: {dataSourceType: "CUSTOM", custom: {id}},
    status
};

isolated service class DefectDeleteMock {
    *http:Service;

    isolated resource function post [string... path](http:Request req) returns json|error {
        // `doc-gone` was accepted for deletion; `doc-stuck` came back still INDEXED,
        // which is how a failed delete surfaces (there is no `DELETE_UNSUCCESSFUL` in
        // `DocumentStatus`); `doc-silent` was omitted from the response entirely.
        return {
            documentDetails: [
                defectDocDetail("doc-gone", "DELETING"),
                defectDocDetail("doc-stuck", "INDEXED")
            ]
        };
    }
}

@test:Config {}
function testAnUnconfirmedDeleteIsReportedRatherThanCountedAsSuccess() returns error? {
    final int port = 18771;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new DefectDeleteMock(), "/");
    check mockListener.'start();

    BedrockTransport transport = check new (
        check resolveCredentials(KB_TEST_CREDS), "us-east-1",
        check buildAgentEndpoint(AGENT_CONTROL, "us-east-1", {customEndpoint: string `http://localhost:${port}`}),
        (), (), true);

    json[] identifiers = [
        {dataSourceType: "CUSTOM", custom: {id: "doc-gone"}},
        {dataSourceType: "CUSTOM", custom: {id: "doc-stuck"}},
        {dataSourceType: "CUSTOM", custom: {id: "doc-silent"}}
    ];
    string[] notDeleted = check deleteDocuments(transport, DEFECT_KB_ID, DEFECT_DS_ID, identifiers);
    check mockListener.gracefulStop();

    test:assertEquals(notDeleted.length(), 2, notDeleted.toString());
    test:assertTrue(notDeleted[0].includes("doc-stuck") && notDeleted[0].includes("INDEXED"), notDeleted[0]);
    test:assertTrue(notDeleted[1].includes("doc-silent") && notDeleted[1].includes("no status"), notDeleted[1]);
}

// ============================================================================
// The ingest poll.
// ============================================================================

isolated int defectPollRound = 0;

isolated function nextDefectPollRound() returns int {
    lock {
        defectPollRound += 1;
        return defectPollRound;
    }
}

isolated service class DefectPollMock {
    *http:Service;

    isolated resource function post [string... path](http:Request req) returns json|error {
        int round = nextDefectPollRound();
        if round == 1 {
            // Read-after-write: the ingest was accepted (202), but the read path
            // cannot see the documents yet. `NOT_FOUND` here is "not visible", not a
            // tombstone — and `doc-b` is omitted from the response altogether.
            return {documentDetails: [defectDocDetail("doc-a", "NOT_FOUND")]};
        }
        return {
            documentDetails: [
                defectDocDetail("doc-a", "INDEXED"),
                defectDocDetail("doc-b", "INDEXED")
            ]
        };
    }
}

@test:Config {}
function testTheIngestPollWaitsThroughNotFoundAndThroughAnOmittedId() returns error? {
    final int port = 18772;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new DefectPollMock(), "/");
    check mockListener.'start();
    lock {
        defectPollRound = 0;
    }

    BedrockTransport transport = check new (
        check resolveCredentials(KB_TEST_CREDS), "us-east-1",
        check buildAgentEndpoint(AGENT_CONTROL, "us-east-1", {customEndpoint: string `http://localhost:${port}`}),
        (), (), true);

    map<DocumentOutcome> outcomes =
        check pollDocumentsTerminal(transport, DEFECT_KB_ID, DEFECT_DS_ID, ["doc-a", "doc-b"], 60);
    check mockListener.gracefulStop();

    // Neither document was written off on the first round: `NOT_FOUND` was polled
    // through, and the id the response omitted stayed pending instead of being
    // dropped and silently counted as a success.
    test:assertEquals(outcomes.length(), 2, outcomes.toString());
    test:assertEquals(outcomes.get("doc-a").status, "INDEXED");
    test:assertEquals(outcomes.get("doc-b").status, "INDEXED");
    test:assertFalse(KB_DOC_FAILED_STATUSES.indexOf("NOT_FOUND") is int,
        "NOT_FOUND must not be a terminal ingest failure");
}

isolated service class DefectPollTimeoutMock {
    *http:Service;

    isolated resource function post [string... path](http:Request req) returns json|error {
        // Never becomes visible. The poll must run to the deadline and NAME the
        // document, not report success for one it never confirmed.
        return {documentDetails: []};
    }
}

@test:Config {}
function testAnIdTheApiNeverConfirmsTimesOutInsteadOfReportingSuccess() returns error? {
    final int port = 18773;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new DefectPollTimeoutMock(), "/");
    check mockListener.'start();

    BedrockTransport transport = check new (
        check resolveCredentials(KB_TEST_CREDS), "us-east-1",
        check buildAgentEndpoint(AGENT_CONTROL, "us-east-1", {customEndpoint: string `http://localhost:${port}`}),
        (), (), true);

    map<DocumentOutcome>|ai:Error outcomes =
        pollDocumentsTerminal(transport, DEFECT_KB_ID, DEFECT_DS_ID, ["doc-ghost"], 1);
    check mockListener.gracefulStop();

    test:assertTrue(outcomes is ai:Error);
    if outcomes is ai:Error {
        test:assertTrue(outcomes.message().includes("doc-ghost"), outcomes.message());
    }
}

// ============================================================================
// The `deleteByFilter` probe's identity check, on the MANAGED reserved key.
//
// This is the guard between "under-delete and report it" and "delete the entire
// knowledge base". A managed knowledge base spells the reserved attribute
// `_source_uri`; a self-managed one spells it `x-amz-bedrock-kb-source-uri`.
// ============================================================================

@test:Config {}
function testTheManagedProbeAcceptsOnlyAResultThatIsThePinnedDocument() {
    json pinned = {
        content: {'type: "TEXT", text: "chunk"},
        metadata: {"_source_uri": "doc-1"},
        location: {'type: "CUSTOM", customDocumentLocation: {id: "doc-1"}}
    };
    test:assertTrue(retrievalResultIdentifies(pinned, "doc-1", SOURCE_URI_METADATA_KEY));
    test:assertFalse(retrievalResultIdentifies(pinned, "doc-2", SOURCE_URI_METADATA_KEY));

    // A result that carries NEITHER identity member is not evidence about any
    // document. Counting it would make every probe hit and delete everything.
    json anonymous = {content: {'type: "TEXT", text: "chunk"}, metadata: {}, score: 0.9};
    test:assertFalse(retrievalResultIdentifies(anonymous, "doc-1", SOURCE_URI_METADATA_KEY));

    // `documentId` alone is deliberately NOT accepted: AWS documents no equality
    // between it and `customDocumentIdentifier.id`.
    json documentIdOnly = {content: {'type: "TEXT", text: "chunk"}, documentId: "doc-1", metadata: {}};
    test:assertFalse(retrievalResultIdentifies(documentIdOnly, "doc-1", SOURCE_URI_METADATA_KEY));

    // The two spellings do not cross-match — a managed key on a vector probe (or the
    // reverse) must not silently identify anything.
    json vectorPinned = {content: {'type: "TEXT", text: "chunk"}, metadata: {"x-amz-bedrock-kb-source-uri": "doc-1"}};
    test:assertFalse(retrievalResultIdentifies(vectorPinned, "doc-1", SOURCE_URI_METADATA_KEY));
    test:assertTrue(retrievalResultIdentifies(vectorPinned, "doc-1", VECTOR_SOURCE_URI_METADATA_KEY));
}
