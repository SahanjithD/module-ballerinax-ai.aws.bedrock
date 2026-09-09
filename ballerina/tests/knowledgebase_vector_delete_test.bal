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

// `deleteByFilter()` against a stubbed agent pair, exercising the A17 two-enumeration
// algorithm (see `resolveDataSourceDeletes`, knowledgebase_common.bal) on the
// self-managed (VECTOR) branch. THE LOAD-BEARING ASSERTION is that identity is
// extracted from `x-amz-bedrock-kb-source-uri` and NOT the managed `_source_uri` —
// the two knowledge base types use different reserved metadata prefixes, and reading
// the managed spelling here would extract no identities at all, so nothing would
// ever be deleted and no error would be raised (A17's root cause on the OLD
// per-document-pin algorithm; this is the shape the bug takes if the key is ever
// wrong again under the NEW one).
// Prefix rule: https://docs.aws.amazon.com/bedrock/latest/userguide/kb-test-config.html
// The exact key, under "Auto-created fields":
// https://docs.aws.amazon.com/bedrock/latest/userguide/kb-multimodal-test-and-query.html

const string VDEL_KB_ID = "KBVECDEL01";
const string VDEL_DS_ID = "DSVECDEL01";

// `probe-match` matches the caller's filter (present in BOTH enumerations);
// `probe-miss` does not, but IS reachable under the unfiltered enumeration —
// genuinely excluded; `probe-hidden` is reachable under neither — indeterminate.
const string VDEL_MATCH_ID = "probe-match";
const string VDEL_MISS_ID = "probe-miss";
const string VDEL_HIDDEN_ID = "probe-hidden";

isolated json[] vectorProbeFilters = [];
isolated json[] vectorDeletePayloads = [];

isolated function recordVectorProbe(json filter) {
    lock {
        vectorProbeFilters.push(filter.clone());
    }
}

isolated function readVectorProbes() returns json[] {
    lock {
        return vectorProbeFilters.clone();
    }
}

isolated function recordVectorDelete(json payload) {
    lock {
        vectorDeletePayloads.push(payload.clone());
    }
}

isolated function readVectorDeletes() returns json[] {
    lock {
        return vectorDeletePayloads.clone();
    }
}

isolated service class VectorDeleteMock {
    *http:Service;

    isolated resource function get [string... path](http:Request req) returns json|error {
        string p = req.rawPath;
        if p == string `/knowledgebases/${VDEL_KB_ID}` {
            return {
                knowledgeBase: {
                    knowledgeBaseId: VDEL_KB_ID,
                    name: "kb",
                    status: "ACTIVE",
                    knowledgeBaseConfiguration: {'type: "VECTOR"}
                }
            };
        }
        if p == string `/knowledgebases/${VDEL_KB_ID}/datasources/${VDEL_DS_ID}` {
            return {
                dataSource: {
                    dataSourceId: VDEL_DS_ID,
                    status: "AVAILABLE",
                    dataSourceConfiguration: {'type: "CUSTOM"},
                    vectorIngestionConfiguration: {chunkingConfiguration: {chunkingStrategy: "FIXED_SIZE"}}
                }
            };
        }
        return error(string `unexpected GET ${p}`);
    }

    isolated resource function post [string... path](http:Request req) returns json|error {
        string p = req.rawPath;

        if p == string `/knowledgebases/${VDEL_KB_ID}/datasources/` {
            return {dataSourceSummaries: [{dataSourceId: VDEL_DS_ID, name: "ds"}]};
        }

        // ListKnowledgeBaseDocuments — exhaustive, and carries no metadata at all,
        // which is exactly why the two-enumeration `Retrieve` pass below has to
        // exist.
        if p == string `/knowledgebases/${VDEL_KB_ID}/datasources/${VDEL_DS_ID}/documents` {
            return {
                documentDetails: [VDEL_MATCH_ID, VDEL_MISS_ID, VDEL_HIDDEN_ID].map(id => <json>{
                    identifier: {dataSourceType: "CUSTOM", custom: {id}},
                    status: "INDEXED"
                })
            };
        }

        if p == string `/knowledgebases/${VDEL_KB_ID}/datasources/${VDEL_DS_ID}/documents/deleteDocuments` {
            json body = check req.getJsonPayload();
            recordVectorDelete((<map<json>>body)["documentIdentifiers"] ?: []);
            return {documentDetails: []};
        }

        if p == string `/knowledgebases/${VDEL_KB_ID}/retrieve` {
            json body = check req.getJsonPayload();
            map<json> vectorSearch = <map<json>>(<map<json>>(<map<json>>body)["retrievalConfiguration"])
                ["vectorSearchConfiguration"];
            json? filter = vectorSearch["filter"] ?: ();
            recordVectorProbe(filter);

            // FILTERED enumeration (filter present): only the genuine match.
            if filter !is () {
                return {retrievalResults: [vecDelResult(VDEL_MATCH_ID)]};
            }
            // UNFILTERED (reachability) enumeration: match AND miss are both
            // reachable; hidden is reachable under neither.
            return {retrievalResults: [vecDelResult(VDEL_MATCH_ID), vecDelResult(VDEL_MISS_ID)]};
        }
        return error(string `unexpected POST ${p}`);
    }
}

isolated function vecDelResult(string id) returns json => {
    content: {text: string `text for ${id}`, 'type: "TEXT"},
    documentId: id,
    location: {'type: "CUSTOM", customDocumentLocation: {id}},
    metadata: {"x-amz-bedrock-kb-source-uri": id},
    score: 0.95
};

// `retrievalResultIdentifies` unit tests. The mock results above populate the
// metadata key, `customDocumentLocation.id` AND `documentId` together, so on their
// own they would keep passing with two of the three branches deleted. These isolate
// each branch, and pin the deliberate REJECTION of `documentId`.
@test:Config {}
function testRetrievalResultIdentifiesByMetadataKeyAlone() {
    json result = {content: {text: "t", 'type: "TEXT"}, metadata: {"x-amz-bedrock-kb-source-uri": "doc-1"}};
    test:assertTrue(retrievalResultIdentifies(result, "doc-1", VECTOR_SOURCE_URI_METADATA_KEY));
    test:assertFalse(retrievalResultIdentifies(result, "doc-2", VECTOR_SOURCE_URI_METADATA_KEY));
}

@test:Config {}
function testRetrievalResultIdentifiesByCustomLocationAlone() {
    json result = {content: {text: "t", 'type: "TEXT"},
        location: {'type: "CUSTOM", customDocumentLocation: {id: "doc-1"}}};
    test:assertTrue(retrievalResultIdentifies(result, "doc-1", VECTOR_SOURCE_URI_METADATA_KEY));
    test:assertFalse(retrievalResultIdentifies(result, "doc-2", VECTOR_SOURCE_URI_METADATA_KEY));
}

// The S3 branch — `listDeletableDocuments` uses the S3 URI as `sourceValue`, so this
// is the only thing that can identify a document on an S3 data source.
@test:Config {}
function testRetrievalResultIdentifiesByS3LocationAlone() {
    json result = {content: {text: "t", 'type: "TEXT"},
        location: {'type: "S3", s3Location: {uri: "s3://bucket/docs/a.txt"}}};
    test:assertTrue(retrievalResultIdentifies(result, "s3://bucket/docs/a.txt", VECTOR_SOURCE_URI_METADATA_KEY));
    test:assertFalse(retrievalResultIdentifies(result, "s3://bucket/docs/b.txt", VECTOR_SOURCE_URI_METADATA_KEY));
}

// `documentId` is a service-side id with no documented equality to the custom
// identifier or the S3 URI, so it must NOT count as proof of identity — accepting it
// would admit a relation AWS never promised, and a false positive here deletes.
@test:Config {}
function testRetrievalResultDoesNotIdentifyByDocumentIdAlone() {
    json result = {content: {text: "t", 'type: "TEXT"}, documentId: "doc-1"};
    test:assertFalse(retrievalResultIdentifies(result, "doc-1", VECTOR_SOURCE_URI_METADATA_KEY),
        "documentId must not be accepted as proof of document identity");
}

// A result carrying no identity information at all cannot identify anything — the
// caller must treat it as unreachable, never as a match.
@test:Config {}
function testRetrievalResultWithNoIdentityFieldsIdentifiesNothing() {
    json result = {content: {text: "t", 'type: "TEXT"}, score: 0.99};
    test:assertFalse(retrievalResultIdentifies(result, "doc-1", VECTOR_SOURCE_URI_METADATA_KEY));
}

// THE regression guard for the reserved-prefix split, and for the exactly-two-calls
// cost claim. If this ever fell back to reading `_source_uri` (the MANAGED spelling),
// `probe-match`'s identity would never be extracted from either enumeration's
// results, and it would be reported indeterminate instead of deleted.
@test:Config {}
function testDeleteByFilterExtractsIdentityFromTheVectorSourceUriKeyAndDeletesOnlyTheMatch() returns error? {
    final int port = 18701;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new VectorDeleteMock(), "/");
    check mockListener.'start();
    lock {
        vectorProbeFilters.removeAll();
    }
    lock {
        vectorDeletePayloads.removeAll();
    }

    BedrockVectorKnowledgeBase kb = check new (VDEL_KB_ID, KB_TEST_CREDS, "us-east-1",
        endpoint = {customEndpoint: string `http://localhost:${port}`});
    ai:MetadataFilters filters = {filters: [{key: "tenant", operator: ai:EQUAL, value: "acme"}]};
    ai:Error? result = kb.deleteByFilter(filters);
    check mockListener.gracefulStop();

    // Exactly TWO `Retrieve` calls for the one CUSTOM data source — one filtered
    // enumeration, one unfiltered — regardless of the THREE candidate documents.
    // Replaced the old per-document pinned probe (one to two `Retrieve` calls PER
    // CANDIDATE), which returned nothing at all on a CUSTOM data source (A17).
    json[] probes = readVectorProbes();
    test:assertEquals(probes.length(), 2, probes.toJsonString());
    test:assertEquals(probes[0], {'equals: {key: "tenant", value: "acme"}}, "the filtered pass sends the RAW user filter, unwrapped — no per-document pin");
    test:assertEquals(probes[1], (), "the unfiltered (reachability) pass sends no filter at all");

    // Only the genuine match is deleted.
    json[] deletes = readVectorDeletes();
    test:assertEquals(deletes.length(), 1);
    json[] identifiers = <json[]>deletes[0];
    test:assertEquals(identifiers.length(), 1);
    test:assertEquals(identifiers[0], {dataSourceType: "CUSTOM", custom: {id: VDEL_MATCH_ID}});

    // `probe-hidden` was reachable under neither enumeration, so it is reported
    // rather than silently skipped; `probe-miss` was reachable but excluded by the
    // filter, so it must NOT be reported.
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        string msg = result.message();
        test:assertTrue(msg.includes(VDEL_HIDDEN_ID), msg);
        test:assertFalse(msg.includes(VDEL_MISS_ID),
            string `a document genuinely excluded by the filter must not be reported: ${msg}`);
    }
}

// A store that IGNORES the metadata filter must not cause a mass delete. This mock
// answers EVERY `Retrieve` call — filtered or not — with the same unrelated
// document, so neither enumeration ever sees any of the three real candidate ids.
// (`reachable.length()` stays at 1 here, so the explicit "store does not honour
// filters" refusal in `resolveDataSourceDeletes` does not fire — see
// tests/knowledgebase_a17_test.bal for that refusal firing when
// `reachable.length() > 1`. Either way nothing may be deleted.) AWS documents
// exactly this failure mode for MongoDB Atlas, where "Metadata filtering doesn't
// work by default". Trusting a non-empty response as proof of a match would mark
// every document a "hit" and wipe the knowledge base; checking identity must not.
isolated service class VectorIgnoresFilterMock {
    *http:Service;

    isolated resource function get [string... path](http:Request req) returns json|error {
        string p = req.rawPath;
        if p == string `/knowledgebases/${VDEL_KB_ID}` {
            return {
                knowledgeBase: {
                    knowledgeBaseId: VDEL_KB_ID,
                    name: "kb",
                    status: "ACTIVE",
                    knowledgeBaseConfiguration: {'type: "VECTOR"}
                }
            };
        }
        if p == string `/knowledgebases/${VDEL_KB_ID}/datasources/${VDEL_DS_ID}` {
            return {
                dataSource: {
                    dataSourceId: VDEL_DS_ID,
                    status: "AVAILABLE",
                    dataSourceConfiguration: {'type: "CUSTOM"},
                    vectorIngestionConfiguration: {chunkingConfiguration: {chunkingStrategy: "FIXED_SIZE"}}
                }
            };
        }
        return error(string `unexpected GET ${p}`);
    }

    isolated resource function post [string... path](http:Request req) returns json|error {
        string p = req.rawPath;
        if p == string `/knowledgebases/${VDEL_KB_ID}/datasources/` {
            return {dataSourceSummaries: [{dataSourceId: VDEL_DS_ID, name: "ds"}]};
        }
        if p == string `/knowledgebases/${VDEL_KB_ID}/datasources/${VDEL_DS_ID}/documents` {
            return {
                documentDetails: [VDEL_MATCH_ID, VDEL_MISS_ID, VDEL_HIDDEN_ID].map(id => <json>{
                    identifier: {dataSourceType: "CUSTOM", custom: {id}},
                    status: "INDEXED"
                })
            };
        }
        if p == string `/knowledgebases/${VDEL_KB_ID}/datasources/${VDEL_DS_ID}/documents/deleteDocuments` {
            json body = check req.getJsonPayload();
            recordVectorDelete((<map<json>>body)["documentIdentifiers"] ?: []);
            return {documentDetails: []};
        }
        if p == string `/knowledgebases/${VDEL_KB_ID}/retrieve` {
            // Always the same unrelated document, whatever the filter said.
            return {retrievalResults: [vecDelResult("some-other-document")]};
        }
        return error(string `unexpected POST ${p}`);
    }
}

@test:Config {}
function testDeleteByFilterDoesNotMassDeleteWhenTheStoreIgnoresTheFilter() returns error? {
    final int port = 18704;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new VectorIgnoresFilterMock(), "/");
    check mockListener.'start();
    lock {
        vectorDeletePayloads.removeAll();
    }

    BedrockVectorKnowledgeBase kb = check new (VDEL_KB_ID, KB_TEST_CREDS, "us-east-1",
        endpoint = {customEndpoint: string `http://localhost:${port}`});
    ai:Error? result = kb.deleteByFilter({filters: [{key: "tenant", operator: ai:EQUAL, value: "acme"}]});
    check mockListener.gracefulStop();

    // NOTHING may be deleted: neither enumeration ever returned any of the real ids.
    test:assertEquals(readVectorDeletes().length(), 0,
        "a store that ignores the filter must not cause any deletion");

    // And the caller must be told, not left thinking it succeeded.
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        string msg = result.message();
        foreach string id in [VDEL_MATCH_ID, VDEL_MISS_ID, VDEL_HIDDEN_ID] {
            test:assertTrue(msg.includes(id), string `${id} was not reported as indeterminate: ${msg}`);
        }
    }
}

// An empty `ai:MetadataFilters` maps to no filter at all. Left unguarded, "no filter"
// would make deleteByFilter behave like an unconditional bulk delete. A group made
// only of EMPTY sub-groups is not nil — `metadataFiltersToRetrievalFilter` yields
// `{"andAll": [null, null]}` for it — so a plain nil check would let it through.
@test:Config {}
function testDeleteByFilterRefusesNestedEmptyFilterGroups() returns error? {
    final int port = 18706;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new VectorDeleteMock(), "/");
    check mockListener.'start();
    lock {
        vectorDeletePayloads.removeAll();
    }

    BedrockVectorKnowledgeBase kb = check new (VDEL_KB_ID, KB_TEST_CREDS, "us-east-1",
        endpoint = {customEndpoint: string `http://localhost:${port}`});
    ai:MetadataFilters nestedEmpty = {filters: [{filters: []}, {filters: []}]};
    // Nested empty groups now COLLAPSE to `()` rather than producing
    // `{"andAll": [null, null]}` — the `is json` test in
    // `metadataFiltersToRetrievalFilter` used to accept the recursive call's `()`
    // because `()` is a member of `json`, and the malformed filter reached the wire
    // as a 400. The guard's leaf count stays as the independent second condition:
    // it answers "did the caller constrain anything?" without depending on how the
    // encoder folds empty groups.
    json? mapped = check metadataFiltersToRetrievalFilter(nestedEmpty);
    test:assertTrue(mapped is (), "nested empty groups must collapse to nil, not to a null-bearing andAll");
    test:assertEquals(filterLeafCount(nestedEmpty), 0);

    ai:Error? result = kb.deleteByFilter(nestedEmpty);
    check mockListener.gracefulStop();

    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        test:assertTrue(result.message().includes("at least one"), result.message());
    }
    test:assertEquals(readVectorDeletes().length(), 0, "a filter with no leaf predicates must delete nothing");
}

@test:Config {}
function testDeleteByFilterRefusesAnEmptyFilterSet() returns error? {
    final int port = 18705;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new VectorDeleteMock(), "/");
    check mockListener.'start();
    lock {
        vectorDeletePayloads.removeAll();
    }

    BedrockVectorKnowledgeBase kb = check new (VDEL_KB_ID, KB_TEST_CREDS, "us-east-1",
        endpoint = {customEndpoint: string `http://localhost:${port}`});
    ai:Error? result = kb.deleteByFilter({filters: []});
    check mockListener.gracefulStop();

    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        test:assertTrue(result.message().includes("at least one"), result.message());
    }
    test:assertEquals(readVectorDeletes().length(), 0, "an empty filter set must delete nothing");
}

// Data sources other than CUSTOM/S3 cannot be deleted through this API at all —
// `DocumentIdentifier.dataSourceType` has only those two members. They must be
// named in the error rather than silently skipped. Zero candidates on the CUSTOM
// data source here, so the two-enumeration algorithm never runs for it either —
// `deleteByFilter` skips straight past a data source with nothing to classify.
isolated service class VectorUndeletableSourceMock {
    *http:Service;

    isolated resource function get [string... path](http:Request req) returns json|error {
        string p = req.rawPath;
        if p == string `/knowledgebases/${VDEL_KB_ID}` {
            return {
                knowledgeBase: {
                    knowledgeBaseId: VDEL_KB_ID,
                    name: "kb",
                    status: "ACTIVE",
                    knowledgeBaseConfiguration: {'type: "VECTOR"}
                }
            };
        }
        if p == string `/knowledgebases/${VDEL_KB_ID}/datasources/${VDEL_DS_ID}` {
            return {
                dataSource: {
                    dataSourceId: VDEL_DS_ID,
                    status: "AVAILABLE",
                    dataSourceConfiguration: {'type: "CUSTOM"},
                    vectorIngestionConfiguration: {chunkingConfiguration: {chunkingStrategy: "FIXED_SIZE"}}
                }
            };
        }
        if p == string `/knowledgebases/${VDEL_KB_ID}/datasources/DSSHAREPT1` {
            return {
                dataSource: {
                    dataSourceId: "DSSHAREPT1",
                    dataSourceConfiguration: {'type: "SHAREPOINT"}
                }
            };
        }
        return error(string `unexpected GET ${p}`);
    }

    isolated resource function post [string... path](http:Request req) returns json|error {
        string p = req.rawPath;
        if p == string `/knowledgebases/${VDEL_KB_ID}/datasources/` {
            return {
                dataSourceSummaries: [
                    {dataSourceId: VDEL_DS_ID, name: "custom-ds"},
                    {dataSourceId: "DSSHAREPT1", name: "sharepoint-ds"}
                ]
            };
        }
        if p == string `/knowledgebases/${VDEL_KB_ID}/datasources/${VDEL_DS_ID}/documents` {
            return {documentDetails: []};
        }
        return error(string `unexpected POST ${p}`);
    }
}

@test:Config {}
function testDeleteByFilterNamesUndeletableDataSources() returns error? {
    final int port = 18703;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new VectorUndeletableSourceMock(), "/");
    check mockListener.'start();

    BedrockVectorKnowledgeBase kb = check new (VDEL_KB_ID, KB_TEST_CREDS, "us-east-1",
        endpoint = {customEndpoint: string `http://localhost:${port}`});
    ai:Error? result = kb.deleteByFilter({filters: [{key: "tenant", operator: ai:EQUAL, value: "acme"}]});
    check mockListener.gracefulStop();

    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        string msg = result.message();
        test:assertTrue(msg.includes("DSSHAREPT1"), msg);
        test:assertTrue(msg.includes("SHAREPOINT"), msg);
        test:assertTrue(msg.includes("CUSTOM/S3"), msg);
    }
}
