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

// typedesc -> JSON schema for generate()'s expected response type (CLAUDE.md §3).
// Ported from the reference module module-ballerinax-ai.openai (`to_json_schema.bal`)
// so this module owns its schema generation, as its siblings do.
//
// Resolution order, per the reference:
//   1. the `@ai:JsonSchema` annotation ballerina/ai's compiler plugin attaches at
//      the generate() call site (records),
//   2. runtime generation in this module's `Native` (arrays, unions, simple types),
//   3. the pure-Ballerina fallback below.
// A type none of them can express is an `ai:Error` — never a silently empty schema.

import ballerina/ai;
import ballerina/jballerina.java;

type JsonSchema record {|
    string 'type?;
    (JsonSchema|JsonArraySchema)[] oneOf?;
    map<JsonSchema|JsonArraySchema|map<json>> properties?;
    string[] required?;
|};

type JsonArraySchema record {|
    string 'type = "array";
    JsonSchema items;
|};

isolated function generateJsonSchemaForTypedescAsJson(typedesc<json> expectedResponseTypedesc)
        returns map<json>|ai:Error =>
    let map<json>? ann = expectedResponseTypedesc.@ai:JsonSchema in ann
                ?: check generateJsonSchemaForTypedescNative(expectedResponseTypedesc)
                ?: check generateJsonSchemaForTypedesc(expectedResponseTypedesc,
                        containsNil(expectedResponseTypedesc));

isolated function generateJsonSchemaForTypedesc(typedesc<json> expectedResponseTypedesc, boolean nilableType)
        returns JsonSchema|JsonArraySchema|map<json>|ai:Error {
    if isSimpleType(expectedResponseTypedesc) {
        return <JsonSchema>{
            'type: getStringRepresentation(<typedesc<json>>expectedResponseTypedesc)
        };
    }

    boolean isArray = expectedResponseTypedesc is typedesc<json[]>;

    if isArray {
        typedesc<json> arrayMemberType = getArrayMemberType(<typedesc<json[]>>expectedResponseTypedesc);
        if isSimpleType(arrayMemberType) {
            return <JsonArraySchema>{
                items: !nilableType ? {
                        'type: getStringRepresentation(<typedesc<json>>arrayMemberType)
                    } :
                    {
                        oneOf: [
                            {
                                'type: getStringRepresentation(<typedesc<json>>arrayMemberType)
                            },
                            {
                                'type: "null"
                            }
                        ]
                    }
            };
        }
    }

    return error("Runtime schema generation is not yet supported for type " + expectedResponseTypedesc.toString());
}

isolated function getArrayMemberType(typedesc<json> expectedResponseTypedesc) returns typedesc<json> = @java:Method {
    name: "getArrayMemberType",
    'class: "io.ballerina.lib.ai.aws.bedrock.Native"
} external;

isolated function containsNil(typedesc<json> expectedResponseTypedesc) returns boolean = @java:Method {
    name: "containsNil",
    'class: "io.ballerina.lib.ai.aws.bedrock.Native"
} external;

isolated function isSimpleType(typedesc<json> expectedResponseTypedesc) returns boolean =>
    expectedResponseTypedesc is typedesc<string|int|float|decimal|boolean|()>;

isolated function getStringRepresentation(typedesc<json> fieldType) returns string {
    if fieldType is typedesc<()> {
        return "null";
    }
    if fieldType is typedesc<string> {
        return "string";
    }
    if fieldType is typedesc<int> {
        return "integer";
    }
    if fieldType is typedesc<float|decimal> {
        return "number";
    }
    if fieldType is typedesc<boolean> {
        return "boolean";
    }

    panic error("JSON schema generation is not yet supported for type: " + fieldType.toString());
}

isolated function generateJsonSchemaForTypedescNative(typedesc<anydata> td) returns map<json>?|ai:Error = @java:Method {
    'class: "io.ballerina.lib.ai.aws.bedrock.Native"
} external;
