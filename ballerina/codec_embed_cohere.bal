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

// Cohere Embed (embedding design §1, §6, §7). Like Mistral on the chat side,
// Cohere ships TWO request shapes under one vendor prefix, and only the model id
// tells them apart:
//
//   v3 — {"texts": [string] (0..96), "input_type": REQUIRED,
//         "truncate": "NONE|START|END", "embedding_types": [...]}
//        NO output-size parameter exists at all; vectors are always 1024.
//        https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-embed-v3.html
//   v4 — {"texts": [...], "input_type": REQUIRED,
//         "truncate": "NONE|LEFT|RIGHT", "output_dimension": 256|512|1024|1536,
//         "embedding_types": [...], "max_tokens": int}
//        https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-embed-v4.html
//
// The two differ on BOTH names that matter: the size parameter is `output_dimension`
// (not `dimensions`), and truncate's non-NONE values are LEFT/RIGHT (not START/END).
// Response shape is common to both — `inputTokenCount` is `()` either way.

// Cohere accepts up to 96 texts per call (embedding design §1) — the WIRE limit.
const int COHERE_MAX_BATCH = 96;

// Cohere Embed v3 — no output-size parameter, truncate spelled START/END.
final readonly & EmbeddingCodec COHERE_EMBED_V3_CODEC = {
    maxBatchSize: COHERE_MAX_BATCH,
    encode: encodeCohereEmbedV3,
    decode: decodeCohereEmbed
};

// Cohere Embed v4 — `output_dimension`, truncate spelled LEFT/RIGHT.
final readonly & EmbeddingCodec COHERE_EMBED_V4_CODEC = {
    maxBatchSize: COHERE_MAX_BATCH,
    encode: encodeCohereEmbedV4,
    decode: decodeCohereEmbed
};

// Cohere Embed ids speaking the v4 request shape. An allowlist of v4 (rather than
// of v3) would misroute every future id, so this matches the v4 family and lets
// everything else fall to v3 — the shape the `-english-v3`/`-multilingual-v3` ids
// use today.
isolated function usesCohereEmbedV4(string modelId) returns boolean =>
    modelId.startsWith("cohere.embed-v4");

// The shared part of both request shapes (embedding design §6, §7). `input_type` is
// REQUIRED on every request — omitting it is a 400, and the wrong value silently
// degrades retrieval.
isolated function cohereEmbedBase(string[] texts, EmbeddingParams params) returns map<json>|ai:Error {
    if texts.length() > COHERE_MAX_BATCH {
        return error ai:Error(string `Cohere accepts at most ${COHERE_MAX_BATCH} texts per call; ` +
            string `got ${texts.length()}. This is a batching bug.`);
    }
    CohereInputType? inputType = params?.inputType;
    if inputType is () {
        return error ai:Error("Cohere requires 'input_type' on every embedding request (design §6)");
    }
    return {"texts": texts, "input_type": inputType}; // an ARRAY, never a string
}

// Merges the §9.3-style passthrough last, so a caller can always override us.
isolated function cohereApplyExtra(map<json> body, EmbeddingParams params) returns json {
    json extra = params?.additionalModelRequestFields;
    if extra is map<json> {
        foreach [string, json] [k, v] in extra.entries() {
            body[k] = v;
        }
    }
    return body;
}

// Encodes a Cohere Embed **v3** request.
isolated function encodeCohereEmbedV3(string[] texts, EmbeddingParams params) returns json|ai:Error {
    map<json>|ai:Error base = cohereEmbedBase(texts, params);
    if base is ai:Error {
        return base;
    }
    map<json> body = base;
    Truncate? truncate = params?.truncate;
    if truncate is Truncate {
        body["truncate"] = truncate; // v3 spells these NONE|START|END — our enum's own values
    }
    // v3 has NO output-size parameter. `dimensions` is rejected at construction
    // rather than silently dropped here (embedding design §8).
    return cohereApplyExtra(body, params);
}

// Encodes a Cohere Embed **v4** request.
isolated function encodeCohereEmbedV4(string[] texts, EmbeddingParams params) returns json|ai:Error {
    map<json>|ai:Error base = cohereEmbedBase(texts, params);
    if base is ai:Error {
        return base;
    }
    map<json> body = base;
    Truncate? truncate = params?.truncate;
    if truncate is Truncate {
        // v4 renamed the non-NONE values: START→LEFT, END→RIGHT. Same meaning
        // ("discard from the start / the end"), so the public enum keeps one
        // spelling and we translate here rather than leaking the version into it.
        body["truncate"] = cohereV4Truncate(truncate);
    }
    int? dimensions = params?.dimensions;
    if dimensions is int {
        body["output_dimension"] = dimensions; // NOT `dimensions` — v4's own name
    }
    return cohereApplyExtra(body, params);
}

// START→LEFT, END→RIGHT per the v4 parameter page; NONE is unchanged.
isolated function cohereV4Truncate(Truncate truncate) returns string {
    match truncate {
        TRUNCATE_START => {
            return "LEFT";
        }
        TRUNCATE_END => {
            return "RIGHT";
        }
    }
    return "NONE";
}

// Decodes a Cohere embedding response (embedding design §7). Cohere reports NO
// token count — `inputTokenCount` is `()`, and the span call must be guarded.
isolated function decodeCohereEmbed(json response) returns DecodedEmbedding|ai:Error {
    map<json>|error rr = response.ensureType();
    if rr is error {
        return error ai:LlmInvalidResponseError("Cohere embedding response was not a JSON object", rr);
    }
    map<json> r = rr;

    // v3 returns `embeddings: [[float]]`; v4 with embedding_types returns
    // `embeddings: {"float": [[float]]}`. Accept both.
    json[]? rows = arrField(r, "embeddings");
    if rows is () {
        map<json>? typed = mapField(r, "embeddings");
        if typed is map<json> {
            rows = arrField(typed, "float");
        }
    }
    if rows is () {
        return error ai:LlmInvalidResponseError("Cohere embedding response had no 'embeddings' field");
    }

    ai:Embedding[] embeddings = [];
    foreach json row in rows {
        if row !is json[] {
            return error ai:LlmInvalidResponseError("Cohere embedding row was not an array of floats");
        }
        ai:Vector|ai:Error vector = toVector(row);
        if vector is ai:Error {
            return vector;
        }
        embeddings.push(vector);
    }
    return {
        embeddings,
        inputTokenCount: (), // Cohere has no such field (embedding design §1, §2)
        responseId: strField(r, "id")
    };
}
