## Overview

This module provides native [Ballerina `ai`](https://central.ballerina.io/ballerina/ai/latest) model and
embedding providers for **AWS Bedrock**, implementing the standard `ai:ModelProvider` and
`ai:EmbeddingProvider` contracts.

Bedrock exposes LLMs through **two endpoints with incompatible wire contracts**, and this module hides
both:

| Endpoint | Inference APIs | Signing scope |
| --- | --- | --- |
| `bedrock-runtime.{region}.amazonaws.com` | InvokeModel, Converse | `bedrock` |
| `bedrock-mantle.{region}.api.aws` | Responses, Chat Completions, Messages | `bedrock-mantle` |

Claude Mythos Preview, GPT-5.5, and GPT-5.4 live **only** on `bedrock-mantle` — a Converse-only provider
cannot reach them at all. That is the reason this module exists.

### Key features

- Chat completion across seven vendors through one `ai:ModelProvider` contract
- Structured output (`generate()`) with native tool-forcing on Converse and InvokeModel
- Text embeddings through the `ai:EmbeddingProvider` contract, with order-preserving batching
- Automatic endpoint, dialect, and SigV4 signing-scope resolution per model id
- The full AWS credential chain (IMDSv2, ECS, EKS IRSA, SSO, profiles, `AssumeRole`) via
  `ballerinax/aws.auth` — zero credential configuration on AWS compute — plus Bedrock API keys (bearer)
- Cross-region inference (CRIS) profiles, provisioned and custom-deployment ARNs
- Guardrail support on both `bedrock-runtime` inference APIs

### Providers

The public surface is split **by vendor**. Each class is a thin typed facade over one shared internal
spine (resolver → endpoint builder → converter → SigV4 transport).

**Chat** — `AnthropicModelProvider`, `OpenAIModelProvider`, `AmazonModelProvider` (Nova),
`MistralModelProvider`, `QwenModelProvider`, `GoogleModelProvider` (Gemma), `DeepSeekModelProvider`.

**Embeddings** — `TitanEmbeddingProvider`, `CohereEmbeddingProvider`.

A model AWS ships before this module updates an enum is still usable — pass its id as a `string`. Every
provider takes `<Vendor>Model|string`, so the enums are autocomplete and documentation, never a gate.
Passing a raw string skips the enum, not the routing: an id the resolver does not recognise resolves to
**Converse**, never to Mantle. A brand-new *Mantle-only* model is the one case that needs a module
release, because its request path cannot be derived from its id. See [Escape hatches](#escape-hatches).

> **A vendor is not an endpoint.** Which class you pick does not tell you which endpoint you reach:
> **Gemma 3** is dual-homed and defaults to `bedrock-mantle` (its Mantle path — `/v1/chat/completions` —
> even differs from **Gemma 4**'s `/openai/v1/responses`), while a runtime-only Claude like Sonnet 4.6
> stays on Converse. The module resolves this per model id, so you don't have to — but any model that
> resolves to Mantle needs the Mantle IAM permission below and cannot do structured output.

## Prerequisites

Before using this module in your Ballerina application, complete the following:

1. Create an [AWS account](https://portal.aws.amazon.com/billing/signup).
2. [Request access to the Bedrock foundation models](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html)
   you intend to use, in the region you intend to call.
3. Arrange credentials. On EC2, ECS, EKS or Lambda there is **nothing to do** — the default
   credential chain picks up the instance profile, task role, or IRSA service account. Elsewhere,
   supply IAM access keys, an assumed role, a named profile, or a
   [Bedrock API key](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html).
4. Attach the IAM permissions for the endpoint you will reach: `bedrock:InvokeModel` for
   Converse/InvokeModel, and **additionally `bedrock-mantle:CreateInference`** for Mantle routes. See
   [Mantle needs a separate IAM permission](#mantle-needs-a-separate-iam-permission).

## Quickstart

To use the `ai.aws.bedrock` module in your Ballerina application, update the `.bal` file as follows:

### Step 1: Import the module

```ballerina
import ballerina/ai;
import ballerinax/ai.aws.bedrock;
```

### Step 2: Initialize the model provider

Only the model is required. Region falls back to `AWS_REGION`/`AWS_DEFAULT_REGION`, and credentials
to the AWS credential chain — so on AWS compute this is the whole thing:

```ballerina
final ai:ModelProvider claude = check new bedrock:AnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6);
```

Every vendor follows the same shape — `(model, region?, credentials?, serviceUrl?, maxTokens?,
temperature?, *Config)`:

```ballerina
final ai:ModelProvider nova = check new bedrock:AmazonModelProvider(bedrock:NOVA_PRO, "us-east-1");
final ai:ModelProvider gpt = check new bedrock:OpenAIModelProvider(bedrock:GPT_5_4, "us-east-2");
final ai:ModelProvider gemma = check new bedrock:GoogleModelProvider(bedrock:GEMMA_3_27B_IT, "us-east-1");
```

### Credentials

`credentials` defaults to `auth:DEFAULT_CREDENTIALS`, which walks the standard AWS chain —
environment variables, EKS IRSA web identity, IAM Identity Center (SSO), the shared config file,
`credential_process`, ECS container credentials, then EC2 IMDSv2 — with expiry and refresh handled
for you. **On EC2, ECS, EKS and Lambda you do not configure credentials at all.**

To be explicit, pass any [`ballerinax/aws.auth`](https://central.ballerina.io/ballerinax/aws/latest)
config, or a Bedrock API key:

```ballerina
import ballerinax/aws.auth;

// Long-lived keys (add `sessionToken` for temporary STS credentials).
bedrock:BedrockCredentials keys = {accessKeyId: "...", secretAccessKey: "..."};

// Cross-account: assume a role in another account.
bedrock:BedrockCredentials role = {
    roleArn: "arn:aws:iam::222222222222:role/IntegratorRole",
    externalId: "optional-for-third-party-access"
};

// A named profile from ~/.aws/credentials.
bedrock:BedrockCredentials profile = {profileName: "prod"};

// A Bedrock API key (bearer) — bypasses SigV4 entirely.
bedrock:BedrockCredentials apiKey = {apiKey: "..."};

final ai:ModelProvider claude =
    check new bedrock:AnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6, "us-east-1", role);
```

### Step 3: Invoke chat completion

```ballerina
ai:ChatAssistantMessage response = check claude->chat([
    {role: ai:SYSTEM, content: "Be brief."},
    {role: ai:USER, content: "Why is the sky blue?"}
]);
```

### Step 4: Generate structured output

```ballerina
type Review record {| string sentiment; int score; |};

Review review = check claude->generate(`Rate this review: ${text}`);
```

> **Under `AUTO`, `generate()` falls back to Converse by itself.** A Mantle-capable model routes `chat()`
> to `bedrock-mantle`, which has no structured output — so when the same model is **also** served on
> `bedrock-runtime` (`CLAUDE_OPUS_5`, `CLAUDE_OPUS_4_8`, `CLAUDE_SONNET_5`, `CLAUDE_HAIKU_4_5`,
> `DEEPSEEK_V3_2`, Gemma 3, GLM 5, gpt-oss, Qwen3, Mistral Large 3), a typed `generate()` quietly
> resolves a second Converse spine and uses that. You do not have to set `apiFamily` yourself.
>
> **This means one provider can talk to two endpoints, which need two different IAM permissions:**
> `bedrock-mantle:CreateInference` for `chat()` and `bedrock:InvokeModel` for a typed `generate()`.
> Credentials holding only one will see the other path return 403.
>
> Two cases still return an `ai:Error` for a non-`string` target:
> - **Mantle-only models** (`GPT_5_4`, `GPT_5_5`, `CLAUDE_MYTHOS_5`, `CLAUDE_MYTHOS_PREVIEW`, Gemma 4).
>   There is no `bedrock-runtime` route to fall back to.
> - **An explicit `apiFamily = bedrock:MANTLE`.** The fallback is an `AUTO` convenience; naming a
>   destination explicitly is respected rather than silently overridden.
>
> A `string` target always returns text normally, and `chat()` is unaffected in every case.
>
> It is also unavailable on Mistral's **text-completion** dialect (see below), which has no tool-calling
> at all. This only bites when you force `apiFamily = INVOKE` on those ids — the default Converse route
> supports typed generation for every Mistral model.

### Step 5: Generate embeddings

```ballerina
final ai:EmbeddingProvider titan = check new bedrock:TitanEmbeddingProvider(
    bedrock:TITAN_EMBED_TEXT_V2, "us-east-1", creds, dimensions = 1024);

ai:Embedding vector = check titan->embed({content: "hello", 'type: "text-chunk"});
```

`batchEmbed` preserves input order. Note the wire asymmetry: Titan's `inputText` is a single string, so
n chunks is n sequential round trips; Cohere batches up to 96 per call.

## Two callouts that will silently cost you

### Mantle needs a separate IAM permission

**Mantle is a different IAM namespace.** Working `bedrock:InvokeModel` permissions are **not** enough —
Mantle requires **`bedrock-mantle:CreateInference`**, with its own managed policies. Without it you get
`AccessDenied` from a service you never meant to call, with no clue why. (This module's 403 error message
names the action for you.)

See [IAM for Bedrock powered by AWS Mantle](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonbedrockpoweredbyawsmantle.html).

### Cohere `inputType` decides your retrieval quality

**Cohere requires `input_type` on every request, and getting it wrong degrades retrieval silently** — no
error, no exception, just worse results. Use **`SEARCH_DOCUMENT` for your corpus** and **`SEARCH_QUERY`
for your queries**, constructing one provider per role:

```ballerina
// Ingest side
final ai:EmbeddingProvider ingest = check new bedrock:CohereEmbeddingProvider(
    bedrock:COHERE_EMBED_ENGLISH_V3, "us-east-1", creds, inputType = bedrock:SEARCH_DOCUMENT);

// Query side
final ai:EmbeddingProvider query = check new bedrock:CohereEmbeddingProvider(
    bedrock:COHERE_EMBED_ENGLISH_V3, "us-east-1", creds, inputType = bedrock:SEARCH_QUERY);
```

The `ai:EmbeddingProvider` contract carries no query-vs-document signal, which is exactly why this is
config rather than a method argument. It defaults to `SEARCH_DOCUMENT`.

## Routing

You pick a model; the module picks the wire dialect. The resolver runs once, at construction.

Under `AUTO` (the default), the preference order is **Mantle → Converse → Invoke**: any model with a
verified Mantle entry defaults to `bedrock-mantle`; Converse is chosen when the model has no Mantle
entry; Invoke is reached only by asking for it (`apiFamily = bedrock:INVOKE`).

| You pass | Resolves to |
| --- | --- |
| a Mantle-capable bare id (`anthropic.claude-opus-4-8`, `anthropic.claude-sonnet-5`, `openai.gpt-5.4`, `google.gemma-4-31b`) | Mantle, on that model's own path |
| a CRIS id (`us.anthropic.claude-opus-4-8`) | Converse, prefix re-applied on the wire |
| a bare id with no Mantle entry (`amazon.nova-pro-v1:0`, `anthropic.claude-sonnet-4-6`) | Converse |
| `provisioned-model/` · `custom-model-deployment/` · `inference-profile/` ARN | Converse |
| an unknown id | Converse — **never** Mantle |
| `imported-model/` ARN | **not supported** — construction error |

> **`generate()` with a typed (non-`string`) return errors on any model that `AUTO` sends to Mantle**,
> because Mantle has no structured-output path. To get typed generation on a dual-homed model such as
> Claude Sonnet 5 or Opus 4.8, force the runtime surface: `apiFamily = bedrock:CONVERSE` (or a
> `converse/` prefix). **`chat()` is unaffected** — it works the same on either route. A CRIS-prefixed id
> already resolves to Converse, so it is unaffected too.

A CRIS geo prefix (`us.`, `eu.`, …) is a `bedrock-runtime` concept — Mantle has no geo prefixes — so a
geo-prefixed id always stays on Converse regardless of the Mantle preference.

Mantle is matched by the `MANTLE_CAPABLE` table only. A model's *absence* from
that table is never taken as evidence it is a Mantle model: an unknown id sinks to Converse, so a typo
can never become a cryptic 403 from a different service with a different IAM namespace.

### Escape hatches

```ballerina
// 1. Force a family (default is AUTO, which runs the resolver)
check new bedrock:AnthropicModelProvider("anthropic.claude-haiku-4-5", "us-east-1", creds,
        apiFamily = bedrock:MANTLE);

// 2. Prefix override on the model string
check new bedrock:AnthropicModelProvider("mantle/anthropic.claude-haiku-4-5", "us-east-1", creds);

// 3. Any raw model id string is always accepted — the model enums are
//    conveniences, never a gate. A model AWS shipped after this release works today.
check new bedrock:AmazonModelProvider("amazon.nova-something-new-v1:0", "us-east-1", creds);
```

**A brand-new model needs no module release to reach Converse or Invoke** — pass its id as a string.
The one exception is a brand-new **Mantle** model: its request path is per-model data that cannot be
derived from the id, so it needs a table entry. Forcing `apiFamily = MANTLE` on a model absent from
`MANTLE_CAPABLE` returns a construction error rather than guessing a path.

### FIPS endpoints

Set `fips` and the host comes from AWS SDK endpoint metadata — no host-name guessing:

```ballerina
check new bedrock:AnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6, "us-gov-west-1",
    config = {fips: true});
// → https://bedrock-runtime-fips.us-gov-west-1.amazonaws.com
```

> FIPS applies to `bedrock-runtime` only. There is **no** `bedrock-mantle` FIPS host, so `fips` on a
> Mantle-resolved model is a **construction error** rather than a DNS failure at call time. Use
> `apiFamily = bedrock:CONVERSE` (or `INVOKE`) for a FIPS-compliant call.

It changes only the host dialled. The SigV4 signing scope, the request path, and the body are untouched.

### Custom endpoints (`serviceUrl`)

`serviceUrl` defaults to the template `https://bedrock-{endpoint}.{region}.{domain}`. Left at its
default, the origin is resolved entirely from AWS SDK endpoint metadata — every partition, the
FIPS variants, and per-service exceptions, with a standard-pattern fallback for regions newer than the
bundled metadata. That covers `amazonaws.com.cn` in China and `api.aws` for Mantle automatically.

```ballerina
// PrivateLink VPC endpoint, or any gateway / mock server — fully literal
serviceUrl = "https://vpce-0abc.bedrock-runtime.us-east-1.vpce.amazonaws.com"

// Partial override: pin the service segment, let region and domain resolve
serviceUrl = "https://bedrock-{endpoint}.{region}.{domain}"
```

It replaces the **origin only** — the route-derived request path is still appended — and it never
changes the SigV4 scope: a VPCE or gateway host still signs the route's own region and service. A
placeholder that survives substitution (a typo like `{regoin}`) is a construction error, not a DNS
failure.

### Inference parameters

`additionalModelRequestFields` forwards anything Converse does not model (Claude `top_k`/`thinking`, Nova
`reasoningConfig`, sampling knobs beyond `temperature`, …) verbatim.

The module deliberately exposes only `maxTokens` and `temperature` as first-class inference knobs — the
two an integration developer actually reaches for. Anything finer-grained (`top_p`, `top_k`, …) goes
through `additionalModelRequestFields` rather than cluttering the config record. Note that passthrough is
honoured on Converse, Nova, OpenAI-chat, Responses, Mistral, and Invoke-DeepSeek, but **not** on the
Invoke-Anthropic converter.

> **`temperature` has no default, and that is deliberate.** Leave it unset and the field is omitted from
> the request entirely, so the model applies its own default. This is not a style choice: Anthropic
> deprecated sampling parameters on Claude 4.7 and later (`CLAUDE_OPUS_4_8`, `CLAUDE_OPUS_5`,
> `CLAUDE_SONNET_5`, `CLAUDE_MYTHOS_5`) and OpenAI's GPT-5.x reasoning models (`GPT_5_4`, `GPT_5_5`,
> `GPT_5_6_*`) never accepted them. On those models **any** value returns
> `400 temperature is deprecated for this model`, so a module-level default would make them unusable out
> of the box. Set `temperature` only for models you know accept it — Nova, Mistral, Qwen, Gemma,
> DeepSeek, GPT-OSS, and Claude 4.6 and earlier.

`maxTokens` **does** default (to 4096). It is capped per model — Nova Pro/Lite/Micro top out at 5K output
tokens — and on adaptive-thinking models the thinking pass is billed against the same ceiling, so raise
it for long reasoning tasks.

## Vendor dialects

### Mistral speaks two InvokeModel dialects

Mistral is the one vendor whose `InvokeModel` wire shape cannot be derived from its vendor prefix:

| Dialect | Models | Wire |
| --- | --- | --- |
| [text completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-text-completion.html) | 7B Instruct, Mixtral 8x7B, **Large 24.02** | `prompt` (`<s>[INST]…[/INST]`) → `outputs[].text`; no tools |
| [chat completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-large-2407.html) | **Large 24.07**, newer ids | `messages`/`tools` → `choices[].message` |

Note that `mistral-large-**2402**` and `mistral-large-**2407**` are the same family four months apart and
speak *opposite* dialects. The module picks by id; an id it has never seen defaults to chat. If it guesses wrong, Bedrock returns a
`ValidationException` — switch to `apiFamily = bedrock:CONVERSE`, which is model-agnostic and sidesteps
the split entirely.

**Converse (the default) hides all of this** — the split only matters under `apiFamily = INVOKE`.

### DeepSeek does too

Same story, split by generation rather than by date:

| Dialect | Models | Wire |
| --- | --- | --- |
| [text completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-deepseek.html) | **R1** (`deepseek.r1-v1:0`) | `prompt` (DeepSeek's `<｜User｜>` template) → `choices[].text`; no tools |
| [chat completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-v3-2.html) | **V3.1**, **V3.2**, newer ids | `messages`/`tools` → `choices[].message` |

The module picks by id, and an id it has never seen defaults to chat. Again, only relevant under
`apiFamily = INVOKE` — Converse and Mantle are unaffected.

## Guardrails

| Route | Mechanism |
| --- | --- |
| Converse | `guardrailConfig` body field |
| Invoke | `X-Amzn-Bedrock-Guardrail*` request headers; the fired signal returns in the response body |
| Mantle | not supported → construction error pointing at `ApplyGuardrail` |

A fired guardrail is never silently dropped on either supported route.

## Fails fast, before any network call

Construction errors are reserved for what AWS *cannot* diagnose for you:

- an `imported-model/` ARN (AWS applies no default chat template to imported weights)
- an unresolved `{placeholder}` left in `serviceUrl`
- `apiFamily = MANTLE` on a model with no known Mantle request path
- a guardrail on a Mantle route (the error names the standalone `ApplyGuardrail` API)
- Mantle on a partition with no `api.aws` host (`aws-cn`); GovCloud **is** supported
- a `custom-model/` ARN (an artifact, not a deployment)

Everything AWS *can* tell you — a model unavailable in a region, a bad id — is left to Bedrock's own
`ValidationException`, so this module never becomes a release dependency for AWS's catalogue.

## Migrating from 0.9.x

Credentials moved to [`ballerinax/aws.auth`](https://central.ballerina.io/ballerinax/aws/latest), which
required reordering `init` — Ballerina requires required parameters before defaultable ones, and both
`region` and `credentials` are now defaultable.

**Argument order changed on all nine providers:**

```ballerina
// 0.9.x
check new bedrock:AnthropicModelProvider(creds, bedrock:CLAUDE_SONNET_4_6, "us-east-1");

// now — model first, credentials optional
check new bedrock:AnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6, "us-east-1", creds);
```

**`StaticCredentials` and `StsCredentials` were removed.** Both collapse into
`auth:StaticAuthConfig`, whose `sessionToken` is optional. Inline record literals are unchanged —
`{accessKeyId, secretAccessKey}` and `{accessKeyId, secretAccessKey, sessionToken}` both still work;
only code that named those types needs editing. `BearerToken` is unchanged.

**FIPS moved from a `serviceUrl` template to `config = {fips: true}`.** The old
`"https://bedrock-{endpoint}-fips.{region}.{domain}"` still works, but the flag takes the host from SDK
metadata and rejects FIPS-on-Mantle at construction.

Nothing else moved. `serviceUrl`, `DEFAULT_SERVICE_URL` and all three placeholders behave as before,
and SigV4 signing is unchanged — see [Not implemented](#not-implemented) for why signing stayed
in-module.

## Not implemented

Streaming (the codec seam exists, but no `decodeStream`), image/video/audio embeddings and
`StartAsyncInvoke` (the `ai:Chunk` contract carries text), provisioned-throughput embedding ARNs,
Meta/Llama, and Custom Model Import (`imported-model/` ARNs).

**SigV4 signing is not delegated to `aws.auth`,** though credential resolution and endpoint metadata
are. `auth:getSignedHeaders` builds its canonical URI by double-encoding while always treating `/` as a
path separator, so for a model-id ARN it produces `...inference-profile/us.anthropic...` where AWS
expects `...inference-profile%252Fus.anthropic...`. No input fixes this — a literal `/` survives both
passes, and a pre-encoded `%2F` becomes `%25252F` — so every provisioned-model, inference-profile and
custom-model-deployment ARN would fail with `SignatureDoesNotMatch`. Verified against `ballerinax/aws`
1.0.1 on 2026-08-09.

Deliberately **not** surfaced as config, because the `ai` contract has nowhere to return them:
`additionalModelResponseFieldPaths` (its result would be dropped — `ai:ChatAssistantMessage` is
`{role, content, toolCalls}`) and `requestMetadata` (write-only; it tags invocation logs).
`top_p`/`top_k` and other fine-grained sampling knobs go through `additionalModelRequestFields`.
