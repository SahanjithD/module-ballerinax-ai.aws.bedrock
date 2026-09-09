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
import ballerinax/aws;
import ballerinax/aws.auth;

// The wire layer for `BedrockVectorKnowledgeBase`. Deliberately SEPARATE from
// knowledgebase_common.bal rather than branching inside it on a knowledge base type:
// the managed class's request bodies and search branch stay untouched, so a change
// here cannot regress it.
//
// Everything type-AGNOSTIC is reused from knowledgebase_common.bal unchanged and is
// not duplicated here — `guardRegion`, `buildAgentEndpoint`, both `BedrockTransport`
// constructions, `listKnowledgeBaseIdsByName`, `getKnowledgeBase`,
// `pollKnowledgeBaseActive`, `failureReasonsOf`, `pollDataSourceAvailable`,
// `getDataSource`, `listDataSources`, `resolveCustomDataSource`,
// `effectiveDataSourceType`, `validateResolvedDataSource`, every document operation, the
// `KB_*` constants, `asMap`/`stringField`/`partitionJson`, plus
// knowledgebase_convert.bal and knowledgebase_filter.bal in full.

// The document-identity metadata attribute injected by Bedrock, used by
// `deleteByFilter` to pin a probe to one document.
//
// SELF-MANAGED USES A DIFFERENT PREFIX FROM MANAGED. AWS documents the split:
// "For custom knowledge bases, metadata fields prefixed with `x-amz-bedrock` are
// reserved by the service. For fully managed knowledge bases, reserved metadata
// fields use an underscore prefix (for example, `_source_uri`, `_data_source_id`).
// You cannot override reserved metadata fields in either knowledge base type."
// https://docs.aws.amazon.com/bedrock/latest/userguide/kb-test-config.html
//
// So `SOURCE_URI_METADATA_KEY` ("_source_uri", knowledgebase_common.bal) is the
// MANAGED spelling and reusing it here would silently match nothing — and a
// `deleteByFilter` that matches nothing deletes nothing, with no error.
//
// That page gives the PREFIX rule but not this exact key. The key itself is listed
// under "Auto-created fields": "`x-amz-bedrock-kb-source-uri`: Original source URI
// for filtering operations".
// https://docs.aws.amazon.com/bedrock/latest/userguide/kb-multimodal-test-and-query.html
//
// UNMEASURED: the key name is documented, but the live-API checks behind this
// module all ran against a MANAGED knowledge base, never a VECTOR one. Two things
// therefore remain assumptions rather than measurements: that Bedrock populates this
// attribute for a CUSTOM data source on a self-managed knowledge base, and that the
// relevance floor `deleteByFilter`'s two-probe disambiguation exists to defeat
// behaves the same way when the scoring is your vector store's rather than Bedrock's.
const string VECTOR_SOURCE_URI_METADATA_KEY = "x-amz-bedrock-kb-source-uri";

// `FixedSizeChunkingConfigurationMaxTokensInteger` in the `bedrock-agent` service
// model (botocore `service-2.json`) is `{"min": 1, "max": 8192}`. The API reference
// documents no maximum, so the service model is the source here.
const int MAX_FIXED_SIZE_CHUNK_TOKENS = 8192;

// `VectorSearchBedrockRerankingConfiguration.numberOfRerankedResults`: min 1, max 100.
const int MAX_RERANKED_RESULTS = 100;

// ============================================================================
// Pure request-body builders. No transport, so every wire shape below is
// assertable without AWS.
// ============================================================================

// Encodes a `StorageConfiguration` into the `storageConfiguration` request field.
//
// `type` is emitted unconditionally: `API_agent_StorageConfiguration.html` marks it
// `Required: Yes`, even though the worked example in `knowledge-base-create.html`
// omits it. The API reference is the shape authority.
isolated function storageConfigurationJson(StorageConfiguration storage) returns json {
    if storage is OpenSearchServerlessStorage {
        return {
            'type: storage.'type,
            opensearchServerlessConfiguration: {
                collectionArn: storage.collectionArn,
                vectorIndexName: storage.vectorIndexName,
                fieldMapping: {
                    vectorField: storage.fieldMapping.vectorField,
                    textField: storage.fieldMapping.textField,
                    metadataField: storage.fieldMapping.metadataField
                }
            }
        };
    }
    if storage is OpenSearchManagedClusterStorage {
        return {
            'type: storage.'type,
            opensearchManagedClusterConfiguration: {
                domainEndpoint: storage.domainEndpoint,
                domainArn: storage.domainArn,
                vectorIndexName: storage.vectorIndexName,
                fieldMapping: {
                    vectorField: storage.fieldMapping.vectorField,
                    textField: storage.fieldMapping.textField,
                    metadataField: storage.fieldMapping.metadataField
                }
            }
        };
    }
    if storage is S3VectorsStorage {
        // Every member is individually optional in the service model; which
        // combination is valid is enforced by `validateStorageConfiguration`.
        map<json> s3Vectors = {};
        string? vectorBucketArn = storage?.vectorBucketArn;
        if vectorBucketArn is string {
            s3Vectors["vectorBucketArn"] = vectorBucketArn;
        }
        string? indexArn = storage?.indexArn;
        if indexArn is string {
            s3Vectors["indexArn"] = indexArn;
        }
        string? indexName = storage?.indexName;
        if indexName is string {
            s3Vectors["indexName"] = indexName;
        }
        return {'type: storage.'type, s3VectorsConfiguration: s3Vectors};
    }
    if storage is RdsStorage {
        map<json> fieldMapping = {
            primaryKeyField: storage.fieldMapping.primaryKeyField,
            vectorField: storage.fieldMapping.vectorField,
            textField: storage.fieldMapping.textField,
            metadataField: storage.fieldMapping.metadataField
        };
        string? customMetadataField = storage.fieldMapping?.customMetadataField;
        if customMetadataField is string {
            fieldMapping["customMetadataField"] = customMetadataField;
        }
        return {
            'type: storage.'type,
            rdsConfiguration: {
                resourceArn: storage.resourceArn,
                credentialsSecretArn: storage.credentialsSecretArn,
                databaseName: storage.databaseName,
                tableName: storage.tableName,
                fieldMapping
            }
        };
    }
    if storage is NeptuneAnalyticsStorage {
        // No `vectorField` — not a member of `NeptuneAnalyticsFieldMapping`.
        return {
            'type: storage.'type,
            neptuneAnalyticsConfiguration: {
                graphArn: storage.graphArn,
                fieldMapping: {
                    textField: storage.fieldMapping.textField,
                    metadataField: storage.fieldMapping.metadataField
                }
            }
        };
    }
    if storage is PineconeStorage {
        // No `vectorField` — not a member of `PineconeFieldMapping`.
        map<json> pinecone = {
            connectionString: storage.connectionString,
            credentialsSecretArn: storage.credentialsSecretArn,
            fieldMapping: {
                textField: storage.fieldMapping.textField,
                metadataField: storage.fieldMapping.metadataField
            }
        };
        string? namespace = storage?.namespace;
        if namespace is string {
            pinecone["namespace"] = namespace;
        }
        return {'type: storage.'type, pineconeConfiguration: pinecone};
    }
    if storage is RedisEnterpriseCloudStorage {
        return {
            'type: storage.'type,
            redisEnterpriseCloudConfiguration: {
                endpoint: storage.endpoint,
                vectorIndexName: storage.vectorIndexName,
                credentialsSecretArn: storage.credentialsSecretArn,
                fieldMapping: {
                    vectorField: storage.fieldMapping.vectorField,
                    textField: storage.fieldMapping.textField,
                    metadataField: storage.fieldMapping.metadataField
                }
            }
        };
    }
    map<json> mongo = {
        endpoint: storage.endpoint,
        databaseName: storage.databaseName,
        collectionName: storage.collectionName,
        vectorIndexName: storage.vectorIndexName,
        credentialsSecretArn: storage.credentialsSecretArn,
        fieldMapping: {
            vectorField: storage.fieldMapping.vectorField,
            textField: storage.fieldMapping.textField,
            metadataField: storage.fieldMapping.metadataField
        }
    };
    string? endpointServiceName = storage?.endpointServiceName;
    if endpointServiceName is string {
        mongo["endpointServiceName"] = endpointServiceName;
    }
    string? textIndexName = storage?.textIndexName;
    if textIndexName is string {
        mongo["textIndexName"] = textIndexName;
    }
    return {'type: storage.'type, mongoDbAtlasConfiguration: mongo};
}

// The `CreateKnowledgeBase` request body for a self-managed knowledge base.
//
// Differs from the managed body (`createKnowledgeBaseRequestBody`) in exactly two
// ways: `knowledgeBaseConfiguration.type` is `VECTOR` with a
// `vectorKnowledgeBaseConfiguration` carrying a REQUIRED `embeddingModelArn` (there
// is no service-managed embedding model on this path), and `storageConfiguration`
// is sent at the TOP LEVEL — it is a sibling of `knowledgeBaseConfiguration`, not a
// child of it.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CreateKnowledgeBase.html
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_VectorKnowledgeBaseConfiguration.html
isolated function createVectorKnowledgeBaseRequestBody(VectorKnowledgeBaseDefinition def) returns map<json> {
    map<json> vectorConfig = {embeddingModelArn: def.embeddingModelArn};
    VectorEmbeddingModelConfig? embeddingModel = def?.embeddingModel;
    if embeddingModel is VectorEmbeddingModelConfig {
        map<json> bedrockEmbedding = {};
        int? dimensions = embeddingModel?.dimensions;
        if dimensions is int {
            bedrockEmbedding["dimensions"] = dimensions;
        }
        EmbeddingDataType? embeddingDataType = embeddingModel?.embeddingDataType;
        if embeddingDataType is EmbeddingDataType {
            bedrockEmbedding["embeddingDataType"] = embeddingDataType;
        }
        // An empty `bedrockEmbeddingModelConfiguration` is meaningless — omit the
        // whole wrapper rather than sending `{}`.
        if bedrockEmbedding.length() > 0 {
            vectorConfig["embeddingModelConfiguration"] = {bedrockEmbeddingModelConfiguration: bedrockEmbedding};
        }
    }
    map<json> body = {
        name: def.name,
        roleArn: def.roleArn,
        knowledgeBaseConfiguration: {
            'type: "VECTOR",
            vectorKnowledgeBaseConfiguration: vectorConfig
        },
        storageConfiguration: storageConfigurationJson(def.storageConfiguration)
    };
    string? description = def.description;
    if description is string {
        body["description"] = description;
    }
    return body;
}

// The `CreateDataSource` request body for a self-managed knowledge base.
//
// THE SHAPE MOST LIKELY TO BE GOT WRONG BY COPYING THE MANAGED PATH. A managed
// knowledge base rejects a bare `{"type": "CUSTOM"}` with "Unsupported data source
// type for MANAGED knowledge base type." and requires the
// `MANAGED_KNOWLEDGE_BASE_CONNECTOR` wrapper with the real type nested inside
// `connectorParameters` (established by calling the live API; not documented). A
// SELF-MANAGED knowledge base takes the plain, direct form instead — `CUSTOM` is a
// first-class member of `DataSourceConfiguration.type` and has no sub-configuration
// object of its own.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_DataSourceConfiguration.html
//
// `vectorIngestionConfiguration` IS sent here, unlike on the managed path where
// Bedrock rejects `chunkingConfiguration` against a service-managed embedding model.
// A self-managed knowledge base always brings its own embedding model, so chunking
// is configurable and `ChunkingStrategy` is genuinely reachable.
isolated function createVectorDataSourceRequestBody(VectorDataSourceDefinition def) returns map<json>|ai:Error {
    map<json> body = {
        name: def.name,
        dataSourceConfiguration: {'type: "CUSTOM"},
        vectorIngestionConfiguration: {
            chunkingConfiguration: check vectorChunkingConfigurationJson(def)
        }
    };
    string? description = def.description;
    if description is string {
        body["description"] = description;
    }
    return body;
}

// `ChunkingStrategy` -> `chunkingConfiguration`.
//
// Only `FIXED_SIZE` and `NONE` are reachable: `validateVectorDataSource` rejects the
// other two before this is ever called, because neither can be emitted correctly
// from `VectorDataSourceDefinition` as it stands. Their sub-objects carry required
// members with no documented service-side default —
// `HierarchicalChunkingConfiguration` requires `levelConfigurations` and
// `overlapTokens`, `SemanticChunkingConfiguration` requires `maxTokens`,
// `bufferSize` and `breakpointPercentileThreshold` (per the `bedrock-agent` service
// model) — so emitting the bare strategy would send an incomplete body.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_ChunkingConfiguration.html
isolated function vectorChunkingConfigurationJson(VectorDataSourceDefinition def) returns json|ai:Error {
    match def.chunkingStrategy {
        NONE => {
            return {chunkingStrategy: "NONE"};
        }
        FIXED_SIZE => {
            return {
                chunkingStrategy: "FIXED_SIZE",
                fixedSizeChunkingConfiguration: {
                    maxTokens: def.maxTokens,
                    overlapPercentage: def.overlapPercentage
                }
            };
        }
    }
    // Unreachable by construction — `validateVectorDataSource` rejects HIERARCHICAL
    // and SEMANTIC before any caller reaches here. Erroring rather than falling
    // through to the FIXED_SIZE arm means a future caller that forgets the validation
    // gets a loud failure instead of a silently wrong request body.
    return error ai:Error(
        string `chunkingStrategy '${def.chunkingStrategy}' cannot be encoded — it must be rejected by ` +
        "'validateVectorDataSource' before reaching the request builder");
}

// The `vectorSearchConfiguration` branch of `retrievalConfiguration`.
//
// NOT interchangeable with the managed class's `managedSearchConfiguration`: this
// branch has `overrideSearchType` and `implicitFilterConfiguration`, and has NO
// `rerankingModelType` — reranking is expressed only through `rerankingConfiguration`.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_KnowledgeBaseVectorSearchConfiguration.html
//
// `overrideSearchType` is emitted ONLY when the caller set it. Defaulting it to
// `HYBRID` would 400 or silently degrade on most backends; unset means Bedrock picks
// a strategy suited to the store.
isolated function vectorSearchConfigJson(json? filter, int numberOfResults, SearchType? overrideSearchType,
        VectorRerankingConfig? reranking) returns json {
    map<json> vectorSearch = {numberOfResults};
    // `filter is json` would NOT reject nil — `()` is a member of `json` — and would
    // put `"filter": null` on the wire.
    if filter !is () {
        vectorSearch["filter"] = filter;
    }
    if overrideSearchType is SearchType {
        vectorSearch["overrideSearchType"] = overrideSearchType;
    }
    if reranking is VectorRerankingConfig {
        vectorSearch["rerankingConfiguration"] = rerankingConfigJson(reranking, numberOfResults);
    }
    return vectorSearch;
}

// `VectorRerankingConfig` -> `VectorSearchRerankingConfiguration`. `type` is the only
// required member and `BEDROCK_RERANKING_MODEL` its only valid value.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_VectorSearchRerankingConfiguration.html
//
// B5b: `numberOfRerankedResults` is CLAMPED to the effective `numberOfResults` this
// call is actually making — not just construction's static config, but the per-call
// value after `retrieve(maxLimit=...)` has narrowed it (see `retrieveInternal`).
// `validateVectorRetrievalConfig` (B5a) can only catch the construction-time case:
// a config with `numberOfResults` left unset (falling back to Bedrock's own default
// of 5) still reaches the wire with `numberOfRerankedResults` uncapped, and a small
// per-call `maxLimit` narrows the search further still. Clamping rather than erroring
// here is deliberate: `maxLimit` is caller intent on ONE call, and erroring would make
// a construction-time-legal config fail on a small `maxLimit` — a clamp degrades
// gracefully to "rerank everything the search returned" instead.
isolated function rerankingConfigJson(VectorRerankingConfig reranking, int numberOfResults) returns json {
    map<json> bedrockReranking = {modelConfiguration: {modelArn: reranking.modelArn}};
    int? numberOfRerankedResults = reranking?.numberOfRerankedResults;
    if numberOfRerankedResults is int {
        bedrockReranking["numberOfRerankedResults"] =
            numberOfRerankedResults < numberOfResults ? numberOfRerankedResults : numberOfResults;
    }
    return {'type: "BEDROCK_RERANKING_MODEL", bedrockRerankingConfiguration: bedrockReranking};
}

// ============================================================================
// Construction-time validation.
//
// Everything here is decided from the caller's own configuration or from what
// `GetKnowledgeBase` already returns, so it costs no extra API call and needs no
// permission beyond the ones the class already uses.
//
// Deliberately NOT validated, because each would require querying the vector store
// itself — credentials and network reach the calling application does not have,
// since those permissions belong to the knowledge base's service role and the store
// is often VPC-private: that the index dimension matches the embedding model, that
// an OpenSearch index uses `faiss` rather than `nmslib`, that custom metadata fields
// are `keyword`-typed, and that documents stay inside S3 Vectors' metadata caps.
// These are covered in the README's pitfalls section instead.
// ============================================================================

// Rejects a data source definition this module cannot encode faithfully, or that
// Bedrock would reject, before any I/O.
//
// Ranges come from the `bedrock-agent` service model's own integer constraints —
// catching them here turns an opaque Bedrock 400 into a message naming the field and
// the bound.
isolated function validateVectorDataSource(VectorDataSourceDefinition def) returns ai:Error? {
    if def.chunkingStrategy == HIERARCHICAL || def.chunkingStrategy == SEMANTIC {
        return error ai:Error(
            string `chunkingStrategy '${def.chunkingStrategy}' is not supported by this module yet: it ` +
            "requires a tuning sub-object with required members and no service-side default " +
            "(HIERARCHICAL needs 'levelConfigurations' and 'overlapTokens'; SEMANTIC needs 'maxTokens', " +
            "'bufferSize' and 'breakpointPercentileThreshold'), and 'VectorDataSourceDefinition' has no " +
            "way to express them. Use FIXED_SIZE, or NONE to chunk client-side with an 'ai:Chunker'. " +
            "To use one of these strategies, create the data source in the AWS console and attach to it " +
            "by passing the knowledge base id instead of a definition.");
    }
    // FixedSizeChunkingConfigurationMaxTokensInteger: min 1, max 8192.
    if def.maxTokens < 1 || def.maxTokens > MAX_FIXED_SIZE_CHUNK_TOKENS {
        return error ai:Error(
            string `'maxTokens' must be between 1 and ${MAX_FIXED_SIZE_CHUNK_TOKENS}, got ${def.maxTokens}`);
    }
    // FixedSizeChunkingConfigurationOverlapPercentageInteger: min 1, max 99 — note
    // 0 is NOT valid, despite reading like a natural "no overlap".
    if def.overlapPercentage < 1 || def.overlapPercentage > 99 {
        return error ai:Error(
            string `'overlapPercentage' must be between 1 and 99, got ${def.overlapPercentage}. ` +
            "Bedrock rejects 0 — there is no 'no overlap' value on FIXED_SIZE; use " +
            "'chunkingStrategy = NONE' if you do not want Bedrock to chunk at all.");
    }
    return;
}

// Rejects retrieve-time configuration Bedrock would reject, before any I/O.
isolated function validateVectorRetrievalConfig(VectorKnowledgeBaseConfig config) returns ai:Error? {
    // KnowledgeBaseVectorSearchConfigurationNumberOfResultsInteger: min 1, max 100.
    int? numberOfResults = config?.numberOfResults;
    if numberOfResults is int && (numberOfResults < 1 || numberOfResults > KB_MAX_RESULTS_PER_CALL) {
        return error ai:Error(
            string `'numberOfResults' must be between 1 and ${KB_MAX_RESULTS_PER_CALL}, got ${numberOfResults}`);
    }
    // VectorSearchBedrockRerankingConfiguration.numberOfRerankedResults: min 1, max 100.
    VectorRerankingConfig? reranking = config?.rerankingConfiguration;
    if reranking is VectorRerankingConfig {
        int? rerankedResults = reranking?.numberOfRerankedResults;
        if rerankedResults is int && (rerankedResults < 1 || rerankedResults > MAX_RERANKED_RESULTS) {
            return error ai:Error(
                string `'numberOfRerankedResults' must be between 1 and ${MAX_RERANKED_RESULTS}, ` +
                string `got ${rerankedResults}`);
        }
        // B5a: asking to rerank more results than the search itself returns is
        // accepted by the service model's independent bounds (each is checked only
        // against 1-100) but is nonsensical — Bedrock would rerank at most
        // `numberOfResults` results regardless of what `numberOfRerankedResults` asks
        // for. Only checkable when BOTH are set here; a `numberOfResults` left unset
        // falls back to Bedrock's own default (5) or, per call, `maxLimit` — neither
        // of which is visible at construction — so 4b clamps the per-call case instead.
        if rerankedResults is int && numberOfResults is int && rerankedResults > numberOfResults {
            return error ai:Error(
                string `'numberOfRerankedResults' (${rerankedResults}) cannot exceed 'numberOfResults' ` +
                string `(${numberOfResults}) — cannot rerank ${rerankedResults} results out of a search ` +
                string `that returns at most ${numberOfResults}.`);
        }
    }
    return;
}

// Rejects storage configurations Bedrock would reject, before any I/O.
isolated function validateStorageConfiguration(StorageConfiguration storage) returns ai:Error? {
    if storage is S3VectorsStorage {
        // All three members are `Required: No` INDIVIDUALLY in the service model,
        // but a configuration naming no index at all cannot resolve to one. Bedrock
        // answers this with a generic 400; naming the two valid combinations here is
        // more useful.
        // https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_S3VectorsConfiguration.html
        boolean hasIndexArn = storage?.indexArn is string;
        boolean hasBucketAndName = storage?.vectorBucketArn is string && storage?.indexName is string;
        if !hasIndexArn && !hasBucketAndName {
            return error ai:Error(
                "S3 Vectors storage needs either 'indexArn', or both 'vectorBucketArn' and 'indexName'. " +
                "Neither was set, so there is no vector index to attach to.");
        }
        // B4: `indexArn` and `vectorBucketArn`/`indexName` are both `Required: No`
        // individually, so nothing in the service model stops a caller setting
        // `indexArn` AND a `vectorBucketArn`/`indexName` naming a DIFFERENT index.
        // `storageConfigurationJson` forwards every member it is given, so Bedrock —
        // not this module, not the caller — would silently pick one. Refuse the
        // ambiguity here, naming both, rather than letting the wrong index win quietly.
        if hasIndexArn && (storage?.vectorBucketArn is string || storage?.indexName is string) {
            string? indexArn = storage?.indexArn;
            string other = storage?.vectorBucketArn is string
                ? string `vectorBucketArn '${storage?.vectorBucketArn ?: ""}'`
                : string `indexName '${storage?.indexName ?: ""}'`;
            return error ai:Error(
                string `S3 Vectors storage sets both 'indexArn' ('${indexArn ?: ""}') and ${other} — these ` +
                "may name different indexes, and which one Bedrock would attach to is not documented. Pass " +
                "exactly one of the two valid forms: 'indexArn', or 'vectorBucketArn' + 'indexName'.");
        }
    }
    return;
}

// Both that the knowledge base is `ACTIVE` and that it is actually a `VECTOR` one.
//
// The type check mirrors the managed class's guard, in the opposite direction and
// for the same reason. This class sends the `vectorSearchConfiguration` branch
// unconditionally and keys `deleteByFilter`'s probe on
// `x-amz-bedrock-kb-source-uri`; on a MANAGED knowledge base the branch is wrong and
// the reserved attribute is spelled `_source_uri`, so `retrieve()` and
// `deleteByFilter()` would both misbehave — the latter silently, by matching nothing.
// Refuse at construction rather than half-work at runtime.
// Returns the fetched knowledge base so the attach-by-definition comparison can
// reuse it rather than issuing a second identical `GetKnowledgeBase`.
isolated function verifyVectorKnowledgeBaseUsable(BedrockTransport controlTransport, string kbId)
        returns map<json>|ai:Error {
    map<json> kb = check getKnowledgeBase(controlTransport, kbId);
    string status = stringField(kb, "status") ?: "";
    if status != "ACTIVE" {
        return error ai:Error(
            string `Knowledge base '${kbId}' is not usable: status is '${status}' (expected 'ACTIVE'). ` +
            "Wait for it to finish provisioning, or check the AWS console for failure details.");
    }
    string kbType = stringField(asMap(kb["knowledgeBaseConfiguration"] ?: {}), "type") ?: "";
    // Absent type is tolerated: it is required in the service model, so a missing one
    // means an unexpected response shape rather than a non-vector knowledge base, and
    // failing construction over it would be a false positive.
    if kbType != "" && kbType != "VECTOR" {
        return error ai:Error(
            string `Knowledge base '${kbId}' is of type '${kbType}', but BedrockVectorKnowledgeBase ` +
            "supports only 'VECTOR' knowledge bases (the self-managed ones, backed by your own vector " +
            "store). A 'MANAGED' knowledge base is served by a different search branch and uses a " +
            "different reserved metadata prefix, so retrieve() and deleteByFilter() are not valid " +
            "against it. Use BedrockManagedKnowledgeBase instead.");
    }
    return kb;
}

// ============================================================================
// The construction spine: transports -> find-or-create -> data-source resolution
// -> chunking detection. Mirrors `resolveKbSpine` step for step; only the two
// creators and the knowledge base type guard differ.
// ============================================================================

// Everything the spine needs beyond the resource itself is read off `config` here
// rather than being passed alongside it — one source of truth, so a future field
// cannot be wired at one call site and forgotten at another.
isolated function resolveVectorKbSpine(string providerName, KnowledgeBaseCredentials credentials, string region,
        aws:EndpointConfig? endpointConfig, string|VectorKnowledgeBaseDefinition knowledgeBase,
        VectorKnowledgeBaseConfig config)
        returns KbSpine|ai:Error {
    do {
        check guardRegion(region);
        check validateVectorRetrievalConfig(config);
        if knowledgeBase is VectorKnowledgeBaseDefinition {
            check validateStorageConfiguration(knowledgeBase.storageConfiguration);
            check validateVectorDataSource(knowledgeBase.dataSource);
        }
        string? dataSourceIdOverride = config?.dataSourceId;
        http:ClientConfiguration? httpConfig = config?.httpConfig;
        RetryConfig? retryConfig = config?.retryConfig;
        Endpoint controlEp = check buildAgentEndpoint(AGENT_CONTROL, region, endpointConfig);
        Endpoint dataEp = check buildAgentEndpoint(AGENT_DATA, region, endpointConfig);
        // One provider, both planes.
        auth:CredentialProvider|BearerToken resolved = check resolveCredentials(credentials);
        BedrockTransport controlTransport =
            check new (resolved, region, controlEp, httpConfig, retryConfig, true);
        BedrockTransport dataTransport =
            check new (resolved, region, dataEp, httpConfig, retryConfig, true);

        KbAttachResult attach = check resolveVectorKnowledgeBase(controlTransport, knowledgeBase);
        string dataSourceId;
        if dataSourceIdOverride is string {
            dataSourceId = dataSourceIdOverride;
        } else if attach.createdDataSourceId is string {
            dataSourceId = <string>attach.createdDataSourceId;
        } else {
            dataSourceId = check resolveCustomDataSource(controlTransport, attach.knowledgeBaseId);
        }
        ChunkingStrategy strategy = check validateResolvedDataSource(controlTransport,
            attach.knowledgeBaseId, dataSourceId);
        return {
            controlTransport,
            dataTransport,
            knowledgeBaseId: attach.knowledgeBaseId,
            dataSourceId,
            chunkingStrategy: strategy
        };
    } on fail error e {
        if e is ai:Error {
            return e;
        }
        return error ai:Error(string `Failed to initialize ${providerName}: ${e.message()}`, e);
    }
}

// `string` -> verify and attach (no writes). `VectorKnowledgeBaseDefinition` -> find
// by name; exactly one match attaches, no match creates, more than one is a
// construction error. Same reasoning as the managed path: `CreateKnowledgeBase` has
// no upsert, and while knowledge base names ARE unique per account, AWS's own
// enforcement has a race window — see A10 (§2a/§2b) below, mirrored from
// `resolveKnowledgeBase` in knowledgebase_common.bal.
isolated function resolveVectorKnowledgeBase(BedrockTransport controlTransport,
        string|VectorKnowledgeBaseDefinition knowledgeBase) returns KbAttachResult|ai:Error {
    if knowledgeBase is string {
        map<json> _ = check verifyVectorKnowledgeBaseUsable(controlTransport, knowledgeBase);
        return {knowledgeBaseId: knowledgeBase, createdDataSourceId: ()};
    }
    string[] candidates = check listKnowledgeBaseIdsByName(controlTransport, knowledgeBase.name);
    if candidates.length() == 1 {
        map<json> existing = check verifyVectorKnowledgeBaseUsable(controlTransport, candidates[0]);
        // `storageConfiguration` matters even more here than on the managed path: it
        // names the vector store the caller believes it is reading and writing.
        check assertDefinitionMatches(candidates[0], createVectorKnowledgeBaseRequestBody(knowledgeBase),
            existing);
        return {knowledgeBaseId: candidates[0], createdDataSourceId: ()};
    }
    if candidates.length() > 1 {
        return error ai:Error(nameAmbiguityMessage(knowledgeBase.name, candidates));
    }
    // A10: same two race windows as the managed path (knowledgebase_common.bal) —
    // §2a (sequential 409, recovered by attaching) and §2b (genuinely concurrent
    // in-flight creates, detected after this call's own create is ACTIVE and
    // reported, never silently duplicated or deleted).
    KbCreateOutcome created = check createVectorKnowledgeBaseRecoveringFromConflict(controlTransport, knowledgeBase);
    if created.recovered {
        return {knowledgeBaseId: created.knowledgeBaseId, createdDataSourceId: ()};
    }
    string kbId = created.knowledgeBaseId;
    check pollKnowledgeBaseActive(controlTransport, kbId, knowledgeBase.readyTimeout);
    string dsId = check createVectorCustomDataSource(controlTransport, kbId, knowledgeBase.dataSource);
    check guardAgainstConcurrentDuplicate(controlTransport, knowledgeBase.name, kbId);
    return {knowledgeBaseId: kbId, createdDataSourceId: dsId};
}

// A10 §2a, vector counterpart of `createKnowledgeBaseRecoveringFromConflict` — same
// recovery, using the VECTOR create body and `verifyVectorKnowledgeBaseUsable`.
isolated function createVectorKnowledgeBaseRecoveringFromConflict(BedrockTransport controlTransport,
        VectorKnowledgeBaseDefinition def) returns KbCreateOutcome|ai:Error {
    map<json> body = createVectorKnowledgeBaseRequestBody(def);
    body["clientToken"] = idempotencyToken(body);
    TransportResponse|ConflictError|ai:Error response =
        controlTransport.executeRequestDetectingConflict("PUT", "/knowledgebases/", body);
    if response is ConflictError {
        string[] candidates = check listKnowledgeBaseIdsByName(controlTransport, def.name);
        if candidates.length() == 1 {
            map<json> existing = check verifyVectorKnowledgeBaseUsable(controlTransport, candidates[0]);
            check assertDefinitionMatches(candidates[0], createVectorKnowledgeBaseRequestBody(def), existing);
            return {knowledgeBaseId: candidates[0], recovered: true};
        }
        return error ai:Error(response.message());
    }
    if response is ai:Error {
        return response;
    }
    map<json> kb = asMap(asMap(response.body)["knowledgeBase"] ?: {});
    string? id = stringField(kb, "knowledgeBaseId");
    if id is () {
        return error ai:Error("CreateKnowledgeBase response carried no 'knowledgeBaseId'");
    }
    return {knowledgeBaseId: id, recovered: false};
}

isolated function createVectorCustomDataSource(BedrockTransport controlTransport, string kbId,
        VectorDataSourceDefinition def) returns string|ai:Error {
    map<json> body = check createVectorDataSourceRequestBody(def);
    body["clientToken"] = idempotencyToken({kbId, dataSource: body});
    string path = string `/knowledgebases/${kbId}/datasources/`;
    TransportResponse response = check controlTransport.executeRequest("PUT", path, body);
    map<json> dataSource = asMap(asMap(response.body)["dataSource"] ?: {});
    string? id = stringField(dataSource, "dataSourceId");
    if id is () {
        return error ai:Error("CreateDataSource response carried no 'dataSourceId'");
    }
    // AWS documents `CreateDataSource` as asynchronous ("the data source status
    // transitions from CREATING to AVAILABLE"), so the poll is the documented
    // behaviour rather than dead code, even though the managed path was measured
    // returning AVAILABLE synchronously.
    string status = stringField(dataSource, "status") ?: "";
    if status != "AVAILABLE" {
        check pollDataSourceAvailable(controlTransport, kbId, id, DEFAULT_DATA_SOURCE_READY_TIMEOUT);
    }
    return id;
}

// ============================================================================
// Retrieval.
// ============================================================================

// One `Retrieve` round trip on the VECTOR search branch. `filter` is an
// already-built `RetrievalFilter` JSON value (knowledgebase_filter.bal) or `()` to
// search unfiltered. Returns the raw `retrievalResults[]` plus a `nextToken`.
isolated function callVectorRetrieve(BedrockTransport dataTransport, string kbId, string query, json? filter,
        int numberOfResults, SearchType? overrideSearchType, VectorRerankingConfig? reranking, string? nextToken)
        returns [json[], string?]|ai:Error {
    map<json> body = {
        retrievalQuery: {text: query},
        retrievalConfiguration: {
            vectorSearchConfiguration:
                vectorSearchConfigJson(filter, numberOfResults, overrideSearchType, reranking)
        }
    };
    if nextToken is string {
        body["nextToken"] = nextToken;
    }
    string path = string `/knowledgebases/${kbId}/retrieve`;
    TransportResponse response = check dataTransport.executeRequest("POST", path, body);
    map<json> respBody = asMap(response.body);
    json resultsJson = respBody["retrievalResults"] ?: [];
    json[] results = resultsJson is json[] ? resultsJson : [];
    return [results, stringField(respBody, "nextToken")];
}

// The VECTOR adapter for `DeleteRetrieveCaller` (knowledgebase_common.bal) — A17's
// two-enumeration `deleteByFilter` algorithm, on the `vectorSearchConfiguration`
// branch. Neither reranking nor `overrideSearchType` is applied: reranking imposes
// its own relevance cut, which is exactly the kind of cutoff the unfiltered
// (reachability) enumeration exists to see past, and forcing a search type here
// would make the enumeration's behaviour differ from the `retrieve()` the caller's
// filter was written against.
isolated function vectorDeleteRetrieve(BedrockTransport dataTransport, string kbId, json? filter,
        int numberOfResults, string? nextToken) returns [json[], string?]|ai:Error
    => callVectorRetrieve(dataTransport, kbId, FILTER_PROBE_QUERY, filter, numberOfResults, (), (), nextToken);
