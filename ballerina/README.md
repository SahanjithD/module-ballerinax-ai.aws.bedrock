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
- Image input on Converse and Anthropic Messages; a named error, never a silent drop, elsewhere

### Providers

The public surface is split **by vendor**. Each class is a thin typed facade over one shared internal
spine (resolver → endpoint builder → converter → SigV4 transport).

**Chat** — `AnthropicModelProvider`, `OpenAIModelProvider`, `AmazonModelProvider` (Nova),
`MistralModelProvider`, `QwenModelProvider`, `GoogleModelProvider` (Gemma), `DeepSeekModelProvider`.

**Embeddings** — `TitanEmbeddingProvider`, `CohereEmbeddingProvider`.

**Knowledge base** — `BedrockManagedKnowledgeBase` (Bedrock owns the vector store) and
`BedrockVectorKnowledgeBase` (you own it), both implementing `ai:KnowledgeBase`. See
[Knowledge bases](#knowledge-bases) and [Self-managed knowledge bases](#self-managed-knowledge-bases).

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
import ballerinax/aws;
import ballerinax/aws.auth;

final ai:ModelProvider claude = check new bedrock:AnthropicModelProvider(
        bedrock:CLAUDE_SONNET_4_6, auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);
```

Every vendor follows the same shape — `(model, credentials, region, apiFamily?, endpoint?,
maxTokens?, temperature?, *Config)`. `model`, `credentials` and `region` are required; `apiFamily`
and `endpoint` sit directly on `init` rather than inside the config record, because routing and
endpoint selection are decisions you make at the same moment you pick the model and region:

```ballerina
final ai:ModelProvider nova = check new bedrock:AmazonModelProvider(
        bedrock:NOVA_PRO, auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);
final ai:ModelProvider gpt = check new bedrock:OpenAIModelProvider(
        bedrock:GPT_5_4, auth:DEFAULT_CREDENTIALS, aws:US_EAST_2);
final ai:ModelProvider gemma = check new bedrock:GoogleModelProvider(
        bedrock:GEMMA_3_27B_IT, auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);
```

`region` is typed `aws:Region|string`, so the enum gives you a checked constant and the string
escape hatch still reaches a region newer than the enum. Nothing is read from the environment:
`AWS_REGION` is **not** consulted for this parameter — pass it explicitly. (Credentials are the
exception, and only because `auth:DEFAULT_CREDENTIALS` asks the AWS SDK to run its own chain.)

### Credentials

`credentials` is required — pass `auth:DEFAULT_CREDENTIALS` to walk the standard AWS chain —
environment variables, EKS IRSA web identity, IAM Identity Center (SSO), the shared config file,
`credential_process`, ECS container credentials, then EC2 IMDSv2 — with expiry and refresh handled
for you. **On EC2, ECS, EKS and Lambda that is all you need** — no keys anywhere in your code or
config. It is spelled out rather than defaulted so that the credential source a client uses is
visible at the call site; this matches every other `ballerinax/aws.*` connector, all of which make
`auth` a required field.

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
    check new bedrock:AnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6, role, aws:US_EAST_1);
```

> **Knowledge bases do NOT accept Bedrock API keys.** AWS states API keys "are limited to Amazon
> Bedrock and Amazon Bedrock Runtime actions" and cannot be used with *"Agents for Amazon Bedrock or
> Agents for Amazon Bedrock Runtime API operations"* — and both knowledge base planes
> (`bedrock-agent`, `bedrock-agent-runtime`) are exactly those. `BedrockManagedKnowledgeBase`
> therefore takes `KnowledgeBaseCredentials` (SigV4 only), so a bearer token is rejected at
> **compile time** rather than becoming an opaque runtime 403.

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
    bedrock:TITAN_EMBED_TEXT_V2, creds, "us-east-1", dimensions = 1024);

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
    bedrock:COHERE_EMBED_ENGLISH_V3, creds, "us-east-1", inputType = bedrock:SEARCH_DOCUMENT);

// Query side
final ai:EmbeddingProvider query = check new bedrock:CohereEmbeddingProvider(
    bedrock:COHERE_EMBED_ENGLISH_V3, creds, "us-east-1", inputType = bedrock:SEARCH_QUERY);
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
check new bedrock:AnthropicModelProvider("anthropic.claude-haiku-4-5", creds, "us-east-1",
        apiFamily = bedrock:MANTLE);

// 2. Prefix override on the model string
check new bedrock:AnthropicModelProvider("mantle/anthropic.claude-haiku-4-5", creds, "us-east-1");

// 3. Any raw model id string is always accepted — the model enums are
//    conveniences, never a gate. A model AWS shipped after this release works today.
check new bedrock:AmazonModelProvider("amazon.nova-something-new-v1:0", creds, "us-east-1");
```

**A brand-new model needs no module release to reach Converse or Invoke** — pass its id as a string.
The one exception is a brand-new **Mantle** model: its request path is per-model data that cannot be
derived from the id, so it needs a table entry. Forcing `apiFamily = MANTLE` on a model absent from
`MANTLE_CAPABLE` returns a construction error rather than guessing a path.

### Endpoint configuration (`endpoint`)

The host is derived from the region and the resolved route, entirely through AWS SDK endpoint
metadata. That is correct in every partition and for every route without you doing anything:

| Region | Converse / Invoke | Mantle |
|---|---|---|
| `us-east-1` | `bedrock-runtime.us-east-1.amazonaws.com` | `bedrock-mantle.us-east-1.api.aws` |
| `us-gov-west-1` | `bedrock-runtime.us-gov-west-1.amazonaws.com` | `bedrock-mantle.us-gov-west-1.api.aws` |
| `us-iso-east-1` | `bedrock-runtime.us-iso-east-1.c2s.ic.gov` | *(not served)* |
| `eusc-de-east-1` | `bedrock-runtime.eusc-de-east-1.amazonaws.eu` | *(not served)* |

Note the suffix flips between routes — `amazonaws.com` for runtime, `api.aws` for Mantle — and again
per partition. Hand-writing these is the main way to get an unexplained DNS failure, so don't.

> **`dualstack: true` is refused on every route but Mantle.** `bedrock-mantle` is the only name in this
> service family that publishes a dualstack (`.api.aws`) host — the module already forces it there, which
> is why every Mantle call works. `bedrock-runtime` (Converse, Invoke, and **both embedding providers**),
> `bedrock-agent` and `bedrock-agent-runtime` (**both knowledge-base planes**) have no `.api.aws` record
> in any region, verified by DNS. Setting the flag on those used to build the unservable host happily and
> die at call time as a bare connection error after a full retry cycle. It is now a construction error
> naming the flag and the host family. If AWS later publishes one this guard does not know about, pass
> the origin through `customEndpoint`, which outranks the guard.

The `endpoint` field on every config record is [`aws:EndpointConfig`](https://central.ballerina.io/ballerinax/aws/latest),
the same record the other `ballerinax/aws.*` connectors take:

```ballerina
// FIPS: the host spelling comes from SDK metadata, not from string-building "-fips"
check new bedrock:AnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6, creds, aws:US_GOV_WEST_1,
    endpoint = {fips: true});
// → https://bedrock-runtime-fips.us-gov-west-1.amazonaws.com

// A concrete origin: gateway, LocalStack, or a VPC endpoint
check new bedrock:AnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6, creds, aws:US_EAST_1,
    endpoint = {customEndpoint: "http://localhost:4566"});
```

`customEndpoint` replaces the **origin only** — the route-derived request path is still appended —
and it never changes the SigV4 scope: a VPCE or gateway host still signs the route's own region and
service.

> **`customEndpoint` is a global override.** It has the same semantics as the AWS SDK's
> [`AWS_ENDPOINT_URL`](https://docs.aws.amazon.com/sdkref/latest/guide/feature-ss-endpoints.html):
> one URL for **every** service the client talks to. A knowledge base client talks to two
> (`bedrock-agent` and `bedrock-agent-runtime`), and so does a provider whose `chat()` is on Mantle
> while a typed `generate()` falls back to Converse. That suits a mock or a single gateway; it does
> **not** describe a real PrivateLink deployment, where each service has its own interface endpoint
> and its own `vpce-id`. For PrivateLink, **enable private DNS and set nothing** — AWS's own guidance
> is *"No code changes needed."* If you must pin per service, the AWS-blessed mechanism is the
> per-service environment variables (`AWS_ENDPOINT_URL_BEDROCK_RUNTIME`, `..._BEDROCK_AGENT`,
> `..._BEDROCK_AGENT_RUNTIME`).

Setting `customEndpoint` also **skips the host-shape guards** below — they validate a host we would
otherwise derive, and a concrete origin means there is nothing left to validate.

### FIPS, GovCloud and Mantle

FIPS applies to `bedrock-runtime` only. There is **no** `bedrock-mantle` FIPS host, so `fips` on a
Mantle-resolved model is a **construction error** rather than a DNS failure at call time.

This bites hardest in GovCloud, so read this before deploying there:

- **FIPS is opt-in**, not automatic, matching AWS SDK behaviour. If your posture requires FIPS
  endpoints you must set `endpoint = {fips: true}` yourself.
- Under `AUTO`, a Mantle-capable model resolves to Mantle. Combined with `fips: true` that is a
  construction error on **every** flagship Claude model. Set `apiFamily = bedrock:CONVERSE`.
- **`us-gov-west-1` has Mantle; `us-gov-east-1` does not.** We deliberately do not encode region
  lists — they go stale — so a Mantle-capable model on `us-gov-east-1` builds a Mantle host and gets
  AWS's own error at call time, which names the real problem better than a stale list could.

### Partitions

- **China (`cn-`) is rejected at construction, on every API family.** Amazon Bedrock is not offered
  in the AWS China partition at all — not Mantle, not `bedrock-runtime`. The endpoint resolver would
  still happily build a well-formed host (it is a string builder and never fails), so without this
  guard the first call fails with a bare connection error naming nothing.
- **ISO and EU Sovereign partitions** (`us-iso-`, `us-isob-`, `us-isof-`, `eusc-`) reach
  `bedrock-runtime` normally. They serve no Mantle host, so under `AUTO` a Mantle-capable model
  resolves to **Converse** instead of failing — `AUTO` names no destination, so the model's only home
  there is the one it gets. An explicit `apiFamily = MANTLE` still errors, because an explicit
  override names a destination and silently going elsewhere would defeat the point of setting it.

### Inference parameters

`additionalModelRequestFields` forwards anything the module does not model (Claude `top_k`/`anthropic_beta`,
prompt-caching `cache_control`, Nova `reasoningConfig`, sampling knobs beyond `temperature`, …) verbatim.

The module deliberately exposes only `maxTokens` and `temperature` as first-class inference knobs — the
two an integration developer actually reaches for. Anything finer-grained (`top_p`, `top_k`, …) goes
through `additionalModelRequestFields` rather than cluttering the config record. It is honoured on
**every** dialect — Converse's `additionalModelRequestFields`, and the top level of each Invoke/Mantle
vendor body — and it is spliced **untouched**: the module never renames, reshapes or adds to what you put
there.

#### Route-scoped knobs are refused, never dropped

Several config fields only exist on some routes. When a field cannot reach the wire on the route your
model resolved to, **construction fails and names it** — it is never accepted and quietly ignored:

| Field | Converse | Invoke | Mantle |
|---|---|---|---|
| `serviceTier` | `serviceTier` body field | `X-Amzn-Bedrock-Service-Tier` header | **refused** |
| `latencyOptimized` | `performanceConfig` body field | `X-Amzn-Bedrock-PerformanceConfig-Latency` header | **refused** |
| `stopSequences` | ✅ | ✅ | ✅ except OpenAI Responses, which has no such parameter — **refused** |
| `thinking`, `effort` | ✅ | Anthropic dialects only | Anthropic Messages only |
| `reasoningEffort` | via passthrough | `reasoning_effort` | `reasoning: {effort}` on Responses |

Worth knowing before you upgrade:

> **`reasoningEffort` is one field with three wire shapes, and you no longer have to care which.** The
> Responses API nests it (`reasoning: {effort: "low"}`) while Chat Completions keeps it flat
> (`reasoning_effort: "low"`). Pass the value; the resolved route picks the spelling. Sending the flat
> form to a GPT-5.x model on `/openai/v1/responses` is a hard `400 Unknown parameter:
> 'reasoning_effort'`, which is what this used to do.

> **`serviceTier` / `latencyOptimized` on a Mantle-resolved model is now a construction error.** Under
> `AUTO`, Mantle-capable models resolve to `bedrock-mantle` — so `anthropic.claude-opus-4-8`,
> `openai.gpt-oss-120b-1:0`, `openai.gpt-5.x` and the Qwen tiers all take this path. Previously the field
> was accepted and silently dropped: you got an ordinary 200 for a request that never carried it, and no
> way to tell that from one that did. Set `apiFamily = CONVERSE` (or `INVOKE`) to send it as Bedrock
> defines it. Mantle's vendor-compatible surfaces do have a `service_tier` body field, but with the
> **vendor's** value set (`auto|default|flex|fast|priority|ultrafast`) rather than Bedrock's
> (`default|priority|flex|reserved`) — two first-party sources, one field name, different vocabularies —
> so this module will not guess a mapping. If you know your model's, send it through
> `additionalModelRequestFields`.

> **`temperature` has no default, and that is deliberate.** Leave it unset and the field is omitted from
> the request entirely, so the model applies its own default. This is not a style choice: Anthropic
> deprecated sampling parameters on Claude 4.7 and later (`CLAUDE_OPUS_4_8`, `CLAUDE_OPUS_5`,
> `CLAUDE_SONNET_5`, `CLAUDE_MYTHOS_5`) and OpenAI's GPT-5.x reasoning models (`GPT_5_4`, `GPT_5_5`,
> `GPT_5_6_*`) never accepted them. On those models **any** value returns
> `400 temperature is deprecated for this model`, so a module-level default would make them unusable out
> of the box. Set `temperature` only for models you know accept it — Nova, Mistral, Qwen, Gemma,
> DeepSeek, GPT-OSS, and Claude 4.6 and earlier.

> **`reasoningEffort` is a `ReasoningEffort` enum, and `minimal` is gpt-oss-only.** The members —
> `REASONING_NONE`, `REASONING_MINIMAL`, `REASONING_LOW`, `REASONING_MEDIUM`, `REASONING_HIGH`,
> `REASONING_XHIGH`, `REASONING_MAX` — are the union of what the OpenAI models on Bedrock accepted on
> 2026-09-09, read out of the endpoint's own 400s in `us-east-1`. Membership is not a promise every
> model takes it: the two families differ in exactly one value, `openai.gpt-oss-*` accepting `minimal`
> where every `openai.gpt-5.x` refuses it with `Invalid value: 'minimal'`. The module does **not**
> enforce that split — which values a model accepts is the model's contract, AWS's model cards document
> no list for either family, and a per-model table here would only go stale. The endpoint stays the
> authority: its refusal enumerates the set that model does accept, which is the list worth reading.

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

## Knowledge bases

`BedrockManagedKnowledgeBase` implements `ai:KnowledgeBase` against a Bedrock **managed** knowledge
base (`KnowledgeBaseConfiguration.type = MANAGED` — Bedrock owns the vector store; there is nothing
to provision). It spans two additional endpoints beyond the chat/embedding surface —
`bedrock-agent.{region}.amazonaws.com` (control: create/list/get/ingest/delete) and
`bedrock-agent-runtime.{region}.amazonaws.com` (data: retrieve) — both signing as SigV4 service
`bedrock`, same as Converse/InvokeModel.

`BedrockVectorKnowledgeBase` implements the same interface against a **self-managed** knowledge base
(`KnowledgeBaseConfiguration.type = VECTOR` — a vector store you provision and own), which is the
console's *Self-managed KB → Unstructured Vector Store KB*. Both classes use the same two endpoints
and the same signing scope; see [Self-managed knowledge bases](#self-managed-knowledge-bases) below
for what differs.

### Two ways to use it

**Attach to a knowledge base you configured in AWS** — pass its id. AWS owns ingestion through its
own native connectors (S3, SharePoint, Confluence, Google Drive, OneDrive, Web Crawler) on their own
sync schedule:

```ballerina
ai:KnowledgeBase kb = check new bedrock:BedrockManagedKnowledgeBase("GKICZMNWRG", creds, "us-east-1");
ai:QueryMatch[] matches = check kb->retrieve("What is our refund policy?", 5);
```

`retrieve()` searches across **every** data source on the knowledge base. `ingest()` and
`deleteByFilter()` need the knowledge base to also have a `CUSTOM` (direct-ingestion) data source —
construction fails, naming why, if it does not have one; add one in the console, or use the
find-or-create path below.

**Create and own it end to end** — pass a `KnowledgeBaseDefinition`. This class creates the knowledge
base and a `CUSTOM` data source, and every document flows through `ingest()`:

```ballerina
ai:KnowledgeBase kb = check new bedrock:BedrockManagedKnowledgeBase(
    {
        name: "support-docs",
        roleArn: "arn:aws:iam::123456789012:role/service-role/bedrock-kb-execution-role"
    },
    creds, "us-east-1");

check kb->ingest([{content: "Refunds are processed within 5 business days."}]);
```

**Find-or-create is by NAME.** `CreateKnowledgeBase` has no upsert, so `init` searches for an exact
name match first: exactly one match attaches (no writes); no match creates one (a MANAGED knowledge
base typically reaches `ACTIVE` in well under 5s — Bedrock owns the store; a VECTOR one can take on
the order of a minute, since a customer-owned store has to be provisioned; both are bounded by
`readyTimeout`); more than one match is a construction error naming the candidate ids — pick the id
and pass it as a `string` instead.

> **A name match is VERIFIED against the rest of the definition.** The name is only the lookup key.
> On a match, `init` compares the definition's `roleArn`, embedding-model configuration, KMS key and
> (for a self-managed knowledge base) `storageConfiguration` against what the knowledge base actually
> has, and fails construction naming each field that differs. Otherwise a definition carrying, say, a
> `roleArn` from an entirely different account would attach silently and leave the real role in
> effect, with no way for the caller to learn the definition it passed is not the one in force. Pass
> the knowledge base id directly to attach to it as it is. `description` is deliberately not compared
> — it is a mutable, non-behavioural label.

> **Find-or-create is a read-then-write, and that has a limitation you should know about.**
> Knowledge base names **are** unique per account — AWS itself rejects a *sequential* duplicate-name
> `CreateKnowledgeBase` with a 409 — but there is still a race window, because `init` lists by name,
> sees no match, then creates. This module closes as much of that window as it can, and reports
> honestly on what it cannot:
>
> - **A sequential duplicate (a 409) is recovered automatically.** If another `init()` call already
>   created a knowledge base under this name by the time this one's create lands, this call re-resolves
>   the name and attaches to the existing one — the same definition check described above runs on the
>   recovered attach, so it is never bypassed.
> - **A deterministic `clientToken`** (derived from the request body) collapses a *retried* identical
>   create into the original.
> - **A genuinely concurrent race — two `init()` calls already in flight at the same instant, sharing
>   the same token — can still both be accepted by AWS.** Measured live: the token collapses retries,
>   not requests that are already in flight together. This module detects that case *after* its own
>   create finishes and reports it rather than silently duplicating: the error names the surviving
>   knowledge base (deterministically the same for every racer, so the account converges on one), the
>   orphan(s), and the cleanup command (`aws bedrock-agent delete-knowledge-base --knowledge-base-id
>   <orphan>`). **This module never issues `DeleteKnowledgeBase` itself** — no HTTP `DELETE` verb
>   exists in it, and a destructive call from a constructor that might lack
>   `bedrock:DeleteKnowledgeBase` would be worse than the duplicate it is trying to clean up.
>
> Callers who cannot tolerate this residual race at all should resolve the knowledge base once (by
> name or however you like) and pass its **id** on every subsequent `init()`, rather than passing a
> `KnowledgeBaseDefinition` from multiple places that might run concurrently.

### Chunking

A `CUSTOM` data source's `chunkingStrategy` is fixed for its lifetime. **`FIXED_SIZE`** (the default
when this class creates one) means Bedrock chunks server-side — pass `chunkingStrategy: NONE` on
`KnowledgeBaseDefinition.dataSource` to chunk client-side with an `ai:Chunker` instead:

```ballerina
ai:KnowledgeBase kb = check new bedrock:BedrockManagedKnowledgeBase(
    {
        name: "support-docs",
        roleArn: "arn:...:role/service-role/bedrock-kb-execution-role",
        dataSource: {name: "custom-source", chunkingStrategy: bedrock:NONE}
    },
    creds, "us-east-1",
    chunker = new ai:MarkdownChunker());
```

> **Client-side chunking rewrites document ids, on purpose.** Bedrock upserts by
> `customDocumentIdentifier.id`, and this module derives that id from `ai:Metadata.id` when you set
> one. Ballerina's chunkers copy the parent document's metadata — `id` included — onto every chunk,
> so a document that split into 20 pieces would submit 20 documents under one id and keep exactly
> one, silently. A document this module chunks into **more than one** piece therefore submits its
> chunks as `<id>#0`, `<id>#1`, …; a document that does not fan out keeps `<id>` unchanged, so
> existing single-chunk corpora re-ingest onto themselves as before. Re-ingesting a document whose
> chunk count changed leaves the surplus old chunks behind — that is inherent to upsert-by-id, and
> `deleteByFilter` is how you clear them. Two documents in one `ingest()` call that resolve to the
> same id are rejected rather than silently overwriting each other.

`ManagedKnowledgeBaseConfig.chunker` is **detected**, not assumed, when left unset: `init` reads the
resolved data source's actual strategy and defaults to `ai:DISABLE` when Bedrock chunks server-side,
`ai:AUTO` when it is `NONE`. Passing an explicit `ai:Chunker` against a server-chunking data source
is a construction error — Bedrock would re-split whatever is submitted, silently overwriting the
chunker's own boundaries.

> **Ingestion needs a SECOND IAM action.** `bedrock:StartIngestionJob` **and**
> `bedrock:IngestKnowledgeBaseDocuments` are both required — working `bedrock:InvokeModel`/console
> permissions are not enough, and the failure mode is an `AccessDenied` that does not name the
> missing action on its own. This module's 403 error does name it.

> **`ingest()` is slow, by design.** `IngestKnowledgeBaseDocuments` returns 202 as soon as Bedrock has
> accepted the documents, not once they are indexed, and indexing latency **varies by an order of
> magnitude** — do not tune against a fixed figure. `ingest()` therefore blocks until every document
> reaches a terminal status or `ingestTimeout` elapses, so a `retrieve()` immediately afterward sees
> them. There is deliberately no fire-and-forget mode: `ai:KnowledgeBase.ingest` returns a bare
> `Error?` with no job handle and no status method, so returning at the 202 would report success for a
> document that later lands `FAILED` and leave you no way to ever find out.
>
> **A freshly accepted document can also stay invisible to the *read* path for a while** —
> `GetKnowledgeBaseDocuments` can answer `NOT_FOUND` for a document that was genuinely just accepted,
> not one that failed. `ingest()`'s poll treats that as "not yet visible" and keeps waiting rather than
> failing fast on it (this is the correct, honest behaviour: a fast-fail here would misreport a
> read-after-write timing gap as an ingest failure). If you see `ingest()` time out with documents
> named as "accepted but not yet visible", that is this gap, not a defect — raise `ingestTimeout` if
> it happens often in your account/region.

> **`retrieve()` cannot return more than 100 results.** `Retrieve` caps `numberOfResults` at 100 and
> returns **no `nextToken`** when results are truncated, so there is nothing to page with. `maxLimit`
> above 100 (including `-1`) is bounded by this.

### `deleteByFilter` is a reconstruction

**Bedrock has no metadata-based delete API and no way to read a document's metadata back**
(`ListKnowledgeBaseDocuments` carries status and identifier only; `GetDocumentContent` returns a
presigned content URL). `deleteByFilter` reconstructs one, per data source, from two **paged
enumerations**: `Retrieve` with the caller's filter applied, then `Retrieve` again with no filter at
all, each paged to exhaustion (or a page cap — see below). A candidate document (from
`ListKnowledgeBaseDocuments`) is then classified by which enumeration(s) saw it:

| candidate identity was seen in | meaning | action |
| --- | --- | --- |
| the FILTERED enumeration | a confirmed match | delete |
| a pinned probe reaches it WITH the filter | the filter matched it | delete |
| a pinned probe reaches it only WITHOUT the filter | the filter excluded it | skip — sound, not reported |
| no pinned probe reaches it at all | nothing can be concluded | indeterminate — named in the error |

This replaced an earlier per-document PINNED-probe design (the caller's filter ANDed onto a
`sourceUri == id` leaf, one to two `Retrieve` calls **per candidate document**). That design silently
deleted nothing at all on a self-managed knowledge base whose data source is `CUSTOM`: Bedrock does
not emit the pin key (`x-amz-bedrock-kb-source-uri`) for that source type, so every pinned probe came
back empty. The two-enumeration design does not depend on that key being emitted at all — identity is
read from whatever the response actually carries (the reserved metadata key when present, or the
documented `location.customDocumentLocation.id`/`location.s3Location.uri` members).

**Identity is still verified, not just result count.** A non-empty response only says *something* came
back; it does not say the filter was honoured. If a filter were ever silently ignored, the filtered
and unfiltered enumerations would return the exact same set, and every document would look like a
match. `deleteByFilter` checks for exactly that: if a non-nil filter is set and the filtered
enumeration returns the same set as the unfiltered one (with more than one document in it), the
result is treated as *ambiguous* — because it has two possible causes, and only one of them is a
fault:

- the store ignored the filter, so the filtered pass degenerated into the unfiltered one; or
- the filter is honoured and legitimately selects **every** document — `deleteByFilter({tenant ==
  "acme"})` on a knowledge base where every document really is `acme`, an ordinary single-tenant
  cleanup.

To separate them, `deleteByFilter` re-probes once with a filter that no document can possibly match.
A store that honours filters returns nothing for it, and the delete proceeds; a store that still
returns results is not applying filters at all, and **`deleteByFilter` refuses to delete anything
from that data source**, returning an error naming it. If that follow-up probe cannot be completed,
the refusal stands — an unverifiable filter is not permission to delete. AWS documents this failure
mode for MongoDB Atlas ("Metadata filtering doesn't work by default").

> **`filters` must contain at least one leaf predicate.** `ai:KnowledgeBase.deleteByFilter` takes
> filters as a required argument, so a caller assembling them from a collection that happened to be
> empty would otherwise get silent total deletion — an unfiltered `deleteByFilter` would match every
> document. An `ai:MetadataFilters` with no leaf predicates is refused. "Delete everything" has to be
> explicit.

**Cost: two paged `Retrieve` enumerations PER DATA SOURCE** (a small, bounded number of round trips —
at most 100 pages of 100 results each per enumeration — regardless of how many documents that data
source holds), not one to two round trips per document. This is a real improvement over the earlier
design, not just a bug fix: cost no longer scales with the size of the knowledge base. Each
enumeration pass is capped; if either one hits the cap, the result set may be incomplete, so **nothing
is deleted from that data source**, reported by name rather than risking an unsound skip. Documents on
a non-`CUSTOM`/`S3` data source (a native connector) cannot be deleted through this API at all, and are
named in the returned error; deletes that CAN be made still happen. The per-document delete statuses
AWS returns are checked, so a document the service did not confirm deleted is reported rather than
counted as a success.

> **Why candidates are resolved one at a time.** An earlier design classified a
> candidate by whether a paged UNFILTERED `Retrieve` had seen it: seen there but not in
> the filtered pass was read as "the filter excluded it". That was measured false
> against live AWS on 2026-09-09 — on a knowledge base with 9 usable documents, a fully
> paged unfiltered `Retrieve` reached 6 and missed 3 — so a document it happened to
> miss was silently skipped by a delete that should have removed it. `Retrieve` is
> documented as returning "the most relevant results", and paging to the last page does
> not make it an enumeration primitive.
>
> Pinning fixes this at the root: a pinned probe narrows the candidate set to the
> pinned document, so what `Retrieve` chose to rank never enters the answer. The
> second, unfiltered pinned probe is what makes a skip sound — it proves the pin
> reaches that exact document, so the first probe's silence is attributable to the
> filter and nothing else.
>
> **A document is only ever deleted on its OWN evidence.** A pin on `ai:Metadata.id`
> selects everything carrying that id, which is a whole fan-out family (`7#0`…`7#29`)
> plus any document ingested under the bare id `7`. Those are probed together for
> efficiency, but the verdict is per document and by exact identity — one family
> member matching says nothing about a namesake, and treating it as evidence deleted
> documents no filter had selected.
>
> **`deleteByFilter` still under-deletes rather than over-deletes**, and you should read
> its error: a document no probe can reach is named as indeterminate instead of being
> assumed to match or not match. Treat a returned `ai:Error` as a partial result — the
> confirmed deletes did happen.
>
> **A document chunked into more than 100 pieces needs more than one call.** `Retrieve`
> answers one relevance-bounded call of at most 100 results and offers no `nextToken`,
> so a set of documents sharing one `ai:Metadata.id` cannot be enumerated past that cap
> — there is no filter that can partition siblings, because they share one metadata
> record by construction. When a group exceeds the cap, the documents beyond it are
> reported as unconfirmed rather than assumed excluded, and the error says so. The
> confirmed matches are still deleted, which shrinks the group, so **repeating the same
> `deleteByFilter` call converges** — a 180-chunk document takes two calls. An earlier
> version read a full page as "the result set ended" and reported a half-finished
> delete as a complete one.

### `RetrieveAndGenerate` is unusable on managed knowledge bases

AWS documents this directly: *"This API cannot be used with managed knowledge bases."* Use
`retrieve()` plus your own model provider (`ai:augmentUserQuery` bridges the two), or AWS's
`AgenticRetrieveStream` outside this module.

## Self-managed knowledge bases

`BedrockVectorKnowledgeBase` is the sibling of `BedrockManagedKnowledgeBase` for
`KnowledgeBaseConfiguration.type = VECTOR`. Same three methods, same two endpoints, same SigV4 scope.
Use it when you want control over indexing and ranking; use the managed class when you do not want to
run a vector store.

```ballerina
import ballerinax/ai.aws.bedrock;

// Attach to a knowledge base that already exists.
final bedrock:BedrockVectorKnowledgeBase kb = check new ("KB1234ABCD");
```

```ballerina
// Or create the knowledge base and its CUSTOM data source from Ballerina.
// The VECTOR STORE ITSELF MUST ALREADY EXIST — see the callout below.
final bedrock:BedrockVectorKnowledgeBase kb = check new ({
    name: "support-articles",
    roleArn: "arn:aws:iam::123456789012:role/service-role/AmazonBedrockExecutionRoleForKnowledgeBase_1",
    embeddingModelArn: "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v2:0",
    storageConfiguration: <bedrock:OpenSearchServerlessStorage>{
        collectionArn: "arn:aws:aoss:us-east-1:123456789012:collection/abcdefghij1234567890",
        vectorIndexName: "bedrock-index",
        fieldMapping: {
            vectorField: "embeddings",
            textField: "AMAZON_BEDROCK_TEXT_CHUNK",
            metadataField: "AMAZON_BEDROCK_METADATA"
        }
    }
});
```

> **The vector store must already exist.** This class never provisions one. `CreateKnowledgeBase`
> accepts only a `storageConfiguration` naming an existing collection, cluster, table, or bucket — the
> console's "Quick create a new vector store" has **no API equivalent**: *"If you prefer to let Amazon
> Bedrock create and manage a vector store for you, use the console."* Provision it with
> Terraform/CDK/the console first, then pass its ARNs. This is why the managed class is frictionless
> by comparison: there is nothing to provision.

Eight backends are supported, one record each: `OpenSearchServerlessStorage`,
`OpenSearchManagedClusterStorage`, `S3VectorsStorage`, `RdsStorage`, `NeptuneAnalyticsStorage`,
`PineconeStorage`, `RedisEnterpriseCloudStorage`, `MongoDbAtlasStorage`. Their field mappings are
**not** interchangeable — Pinecone and Neptune Analytics have no `vectorField` at all, and RDS adds
`primaryKeyField` plus an optional `customMetadataField`.

### What differs from the managed class

| | `BedrockManagedKnowledgeBase` | `BedrockVectorKnowledgeBase` |
|---|---|---|
| Vector store | Bedrock's, nothing to provision | Yours, must pre-exist |
| Embedding model | Optional (service-managed by default) | **Required** — `embeddingModelArn` |
| Chunking | Rejected on a service-managed model | Configurable, so `ai:Chunker` is usable |
| Data source body | `MANAGED_KNOWLEDGE_BASE_CONNECTOR` wrapper | Plain `{"type": "CUSTOM"}` |
| Search branch | `managedSearchConfiguration` | `vectorSearchConfiguration` |
| Reranking | `rerankingModelType` enum | `rerankingConfiguration` record |
| Search type override | Not available | `overrideSearchType`, opt-in |
| Reserved metadata prefix | `_` (`_source_uri`) | `x-amz-bedrock` |

`startsWith` and `stringContains` are supported by Bedrock on self-managed knowledge bases and not on
managed ones, but **neither class can emit them**: `ai:MetadataFilterOperator` has exactly eight members
(`==`, `!=`, `>`, `<`, `>=`, `<=`, `in`, `nin`) and none maps to either. See
[Not implemented](#not-implemented).

### `overrideSearchType` is backend-dependent, and two AWS sources disagree

Leave it unset unless you know your backend supports the value — unset means Bedrock picks a strategy
suited to the store, which is correct everywhere. The API reference says `HYBRID` works only on
**OpenSearch Serverless** with a filterable text field; the user guide says *"Amazon RDS, Amazon
OpenSearch Serverless, and MongoDB vector stores that contain a filterable text field."* Both agree it
is unavailable on S3 Vectors, Neptune Analytics, Pinecone, and Redis. Neither is treated as
authoritative here, so nothing is defaulted.

### `ingest()` needs two IAM permissions, and AWS names only one at a time

Same as the managed class: `bedrock:StartIngestionJob` **and**
`bedrock:IngestKnowledgeBaseDocuments`. Granting the one named in the first `AccessDenied` fails again
on the other. Separately, the knowledge base's own `roleArn` needs permissions on **your** vector store
(`aoss:APIAccessAll`, `es:ESHttp*`, `rds-data:*`, `neptune-graph:*`, `s3vectors:*`, or
`secretsmanager:GetSecretValue` depending on backend). Those belong to that role, not to this client's
credentials.

### Pitfalls this module cannot check for you

Each of these needs a query against your vector store to detect — credentials and network reach the
calling application does not have, since those permissions belong to the knowledge base's service role
and the store is often VPC-private. Construction validates everything Bedrock itself reports; the rest
is on you:

- **Index dimension must match the embedding model.** A mismatch fails ingestion with an opaque error.
- **OpenSearch must use the `faiss` engine.** With `nmslib`, metadata filtering does not work at all
  and the documented fix is to rebuild the index.
- **OpenSearch custom metadata fields must be `keyword`-typed** (or `text` with a `keyword` subfield).
  Without that, filtering on them fails with a *"Rewrite first"* error.
- **S3 Vectors caps metadata at 1 KB and 35 keys per vector.** Hierarchical chunking can exceed it,
  and *"the ingestion job will throw an exception."* S3 Vectors is also SEMANTIC-only, float32-only,
  and rejects `startsWith`/`stringContains`.
- **Aurora needs HNSW iterative index scans** (pgvector 0.8.0+) when you filter on metadata. Without
  them, selective filters **silently return fewer results than they should** — no error.
- **MongoDB Atlas metadata filtering does not work by default**; filters must be configured in the
  Atlas vector index first.

### `deleteByFilter` — same algorithm as the managed class, a different reserved key

The reconstruction is [the same two-enumeration algorithm as the managed one](#deletebyfilter-is-a-reconstruction)
— literally the same implementation, called with this class's own reserved metadata key and its own
`vectorSearchConfiguration` search branch instead of the managed class's `_source_uri` and
`managedSearchConfiguration`. **Self-managed and managed knowledge bases use DIFFERENT reserved
metadata prefixes** — `_` for managed, `x-amz-bedrock-kb-` for self-managed
(`x-amz-bedrock-kb-source-uri` specifically) — and reusing the wrong one here would extract no identity
from any retrieval result, silently deleting nothing. `deleteByFilter` also **rejects a filter set with
no leaf predicates** — an empty or all-empty-groups `ai:MetadataFilters` would otherwise select
everything.

> **Measured, and worse on a customer-owned store.** Bedrock does **not** populate
> `x-amz-bedrock-kb-source-uri` for a CUSTOM data source on a self-managed knowledge base — confirmed
> live — which is why identity falls back to `location.customDocumentLocation.id`. Separately, the
> "unfiltered `Retrieve` is exhaustive" premise was measured false on the managed side (see the
> callout under the managed section) and is **unmeasured on a customer-owned store**, where there is
> no reason to expect it to hold better. `deleteByFilter` here therefore confirms deletes only through
> the filtered enumeration and reports everything else; on S3 Vectors specifically, a filtered
> `Retrieve` has been observed to miss a just-ingested document that trivially satisfies the filter,
> so expect `deleteByFilter` to under-delete and report rather than to complete silently.


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
- any route in the AWS China partition (`cn-`) — Bedrock is not offered there at all
- `apiFamily = MANTLE` on a model with no known Mantle request path
- an explicit `apiFamily = MANTLE` on a partition that serves no Mantle host (ISO, EU Sovereign);
  GovCloud and commercial **are** supported, and `AUTO` falls back to Converse rather than failing
- `fips` on a Mantle-resolved model (there is no `bedrock-mantle-fips` host)
- a guardrail on a Mantle route (the error names the standalone `ApplyGuardrail` API)
- a `custom-model/` ARN (an artifact, not a deployment)
- `dualstack` on any route but Mantle (no `.api.aws` host exists for the other four service names)
- any inference knob the resolved route cannot carry — `serviceTier`/`latencyOptimized` on Mantle,
  `stopSequences` on OpenAI Responses, `thinking`/`effort`/`reasoningEffort` on a dialect with no such
  concept. **A field the module cannot honour is refused, never dropped:** a silent drop is
  indistinguishable, from the `ai:ModelProvider` contract, from a request that honoured it

Everything AWS *can* tell you — a model unavailable in a region, a bad id — is left to Bedrock's own
`ValidationException`, so this module never becomes a release dependency for AWS's catalogue.

## Images

Pass an `ai:ImageDocument` inside a prompt and it is sent as a real image, not as text:

```ballerina
byte[] png = check io:fileReadBytes("invoice.png");
ai:ImageDocument invoice = {content: png, metadata: {mimeType: "image/png"}};

ai:ChatAssistantMessage answer = check claude->chat({
    role: ai:USER,
    content: `Extract the total from this invoice: ${invoice}`
});
```

**Supported on the routes below.** Everywhere else an image is a **construction-time
`ai:Error` naming the dialect** — never silently dropped into the prompt text.

| Route | Images | Notes |
| --- | --- | --- |
| Converse (and Nova on InvokeModel) | ✅ | Native `image` content block |
| Anthropic Messages (InvokeModel **and** Mantle) | ✅ | base64 source |
| OpenAI chat completions (Mantle + GPT-OSS Invoke) | ❌ | unverified — see below |
| OpenAI Responses (Mantle, GPT-5.x) | ❌ | unverified — see below |
| Mistral chat (InvokeModel) | ❌ | sources disagree — see below |
| Mistral instruct / DeepSeek-R1 | ❌ | single prompt string; no content-part array |
| Any `ChatSystemMessage` | ❌ | `system` is text-only on every Bedrock route |

`mimeType` comes from `metadata.mimeType` when set, otherwise from the download's
`Content-Type`, otherwise from the file's magic bytes. If none of those identify it,
construction fails with a named error rather than guessing — both Converse's `format`
and Anthropic's `media_type` are required fields with no wildcard, so a guess is a
guaranteed 400. Only **png, jpeg, gif and webp** are accepted.

An `ai:Url` image is **downloaded by the connector** and sent as bytes, because
Bedrock never fetches on your behalf: Converse has no URL source at all, and
Anthropic-on-Bedrock accepts base64 only. Only `http(s)` URLs are fetched, redirects
are followed manually so every hop is re-checked, and the download is capped at 20 MiB.

> **Verifying a refused route.** The emitters for the OpenAI-shaped and Mistral chat
> dialects are written and unit-tested — only the refusal is in the way. Set
> `enableUnverifiedImageRoutes = true` in `Config.toml` and run `bal test --groups live`
> to push a real image through the module and see what AWS says. If the route accepts
> the body this module builds, the default flips permanently.
>
> **Why some routes refuse.** Image support is enabled only where a primary source
> confirms the wire shape. AWS's Mantle pages are JS-rendered and state nothing about
> image parts, and for Mistral's InvokeModel dialect AWS documents `content` as a
> string while Mistral's own API documents image chunks — two first-party sources
> disagreeing. Rather than guess and ship the silent-wrong-answer bug this feature
> exists to fix, those routes refuse. Each is a one-line change once a live call
> settles it.

Images are redacted in the observability span (`[image image/png, 12043 bytes]`), so
the payload never reaches your telemetry backend.

## Migrating from 0.9.x

Credentials moved to [`ballerinax/aws.auth`](https://central.ballerina.io/ballerinax/aws/latest), which
required reordering `init` — Ballerina requires required parameters before defaultable ones, and both
`region` and `credentials` are now defaultable.

**Argument order changed on all nine providers.** `model` is the only required parameter —
Ballerina requires required parameters before defaultable ones, so `credentials` had to move
after it in order to keep its default:

```ballerina
// 0.9.x
check new bedrock:AnthropicModelProvider(creds, bedrock:CLAUDE_SONNET_4_6, "us-east-1");

// now — model first, and credentials + region are both required
check new bedrock:AnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6, creds, aws:US_EAST_1);
```

**`StaticCredentials` and `StsCredentials` were removed.** Both collapse into
`auth:StaticAuthConfig`, whose `sessionToken` is optional. Inline record literals are unchanged —
`{accessKeyId, secretAccessKey}` and `{accessKeyId, secretAccessKey, sessionToken}` both still work;
only code that named those types needs editing. `BearerToken` is unchanged.

**`serviceUrl` and `config.fips` became `endpoint`, an [`aws:EndpointConfig`](https://central.ballerina.io/ballerinax/aws/latest).**
The `DEFAULT_SERVICE_URL` template and its `{endpoint}`/`{region}`/`{domain}` placeholders are gone —
no other Ballerina connector uses a brace template as a default, and none of the AWS ones expose a
`serviceUrl` at all. Migrate:

```ballerina
config = {fips: true}                          → endpoint = {fips: true}
config = {apiFamily: bedrock:CONVERSE}         → apiFamily = bedrock:CONVERSE
serviceUrl = "https://host"                    → endpoint = {customEndpoint: "https://host"}
serviceUrl = "https://bedrock-{endpoint}..."   → (removed; the derived default already covers it)
```

`apiFamily` and `endpoint` moved out of the config record onto `init` itself, so both are named
arguments now rather than config fields.

**`credentials` and `region` became required, and `region` is now `aws:Region|string`.** `region` no
longer falls back to `AWS_REGION`/`AWS_DEFAULT_REGION`: no `ballerinax` connector reads the
environment for a parameter default, and a silent region default sends your prompts to a region you
did not choose. Pass `auth:DEFAULT_CREDENTIALS` and an `aws:Region` explicitly.

**`CLAUDE_MYTHOS_5` and `CLAUDE_MYTHOS_PREVIEW` were removed from `AnthropicModel`** — the models are
not available. Any id still reachable can be passed as a `string`.

SigV4 signing is unchanged — see [Not implemented](#not-implemented) for why signing stayed
in-module.

## Not implemented

Streaming (the codec seam exists, but no `decodeStream`), document/video/audio content blocks
(Converse models all three — see [Images](#images) for the image scope line), image/video/audio embeddings and
`StartAsyncInvoke` (the `ai:Chunk` contract carries text), provisioned-throughput embedding ARNs,
Meta/Llama, and Custom Model Import (`imported-model/` ARNs).

On knowledge bases specifically: **Kendra and SQL/Redshift** knowledge base types (only `MANAGED` and
`VECTOR` are implemented); provisioning the vector store itself, which the Bedrock API cannot do at all;
`implicitFilterConfiguration` on the self-managed search branch; and `startsWith`/`stringContains`
filters, which self-managed knowledge bases support but `ai:MetadataFilterOperator` has no operator for.

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
