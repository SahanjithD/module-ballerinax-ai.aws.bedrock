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

// End-to-end test of `deleteByFilter`'s A17 two-enumeration algorithm against a
// stubbed bedrock-agent/bedrock-agent-runtime pair on a local listener. Both agent
// planes resolve to the SAME `serviceUrl` here (a concrete `http://localhost:...`
// carries no `{endpoint}` placeholder to vary), so one mock serves both.
//
// Scenario: one CUSTOM data source with three INDEXED documents —
//   - 'doc-match': present in BOTH the filtered and the unfiltered enumeration ->
//     a confirmed match -> deleted.
//   - 'doc-skip-a'/'doc-skip-b': present in the UNFILTERED enumeration but NOT the
//     filtered one -> reachable and genuinely excluded by the filter -> left alone,
//     and NOT reported as a problem.
// Plus one SHAREPOINT data source, which `DocumentIdentifier` cannot address at all
// -> reported as undeletable, never silently ignored.
//
// Exactly TWO `Retrieve` calls happen per (deletable) data source — one filtered
// enumeration, one unfiltered — regardless of how many candidate documents that data
// source holds, asserted below. This replaced the old per-document PINNED probe
// (`userFilter AND _source_uri==id`, one to two `Retrieve` calls PER CANDIDATE),
// which returned nothing at all on a self-managed knowledge base with a CUSTOM data
// source, since Bedrock does not emit `_source_uri` there (A17).

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

// The enumeration dispatcher: a FILTERED call (the request body carries a `filter`
// under `managedSearchConfiguration`) sees only 'doc-match'; an UNFILTERED call sees
// all three. Both are asserted to ask for a 100-result page — `KB_MAX_RESULTS_PER_CALL`
// — and neither carries a `nextToken` here, since three results fit on one page.
isolated function deleteTestMockRetrieve(json body) returns json|error {
    recordRetrieveProbe();
    map<json> bodyMap = <map<json>>body;
    map<json> managedSearch =
        <map<json>>(<map<json>>bodyMap["retrievalConfiguration"])["managedSearchConfiguration"];
    if managedSearch["numberOfResults"] != 100 {
        return error(string `expected a 100-result enumeration page: ${body.toJsonString()}`);
    }
    if managedSearch.hasKey("filter") {
        return {retrievalResults: [deleteTestRetrievalResult("doc-match")]};
    }
    return {
        retrievalResults: [
            deleteTestRetrievalResult("doc-match"),
            deleteTestRetrievalResult("doc-skip-a"),
            deleteTestRetrievalResult("doc-skip-b")
        ]
    };
}

@test:Config {}
function testDeleteByFilterDeletesMatchesSkipsExclusionsAndReportsUndeletableSources() returns error? {
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

    // Exactly ONE filtered enumeration and ONE unfiltered enumeration for the CUSTOM
    // data source — cost no longer scales with the number of candidate documents.
    test:assertEquals(readRetrieveProbeCount(), 2, "expected exactly one filtered and one unfiltered enumeration");

    // The undeletable data source is reported; the two excluded documents are not —
    // both are reachable under the unfiltered pass, so exclusion is a sound
    // conclusion.
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        string msg = result.message();
        test:assertTrue(msg.includes(DEL_DS_SHAREPOINT) || msg.includes("SHAREPOINT"), msg);
        test:assertFalse(msg.includes("doc-skip"), msg);
    }
}
