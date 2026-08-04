# Ballerina AWS Bedrock AI Provider

Native Ballerina `ai` model and embedding providers for **AWS Bedrock**, implementing the standard
`ai:ModelProvider` and `ai:EmbeddingProvider` contracts.

Bedrock exposes LLMs through two endpoints with incompatible wire contracts — `bedrock-runtime`
(InvokeModel, Converse; SigV4 scope `bedrock`) and `bedrock-mantle` (Responses, Chat Completions,
Messages; SigV4 scope `bedrock-mantle`). This module hides both. Claude Mythos Preview, GPT-5.5, and
GPT-5.4 live only on `bedrock-mantle`, so a Converse-only provider cannot reach them at all.

## Providers

The public surface is split by vendor; each class is a thin typed facade over one shared internal spine.

**Chat** — `AnthropicModelProvider`, `OpenAIModelProvider`, `AmazonModelProvider` (Nova),
`MistralModelProvider`, `QwenModelProvider`, `GoogleModelProvider` (Gemma), `DeepSeekModelProvider`.

**Embeddings** — `TitanEmbeddingProvider`, `CohereEmbeddingProvider`.

## Quick start

```ballerina
import ballerina/ai;
import ballerinax/ai.aws.bedrock;

final ai:ModelProvider claude = check new bedrock:AnthropicModelProvider(
    {accessKeyId, secretAccessKey}, bedrock:CLAUDE_SONNET_4_6, "us-east-1");

ai:ChatAssistantMessage response = check claude->chat([
    {role: ai:USER, content: "Why is the sky blue?"}
]);
```

## Two things that will silently cost you

**Mantle needs the separate `bedrock-mantle:CreateInference` IAM action.** Working `bedrock:InvokeModel`
permissions are **not** enough — otherwise you get `AccessDenied` with no clue why.

**Cohere's `inputType` decides retrieval quality.** Use `SEARCH_DOCUMENT` for your corpus and
`SEARCH_QUERY` for your queries — getting it wrong degrades retrieval silently, with no error.

You pick a model; the module picks the wire dialect at construction. An unknown model resolves to
Converse and **never** to Mantle. Escape hatches (`apiFamily`, `mantle/|converse/|invoke/` prefixes,
`routeOverrides`, and raw model-id strings) mean a model AWS ships tomorrow needs no release.

See the [README](https://github.com/ballerina-platform/module-ballerinax-ai.aws.bedrock) for the full
routing table, guardrail placement, and build instructions.
