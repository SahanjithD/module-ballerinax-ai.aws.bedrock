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
import ballerina/time;
import ballerina/uuid;

// Pure conversions between `ai` types and the knowledge-base wire shapes.

const string KB_CONTENT_TYPE_TEXT = "TEXT";

// Bedrock's limits on inline metadata, checked here for a clearer error than a 400.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_DocumentMetadata.html
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_MetadataAttribute.html
const int MAX_INLINE_ATTRIBUTES = 50;
const int MAX_METADATA_KEY_LENGTH = 200;
const int MAX_STRING_VALUE_LENGTH = 2048;
const int MAX_STRING_LIST_LENGTH = 10;

// `ai:Metadata`'s typed fields. Each needs converting both ways: a `time:Utc` is a tuple
// that would otherwise look like a string list, and Bedrock returns every number as a
// `decimal`, which would panic if written into an `int` field.
final readonly & string[] METADATA_INT_FIELDS = ["id", "index", "prev"];
final readonly & string[] METADATA_UTC_FIELDS = ["createdAt", "modifiedAt"];
final readonly & string[] METADATA_STRING_FIELDS = [
    "mimeType", "fileName", "header", "language",
    "header1", "header2", "header3", "header4", "header5", "header6"
];
const string METADATA_DECIMAL_FIELD = "fileSize";

// An `ai:Chunk` or `ai:Document` as a `KnowledgeBaseDocument`, plus the id it was given
// (needed to poll its status). Only text is supported; anything else is an error.
isolated function chunkToKnowledgeBaseDocument(string providerName, ai:Chunk|ai:Document chunk,
        int? chunkOrdinal = ()) returns [json, string]|ai:Error {
    string content;
    if chunk is ai:TextChunk {
        content = chunk.content;
    } else if chunk is ai:TextDocument {
        content = chunk.content;
    } else {
        return error ai:Error(
            string `Unsupported document type '${chunk.'type}': ${providerName} only ingests ` +
            "text content ('ai:TextChunk'/'ai:TextDocument'). Convert non-text content to text before ingesting.");
    }

    ai:Metadata? metadata = chunk.metadata;
    string documentId = documentIdFor(metadata, chunkOrdinal);

    map<json> documentJson = {
        content: {
            dataSourceType: "CUSTOM",
            custom: {
                sourceType: "IN_LINE",
                customDocumentIdentifier: {id: documentId},
                inlineContent: {'type: "TEXT", textContent: {data: content}}
            }
        }
    };
    if metadata is ai:Metadata {
        json? metadataJson = check metadataToDocumentMetadata(metadata);
        // `()` is a `json` value, so `metadataJson is json` would send `null`.
        if metadataJson !is () {
            documentJson["metadata"] = metadataJson;
        }
    }
    return [documentJson, documentId];
}

// `ai:Metadata.id` as a string when set, so ids can be stable; otherwise a new UUID.
isolated function documentIdFrom(ai:Metadata? metadata) returns string? {
    if metadata is () {
        return ();
    }
    int? id = metadata.id;
    return id is int ? id.toString() : ();
}

// The id submitted for one document. Chunks of a document split into several get
// `<id>#<n>`: chunkers copy the parent's `id`, and Bedrock upserts by id, so they would
// otherwise overwrite each other. A single chunk keeps the caller's id. `#` cannot
// clash with a caller id, which is always a number.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CustomDocumentIdentifier.html
isolated function documentIdFor(ai:Metadata? metadata, int? chunkOrdinal) returns string {
    string? derived = documentIdFrom(metadata);
    if derived is () {
        // No caller id: each chunk already gets its own UUID.
        return uuid:createRandomUuid();
    }
    return chunkOrdinal is int ? string `${derived}#${chunkOrdinal}` : derived;
}

// `ai:Metadata` as inline attributes, or `()` when there is nothing to send.
isolated function metadataToDocumentMetadata(ai:Metadata metadata) returns json?|ai:Error {
    json[] attributes = [];
    foreach [string, json] [key, value] in metadata.entries() {
        if value is () {
            continue;
        }
        if key.length() > MAX_METADATA_KEY_LENGTH {
            return error ai:Error(
                string `Metadata key '${key}' exceeds Bedrock's ${MAX_METADATA_KEY_LENGTH}-character limit`);
        }
        attributes.push({key, value: check toMetadataAttributeValue(key, value)});
    }
    if attributes.length() == 0 {
        return ();
    }
    if attributes.length() > MAX_INLINE_ATTRIBUTES {
        return error ai:Error(
            string `${attributes.length()} metadata attributes exceed Bedrock's ` +
            string `${MAX_INLINE_ATTRIBUTES}-attribute-per-document limit`);
    }
    return {'type: "IN_LINE_ATTRIBUTE", inlineAttributes: attributes};
}

// One metadata value as a `MetadataAttributeValue`: boolean, number, string or string
// list. Anything else is an error rather than dropped.
isolated function toMetadataAttributeValue(string key, json value) returns json|ai:Error {
    // Before the array branch: a `time:Utc` is a tuple. Sent as an RFC 3339 string.
    if METADATA_UTC_FIELDS.indexOf(key) is int {
        time:Utc|error utc = value.cloneWithType();
        if utc is error {
            return error ai:Error(
                string `Metadata key '${key}' is declared 'time:Utc' but holds ${value.toJsonString()}, ` +
                "which is not a valid UTC timestamp", utc);
        }
        return {'type: "STRING", stringValue: time:utcToString(utc)};
    }
    if value is boolean {
        return {'type: "BOOLEAN", booleanValue: value};
    }
    if value is int || value is float || value is decimal {
        return {'type: "NUMBER", numberValue: <float>value};
    }
    if value is string {
        if value.length() > MAX_STRING_VALUE_LENGTH {
            return error ai:Error(string `Metadata value for key '${key}' exceeds Bedrock's ` +
                string `${MAX_STRING_VALUE_LENGTH}-character 'STRING' limit`);
        }
        return {'type: "STRING", stringValue: value};
    }
    if value is json[] {
        if value.length() > MAX_STRING_LIST_LENGTH {
            return error ai:Error(string `Metadata value for key '${key}' has ${value.length()} entries, ` +
                string `exceeding Bedrock's ${MAX_STRING_LIST_LENGTH}-entry 'STRING_LIST' limit`);
        }
        string[] items = [];
        foreach json item in value {
            if item !is string {
                return error ai:Error(
                    string `Metadata key '${key}' is an array containing a non-string element ` +
                    string `(${item.toJsonString()}); only string arrays map to Bedrock's 'STRING_LIST'`);
            }
            items.push(item);
        }
        return {'type: "STRING_LIST", stringListValue: items};
    }
    return error ai:Error(
        string `Metadata key '${key}' has a value Bedrock cannot represent as an inline attribute ` +
        string `(supported: boolean, number, string, string[]); got ${value.toJsonString()}`);
}

// A retrieval result as an `ai:QueryMatch`. Only text results are supported. Metadata
// is passed through, including Bedrock's own `_`-prefixed attributes.
isolated function retrievalResultToQueryMatch(string providerName, json result) returns ai:QueryMatch|ai:Error {
    map<json> resultMap = result is map<json> ? result : {};
    json contentJson = resultMap["content"] ?: {};
    map<json> content = contentJson is map<json> ? contentJson : {};
    json contentTypeJson = content["type"] ?: KB_CONTENT_TYPE_TEXT;
    string contentType = contentTypeJson is string ? contentTypeJson : contentTypeJson.toString();
    if contentType != KB_CONTENT_TYPE_TEXT {
        return error ai:Error(
            string `${providerName} only supports TEXT retrieval results; got '${contentType}'. ` +
            "Non-text content (IMAGE/ROW/AUDIO/VIDEO) has no 'ai:TextChunk'-shaped representation.");
    }
    json textJson = content["text"] ?: "";
    string text = textJson is string ? textJson : textJson.toString();

    json metadataJson = resultMap["metadata"] ?: {};
    ai:Metadata metadata = check metadataFromRetrievalResult(metadataJson is map<json> ? metadataJson : {});

    json scoreJson = resultMap["score"] ?: 0;
    float similarityScore = toFloatScore(scoreJson);

    ai:TextChunk chunk = {content: text, metadata};
    return {chunk, similarityScore};
}

// Bedrock's metadata back into `ai:Metadata`, converting each typed field (a direct
// write would panic, since numbers come back as `decimal`). Other keys go into the
// rest field as they are.
isolated function metadataFromRetrievalResult(map<json> attributes) returns ai:Metadata|ai:Error {
    ai:Metadata metadata = {};
    foreach [string, json] [key, value] in attributes.entries() {
        if METADATA_INT_FIELDS.indexOf(key) is int {
            int? narrowed = narrowToInt(value);
            if narrowed is () {
                return error ai:Error(
                    string `Retrieval result metadata key '${key}' is declared 'int' on 'ai:Metadata' but ` +
                    string `Bedrock returned ${value.toJsonString()}, which cannot be narrowed to an int ` +
                    "without loss");
            }
            metadata[key] = narrowed;
        } else if key == METADATA_DECIMAL_FIELD {
            decimal? narrowed = narrowToDecimal(value);
            if narrowed is () {
                return error ai:Error(
                    string `Retrieval result metadata key '${key}' is declared 'decimal' on 'ai:Metadata' ` +
                    string `but Bedrock returned ${value.toJsonString()}`);
            }
            metadata[key] = narrowed;
        } else if METADATA_UTC_FIELDS.indexOf(key) is int {
            // The reverse of the RFC 3339 string sent on ingest.
            time:Utc|error utc = value is string ? time:utcFromString(value) : error("not a string");
            if utc is error {
                return error ai:Error(
                    string `Retrieval result metadata key '${key}' is declared 'time:Utc' on 'ai:Metadata' ` +
                    string `but Bedrock returned ${value.toJsonString()}, which is not an RFC 3339 timestamp`);
            }
            metadata[key] = utc;
        } else if METADATA_STRING_FIELDS.indexOf(key) is int {
            if value !is string {
                return error ai:Error(
                    string `Retrieval result metadata key '${key}' is declared 'string' on 'ai:Metadata' but ` +
                    string `Bedrock returned ${value.toJsonString()}`);
            }
            metadata[key] = value;
        } else {
            metadata[key] = value;
        }
    }
    return metadata;
}

// `json` as an `int` only when lossless; `<int>` would round 3.7 to 4.
isolated function narrowToInt(json value) returns int? {
    if value is int {
        return value;
    }
    if value is decimal {
        int|error narrowed = value.cloneWithType();
        return narrowed is int && <decimal>narrowed == value ? narrowed : ();
    }
    if value is float {
        int|error narrowed = value.cloneWithType();
        return narrowed is int && <float>narrowed == value ? narrowed : ();
    }
    return ();
}

isolated function narrowToDecimal(json value) returns decimal? {
    if value is decimal {
        return value;
    }
    if value is int {
        return <decimal>value;
    }
    if value is float {
        decimal|error narrowed = value.cloneWithType();
        return narrowed is decimal ? narrowed : ();
    }
    return ();
}

isolated function toFloatScore(json value) returns float {
    if value is float {
        return value;
    }
    if value is int {
        return <float>value;
    }
    if value is decimal {
        return <float>value;
    }
    return 0.0;
}
