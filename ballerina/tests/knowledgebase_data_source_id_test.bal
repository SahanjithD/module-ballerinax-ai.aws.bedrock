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

// No knowledge base matches the name, and any create is recorded.
isolated service class NoMatchCreateRecorder {
    *http:Service;

    private int creates = 0;

    isolated resource function post [string... path](http:Request req) returns json|error {
        if req.rawPath == "/knowledgebases/" {
            return {knowledgeBaseSummaries: []};
        }
        return error(string `unexpected POST ${req.rawPath}`);
    }

    isolated resource function put [string... path](http:Request req) returns error {
        lock {
            self.creates += 1;
        }
        return error(string `unexpected PUT ${req.rawPath}`);
    }

    isolated function createCount() returns int {
        lock {
            return self.creates;
        }
    }
}

@test:Config {}
function testManagedDefinitionWithDataSourceIdIsRefusedBeforeCreating() returns error? {
    final int port = 18791;
    NoMatchCreateRecorder mock = new;
    http:Listener mockListener = check new (port);
    check mockListener.attach(mock, "/");
    check mockListener.'start();

    ManagedKnowledgeBaseDefinition def = {name: "new-kb", serviceRoleArn: VEC_ROLE_ARN};
    ManagedKnowledgeBase|ai:Error kb = new (def, KB_TEST_CREDS, "us-east-1", dataSourceId = "DS12345678",
        endpoint = {customEndpoint: string `http://localhost:${port}`});
    check mockListener.gracefulStop();

    if kb !is ai:Error {
        test:assertFail("a definition for a new knowledge base with a dataSourceId must be refused");
    }
    test:assertTrue(kb.message().includes("'dataSourceId' cannot be used"), kb.message());
    test:assertEquals(mock.createCount(), 0, "nothing may be created");
}

@test:Config {}
function testSelfManagedDefinitionWithDataSourceIdIsRefusedBeforeCreating() returns error? {
    final int port = 18792;
    NoMatchCreateRecorder mock = new;
    http:Listener mockListener = check new (port);
    check mockListener.attach(mock, "/");
    check mockListener.'start();

    SelfManagedKnowledgeBaseDefinition def = {
        name: "new-vec-kb",
        serviceRoleArn: VEC_ROLE_ARN,
        embeddingModelArn: VEC_EMBEDDING_ARN,
        storageConfiguration: VEC_TEST_STORAGE
    };
    SelfManagedKnowledgeBase|ai:Error kb = new (def, KB_TEST_CREDS, "us-east-1", dataSourceId = "DS12345678",
        endpoint = {customEndpoint: string `http://localhost:${port}`});
    check mockListener.gracefulStop();

    if kb !is ai:Error {
        test:assertFail("a definition for a new knowledge base with a dataSourceId must be refused");
    }
    test:assertTrue(kb.message().includes("'dataSourceId' cannot be used"), kb.message());
    test:assertEquals(mock.createCount(), 0, "nothing may be created");
}
