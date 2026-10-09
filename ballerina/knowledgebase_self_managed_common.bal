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

// The wire layer for `SelfManagedKnowledgeBase`, kept apart from knowledgebase_common.bal
// so the managed class's request bodies cannot be affected. Everything type-agnostic is
// reused from that file.

// The source-uri attribute on a self-managed result. Reserved fields here use the
// `x-amz-bedrock` prefix, not the managed `_` prefix, so `_source_uri` would match
// nothing.
// https://docs.aws.amazon.com/bedrock/latest/userguide/kb-test-config.html
// https://docs.aws.amazon.com/bedrock/latest/userguide/kb-multimodal-test-and-query.html
const string VECTOR_SOURCE_URI_METADATA_KEY = "x-amz-bedrock-kb-source-uri";

// The data source a self-managed result came from (`x-amz-bedrock` prefix).
const string VECTOR_DATA_SOURCE_ID_METADATA_KEY = "x-amz-bedrock-kb-data-source-id";

// `FixedSizeChunkingConfigurationMaxTokensInteger` max, from the botocore service model
// (the API reference states none).
const int MAX_FIXED_SIZE_CHUNK_TOKENS = 8192;

// `VectorSearchBedrockRerankingConfiguration.numberOfRerankedResults`: min 1, max 100.
const int MAX_RERANKED_RESULTS = 100;

// ============================================================================
// Request-body builders, pure so every wire shape is testable without AWS.
// ============================================================================

// `type` is always sent: the API reference marks it required.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_StorageConfiguration.html
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
        // Which combination is valid is checked in `validateStorageConfiguration`.
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

// Unlike the managed body: type `VECTOR` with a required `embeddingModelArn`, and
// `storageConfiguration` at the top level, beside `knowledgeBaseConfiguration`.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CreateKnowledgeBase.html
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_VectorKnowledgeBaseConfiguration.html
isolated function createVectorKnowledgeBaseRequestBody(SelfManagedKnowledgeBaseDefinition def) returns map<json> {
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
        // Leave out an empty wrapper rather than sending `{}`.
        if bedrockEmbedding.length() > 0 {
            vectorConfig["embeddingModelConfiguration"] = {bedrockEmbeddingModelConfiguration: bedrockEmbedding};
        }
    }
    map<json> body = {
        name: def.name,
        roleArn: def.serviceRoleArn,
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

// A self-managed knowledge base takes a plain `CUSTOM` data source (the managed one
// needs the connector wrapper), and its chunking is configurable because it always
// brings its own embedding model.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_DataSourceConfiguration.html
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

// Only `FIXED_SIZE` and `NONE`: the other strategies need settings this record does
// not have, and `validateVectorDataSource` refuses them.
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
    // Unreachable after validation; an error rather than a wrong body if that changes.
    return error ai:Error(
        string `chunkingStrategy '${def.chunkingStrategy}' cannot be encoded — it must be rejected by ` +
        "'validateVectorDataSource' before reaching the request builder");
}

// `overrideSearchType` is sent only when set, so Bedrock otherwise picks one suited to
// the store.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_KnowledgeBaseVectorSearchConfiguration.html
isolated function vectorSearchConfigJson(json? filter, int numberOfResults, SearchType? overrideSearchType,
        VectorRerankingConfig? reranking) returns json {
    map<json> vectorSearch = {numberOfResults};
    // `()` is a `json` value, so `filter is json` would send `"filter": null`.
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

// `type` is required and `BEDROCK_RERANKING_MODEL` its only value.
// `numberOfRerankedResults` is capped at this call's `numberOfResults`, since a small
// `maxLimit` narrows the search after construction.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_VectorSearchRerankingConfiguration.html
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
// Construction checks, from the caller's configuration alone. Checks that would need
// access to the vector store itself (index dimension, engine, field types) are in the
// README instead.
// ============================================================================

isolated function validateVectorDataSource(VectorDataSourceDefinition def) returns ai:Error? {
    if def.chunkingStrategy == HIERARCHICAL || def.chunkingStrategy == SEMANTIC {
        return errorWithDetail(
            string `chunkingStrategy '${def.chunkingStrategy}' is not supported in a definition. Use ` +
            "FIXED_SIZE or NONE, or create the data source in the AWS console and pass the knowledge base id.",
            "It requires a tuning sub-object with required members and no service-side default " +
            "(HIERARCHICAL needs 'levelConfigurations' and 'overlapTokens'; SEMANTIC needs 'maxTokens', " +
            "'bufferSize' and 'breakpointPercentileThreshold'), which 'VectorDataSourceDefinition' cannot " +
            "express.");
    }
    // FixedSizeChunkingConfigurationMaxTokensInteger: min 1, max 8192.
    if def.maxTokens < 1 || def.maxTokens > MAX_FIXED_SIZE_CHUNK_TOKENS {
        return error ai:Error(
            string `'maxTokens' must be between 1 and ${MAX_FIXED_SIZE_CHUNK_TOKENS}, got ${def.maxTokens}`);
    }
    // 0 is not valid.
    if def.overlapPercentage < 1 || def.overlapPercentage > 99 {
        return errorWithDetail(
            string `'overlapPercentage' must be between 1 and 99, got ${def.overlapPercentage}.`,
            "Bedrock rejects 0: FIXED_SIZE has no 'no overlap' value. Use 'chunkingStrategy = NONE' if you " +
            "do not want Bedrock to chunk at all.");
    }
    return;
}

isolated function validateVectorRetrievalConfig(VectorRetrievalSettings config) returns ai:Error? {
    // min 1, max 100.
    int? numberOfResults = config?.numberOfResults;
    if numberOfResults is int && (numberOfResults < 1 || numberOfResults > KB_MAX_RESULTS_PER_CALL) {
        return error ai:Error(
            string `'numberOfResults' must be between 1 and ${KB_MAX_RESULTS_PER_CALL}, got ${numberOfResults}`);
    }
    // min 1, max 100.
    VectorRerankingConfig? reranking = config?.rerankingConfiguration;
    if reranking is VectorRerankingConfig {
        int? rerankedResults = reranking?.numberOfRerankedResults;
        if rerankedResults is int && (rerankedResults < 1 || rerankedResults > MAX_RERANKED_RESULTS) {
            return error ai:Error(
                string `'numberOfRerankedResults' must be between 1 and ${MAX_RERANKED_RESULTS}, ` +
                string `got ${rerankedResults}`);
        }
        // Reranking more results than the search returns is meaningless. Only checked
        // when both are set; the per-call case is capped instead.
        if rerankedResults is int && numberOfResults is int && rerankedResults > numberOfResults {
            return error ai:Error(
                string `'numberOfRerankedResults' (${rerankedResults}) cannot exceed 'numberOfResults' ` +
                string `(${numberOfResults}) — cannot rerank ${rerankedResults} results out of a search ` +
                string `that returns at most ${numberOfResults}.`);
        }
    }
    return;
}

isolated function validateStorageConfiguration(StorageConfiguration storage) returns ai:Error? {
    if storage is S3VectorsStorage {
        // Each member is optional, but one of the two combinations must name an index.
        // https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_S3VectorsConfiguration.html
        boolean hasIndexArn = storage?.indexArn is string;
        boolean hasBucketAndName = storage?.vectorBucketArn is string && storage?.indexName is string;
        if !hasIndexArn && !hasBucketAndName {
            return error ai:Error(
                "S3 Vectors storage needs either 'indexArn', or both 'vectorBucketArn' and 'indexName'. " +
                "Neither was set, so there is no vector index to attach to.");
        }
        // Both forms naming possibly different indexes would let Bedrock pick one.
        if hasIndexArn && (storage?.vectorBucketArn is string || storage?.indexName is string) {
            string? indexArn = storage?.indexArn;
            string other = storage?.vectorBucketArn is string
                ? string `vectorBucketArn '${storage?.vectorBucketArn ?: ""}'`
                : string `indexName '${storage?.indexName ?: ""}'`;
            return errorWithDetail(
                string `S3 Vectors storage sets both 'indexArn' and ${other}. Pass either 'indexArn', or ` +
                "'vectorBucketArn' + 'indexName'.",
                "The two may name different indexes, and which one Bedrock would attach to is not documented.");
        }
    }
    return;
}

// A managed knowledge base needs the other search branch. Returns it for the
// definition check.
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
    // A missing type means an unexpected response shape, not a mismatch.
    if kbType != "" && kbType != "VECTOR" {
        return errorWithDetail(
            string `Knowledge base '${kbId}' is of type '${kbType}'; SelfManagedKnowledgeBase supports only ` +
            "'VECTOR' knowledge bases. Use ManagedKnowledgeBase instead.",
            "A 'MANAGED' knowledge base is served by a different search branch and uses a different " +
            "reserved metadata prefix, so retrieve() and deleteByFilter() are not valid against it.");
    }
    return kb;
}

// ============================================================================
// Construction, mirroring `resolveKbSpine`.
// ============================================================================

isolated function resolveVectorKbSpine(string providerName, KnowledgeBaseAuthConfig credentials, string region,
        aws:EndpointConfig? endpointConfig, string|SelfManagedKnowledgeBaseDefinition knowledgeBase,
        string? dataSourceIdOverride, VectorRetrievalSettings retrieval, http:ClientConfiguration? httpConfig,
        RetryConfig? retryConfig) returns KbSpine|ai:Error {
    do {
        check guardRegion(region);
        check validateVectorRetrievalConfig(retrieval);
        if knowledgeBase is SelfManagedKnowledgeBaseDefinition {
            check validateStorageConfiguration(knowledgeBase.storageConfiguration);
            check validateVectorDataSource(knowledgeBase.dataSource);
        }
        Endpoint controlEp = check buildAgentEndpoint(AGENT_CONTROL, region, endpointConfig);
        Endpoint dataEp = check buildAgentEndpoint(AGENT_DATA, region, endpointConfig);
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

isolated function resolveVectorKnowledgeBase(BedrockTransport controlTransport,
        string|SelfManagedKnowledgeBaseDefinition knowledgeBase) returns KbAttachResult|ai:Error {
    if knowledgeBase is string {
        map<json> _ = check verifyVectorKnowledgeBaseUsable(controlTransport, knowledgeBase);
        return {knowledgeBaseId: knowledgeBase, createdDataSourceId: ()};
    }
    string[] candidates = check listKnowledgeBaseIdsByName(controlTransport, knowledgeBase.name);
    if candidates.length() == 1 {
        map<json> existing = check verifyVectorKnowledgeBaseUsable(controlTransport, candidates[0]);
        // `storageConfiguration` names the vector store the caller thinks it is using.
        check assertDefinitionMatches(candidates[0], createVectorKnowledgeBaseRequestBody(knowledgeBase),
            existing);
        return {knowledgeBaseId: candidates[0], createdDataSourceId: ()};
    }
    if candidates.length() > 1 {
        return error ai:Error(nameAmbiguityMessage(knowledgeBase.name, candidates));
    }
    // Same duplicate-name handling as the managed path.
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

isolated function createVectorKnowledgeBaseRecoveringFromConflict(BedrockTransport controlTransport,
        SelfManagedKnowledgeBaseDefinition def) returns KbCreateOutcome|ai:Error {
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
    // AWS documents `CreateDataSource` as asynchronous, so poll.
    string status = stringField(dataSource, "status") ?: "";
    if status != "AVAILABLE" {
        check pollDataSourceAvailable(controlTransport, kbId, id, DEFAULT_DATA_SOURCE_READY_TIMEOUT);
    }
    return id;
}

// ============================================================================
// Retrieval.
// ============================================================================

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

// The self-managed `DeleteRetrieveCaller`: no reranking and no forced search type, so
// enumeration behaves like the `retrieve()` the filter was written for.
isolated function vectorDeleteRetrieve(BedrockTransport dataTransport, string kbId, json? filter,
        int numberOfResults, string? nextToken) returns [json[], string?]|ai:Error
    => callVectorRetrieve(dataTransport, kbId, FILTER_PROBE_QUERY, filter, numberOfResults, (), (), nextToken);
