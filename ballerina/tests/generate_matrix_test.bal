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
import ballerina/test;

// Typed generate() across every API family: primitives, records, nested records,
// arrays, unions, optional fields, an enum and a nilable target. Each family runs the
// full `generateLlmResponse` path (schema, forced tool, decode, bind, ensureType)
// against an in-process transport answering in that family's own wire shape.

type MatrixPoint record {|
    int x;
    int y;
|};

type MatrixShape record {|
    string name;
    MatrixPoint origin;
    MatrixPoint[] corners;
|};

type MatrixOptional record {|
    string title;
    int? rating = ();
    string note?;
|};

type MatrixPoints MatrixPoint[];

type MatrixInts int[];

type MatrixStrings string[];

type MatrixUnion int|string;

type MatrixNilable string?;

enum MatrixColour {
    MATRIX_RED,
    MATRIX_BLUE
}

// Records get their schema from an `@ai:JsonSchema` annotation the `ai` compiler
// plugin attaches at a generate() call site. Never executed.
function matrixSchemaCallSites(ai:ModelProvider provider) returns error? {
    MatrixPoint _ = check provider->generate(`point`);
    MatrixShape _ = check provider->generate(`shape`);
    MatrixOptional _ = check provider->generate(`optional`);
    MatrixPoint[] _ = check provider->generate(`points`);
}

// One target type: its typedesc, the JSON value the model sends, and the bound value.
type MatrixCase [string, typedesc<anydata>, json, anydata];

function matrixCases() returns MatrixCase[] => [
    ["int", int, 42, 42],
    ["boolean", boolean, true, true],
    ["float", float, 3.5, 3.5],
    ["string[]", MatrixStrings, ["a", "b"], ["a", "b"]],
    ["int[]", MatrixInts, [1, 2, 3], [1, 2, 3]],
    ["record", MatrixPoint, {x: 1, y: 2}, <MatrixPoint>{x: 1, y: 2}],
    [
        "nested record",
        MatrixShape,
        {name: "square", origin: {x: 0, y: 0}, corners: [{x: 1, y: 1}, {x: 2, y: 2}]},
        <MatrixShape>{name: "square", origin: {x: 0, y: 0}, corners: [{x: 1, y: 1}, {x: 2, y: 2}]}
    ],
    ["array of records", MatrixPoints, [{x: 1, y: 2}], <MatrixPoints>[{x: 1, y: 2}]],
    ["union, int member", MatrixUnion, 7, 7],
    ["union, string member", MatrixUnion, "seven", "seven"],
    ["optional fields omitted", MatrixOptional, {title: "t"}, <MatrixOptional>{title: "t"}],
    [
        "optional fields present",
        MatrixOptional,
        {title: "t", rating: 4, note: "n"},
        <MatrixOptional>{title: "t", rating: 4, note: "n"}
    ],
    ["enum", MatrixColour, "MATRIX_BLUE", MATRIX_BLUE],
    ["nilable string", MatrixNilable, "hi", "hi"]
];

// Builds a dialect's tool-call reply; `forcedToolName` reads which tool a request forced.
type ReplyBuilder isolated function (string? text, string toolName = "", json toolArgs = ()) returns json;

type ForcedToolReader function (map<json> body) returns string?;

function runTypedMatrix(string family, readonly & ModelConverter converter, ApiFamily api, string modelId,
        ReplyBuilder reply, ForcedToolReader forcedToolName) returns error? {
    foreach MatrixCase [label, td, value, expected] in matrixCases() {
        // A non-object target travels wrapped in `{"result": ...}` — the forced tool's
        // schema must be an object on every dialect.
        [map<json>, boolean] [_, wrapped] = check wireSchemaFor(td);
        json args = wrapped ? {"result": value} : value;
        CannedTransport transport = new (reply((), RESULT_TOOL, args));

        anydata|ai:Error result = generateLlmResponse(TOOL_FORCING, api, converter, transport, modelId, {},
                GEN_PARAMS, `Produce the value.`, td);
        string caseName = string `${family} / ${label}`;
        if result is ai:Error {
            test:assertFail(string `${caseName}: ${errorText(result)}`);
        }
        test:assertEquals(result, expected, caseName);

        json[] requests = transport.requests();
        test:assertEquals(requests.length(), 1, caseName);
        test:assertEquals(forcedToolName(<map<json>>requests[0]), RESULT_TOOL,
                string `${caseName}: the request must force the result tool`);
    }
}

function converseForced(map<json> body) returns string? {
    json name = (<map<json>>(<map<json>>(<map<json>>body["toolConfig"])["toolChoice"])["tool"])["name"];
    return name is string ? name : ();
}

function anthropicForced(map<json> body) returns string? {
    json name = (<map<json>>body["tool_choice"])["name"];
    return name is string ? name : ();
}

function openAIChatForced(map<json> body) returns string? {
    json name = (<map<json>>(<map<json>>body["tool_choice"])["function"])["name"];
    return name is string ? name : ();
}

function responsesForced(map<json> body) returns string? {
    json name = (<map<json>>body["tool_choice"])["name"];
    return name is string ? name : ();
}

// Mistral cannot name the forced tool: `"any"` with exactly one tool offered.
function mistralForced(map<json> body) returns string? {
    if body["tool_choice"] != "any" {
        return ();
    }
    json[] tools = <json[]>body["tools"];
    json name = (<map<json>>(<map<json>>tools[0])["function"])["name"];
    return tools.length() == 1 && name is string ? name : ();
}

@test:Config {}
function testTypedGenerateOnConverse() returns error? {
    check runTypedMatrix("Converse", CONVERSE_CONVERTER, CONVERSE, "us.anthropic.claude-sonnet-4-6",
            converseReply, converseForced);
}

@test:Config {}
function testTypedGenerateOnAnthropicInvoke() returns error? {
    check runTypedMatrix("Anthropic InvokeModel", INVOKE_ANTHROPIC_CONVERTER, INVOKE,
            "us.anthropic.claude-sonnet-4-6", anthropicReply, anthropicForced);
}

@test:Config {}
function testTypedGenerateOnAnthropicMessages() returns error? {
    check runTypedMatrix("Anthropic Messages", NATIVE_MESSAGES_CONVERTER, MESSAGES,
            "us.anthropic.claude-sonnet-4-6", anthropicReply, anthropicForced);
}

@test:Config {}
function testTypedGenerateOnNovaInvoke() returns error? {
    check runTypedMatrix("Nova InvokeModel", INVOKE_NOVA_CONVERTER, INVOKE, "amazon.nova-pro-v1:0",
            converseReply, converseForced);
}

@test:Config {}
function testTypedGenerateOnOpenAIChatInvoke() returns error? {
    check runTypedMatrix("OpenAI chat InvokeModel", INVOKE_OPENAI_CHAT_CONVERTER, INVOKE,
            "openai.gpt-oss-120b-1:0", openAIChatReply, openAIChatForced);
}

@test:Config {}
function testTypedGenerateOnChatCompletions() returns error? {
    check runTypedMatrix("Chat Completions", NATIVE_CHAT_CONVERTER, CHAT_COMPLETIONS,
            "openai.gpt-oss-120b-1:0", openAIChatReply, openAIChatForced);
}

@test:Config {}
function testTypedGenerateOnResponses() returns error? {
    check runTypedMatrix("Responses", NATIVE_RESPONSES_CONVERTER, RESPONSES, GPT_6_SOL,
            responsesReply, responsesForced);
}

@test:Config {}
function testTypedGenerateOnMistralChatInvoke() returns error? {
    check runTypedMatrix("Mistral chat InvokeModel", INVOKE_MISTRAL_CHAT_CONVERTER, INVOKE,
            "mistral.mistral-large-3-675b-instruct", mistralChatReply, mistralForced);
}

// A response that does not match the expected type is an `LlmInvalidGenerationError`,
// on the shared path every family takes.
@test:Config {}
function testAMismatchedResultIsAnInvalidGenerationError() {
    CannedTransport transport = new (converseReply((), RESULT_TOOL, {x: "not a number", y: 2}));
    anydata|ai:Error result = generateLlmResponse(TOOL_FORCING, CONVERSE, CONVERSE_CONVERTER, transport,
            "us.anthropic.claude-sonnet-4-6", {}, GEN_PARAMS, `Produce the value.`, MatrixPoint);
    test:assertTrue(result is ai:LlmInvalidGenerationError, result is ai:Error ? result.message() : "no error");
}

// A plain `string` target never offers or forces a tool, on any family.
@test:Config {}
function testAStringTargetSendsNoToolOnAnyFamily() returns error? {
    [readonly & ModelConverter, ApiFamily, ReplyBuilder][] families = [
        [CONVERSE_CONVERTER, CONVERSE, converseReply],
        [INVOKE_ANTHROPIC_CONVERTER, INVOKE, anthropicReply],
        [NATIVE_MESSAGES_CONVERTER, MESSAGES, anthropicReply],
        [NATIVE_RESPONSES_CONVERTER, RESPONSES, responsesReply],
        [NATIVE_CHAT_CONVERTER, CHAT_COMPLETIONS, openAIChatReply],
        [INVOKE_MISTRAL_CHAT_CONVERTER, INVOKE, mistralChatReply]
    ];
    foreach [readonly & ModelConverter, ApiFamily, ReplyBuilder] [converter, api, reply] in families {
        CannedTransport transport = new (reply("plain text"));
        anydata result = check generateLlmResponse(TOOL_FORCING, api, converter, transport, "some-model", {},
                GEN_PARAMS, `Say something.`, string);
        test:assertEquals(result, "plain text", converter.dialect);
        string sent = transport.requests()[0].toJsonString();
        test:assertFalse(sent.includes(RESULT_TOOL), string `${converter.dialect}: no result tool for a string`);
    }
}
