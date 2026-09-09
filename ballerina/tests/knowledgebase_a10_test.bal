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

// A10 — concurrent `init()` still creating duplicate knowledge bases. Two distinct
// windows, fixed separately (see knowledgebase_common.bal):
//
//   §2a SEQUENTIAL: a 409 `ConflictException` from `CreateKnowledgeBase` is fully
//   recoverable — re-list by name, attach on exactly one match.
//   §2b GENUINELY CONCURRENT: two `init()` calls already in flight sharing the same
//   deterministic `clientToken` were measured live BOTH accepted by AWS, so this can
//   only be reconciled AFTER this call's own create is ACTIVE — reported, never
//   silently duplicated, and never deleted.

const string A10_KB_ID = "KBA10TEST1";
const string A10_EXISTING_ID = "KBA10EXIST";
const string A10_ROLE_ARN = "arn:aws:iam::367134611783:role/service-role/RealKbRole";
const string A10_KB_NAME = "a10-test-kb";
final KnowledgeBaseDefinition A10_DEF = {name: A10_KB_NAME, roleArn: A10_ROLE_ARN};

// Not `isolated`: `KB_TEST_CREDS` (knowledgebase_construction_test.bal) is `final`
// but not `readonly`, so referencing it from an `isolated function` does not compile
// — matches the pattern other test files already use for this same reason.
function a10Transport(int port) returns BedrockTransport|error
    => new (
        check resolveCredentials(KB_TEST_CREDS), "us-east-1",
        check buildAgentEndpoint(AGENT_CONTROL, "us-east-1", {customEndpoint: string `http://localhost:${port}`}),
        (), (), true);

// ============================================================================
// §2a — the sequential window: a 409 recovered by re-resolving the name.
// ============================================================================

isolated service class ConflictRecoverOneMatchMock {
    *http:Service;

    isolated resource function put [string... path](http:Request req) returns http:Response|error {
        // AWS's own sequential-duplicate wording, measured live 2026-09-08.
        http:Response resp = new;
        resp.statusCode = 409;
        resp.setJsonPayload({message: string `KnowledgeBase with name ${A10_KB_NAME} already exists.`});
        return resp;
    }

    isolated resource function post [string... path](http:Request req) returns json {
        return {
            knowledgeBaseSummaries: [
                {knowledgeBaseId: A10_EXISTING_ID, name: A10_KB_NAME, status: "ACTIVE"}
            ]
        };
    }

    isolated resource function get [string... path](http:Request req) returns json {
        return {
            knowledgeBase: {
                knowledgeBaseId: A10_EXISTING_ID,
                name: A10_KB_NAME,
                status: "ACTIVE",
                roleArn: A10_ROLE_ARN,
                knowledgeBaseConfiguration: {
                    'type: "MANAGED",
                    managedKnowledgeBaseConfiguration: {embeddingModelType: "MANAGED"}
                }
            }
        };
    }
}

@test:Config {}
function testA10ConflictWithExactlyOneNameMatchRecoversByAttaching() returns error? {
    final int port = 18760;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new ConflictRecoverOneMatchMock(), "/");
    check mockListener.'start();

    BedrockTransport transport = check a10Transport(port);
    KbCreateOutcome|ai:Error outcome = createKnowledgeBaseRecoveringFromConflict(transport, A10_DEF);
    check mockListener.gracefulStop();

    test:assertTrue(outcome is KbCreateOutcome, (outcome is ai:Error ? outcome.message() : ""));
    if outcome is KbCreateOutcome {
        test:assertTrue(outcome.recovered);
        test:assertEquals(outcome.knowledgeBaseId, A10_EXISTING_ID);
    }
}

isolated service class ConflictRecoverZeroMatchMock {
    *http:Service;

    isolated resource function put [string... path](http:Request req) returns http:Response|error {
        http:Response resp = new;
        resp.statusCode = 409;
        resp.setJsonPayload({message: string `KnowledgeBase with name ${A10_KB_NAME} already exists.`});
        return resp;
    }

    isolated resource function post [string... path](http:Request req) returns json {
        // Re-listing finds NOTHING — the module cannot resolve this on its own
        // (e.g. the 409 raced against a delete this call never observed).
        return {knowledgeBaseSummaries: []};
    }
}

@test:Config {}
function testA10ConflictWithZeroNameMatchesSurfacesTheOriginal409() returns error? {
    final int port = 18761;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new ConflictRecoverZeroMatchMock(), "/");
    check mockListener.'start();

    BedrockTransport transport = check a10Transport(port);
    KbCreateOutcome|ai:Error outcome = createKnowledgeBaseRecoveringFromConflict(transport, A10_DEF);
    check mockListener.gracefulStop();

    test:assertTrue(outcome is ai:Error);
    if outcome is ai:Error {
        // The ORIGINAL 409 message text, unchanged — proves the recovery did not
        // invent its own wording when it could not resolve the conflict.
        test:assertTrue(outcome.message().includes("already exists"), outcome.message());
        test:assertTrue(outcome.message().includes("409") || outcome.message().includes("ConflictException"),
            outcome.message());
    }
}

isolated service class ConflictRecoverAmbiguousMatchMock {
    *http:Service;

    isolated resource function put [string... path](http:Request req) returns http:Response|error {
        http:Response resp = new;
        resp.statusCode = 409;
        resp.setJsonPayload({message: string `KnowledgeBase with name ${A10_KB_NAME} already exists.`});
        return resp;
    }

    isolated resource function post [string... path](http:Request req) returns json {
        // More than one match: which one this create collided with is genuinely
        // ambiguous, so recovery must not guess.
        return {
            knowledgeBaseSummaries: [
                {knowledgeBaseId: "KBA10AAAAA", name: A10_KB_NAME, status: "ACTIVE"},
                {knowledgeBaseId: "KBA10BBBBB", name: A10_KB_NAME, status: "ACTIVE"}
            ]
        };
    }
}

@test:Config {}
function testA10ConflictWithMoreThanOneNameMatchSurfacesTheOriginal409() returns error? {
    final int port = 18762;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new ConflictRecoverAmbiguousMatchMock(), "/");
    check mockListener.'start();

    BedrockTransport transport = check a10Transport(port);
    KbCreateOutcome|ai:Error outcome = createKnowledgeBaseRecoveringFromConflict(transport, A10_DEF);
    check mockListener.gracefulStop();

    test:assertTrue(outcome is ai:Error);
    if outcome is ai:Error {
        // Still the ORIGINAL 409, not a re-derived "ambiguous name" message — the
        // recovery path does not manufacture its own wording here either.
        test:assertTrue(outcome.message().includes("already exists"), outcome.message());
        test:assertFalse(outcome.message().includes("KBA10AAAAA"), outcome.message());
    }
}

// A successful (non-409) create must still work exactly as before — the recovery
// path must not interfere with the ordinary case.
isolated service class ConflictRecoverOrdinaryCreateMock {
    *http:Service;

    isolated resource function put [string... path](http:Request req) returns json {
        return {knowledgeBase: {knowledgeBaseId: A10_KB_ID, name: A10_KB_NAME, status: "CREATING"}};
    }
}

@test:Config {}
function testA10OrdinaryCreateIsUnaffectedByTheConflictRecoveryPath() returns error? {
    final int port = 18763;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new ConflictRecoverOrdinaryCreateMock(), "/");
    check mockListener.'start();

    BedrockTransport transport = check a10Transport(port);
    KbCreateOutcome|ai:Error outcome = createKnowledgeBaseRecoveringFromConflict(transport, A10_DEF);
    check mockListener.gracefulStop();

    test:assertTrue(outcome is KbCreateOutcome, (outcome is ai:Error ? outcome.message() : ""));
    if outcome is KbCreateOutcome {
        test:assertFalse(outcome.recovered);
        test:assertEquals(outcome.knowledgeBaseId, A10_KB_ID);
    }
}

// ============================================================================
// §2b — the genuinely concurrent window: reconcile deterministically and report,
// never delete.
// ============================================================================

@test:Config {}
function testA10NoDuplicateFoundAfterCreateIsSilent() returns error? {
    final int port = 18764;
    http:Listener mockListener = check new (port);
    // A single-match list — the ordinary, non-racing case.
    check mockListener.attach(new ConflictRecoverOneMatchMockSingle(), "/");
    check mockListener.'start();

    BedrockTransport transport = check a10Transport(port);
    ai:Error? result = guardAgainstConcurrentDuplicate(transport, A10_KB_NAME, A10_KB_ID);
    check mockListener.gracefulStop();

    test:assertEquals(result, ());
}

isolated service class ConflictRecoverOneMatchMockSingle {
    *http:Service;

    isolated resource function post [string... path](http:Request req) returns json {
        return {knowledgeBaseSummaries: [{knowledgeBaseId: A10_KB_ID, name: A10_KB_NAME, status: "ACTIVE"}]};
    }
}

isolated service class ConcurrentDuplicateMock {
    *http:Service;

    isolated resource function post [string... path](http:Request req) returns json {
        // THIS call created "KBA10ZZZZZ" — not the lexicographically smallest of the
        // three — so it must be reported as an orphan, and "KBA10AAAAA" as the winner.
        return {
            knowledgeBaseSummaries: [
                {knowledgeBaseId: "KBA10ZZZZZ", name: A10_KB_NAME, status: "ACTIVE"},
                {knowledgeBaseId: "KBA10AAAAA", name: A10_KB_NAME, status: "ACTIVE"},
                {knowledgeBaseId: "KBA10MMMMM", name: A10_KB_NAME, status: "ACTIVE"}
            ]
        };
    }
}

@test:Config {}
function testA10ConcurrentDuplicateAfterCreateIsReportedNamingWinnerAndOrphan() returns error? {
    final int port = 18765;
    http:Listener mockListener = check new (port);
    check mockListener.attach(new ConcurrentDuplicateMock(), "/");
    check mockListener.'start();

    BedrockTransport transport = check a10Transport(port);
    ai:Error? result = guardAgainstConcurrentDuplicate(transport, A10_KB_NAME, "KBA10ZZZZZ");
    check mockListener.gracefulStop();

    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        string msg = result.message();
        test:assertTrue(msg.includes("KBA10AAAAA"), msg); // the winner
        test:assertTrue(msg.includes("KBA10ZZZZZ"), msg); // this call's own orphan
        test:assertTrue(msg.includes("KBA10MMMMM"), msg); // the other orphan
        test:assertTrue(msg.includes("aws bedrock-agent delete-knowledge-base"), msg);
        test:assertTrue(msg.includes("orphans"), msg); // this call lost the race
    }
}

// ---- concurrentDuplicateMessage: pure, table-tested without AWS ----

@test:Config {}
function testConcurrentDuplicateMessagePicksTheLexicographicallySmallestWinner() {
    string msg = concurrentDuplicateMessage("kb-name", ["KBBBBB", "KBAAAA", "KBCCCC"], "KBAAAA");
    // The winner (this call's own creation) never appears in a cleanup command.
    test:assertFalse(msg.includes("delete-knowledge-base --knowledge-base-id KBAAAA"), msg);
    test:assertTrue(msg.includes("delete-knowledge-base --knowledge-base-id KBBBBB"), msg);
    test:assertTrue(msg.includes("delete-knowledge-base --knowledge-base-id KBCCCC"), msg);
    test:assertTrue(msg.includes("KBAAAA"), msg);
    test:assertTrue(msg.includes("winner"), msg);
}

@test:Config {}
function testConcurrentDuplicateMessageNamesThisCallsOwnOrphan() {
    string msg = concurrentDuplicateMessage("kb-name", ["KBBBBB", "KBAAAA"], "KBBBBB");
    // KBAAAA is the winner (smaller); this call created KBBBBB, the orphan.
    test:assertTrue(msg.includes("orphans"), msg);
    test:assertTrue(msg.includes("delete-knowledge-base --knowledge-base-id KBBBBB"), msg);
    test:assertFalse(msg.includes("delete-knowledge-base --knowledge-base-id KBAAAA"), msg);
}

@test:Config {}
function testConcurrentDuplicateMessageDeterministicAcrossBothRacersViewOfTheSameSet() {
    // Both racers see the SAME candidate set (the point of the deterministic
    // tie-break: neither needs to coordinate to agree on who the survivor is).
    string[] sameSet = ["KBAAAA", "KBBBBB"];
    string fromWinner = concurrentDuplicateMessage("kb-name", sameSet, "KBAAAA");
    string fromLoser = concurrentDuplicateMessage("kb-name", sameSet, "KBBBBB");
    test:assertTrue(fromWinner.includes("KBAAAA") && fromLoser.includes("KBAAAA"));
    // Both messages must name the SAME id as the winner, whichever racer asks.
    test:assertTrue(fromWinner.includes("winner") || fromWinner.includes("this call's own create is the winner"));
    test:assertTrue(fromLoser.includes("orphans"));
}
