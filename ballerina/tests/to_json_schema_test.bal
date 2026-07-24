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

// typedesc -> JSON schema (`to_json_schema.bal`).
//
// The generate() tests assert the schema reaches the wire as a forced tool, but
// they hand-write it — so DERIVATION itself was untested. It is the step that can
// fail silently: an undescribed type yields no schema, the model is told "an object
// with no properties", and it answers in prose. These assert the derived value.

type SchemaProbe record {|
    string sentiment;
    int score;
|};

// `T[]` is not a typedesc expression — the array target types need names.
type SchemaProbeArray SchemaProbe[];

type StringArray string[];

// Records get their schema from an `@ai:JsonSchema` annotation that ballerina/ai's
// compiler plugin attaches AT THE generate() CALL SITE — not from the type
// declaration. This call site is what annotates `SchemaProbe`; it is deliberately
// typed with the CONCRETE provider class (how users write it), which is the case
// that would break if the annotation only fired for the `ai:ModelProvider`
// interface. Never executed — the plugin rewrites source, so existing is enough.
function schemaProbeCallSite(AnthropicModelProvider provider) returns error? {
    SchemaProbe _ = check provider->generate(`rate this`);
    SchemaProbe[] _ = check provider->generate(`rate these`);
}

@test:Config {}
function testSchemaIsDerivedForARecordTargetType() returns error? {
    map<json> schema = check generateJsonSchemaForTypedescAsJson(SchemaProbe);
    test:assertEquals(schema["type"], "object");
    test:assertEquals(schema["properties"],
            <json>{"sentiment": {"type": "string"}, "score": {"type": "integer", "format": "int64"}},
            "every field must reach the schema with its JSON type");
    string[] required = check schema["required"].cloneWithType();
    test:assertEquals(required.sort(), ["score", "sentiment"],
            "required fields must be listed, or the model may omit them");
}

@test:Config {}
function testSchemaIsDerivedForAnArrayOfRecords() returns error? {
    map<json> schema = check generateJsonSchemaForTypedescAsJson(SchemaProbeArray);
    test:assertEquals(schema["type"], "array");
    map<json> items = check schema["items"].ensureType();
    test:assertEquals(items["type"], "object", "the element schema must be the record's, not empty");
}

@test:Config {}
function testSchemaIsDerivedForSimpleAndArrayTargetTypes() returns error? {
    // No call site and no annotation: these come from the structural path.
    test:assertEquals(check generateJsonSchemaForTypedescAsJson(int), <map<json>>{"type": "integer"});
    test:assertEquals(check generateJsonSchemaForTypedescAsJson(string), <map<json>>{"type": "string"});
    test:assertEquals(check generateJsonSchemaForTypedescAsJson(boolean), <map<json>>{"type": "boolean"});
    test:assertEquals(check generateJsonSchemaForTypedescAsJson(float), <map<json>>{"type": "number"});
    test:assertEquals(check generateJsonSchemaForTypedescAsJson(StringArray),
            <map<json>>{"type": "array", "items": {"type": "string"}});
}

@test:Config {}
function testSchemaGenerationFailsLoudlyForAnUndescribableType() {
    // A record with NO generate() call site is never annotated, so nothing can
    // describe it. This MUST be an error: the previous implementation mapped this
    // case to (), and the caller substituted an empty schema — the model then
    // received "return an object with no properties" and generate() failed later
    // with a confusing "no tool call", far from the real cause.
    map<json>|ai:Error schema = generateJsonSchemaForTypedescAsJson(UnannotatedProbe);
    test:assertTrue(schema is ai:Error,
            "an undescribable type must error, never silently yield an empty schema");
}

type UnannotatedProbe record {|
    string name;
|};

@test:Config {}
function testSchemaForRejectsATargetTypeOutsideJson() {
    // `generate()` accepts typedesc<anydata>, but a non-json type cannot be
    // expressed as a JSON schema at all.
    map<json>|ai:Error result = schemaFor(NonJsonProbe);
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        test:assertTrue(result.message().includes("json"),
                "the error should say the type must be a subtype of json; got: " + result.message());
    }
}

// `xml` is anydata but not json. (`byte[]` is NOT a counter-example: byte is a
// subtype of int, so a byte[] field keeps the record inside json.)
type NonJsonProbe record {|
    xml doc;
|};
