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
import ballerinax/aws;

// Every provider class, on every API type it offers, end to end through a real
// signed request to a local stand-in for Bedrock: chat(), generate() into `string`,
// generate() into a record, and a full `ai:Agent` loop with one tool call.
//
// The stand-in answers in the wire dialect the request path (and, for InvokeModel,
// the model id) implies, so each case exercises its own encoder and decoder:
//
//   a forced tool choice      -> a call to the result tool with a `MatrixPoint`
//   tools, not forced         -> a call to the agent's tool
//   a tool result in history  -> the agent's final text
//   anything else             -> the text "OK"

const int PROVIDER_MATRIX_PORT = 18901;
const string MATRIX_TOOL = "getMatrixWeather";
const string MATRIX_FINAL_ANSWER = "It is sunny in Paris.";

isolated int matrixToolCalls = 0;

# Returns the weather for a city.
#
# + city - The city
# + return - The weather
@ai:AgentTool
isolated function getMatrixWeather(string city) returns string {
    lock {
        matrixToolCalls += 1;
    }
    return string `sunny in ${city}`;
}

isolated function readMatrixToolCalls() returns int {
    lock {
        return matrixToolCalls;
    }
}

isolated function matrixReplyBuilder(string path) returns ReplyBuilder {
    if path.endsWith("/converse") {
        return converseReply;
    }
    if path.endsWith("/messages") {
        return anthropicReply;
    }
    if path.endsWith("/responses") {
        return responsesReply;
    }
    if path.endsWith("/chat/completions") {
        return openAIChatReply;
    }
    // InvokeModel: the body is the model's own, picked by the id in the path.
    if path.includes("anthropic.") {
        return anthropicReply;
    }
    if path.includes("amazon.nova") {
        return converseReply;
    }
    if path.includes("mistral.") {
        return mistralChatReply;
    }
    return openAIChatReply;
}

isolated function matrixMockReply(http:Request req) returns json|error {
    ReplyBuilder reply = matrixReplyBuilder(req.rawPath);
    string body = (check req.getJsonPayload()).toJsonString();
    if body.includes("\"tool_choice\"") || body.includes("\"toolChoice\"") {
        return reply((), RESULT_TOOL, {x: 1, y: 2});
    }
    if body.includes("\"toolResult\"") || body.includes("\"tool_result\"") ||
            body.includes("\"role\":\"tool\"") || body.includes("\"function_call_output\"") {
        return reply(MATRIX_FINAL_ANSWER);
    }
    if body.includes(MATRIX_TOOL) {
        return reply((), MATRIX_TOOL, {city: "Paris"});
    }
    return reply("OK");
}

listener http:Listener providerMatrixListener = new (PROVIDER_MATRIX_PORT);

service / on providerMatrixListener {
    isolated resource function post [string... segments](http:Request req) returns json|error
        => matrixMockReply(req);
}

final aws:EndpointConfig MATRIX_ENDPOINT = {customEndpoint: string `http://localhost:${PROVIDER_MATRIX_PORT}`};

// [case name, whether a typed generate() is expected to be refused on that route]
type ProviderCase [string, boolean];

function providerCases() returns ProviderCase[] => [
    ["RuntimeAnthropic CONVERSE", false], ["RuntimeAnthropic INVOKE", false], ["RuntimeAnthropic MESSAGES", false],
    ["RuntimeOpenAI CONVERSE", false], ["RuntimeOpenAI INVOKE", false],
    ["RuntimeOpenAI CHAT_COMPLETIONS", false], ["RuntimeOpenAI RESPONSES", false],
    ["RuntimeAmazon CONVERSE", false], ["RuntimeAmazon INVOKE", false],
    ["RuntimeMistral CONVERSE", false], ["RuntimeMistral INVOKE", false], ["RuntimeMistral CHAT_COMPLETIONS", false],
    ["RuntimeQwen CONVERSE", false], ["RuntimeQwen INVOKE", false], ["RuntimeQwen CHAT_COMPLETIONS", false],
    ["RuntimeGoogle CONVERSE", false], ["RuntimeGoogle INVOKE", false], ["RuntimeGoogle CHAT_COMPLETIONS", false],
    ["RuntimeDeepSeek CONVERSE", false], ["RuntimeDeepSeek INVOKE", false],
    ["RuntimeDeepSeek CHAT_COMPLETIONS", false],
    ["CommonModelProvider", false],
    // Mantle Anthropic Messages has no structured-output path; typed generate() is refused.
    ["MantleAnthropic", true], ["MantleOpenAI GPT-5.4", false], ["MantleOpenAI gpt-oss", false],
    ["MantleMistral", false], ["MantleQwen", false], ["MantleGoogle", false], ["MantleDeepSeek", false]
];

function matrixProvider(string name) returns ai:ModelProvider|error {
    aws:EndpointConfig ep = MATRIX_ENDPOINT;
    match name {
        "RuntimeAnthropic CONVERSE" => {
            return new RuntimeAnthropicModelProvider(CLAUDE_SONNET_4_6, TEST_CREDS, "us-east-1", endpoint = ep);
        }
        "RuntimeAnthropic INVOKE" => {
            return new RuntimeAnthropicModelProvider(CLAUDE_SONNET_4_6, TEST_CREDS, "us-east-1", INVOKE, ep);
        }
        "RuntimeAnthropic MESSAGES" => {
            return new RuntimeAnthropicModelProvider(CLAUDE_SONNET_4_6, TEST_CREDS, "us-east-1", MESSAGES, ep);
        }
        "RuntimeOpenAI CONVERSE" => {
            return new RuntimeOpenAIModelProvider(GPT_OSS_120B, TEST_CREDS, "us-east-1", endpoint = ep);
        }
        "RuntimeOpenAI INVOKE" => {
            return new RuntimeOpenAIModelProvider(GPT_OSS_120B, TEST_CREDS, "us-east-1", INVOKE, ep);
        }
        "RuntimeOpenAI CHAT_COMPLETIONS" => {
            return new RuntimeOpenAIModelProvider(GPT_OSS_120B, TEST_CREDS, "us-east-1", CHAT_COMPLETIONS, ep);
        }
        "RuntimeOpenAI RESPONSES" => {
            return new RuntimeOpenAIModelProvider("us.openai.gpt-5.6-sol", TEST_CREDS, "us-east-1", RESPONSES, ep);
        }
        "RuntimeAmazon CONVERSE" => {
            return new RuntimeAmazonModelProvider(NOVA_PRO, TEST_CREDS, "us-east-1", endpoint = ep);
        }
        "RuntimeAmazon INVOKE" => {
            return new RuntimeAmazonModelProvider(NOVA_PRO, TEST_CREDS, "us-east-1", INVOKE, ep);
        }
        "RuntimeMistral CONVERSE" => {
            return new RuntimeMistralModelProvider(MISTRAL_LARGE_3, TEST_CREDS, "us-east-1", endpoint = ep);
        }
        "RuntimeMistral INVOKE" => {
            return new RuntimeMistralModelProvider(MISTRAL_LARGE_3, TEST_CREDS, "us-east-1", INVOKE, ep);
        }
        "RuntimeMistral CHAT_COMPLETIONS" => {
            return new RuntimeMistralModelProvider(MISTRAL_LARGE_3, TEST_CREDS, "us-east-1", CHAT_COMPLETIONS, ep);
        }
        "RuntimeQwen CONVERSE" => {
            return new RuntimeQwenModelProvider(QWEN3_32B, TEST_CREDS, "us-east-1", endpoint = ep);
        }
        "RuntimeQwen INVOKE" => {
            return new RuntimeQwenModelProvider(QWEN3_32B, TEST_CREDS, "us-east-1", INVOKE, ep);
        }
        "RuntimeQwen CHAT_COMPLETIONS" => {
            return new RuntimeQwenModelProvider(QWEN3_32B, TEST_CREDS, "us-east-1", CHAT_COMPLETIONS, ep);
        }
        "RuntimeGoogle CONVERSE" => {
            return new RuntimeGoogleModelProvider(GEMMA_3_27B_IT, TEST_CREDS, "us-east-1", endpoint = ep);
        }
        "RuntimeGoogle INVOKE" => {
            return new RuntimeGoogleModelProvider(GEMMA_3_27B_IT, TEST_CREDS, "us-east-1", INVOKE, ep);
        }
        "RuntimeGoogle CHAT_COMPLETIONS" => {
            return new RuntimeGoogleModelProvider(GEMMA_3_27B_IT, TEST_CREDS, "us-east-1", CHAT_COMPLETIONS, ep);
        }
        "RuntimeDeepSeek CONVERSE" => {
            return new RuntimeDeepSeekModelProvider(DEEPSEEK_V3_2, TEST_CREDS, "us-east-1", endpoint = ep);
        }
        "RuntimeDeepSeek INVOKE" => {
            return new RuntimeDeepSeekModelProvider(DEEPSEEK_V3_2, TEST_CREDS, "us-east-1", INVOKE, ep);
        }
        "RuntimeDeepSeek CHAT_COMPLETIONS" => {
            return new RuntimeDeepSeekModelProvider(DEEPSEEK_V3_2, TEST_CREDS, "us-east-1", CHAT_COMPLETIONS, ep);
        }
        "CommonModelProvider" => {
            return new CommonModelProvider("us.meta.llama3-3-70b-instruct-v1:0", TEST_CREDS, "us-east-1", ep);
        }
        "MantleAnthropic" => {
            return new MantleAnthropicModelProvider(MANTLE_CLAUDE_SONNET_5, TEST_CREDS, "us-east-1", ep);
        }
        "MantleOpenAI GPT-5.4" => {
            return new MantleOpenAIModelProvider(MANTLE_GPT_5_4, TEST_CREDS, "us-east-1", ep);
        }
        "MantleOpenAI gpt-oss" => {
            return new MantleOpenAIModelProvider(MANTLE_GPT_OSS_120B, TEST_CREDS, "us-east-1", ep);
        }
        "MantleMistral" => {
            return new MantleMistralModelProvider(MANTLE_MISTRAL_LARGE_3, TEST_CREDS, "us-east-1", ep);
        }
        "MantleQwen" => {
            return new MantleQwenModelProvider(MANTLE_QWEN3_32B, TEST_CREDS, "us-east-1", ep);
        }
        "MantleGoogle" => {
            return new MantleGoogleModelProvider(MANTLE_GEMMA_3_27B_IT, TEST_CREDS, "us-east-1", ep);
        }
        "MantleDeepSeek" => {
            return new MantleDeepSeekModelProvider(MANTLE_DEEPSEEK_V3_2, TEST_CREDS, "us-east-1", ep);
        }
    }
    return error(string `no provider case named '${name}'`);
}

@test:Config {}
function testEveryProviderChats() returns error? {
    foreach [string, boolean] [name, _] in providerCases() {
        ai:ModelProvider provider = check matrixProvider(name);
        ai:ChatAssistantMessage|ai:Error reply = provider->chat([
            {role: ai:SYSTEM, content: "Be brief."},
            {role: ai:USER, content: "Say OK."}
        ]);
        if reply is ai:Error {
            test:assertFail(string `${name}: ${errorText(reply)}`);
        }
        test:assertEquals(reply.content, "OK", name);
    }
}

@test:Config {}
function testEveryProviderGeneratesAString() returns error? {
    foreach [string, boolean] [name, _] in providerCases() {
        ai:ModelProvider provider = check matrixProvider(name);
        string|ai:Error text = provider->generate(`Say OK.`);
        if text is ai:Error {
            test:assertFail(string `${name}: ${errorText(text)}`);
        }
        test:assertEquals(text, "OK", name);
    }
}

@test:Config {}
function testEveryProviderGeneratesATypedResultOrRefusesClearly() returns error? {
    foreach [string, boolean] [name, refused] in providerCases() {
        ai:ModelProvider provider = check matrixProvider(name);
        MatrixPoint|ai:Error point = provider->generate(`Give me a point.`);
        if refused {
            test:assertTrue(point is ai:LlmInvalidGenerationError, string `${name} must refuse a typed target`);
            continue;
        }
        if point is ai:Error {
            test:assertFail(string `${name}: ${errorText(point)}`);
        }
        test:assertEquals(point, <MatrixPoint>{x: 1, y: 2}, name);
    }
}

@test:Config {}
function testEveryProviderCompletesAnAgentLoop() returns error? {
    foreach [string, boolean] [name, _] in providerCases() {
        ai:ModelProvider provider = check matrixProvider(name);
        int callsBefore = readMatrixToolCalls();
        ai:Agent agent = check new (
            systemPrompt = {role: "Weather assistant", instructions: "Use the tool to answer."},
            model = provider,
            tools = [getMatrixWeather]
        );
        string|ai:Error answer = agent.run("What is the weather in Paris?");
        if answer is ai:Error {
            test:assertFail(string `${name}: ${errorText(answer)}`);
        }
        test:assertEquals(answer, MATRIX_FINAL_ANSWER, name);
        test:assertEquals(readMatrixToolCalls(), callsBefore + 1, string `${name}: the tool must run exactly once`);
    }
}
