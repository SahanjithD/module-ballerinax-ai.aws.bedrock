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

// typedesc to JSON schema for generate(), ported from ai.openai's `to_json_schema.bal`.
// Uses the `@ai:JsonSchema` annotation the `ai` compiler plugin adds for records, else
// `Native` for arrays, unions and simple types. A type neither covers is an error.

import ballerina/ai;
import ballerina/jballerina.java;

isolated function generateJsonSchemaForTypedescAsJson(typedesc<json> expectedResponseTypedesc)
        returns map<json>|ai:Error =>
    let map<json>? ann = expectedResponseTypedesc.@ai:JsonSchema in ann
                ?: check generateJsonSchemaForTypedescNative(expectedResponseTypedesc);

isolated function generateJsonSchemaForTypedescNative(typedesc<anydata> td) returns map<json>|ai:Error = @java:Method {
    'class: "io.ballerina.lib.ai.aws.bedrock.Native"
} external;
