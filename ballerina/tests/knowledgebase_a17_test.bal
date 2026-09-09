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

// A17 — `deleteByFilter` on a self-managed knowledge base whose data source is
// CUSTOM was deleting nothing: the old per-document pinned probe keyed on
// `x-amz-bedrock-kb-source-uri`, which Bedrock does not emit for that source type.
// Replaced by two paged `Retrieve` enumerations per data source (see
// `resolveDataSourceDeletes`, knowledgebase_common.bal). These tests cover the parts
// that do not need a full `deleteByFilter` end-to-end run: the pure three-way
// classification, and the two refusal paths (page-cap truncation, and a store that
// does not appear to honour metadata filters).

// ============================================================================
// classifyDeleteCandidate — pure, table-tested.
// ============================================================================

@test:Config {}
function testClassifyDeleteCandidateThreeWayDecision() {
    map<()> matched = {"doc-a": ()};
    map<()> reachable = {"doc-a": (), "doc-b": ()};
    // "doc-c" is in neither.

    // In `matched`: always DELETE_MATCH, regardless of the trust flag.
    test:assertEquals(classifyDeleteCandidate("doc-a", matched, reachable, true), DELETE_MATCH);
    test:assertEquals(classifyDeleteCandidate("doc-a", matched, reachable, false), DELETE_MATCH);

    // Reachable but unmatched: DELETE_SKIP when the enumeration is trusted,
    // DELETE_INDETERMINATE under the safe fallback.
    test:assertEquals(classifyDeleteCandidate("doc-b", matched, reachable, true), DELETE_SKIP);
    test:assertEquals(classifyDeleteCandidate("doc-b", matched, reachable, false), DELETE_INDETERMINATE);

    // In neither: always DELETE_INDETERMINATE, regardless of the trust flag — the
    // trust flag only governs what "reachable but unmatched" means, never "never
    // seen at all".
    test:assertEquals(classifyDeleteCandidate("doc-c", matched, reachable, true), DELETE_INDETERMINATE);
    test:assertEquals(classifyDeleteCandidate("doc-c", matched, reachable, false), DELETE_INDETERMINATE);
}

@test:Config {}
function testMapKeySetEquals() {
    map<()> a = {"x": (), "y": ()};
    map<()> b = {"y": (), "x": ()}; // same keys, different insertion order
    map<()> c = {"x": ()};
    map<()> d = {"x": (), "z": ()};

    test:assertTrue(mapKeySetEquals(a, b));
    test:assertTrue(mapKeySetEquals({}, {}));
    test:assertFalse(mapKeySetEquals(a, c)); // different sizes
    test:assertFalse(mapKeySetEquals(a, d)); // same size, different keys
}

// ============================================================================
// resolveDataSourceDeletes — the two refusal paths, against a local mock transport.
// ============================================================================

const string A17_KB_ID = "KBA17TEST1";
const string A17_DS_ID = "DSA17TEST1";

function a17Transport(int port) returns BedrockTransport|error
    => new (
        check resolveCredentials(KB_TEST_CREDS), "us-east-1",
        check buildAgentEndpoint(AGENT_DATA, "us-east-1", {customEndpoint: string `http://localhost:${port}`}),
        (), (), true);

isolated function a17Result(string id) returns json => {
    content: {text: string `text for ${id}`, 'type: "TEXT"},
    location: {'type: "CUSTOM", customDocumentLocation: {id}},
    metadata: {"_source_uri": id},
    score: 0.9
};

// A store that ignores the metadata filter entirely: the SAME two documents come
// back whether or not `filter` is present, so the filtered and unfiltered passes
// see identical, more-than-one-element sets. Per A17, this must refuse rather than
// silently allow a mass delete keyed on a filter the store never applied.
isolated service class FilterNotHonouredMock {
    *http:Service;

    isolated resource function post [string... path](http:Request req) returns json|error {
        // Same two documents regardless of whether a filter was sent.
        return {retrievalResults: [a17Result("doc-1"), a17Result("doc-2")]};
    }
}

@test:Config {}
function testResolveDataSourceDeletesRefusesWhenTheStoreDoesNotAppearToHonourFilters() returns error? {
    final int port = 18780;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new FilterNotHonouredMock(), "/");
    check mockListener.'start();

    BedrockTransport transport = check a17Transport(port);
    DeletableDocument[] candidates = [
        {sourceValue: "doc-1", identifier: {dataSourceType: "CUSTOM", custom: {id: "doc-1"}}},
        {sourceValue: "doc-2", identifier: {dataSourceType: "CUSTOM", custom: {id: "doc-2"}}}
    ];
    json userFilter = {'equals: {key: "tenant", value: "acme"}};
    DataSourceDeleteResult|ai:Error result = resolveDataSourceDeletes(transport, A17_KB_ID, A17_DS_ID, userFilter,
        candidates, SOURCE_URI_METADATA_KEY, managedDeleteRetrieve);
    check mockListener.gracefulStop();

    test:assertTrue(result is DataSourceDeleteResult, (result is ai:Error ? result.message() : ""));
    if result is DataSourceDeleteResult {
        test:assertEquals(result.toDelete.length(), 0, "nothing may be deleted when the filter is not honoured");
        test:assertEquals(result.indeterminate.length(), 0);
        test:assertTrue(result.refusalReason is string);
        string reason = result.refusalReason ?: "";
        test:assertTrue(reason.includes(A17_DS_ID), reason);
        test:assertTrue(reason.includes("honour"), reason);
    }
}

// The guard must NOT fire on a legitimately small, honestly-filtered result: exactly
// one document reachable in total is not evidence the filter was ignored.
isolated service class SingleReachableDocumentMock {
    *http:Service;

    isolated resource function post [string... path](http:Request req) returns json|error {
        return {retrievalResults: [a17Result("doc-1")]};
    }
}

@test:Config {}
function testResolveDataSourceDeletesDoesNotFalselyTriggerOnASingleReachableDocument() returns error? {
    final int port = 18781;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new SingleReachableDocumentMock(), "/");
    check mockListener.'start();

    BedrockTransport transport = check a17Transport(port);
    DeletableDocument[] candidates = [
        {sourceValue: "doc-1", identifier: {dataSourceType: "CUSTOM", custom: {id: "doc-1"}}}
    ];
    json userFilter = {'equals: {key: "tenant", value: "acme"}};
    DataSourceDeleteResult|ai:Error result = resolveDataSourceDeletes(transport, A17_KB_ID, A17_DS_ID, userFilter,
        candidates, SOURCE_URI_METADATA_KEY, managedDeleteRetrieve);
    check mockListener.gracefulStop();

    test:assertTrue(result is DataSourceDeleteResult, (result is ai:Error ? result.message() : ""));
    if result is DataSourceDeleteResult {
        test:assertEquals(result.refusalReason, ());
        test:assertEquals(result.toDelete.length(), 1);
    }
}

// Every page carries a `nextToken` and never terminates on its own, forcing BOTH
// enumeration passes past `KB_DELETE_ENUMERATION_MAX_PAGES`. Nothing may be deleted
// from a data source whose result set might be incomplete.
isolated service class TruncatedEnumerationMock {
    *http:Service;

    isolated resource function post [string... path](http:Request req) returns json {
        return {retrievalResults: [], nextToken: "keep-going"};
    }
}

@test:Config {}
function testResolveDataSourceDeletesRefusesOnEnumerationTruncation() returns error? {
    final int port = 18782;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new TruncatedEnumerationMock(), "/");
    check mockListener.'start();

    BedrockTransport transport = check a17Transport(port);
    DeletableDocument[] candidates = [
        {sourceValue: "doc-1", identifier: {dataSourceType: "CUSTOM", custom: {id: "doc-1"}}}
    ];
    json userFilter = {'equals: {key: "tenant", value: "acme"}};
    DataSourceDeleteResult|ai:Error result = resolveDataSourceDeletes(transport, A17_KB_ID, A17_DS_ID, userFilter,
        candidates, SOURCE_URI_METADATA_KEY, managedDeleteRetrieve);
    check mockListener.gracefulStop();

    test:assertTrue(result is DataSourceDeleteResult, (result is ai:Error ? result.message() : ""));
    if result is DataSourceDeleteResult {
        test:assertEquals(result.toDelete.length(), 0, "nothing may be deleted from a truncated enumeration");
        test:assertEquals(result.indeterminate.length(), 0);
        test:assertTrue(result.refusalReason is string);
        string reason = result.refusalReason ?: "";
        test:assertTrue(reason.includes(A17_DS_ID), reason);
        test:assertTrue(reason.includes("100"), reason);
    }
}

// An unfiltered call (userFilter == ()) never triggers the "not honoured" refusal —
// there is no filter to be dishonouring.
@test:Config {}
function testFilterNotHonouredRefusalNeverFiresOnAnUnfilteredCall() returns error? {
    final int port = 18783;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new FilterNotHonouredMock(), "/");
    check mockListener.'start();

    BedrockTransport transport = check a17Transport(port);
    DeletableDocument[] candidates = [
        {sourceValue: "doc-1", identifier: {dataSourceType: "CUSTOM", custom: {id: "doc-1"}}},
        {sourceValue: "doc-2", identifier: {dataSourceType: "CUSTOM", custom: {id: "doc-2"}}}
    ];
    DataSourceDeleteResult|ai:Error result = resolveDataSourceDeletes(transport, A17_KB_ID, A17_DS_ID, (),
        candidates, SOURCE_URI_METADATA_KEY, managedDeleteRetrieve);
    check mockListener.gracefulStop();

    test:assertTrue(result is DataSourceDeleteResult, (result is ai:Error ? result.message() : ""));
    if result is DataSourceDeleteResult {
        test:assertEquals(result.refusalReason, ());
        // Both are "matched" (there was no filter to exclude anything), so both
        // delete.
        test:assertEquals(result.toDelete.length(), 2);
    }
}

// ============================================================================
// The negative control that separates "the store ignored the filter" from "the
// filter is honoured and legitimately matches everything".
//
// `matched == reachable` alone cannot tell those apart, and refusing on it alone
// would make an ordinary single-tenant cleanup — `deleteByFilter({tenant == "acme"})`
// on a knowledge base where every document IS `acme` — permanently impossible.
// `storeIgnoresMetadataFilters` re-probes with `FILTER_CONTROL_SENTINEL`, a value no
// document can carry, and only a store that STILL returns results is refused.
// ============================================================================

// Honours filters: returns nothing for the sentinel control, everything otherwise.
// Models the innocent case — the caller's filter really does select both documents.
isolated service class FilterHonouredMatchesEverythingMock {
    *http:Service;

    isolated resource function post [string... path](http:Request req) returns json|error {
        json payload = check req.getJsonPayload();
        if payload.toJsonString().includes(FILTER_CONTROL_SENTINEL) {
            return {retrievalResults: []};
        }
        return {retrievalResults: [a17Result("doc-1"), a17Result("doc-2")]};
    }
}

@test:Config {}
function testAFilterThatLegitimatelyMatchesEveryDocumentStillDeletes() returns error? {
    final int port = 18783;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new FilterHonouredMatchesEverythingMock(), "/");
    check mockListener.'start();

    BedrockTransport transport = check a17Transport(port);
    DeletableDocument[] candidates = [
        {sourceValue: "doc-1", identifier: {dataSourceType: "CUSTOM", custom: {id: "doc-1"}}},
        {sourceValue: "doc-2", identifier: {dataSourceType: "CUSTOM", custom: {id: "doc-2"}}}
    ];
    json userFilter = {'equals: {key: "tenant", value: "acme"}};
    DataSourceDeleteResult|ai:Error result = resolveDataSourceDeletes(transport, A17_KB_ID, A17_DS_ID, userFilter,
        candidates, SOURCE_URI_METADATA_KEY, managedDeleteRetrieve);
    check mockListener.gracefulStop();

    test:assertTrue(result is DataSourceDeleteResult, (result is ai:Error ? result.message() : ""));
    if result is DataSourceDeleteResult {
        test:assertTrue(result.refusalReason is (),
            string `a store that honours filters must not be refused: ${result.refusalReason ?: ""}`);
        test:assertEquals(result.toDelete.length(), 2, "both documents genuinely match and must be deleted");
        test:assertEquals(result.indeterminate.length(), 0);
    }
}

// The control probe itself failing is NOT permission to delete on a filter that may
// never have been applied: refuse, and say the check could not be completed rather
// than asserting the store is broken.
isolated service class FilterControlProbeFailsMock {
    *http:Service;

    isolated resource function post [string... path](http:Request req) returns http:Response|error {
        json payload = check req.getJsonPayload();
        http:Response response = new;
        if payload.toJsonString().includes(FILTER_CONTROL_SENTINEL) {
            response.statusCode = 400;
            response.setJsonPayload({message: "Unknown metadata key in filter"});
            return response;
        }
        response.statusCode = 200;
        response.setJsonPayload({retrievalResults: [a17Result("doc-1"), a17Result("doc-2")]});
        return response;
    }
}

@test:Config {}
function testAFailedFilterControlProbeRefusesRatherThanDeleting() returns error? {
    final int port = 18784;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new FilterControlProbeFailsMock(), "/");
    check mockListener.'start();

    BedrockTransport transport = check a17Transport(port);
    DeletableDocument[] candidates = [
        {sourceValue: "doc-1", identifier: {dataSourceType: "CUSTOM", custom: {id: "doc-1"}}},
        {sourceValue: "doc-2", identifier: {dataSourceType: "CUSTOM", custom: {id: "doc-2"}}}
    ];
    json userFilter = {'equals: {key: "tenant", value: "acme"}};
    DataSourceDeleteResult|ai:Error result = resolveDataSourceDeletes(transport, A17_KB_ID, A17_DS_ID, userFilter,
        candidates, SOURCE_URI_METADATA_KEY, managedDeleteRetrieve);
    check mockListener.gracefulStop();

    test:assertTrue(result is DataSourceDeleteResult, (result is ai:Error ? result.message() : ""));
    if result is DataSourceDeleteResult {
        test:assertEquals(result.toDelete.length(), 0, "an unverifiable filter must delete nothing");
        test:assertTrue(result.refusalReason is string);
        test:assertTrue((result.refusalReason ?: "").includes("could not be completed"),
            result.refusalReason ?: "");
    }
}
