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

import ballerina/http;
import ballerina/test;

// Settles the SigV4 double-encoding assumption WITHOUT AWS: proves an
// `http:Client` transmits an already-percent-encoded path verbatim (no `%`→`%25`,
// no `%2F`→`/`). If this holds, the wire=single / canonical=double split is
// correct (design §9.4).

isolated string capturedRawPath = "";

isolated function recordRawPath(string path) {
    lock {
        capturedRawPath = path;
    }
}

isolated function readRawPath() returns string {
    lock {
        return capturedRawPath;
    }
}

listener http:Listener echoListener = new (18637);

service / on echoListener {
    isolated resource function post [string... path](http:Request req) returns json {
        recordRawPath(req.rawPath);
        return {"ok": true};
    }
}

@test:Config {}
function testHttpClientSendsEncodedPathVerbatim() returns error? {
    http:Client echoClient = check new ("http://localhost:18637");
    string wirePath = "/model/arn%3Aaws%3Abedrock%3Aimported-model%2Fabc123/invoke";
    json _ = check echoClient->post(wirePath, {});
    string received = readRawPath();
    test:assertTrue(received.includes("%3A"), "client must send %3A verbatim; got: " + received);
    test:assertFalse(received.includes("%253A"), "client must NOT double-encode; got: " + received);
    test:assertFalse(received.includes("imported-model/abc123"), "client must NOT decode %2F; got: " + received);
}
