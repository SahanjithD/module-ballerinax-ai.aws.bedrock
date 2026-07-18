# Ballerina AWS Bedrock AI Provider

`ballerinax/ai.aws.bedrock` — native [Ballerina `ai`](https://central.ballerina.io/ballerina/ai/latest)
model and embedding providers for **AWS Bedrock**.

Bedrock exposes LLMs through **two endpoints with incompatible wire contracts**, and this module hides
both behind the standard `ai:ModelProvider` / `ai:EmbeddingProvider` contracts:

| Endpoint | Inference APIs | Signing scope |
| --- | --- | --- |
| `bedrock-runtime.{region}.amazonaws.com` | InvokeModel, Converse | `bedrock` |
| `bedrock-mantle.{region}.api.aws` | Responses, Chat Completions, Messages | `bedrock-mantle` |

Claude Mythos Preview, GPT-5.5, and GPT-5.4 live **only** on `bedrock-mantle` — a Converse-only provider
cannot reach them at all. That is the reason this module exists.

## Providers

The public surface is split **by vendor**. Each class is a thin typed facade over one shared internal
spine (resolver → endpoint builder → codec → SigV4 transport).

**Chat** — `AnthropicModelProvider`, `OpenAIModelProvider`, `AmazonModelProvider` (Nova),
`MistralModelProvider`, `QwenModelProvider`, `GoogleModelProvider` (Gemma), `DeepSeekModelProvider`.

**Embeddings** — `TitanEmbeddingProvider`, `CohereEmbeddingProvider`.

A model AWS ships before we update an enum is always reachable by passing its id as a `string`.

> **A vendor is not an endpoint.** Which class you pick does not tell you which endpoint you reach:
> **Gemma 3** is dual-homed and defaults to `bedrock-mantle` (its Mantle path — `/v1/chat/completions`
> — even differs from **Gemma 4**'s `/openai/v1/responses`), while a runtime-only Claude like Sonnet 4.6
> stays on Converse. The module resolves this per model id, so you don't have to — but any model that
> resolves to Mantle needs the Mantle IAM permission below and cannot do structured output.

## Quick start

### Chat

```ballerina
import ballerina/ai;
import ballerinax/ai.aws.bedrock;

final ai:ModelProvider claude = check new bedrock:AnthropicModelProvider(
    {accessKeyId, secretAccessKey}, bedrock:CLAUDE_SONNET_4_6, "us-east-1");

ai:ChatAssistantMessage response = check claude->chat([
    {role: ai:SYSTEM, content: "Be brief."},
    {role: ai:USER, content: "Why is the sky blue?"}
]);
```

Every vendor follows the same shape — `(credentials, model, region, maxTokens?, temperature?, *Config)`:

```ballerina
final ai:ModelProvider nova = check new bedrock:AmazonModelProvider(creds, bedrock:NOVA_PRO, "us-east-1");
final ai:ModelProvider gpt = check new bedrock:OpenAIModelProvider(creds, bedrock:GPT_5_4, "us-east-2");
final ai:ModelProvider gemma = check new bedrock:GoogleModelProvider(creds, bedrock:GEMMA_3_27B_IT, "us-east-1");
```

Credentials are a union — static keys, STS, or a Bedrock API key:

```ballerina
bedrock:BedrockCredentials staticKeys = {accessKeyId: "...", secretAccessKey: "..."};
bedrock:BedrockCredentials sts = {accessKeyId: "...", secretAccessKey: "...", sessionToken: "..."};
bedrock:BedrockCredentials apiKey = {apiKey: "..."};   // Bedrock API key (bearer)
```

### Structured output — `generate()`

```ballerina
type Review record {| string sentiment; int score; |};

Review review = check claude->generate(`Rate this review: ${text}`);
```

> **Structured output is not available on the `bedrock-mantle` route.** A provider resolved to Mantle
> returns an `ai:Error` naming the model when the target type is anything other than `string`; a
> `string` target returns text normally.
>
> Under `AUTO` this includes **every Mantle-capable model** — the Mantle-only ones (`GPT_5_4`,
> `CLAUDE_MYTHOS_PREVIEW`, …) **and** the dual-homed ones (`CLAUDE_OPUS_4_8`, `CLAUDE_SONNET_5`,
> `DEEPSEEK_V3_2`, …), because `AUTO` now prefers Mantle (see [Routing](#routing)). For typed
> generation on a dual-homed model, force the runtime surface with `apiFamily = bedrock:CONVERSE`. The
> example above works because `CLAUDE_SONNET_4_6` is runtime-only, so it resolves to Converse.

> It is also unavailable on Mistral's **text-completion** dialect (see below), which has no
> tool-calling at all. This only bites when you force `apiFamily = INVOKE` on those ids — the default
> Converse route supports typed generation for every Mistral model.

### Mistral speaks two InvokeModel dialects

Mistral is the one vendor whose `InvokeModel` wire shape cannot be derived from its vendor prefix:

| Dialect | Models | Wire |
| --- | --- | --- |
| [text completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-text-completion.html) | 7B Instruct, Mixtral 8x7B, **Large 24.02** | `prompt` (`<s>[INST]…[/INST]`) → `outputs[].text`; no tools |
| [chat completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-large-2407.html) | **Large 24.07**, newer ids | `messages`/`tools` → `choices[].message` |

Note that `mistral-large-**2402**` and `mistral-large-**2407**` are the same family four months apart
and speak *opposite* dialects. The module picks by id; an id it has never seen defaults to chat.
`modelSchema = bedrock:MISTRAL_TEXT` forces the legacy dialect for imported models.

**Converse (the default) hides all of this** — the split only matters under `apiFamily = INVOKE`.

### Embeddings

```ballerina
final ai:EmbeddingProvider titan = check new bedrock:TitanEmbeddingProvider(
    creds, bedrock:TITAN_EMBED_TEXT_V2, "us-east-1", dimensions = 1024);

ai:Embedding vector = check titan->embed({content: "hello", 'type: "text-chunk"});
```

`batchEmbed` preserves input order. Note the wire asymmetry: Titan's `inputText` is a single string, so
n chunks is n sequential round trips; Cohere batches up to 96 per call.

## ⚠️ Two callouts that will silently cost you

### **Mantle needs a separate IAM permission**

**Mantle is a different IAM namespace.** Working `bedrock:InvokeModel` permissions are **not** enough —
Mantle requires **`bedrock-mantle:CreateInference`**, with its own managed policies. Without it you get
`AccessDenied` from a service you never meant to call, with no clue why. (This module's 403 error message
names the action for you.)

See [IAM for Bedrock powered by AWS Mantle](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonbedrockpoweredbyawsmantle.html).

### **Cohere `inputType` decides your retrieval quality**

**Cohere requires `input_type` on every request, and getting it wrong degrades retrieval silently** — no
error, no exception, just worse results. Use **`SEARCH_DOCUMENT` for your corpus** and **`SEARCH_QUERY`
for your queries**, constructing one provider per role:

```ballerina
// Ingest side
final ai:EmbeddingProvider ingest = check new bedrock:CohereEmbeddingProvider(
    creds, bedrock:COHERE_EMBED_ENGLISH_V3, "us-east-1", inputType = bedrock:SEARCH_DOCUMENT);

// Query side
final ai:EmbeddingProvider query = check new bedrock:CohereEmbeddingProvider(
    creds, bedrock:COHERE_EMBED_ENGLISH_V3, "us-east-1", inputType = bedrock:SEARCH_QUERY);
```

The `ai:EmbeddingProvider` contract carries no query-vs-document signal, which is exactly why this is
config rather than a method argument. It defaults to `SEARCH_DOCUMENT`.

## Routing

You pick a model; the module picks the wire dialect. The resolver runs once, at construction.

Under `AUTO` (the default), the preference order is **Mantle → Converse → Invoke**: any model with a
verified Mantle entry defaults to `bedrock-mantle`; Converse is chosen when the model has no Mantle
entry; Invoke only for `imported-model/` ARNs.

| You pass | Resolves to |
| --- | --- |
| a Mantle-capable bare id (`anthropic.claude-opus-4-8`, `anthropic.claude-sonnet-5`, `openai.gpt-5.4`, `google.gemma-4-31b`) | Mantle, on that model's own path |
| a CRIS id (`us.anthropic.claude-opus-4-8`) | Converse, prefix re-applied on the wire |
| a bare id with no Mantle entry (`amazon.nova-pro-v1:0`, `anthropic.claude-sonnet-4-6`) | Converse |
| `provisioned-model/` · `custom-model-deployment/` · `inference-profile/` ARN | Converse |
| `imported-model/` ARN | Invoke (**requires `modelSchema`**) |
| an unknown id | Converse — **never** Mantle |

> **`generate()` with a typed (non-`string`) return errors on any model that `AUTO` sends to Mantle**,
> because Mantle has no structured-output path. To get typed generation on a dual-homed model such as
> Claude Sonnet 5 or Opus 4.8, force the runtime surface: `apiFamily = bedrock:CONVERSE` (or a
> `converse/` prefix). **`chat()` is unaffected** — it works the same on either route. A CRIS-prefixed
> id already resolves to Converse, so it is unaffected too.

A CRIS geo prefix (`us.`, `eu.`, …) is a `bedrock-runtime` concept — Mantle has no geo prefixes — so a
geo-prefixed id always stays on Converse regardless of the Mantle preference.

Mantle is matched by the `MANTLE_CAPABLE` table or an explicit override only. A model's *absence* from
that table is never taken as evidence it is a Mantle model: an unknown id sinks to Converse, so a typo
can never become a cryptic 403 from a different service with a different IAM namespace.

### Escape hatches

AWS ships models faster than releases are cut, so nothing here is a dead end:

```ballerina
// 1. Force a family (default is AUTO, which runs the resolver)
check new bedrock:AnthropicModelProvider(creds, "anthropic.claude-haiku-4-5", "us-east-1",
        apiFamily = bedrock:MANTLE);

// 2. Prefix override on the model string
check new bedrock:AnthropicModelProvider(creds, "mantle/anthropic.claude-haiku-4-5", "us-east-1");

// 3. Teach the tables a brand-new model without a release
check new bedrock:OpenAIModelProvider(creds, "openai.gpt-6", "us-east-2",
        routeOverrides = {"openai.gpt-6": {path: "/openai/v1/responses",
                                           authHeader: bedrock:BEARER,
                                           codec: bedrock:RESPONSES_CODEC}});

// 4. Any raw model id string is always accepted
check new bedrock:AmazonModelProvider(creds, "amazon.nova-something-new-v1:0", "us-east-1");
```

`additionalModelRequestFields` forwards anything Converse does not model (Claude `top_k`/`thinking`,
Nova `reasoningConfig`, …) verbatim.

## Fails fast, before any network call

Construction errors are reserved for what AWS *cannot* diagnose for you:

- an `imported-model/` ARN without `modelSchema` (AWS applies no default chat template)
- a guardrail on a Mantle route (the error names the standalone `ApplyGuardrail` API)
- Mantle on a `cn-`/GovCloud partition (the `api.aws` host is not partition-templated)
- a `custom-model/` ARN (an artifact, not a deployment)

Everything AWS *can* tell you — a model unavailable in a region, a bad id — is left to Bedrock's own
`ValidationException`, so this module never becomes a release dependency for AWS's catalogue.

## Guardrails

| Route | Mechanism |
| --- | --- |
| Converse | `guardrailConfig` body field |
| Invoke | `X-Amzn-Bedrock-Guardrail*` request headers; the fired signal returns in the response body |
| Mantle | not supported → construction error pointing at `ApplyGuardrail` |

A fired guardrail is never silently dropped on either supported route.

## Building

The `generate()` native shim must be built before `bal build`:

```bash
BAL_HOME=$(bal home)
mkdir -p native/build/classes native/build/libs
javac -cp "$BAL_HOME/bre/lib/ballerina-rt-2201.12.0.jar" \
      -d native/build/classes native/src/main/java/io/ballerina/lib/ai/aws/bedrock/*.java
(cd native/build/classes && jar cf ../libs/ai.aws.bedrock-native-0.1.0.jar io)

cd ballerina && bal build && bal test
```

## Not implemented

Streaming (the codec seam exists, but no `decodeStream`), image/video/audio embeddings and
`StartAsyncInvoke` (the `ai:Chunk` contract carries text), provisioned-throughput embedding ARNs, and
Meta/Llama.
