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

// Pure conversions between `ai:Chunk`/`ai:Document`/`ai:QueryMatch` and the Bedrock
// `KnowledgeBaseDocument` / `KnowledgeBaseRetrievalResult` wire shapes. No I/O —
// golden-file testable directly.

const string KB_CONTENT_TYPE_TEXT = "TEXT";

// Bedrock's own limits on `DocumentMetadata.inlineAttributes` — validated here so a
// caller sees a clear message instead of an opaque 400 from `IngestKnowledgeBaseDocuments`.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_DocumentMetadata.html
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_MetadataAttribute.html
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_MetadataAttributeValue.html
const int MAX_INLINE_ATTRIBUTES = 50;
const int MAX_METADATA_KEY_LENGTH = 200;
const int MAX_STRING_VALUE_LENGTH = 2048;
const int MAX_STRING_LIST_LENGTH = 10;

// `ai:Metadata` (ballerina/ai `document-types.bal`) is an open record whose DECLARED
// fields are TYPED — `int id|index|prev`, `decimal fileSize`, `time:Utc
// createdAt|modifiedAt`, and ten `string` fields — with a `json...` rest field
// underneath. Both directions of the conversion have to respect those types:
//
//   - OUTBOUND, `time:Utc` is a TUPLE (`readonly & [int, decimal]`), so it reaches
//     `toMetadataAttributeValue` as a `json[]` and would hit the STRING_LIST branch
//     and be rejected for holding non-string elements. Any document that has been
//     through Ballerina's own chunkers or loaders carries one.
//   - INBOUND, writing a raw `json` into a typed field is an inherent type violation
//     that PANICS (not an `ai:Error`) and kills the strand. Bedrock stores every
//     numeric metadata attribute as `NUMBER` and answers with a `decimal` even for a
//     value submitted as an `int`, so `metadata["id"] = <decimal>` is the ordinary
//     case, not an edge one.
//
// Listed by name, which is safe precisely because these names are DECLARED fields:
// a value under one of them can only ever be that field's type.
final readonly & string[] METADATA_INT_FIELDS = ["id", "index", "prev"];
final readonly & string[] METADATA_UTC_FIELDS = ["createdAt", "modifiedAt"];
final readonly & string[] METADATA_STRING_FIELDS = [
    "mimeType", "fileName", "header", "language",
    "header1", "header2", "header3", "header4", "header5", "header6"
];
const string METADATA_DECIMAL_FIELD = "fileSize";

// `ai:Chunk`/`ai:Document` -> a `KnowledgeBaseDocument` JSON fragment (the
// `documents[]` array element for `IngestKnowledgeBaseDocuments`), plus the
// `customDocumentIdentifier.id` it was given — the caller needs that id back to
// poll `GetKnowledgeBaseDocuments` for the document it just submitted.
//
// Only `ai:TextChunk`/`ai:TextDocument` are supported: a non-text chunk returns a
// clean `ai:Error` rather than being silently dropped from the batch, matching this
// module's existing multimodal stance (see content_parts.bal).
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
        // `metadataJson is json` would NOT reject nil — `()` is a member of `json` —
        // and would put `"metadata": null` on an ingest document that simply has no
        // metadata, rather than omitting the field.
        if metadataJson !is () {
            documentJson["metadata"] = metadataJson;
        }
    }
    return [documentJson, documentId];
}

// The document id to submit: `ai:Metadata.id` (an int field already on the shared
// `ai` module type) stringified when present, so a caller who wants deterministic,
// re-ingestable ids can supply one; otherwise a fresh UUID, mirroring the Azure
// knowledge base precedent's fallback.
isolated function documentIdFrom(ai:Metadata? metadata) returns string? {
    if metadata is () {
        return ();
    }
    int? id = metadata.id;
    return id is int ? id.toString() : ();
}

// The id actually submitted for one document.
//
// `chunkOrdinal` is set ONLY for chunks this module produced client-side from a
// parent that fanned out into more than one — see `applyChunker`. It exists because
// Ballerina's chunkers COPY the parent document's metadata, `id` included, onto every
// chunk (verified against `ai:GenericRecursiveChunker`: 14 chunks, all carrying the
// parent's `id`), while Bedrock UPSERTS by `customDocumentIdentifier.id`. Without a
// per-chunk id, a document that split into 20 pieces submits 20 documents under one
// id, each overwriting the last: one chunk survives, 19 are silently discarded, and
// `ingest()` reports complete success.
//
// A parent that produced exactly ONE chunk keeps the caller's own id — rewriting the
// id of a document that never fanned out would orphan whatever was ingested under it
// before, for no correctness gain.
//
// `#` is safe as a separator: `CustomDocumentIdentifier.id` has no pattern and allows
// 1-2048 characters, and every caller-supplied id is a stringified `ai:Metadata.id`
// (an `int`), so no caller id can collide with a generated one.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CustomDocumentIdentifier.html
isolated function documentIdFor(ai:Metadata? metadata, int? chunkOrdinal) returns string {
    string? derived = documentIdFrom(metadata);
    if derived is () {
        // No caller id at all: every chunk already gets its own UUID, so there is
        // nothing to disambiguate.
        return uuid:createRandomUuid();
    }
    return chunkOrdinal is int ? string `${derived}#${chunkOrdinal}` : derived;
}

// `ai:Metadata` -> `DocumentMetadata` (`IN_LINE_ATTRIBUTE`). Returns `()` when there
// is nothing to send (an empty or all-`()` metadata record) so the caller omits the
// `metadata` field entirely.
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

// One `ai:Metadata` value -> a typed `MetadataAttributeValue`. Bedrock supports
// exactly four shapes (`BOOLEAN`/`NUMBER`/`STRING`/`STRING_LIST`); anything else
// (nested objects, mixed-type arrays, ...) is a clear `ai:Error` rather than a
// silent drop or a lossy `toString()`.
isolated function toMetadataAttributeValue(string key, json value) returns json|ai:Error {
    // BEFORE the array branch: `time:Utc` is `readonly & [int, decimal]`, so
    // `createdAt`/`modifiedAt` arrive here as a two-element `json[]` and would
    // otherwise be rejected as "an array containing a non-string element" — an error
    // naming STRING_LIST for what is really a standard timestamp field, making any
    // document that has been through Ballerina's chunkers or loaders un-ingestable.
    // Sent as an RFC 3339 `STRING`, which `metadataFromRetrievalResult` parses back
    // symmetrically.
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

// A `KnowledgeBaseRetrievalResult` (one element of `Retrieve`'s `retrievalResults[]`)
// -> `ai:QueryMatch`. Only `content.type == "TEXT"` is supported — `IMAGE`/`ROW`/
// `AUDIO`/`VIDEO` have no `ai:TextChunk`-shaped representation, so they are a clean
// `ai:Error` rather than a silently empty or truncated chunk.
//
// `metadata` is passed through VERBATIM, including the six underscore-prefixed
// system attributes Bedrock injects (`_source_uri`, `_chunk_id`, `_data_source_id`,
// `_data_source_type`, `_file_type`, `_language_code`) — `_source_uri` in particular
// is what makes `deleteByFilter`'s probe possible at all (see knowledgebase_managed.bal).
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

// Bedrock's returned `metadata` map -> `ai:Metadata`, COERCED per declared field.
//
// A blind `metadata[key] = value` panics with an `InherentTypeViolation` the moment a
// declared field's type and the returned JSON's type disagree — which is the ordinary
// case, not an edge one: Bedrock stores every numeric attribute as `NUMBER` and
// answers with a `decimal`, so a document ingested with `metadata.id` (the documented
// way to give a document a stable, re-ingestable id — see `documentIdFrom`) could not
// be retrieved at all. A panic is not an `ai:Error`: it escapes `retrieve()`'s error
// union and kills the strand.
//
// Undeclared keys — including the six underscore-prefixed system attributes Bedrock
// injects (`_source_uri`, `_chunk_id`, `_data_source_id`, `_data_source_type`,
// `_file_type`, `_language_code`) — go through the `json...` rest field verbatim.
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
            // The symmetric half of `toMetadataAttributeValue`'s RFC 3339 STRING.
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
            // Rest field (`json...`): no declared type to violate.
            metadata[key] = value;
        }
    }
    return metadata;
}

// `json` -> `int`, or `()` when the value cannot be represented as one WITHOUT LOSS.
// The round-trip comparison is the point: a plain `<int>` cast rounds half-even, so
// `3.7` would silently become `4`.
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

// `json` -> `decimal`. Widening from `int`/`float` is lossless in the direction that
// matters here, so no round-trip check is needed.
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
