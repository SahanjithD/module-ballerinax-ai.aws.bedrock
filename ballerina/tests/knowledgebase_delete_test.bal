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

// End-to-end test of `deleteByFilter` against a stubbed bedrock-agent /
// bedrock-agent-runtime pair on a local listener. Both agent planes resolve to the
// SAME `serviceUrl` here (a concrete `http://localhost:...` carries no `{endpoint}`
// placeholder to vary), so one mock serves both.
//
// Scenario: one CUSTOM data source with three INDEXED documents, of which only
// 'doc-match' carries tenant=acme —
//   - 'doc-match': confirmed by the filtered enumeration -> deleted.
//   - 'doc-skip-a'/'doc-skip-b': not confirmed by the enumeration, then resolved
//     INDIVIDUALLY by pinned probes — the pin reaches each one without the filter and
//     not with it, so the filter is what excluded them -> left alone, not reported.
// Plus one SHAREPOINT data source, which `DocumentIdentifier` cannot address at all
// -> reported as undeletable, never silently ignored.
//
// The per-document probes are the A18 repair. Resolving a candidate by MEMBERSHIP in
// a paged unfiltered enumeration was measured unsound — a fully paged unfiltered
// `Retrieve` reached 6 of a live knowledge base's 9 usable documents — so a document
// it missed was silently skipped by a delete that should have removed it. A pinned
// probe narrows the candidate set to one document, so what `Retrieve` chose to rank
// never enters the answer.

const string DEL_KB_ID = "KBDELTEST1";
const string DEL_DS_CUSTOM = "DSCUSTOM01";
const string DEL_DS_SHAREPOINT = "DSSHAREPT1";

isolated json[] deletedIdentifiers = [];
isolated int retrieveProbeCount = 0;

isolated function recordDeletedIdentifiers(json[] identifiers) {
    lock {
        deletedIdentifiers.push(...identifiers.clone());
    }
}

isolated function readDeletedIdentifiers() returns json[] {
    lock {
        return deletedIdentifiers.clone();
    }
}

isolated function recordRetrieveProbe() {
    lock {
        retrieveProbeCount += 1;
    }
}

isolated function readRetrieveProbeCount() returns int {
    lock {
        return retrieveProbeCount;
    }
}

isolated function deleteTestDocDetail(string id) returns json => {
    knowledgeBaseId: DEL_KB_ID,
    dataSourceId: DEL_DS_CUSTOM,
    identifier: {dataSourceType: "CUSTOM", custom: {id}},
    status: "INDEXED",
    updatedAt: "2026-08-13T00:00:00Z"
};

isolated function deleteTestRetrievalResult(string id) returns json => {
    content: {text: string `chunk text for ${id}`, 'type: "TEXT"},
    documentId: id,
    location: {'type: "CUSTOM", customDocumentLocation: {id}},
    metadata: {"_source_uri": id},
    score: 0.9
};

isolated service class DeleteTestMock {
    *http:Service;

    isolated resource function get [string... path](http:Request req) returns json|error {
        string p = req.rawPath;
        if p == string `/knowledgebases/${DEL_KB_ID}` {
            return {
                knowledgeBase: {
                    knowledgeBaseId: DEL_KB_ID,
                    name: "kb",
                    status: "ACTIVE",
                    knowledgeBaseConfiguration: {'type: "MANAGED"}
                }
            };
        }
        if p == string `/knowledgebases/${DEL_KB_ID}/datasources/${DEL_DS_CUSTOM}` {
            return {
                dataSource: {
                    knowledgeBaseId: DEL_KB_ID,
                    dataSourceId: DEL_DS_CUSTOM,
                    name: "custom-src",
                    status: "AVAILABLE",
                    dataSourceConfiguration: {'type: "CUSTOM"},
                    vectorIngestionConfiguration: {chunkingConfiguration: {chunkingStrategy: "FIXED_SIZE"}}
                }
            };
        }
        if p == string `/knowledgebases/${DEL_KB_ID}/datasources/${DEL_DS_SHAREPOINT}` {
            return {
                dataSource: {
                    knowledgeBaseId: DEL_KB_ID,
                    dataSourceId: DEL_DS_SHAREPOINT,
                    name: "sp-src",
                    status: "AVAILABLE",
                    dataSourceConfiguration: {'type: "SHAREPOINT"}
                }
            };
        }
        return error(string `unexpected GET ${p}`);
    }

    isolated resource function post [string... path](http:Request req) returns json|error {
        string p = req.rawPath;
        json body = check req.getJsonPayload();

        if p == string `/knowledgebases/${DEL_KB_ID}/datasources/` {
            return {
                dataSourceSummaries: [
                    {
                        knowledgeBaseId: DEL_KB_ID,
                        dataSourceId: DEL_DS_CUSTOM,
                        name: "custom-src",
                        status: "AVAILABLE",
                        updatedAt: "2026-08-13T00:00:00Z"
                    },
                    {
                        knowledgeBaseId: DEL_KB_ID,
                        dataSourceId: DEL_DS_SHAREPOINT,
                        name: "sp-src",
                        status: "AVAILABLE",
                        updatedAt: "2026-08-13T00:00:00Z"
                    }
                ]
            };
        }
        if p == string `/knowledgebases/${DEL_KB_ID}/datasources/${DEL_DS_CUSTOM}/documents` {
            return {
                documentDetails: [
                    deleteTestDocDetail("doc-match"),
                    deleteTestDocDetail("doc-skip-a"),
                    deleteTestDocDetail("doc-skip-b")
                ]
            };
        }
        if p == string `/knowledgebases/${DEL_KB_ID}/datasources/${DEL_DS_CUSTOM}/documents/deleteDocuments` {
            map<json> bodyMap = <map<json>>body;
            json[] identifiers = <json[]>bodyMap["documentIdentifiers"];
            recordDeletedIdentifiers(identifiers);
            // A real `DeleteKnowledgeBaseDocuments` answers with a per-document
            // status. Returning the empty array the mock used to return now trips the
            // "not confirmed deleted" check, which is the point of that check.
            return {
                documentDetails: identifiers.'map(identifier => <json>{
                    knowledgeBaseId: DEL_KB_ID,
                    dataSourceId: DEL_DS_CUSTOM,
                    identifier,
                    status: "DELETING"
                })
            };
        }
        if p == string `/knowledgebases/${DEL_KB_ID}/retrieve` {
            return deleteTestMockRetrieve(body);
        }
        return error(string `unexpected POST ${p}`);
    }
}

// A stand-in vector store that actually EVALUATES the filter it is sent, rather than
// answering "filtered" vs "unfiltered". The A17/A18 rework resolves each unconfirmed
// candidate with a pinned probe (`pin == doc`, optionally ANDed with the caller's
// filter), and it sends a sentinel control filter that must match nothing — so a mock
// that keys off the mere PRESENCE of a filter cannot exercise any of it.
//
// Three documents, of which only 'doc-match' carries tenant=acme.
isolated function deleteTestDocs() returns map<map<json>> => {
    "doc-match": {"tenant": "acme", "_source_uri": "doc-match"},
    "doc-skip-a": {"tenant": "globex", "_source_uri": "doc-skip-a"},
    "doc-skip-b": {"tenant": "globex", "_source_uri": "doc-skip-b"}
};

// Evaluates the `RetrievalFilter` subset this module ever emits: an `equals` leaf, and
// an `andAll` of them. Anything else is an error rather than a silent pass, so a
// change in emitted filter shape fails loudly here.
isolated function deleteTestFilterMatches(json filter, map<json> metadata) returns boolean|error {
    map<json> f = <map<json>>filter;
    if f.hasKey("equals") {
        map<json> leaf = <map<json>>f["equals"];
        return metadata[<string>leaf["key"]] == leaf["value"];
    }
    if f.hasKey("andAll") {
        foreach json child in <json[]>f["andAll"] {
            if !check deleteTestFilterMatches(child, metadata) {
                return false;
            }
        }
        return true;
    }
    return error(string `mock cannot evaluate filter ${filter.toJsonString()}`);
}

isolated function deleteTestMockRetrieve(json body) returns json|error {
    recordRetrieveProbe();
    map<json> bodyMap = <map<json>>body;
    map<json> managedSearch =
        <map<json>>(<map<json>>bodyMap["retrievalConfiguration"])["managedSearchConfiguration"];
    json? filter = managedSearch.hasKey("filter") ? managedSearch["filter"] : ();

    json[] results = [];
    foreach [string, map<json>] [id, metadata] in deleteTestDocs().entries() {
        if filter is () || check deleteTestFilterMatches(filter, metadata) {
            results.push(deleteTestRetrievalResult(id));
        }
    }
    return {retrievalResults: results};
}

@test:Config {}
function testDeleteByFilterDeletesMatchesAndReportsEveryUnconfirmedCandidate() returns error? {
    final int port = 18651;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new DeleteTestMock(), "/");
    check mockListener.'start();

    BedrockManagedKnowledgeBase kb = check new (
        DEL_KB_ID, KB_TEST_CREDS, "us-east-1",
        endpoint = {customEndpoint: string `http://localhost:${port}`},
        dataSourceId = DEL_DS_CUSTOM);

    ai:MetadataFilters filters = {filters: [{key: "tenant", operator: ai:EQUAL, value: "acme"}]};
    ai:Error? result = kb.deleteByFilter(filters);
    check mockListener.gracefulStop();

    // The confirmed match was deleted regardless of the undeletable data source
    // elsewhere — a partial failure must not withhold the deletes it COULD make.
    json[] deleted = readDeletedIdentifiers();
    test:assertEquals(deleted.length(), 1, deleted.toJsonString());
    map<json> deletedIdentifier = <map<json>>deleted[0];
    test:assertEquals((<map<json>>deletedIdentifier["custom"])["id"], "doc-match");

    // The call budget for the CUSTOM data source: one sentinel control probe, one
    // filtered enumeration, one pin-key observation, then two pinned probes for each
    // of the two candidates the enumeration did not confirm = 7. Only the last term
    // scales with candidates, and only with UNCONFIRMED ones — a filter that matches
    // everything costs the three fixed calls and nothing more.
    test:assertEquals(readRetrieveProbeCount(), 7, "unexpected Retrieve call budget");

    // The undeletable data source is reported. The two excluded documents are NOT:
    // each was resolved by its own pinned probe, which reached it without the filter
    // and not with it, so "the filter excluded it" is an observation about that
    // document rather than an inference from one enumeration's coverage.
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        string msg = result.message();
        test:assertTrue(msg.includes(DEL_DS_SHAREPOINT) || msg.includes("SHAREPOINT"), msg);
        test:assertFalse(msg.includes("doc-skip"),
            string `a document the pin proved excluded by the filter must not be reported: ${msg}`);
    }
}
