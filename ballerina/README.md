## Overview

[Amazon Bedrock](https://aws.amazon.com/bedrock/) is a fully managed service that offers foundation models from Amazon and other leading AI companies through a single API.

The AWS Bedrock connector provides model, embedding and knowledge base providers for the [Ballerina `ai`](https://central.ballerina.io/ballerina/ai/latest) module, implementing the `ai:ModelProvider`, `ai:EmbeddingProvider` and `ai:KnowledgeBase` contracts.

### Key Features

- Chat completion and structured output (`generate()`) with Anthropic Claude, OpenAI, Amazon Nova, Mistral, Qwen, Google Gemma and DeepSeek models
- `ConverseModelProvider` for any other model Bedrock serves through the Converse API
- A choice of API per model: Converse (default), InvokeModel, Anthropic Messages, Chat Completions and Responses
- Text embeddings with Amazon Titan and Cohere models
- Managed and self-managed Bedrock knowledge bases
- Guardrails, image input, and cross-region inference profiles
- Flexible credential configuration: static keys, AWS profiles, assumed roles, the default AWS credential provider chain, or Bedrock API keys

## Prerequisites

Before using this module in your Ballerina application, complete the following:

1. Create an [AWS account](https://portal.aws.amazon.com/billing/signup).
2. Make sure the [Bedrock models](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html) you plan to use are available to your account in your region.
3. Grant the `bedrock:InvokeModel` IAM permission for those models. Knowledge base ingestion also needs `bedrock:StartIngestionJob` and `bedrock:IngestKnowledgeBaseDocuments`.

## Quickstart

To use the `ai.aws.bedrock` module in your Ballerina application, update the `.bal` file as follows:

### Step 1: Import the module

Import the `ai.aws.bedrock` module.

```ballerina
import ballerina/ai;
import ballerinax/aws;
import ballerinax/aws.auth;
import ballerinax/ai.aws.bedrock;
```

### Step 2: Initialize the Model Provider

Every model provider takes a model, credentials and a region:

```ballerina
final ai:ModelProvider claude = check new bedrock:RuntimeAnthropicModelProvider(
        bedrock:CLAUDE_SONNET_4_6, auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);
```

One class is provided per vendor: `RuntimeAnthropicModelProvider`, `RuntimeOpenAIModelProvider`, `RuntimeAmazonModelProvider`, `RuntimeMistralModelProvider`, `RuntimeQwenModelProvider`, `RuntimeGoogleModelProvider` and `RuntimeDeepSeekModelProvider`. For any other vendor, use `ConverseModelProvider` with the model ID:

```ballerina
final ai:ModelProvider llama = check new bedrock:ConverseModelProvider(
        "us.meta.llama3-3-70b-instruct-v1:0", auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);
```

The default API is Converse. To use a vendor's own API instead, set `apiType`:

```ballerina
final ai:ModelProvider claudeMessages = check new bedrock:RuntimeAnthropicModelProvider(
        bedrock:CLAUDE_SONNET_4_6, auth:DEFAULT_CREDENTIALS, aws:US_EAST_1, apiType = bedrock:MESSAGES);
```

### Step 3: Invoke chat completion

```ballerina
ai:ChatAssistantMessage response = check claude->chat([
    {role: ai:SYSTEM, content: "Be brief."},
    {role: ai:USER, content: "Why is the sky blue?"}
]);
```

### Step 4: Generate typed output

```ballerina
type Review record {|
    string sentiment;
    int score;
|};

string text = "Great product, arrived on time.";
Review review = check claude->generate(`Rate this review: ${text}`);
```

### Step 5: Run the Ballerina application

```bash
bal run
```

## Authentication

On EC2, ECS, EKS or Lambda, `auth:DEFAULT_CREDENTIALS` picks up the instance profile, task role or service account with no further setup. Elsewhere, pass one of the following:

```ballerina
// Access keys (add `sessionToken` for temporary credentials).
bedrock:BedrockAuthConfig keys = {accessKeyId: "<ACCESS_KEY_ID>", secretAccessKey: "<SECRET_ACCESS_KEY>"};

// A named profile from ~/.aws/credentials.
bedrock:BedrockAuthConfig profile = {profileName: "<PROFILE_NAME>"};

// An assumed role.
bedrock:BedrockAuthConfig role = {roleArn: "arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_NAME>"};

// A Bedrock API key.
bedrock:BedrockAuthConfig apiKey = {apiKey: "<BEDROCK_API_KEY>"};
```

See [`ballerinax/aws`](https://central.ballerina.io/ballerinax/aws/latest) for all credential options. Bedrock API keys work with the model and embedding providers, but not with knowledge bases.

## Embeddings

```ballerina
final ai:EmbeddingProvider titan = check new bedrock:TitanEmbeddingProvider(
        bedrock:TITAN_EMBED_TEXT_V2, auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);

ai:Embedding vector = check titan->embed({content: "hello", 'type: "text-chunk"});
```

`CohereEmbeddingProvider` embeds with `search_query` from `embed()` and with `search_document` from `batchEmbed()`, which matches how `ai:VectorKnowledgeBase` uses it. If you ingest documents one at a time with `embed()`, set `inputType = bedrock:SEARCH_DOCUMENT`.

## Knowledge bases

`ManagedKnowledgeBase` works with a Bedrock managed knowledge base, where Bedrock owns the vector store. Pass the ID of an existing knowledge base:

```ballerina
final ai:KnowledgeBase kb = check new bedrock:ManagedKnowledgeBase(
        "<KNOWLEDGE_BASE_ID>", auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);

ai:QueryMatch[] matches = check kb.retrieve("What is our refund policy?", 5);
```

Or pass a definition, and the knowledge base is created if one with that name does not exist:

```ballerina
final ai:KnowledgeBase kb = check new bedrock:ManagedKnowledgeBase(
        {name: "support-docs", serviceRoleArn: "arn:aws:iam::<ACCOUNT_ID>:role/<KB_ROLE>"},
        auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);

ai:TextDocument[] docs = [{content: "Refunds are processed within 5 business days."}];
check kb.ingest(docs);
```

`ingest()` needs a `CUSTOM` data source on the knowledge base. One is created along with a new knowledge base. For an existing one, add it in the Bedrock console.

`SelfManagedKnowledgeBase` takes the same arguments and works with a knowledge base backed by a vector store you own (OpenSearch Serverless, OpenSearch managed cluster, S3 Vectors, Aurora PostgreSQL, Neptune Analytics, Pinecone, Redis Enterprise Cloud or MongoDB Atlas). The vector store must already exist.

## Notes

- **Claude model IDs need a cross-region prefix.** Current Claude models are served only through cross-region inference profiles, so use the `bedrock:CLAUDE_*` constants or an ID with a prefix such as `us.` or `global.`.
- **Any model ID can be passed as a string.** The model constants are for convenience, so a model released after this module still works.
- **`temperature` is unset by default**, so each model uses its own default. Recent Claude models reject any `temperature`.
- **`maxTokens` defaults to 4096.** Raise it for reasoning models, whose thinking counts toward the same limit.
- **The region is required.** `AWS_REGION` is not read.
- **Settings the chosen API cannot carry are rejected when the provider is created**, so they are never silently dropped. For example, a guardrail on the Responses or Messages API.
- Streaming is not supported yet.
