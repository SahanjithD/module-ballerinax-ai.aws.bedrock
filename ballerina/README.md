## Overview

This module provides native [Ballerina `ai`](https://central.ballerina.io/ballerina/ai/latest) model and
embedding providers for **AWS Bedrock**, implementing the standard `ai:ModelProvider` and
`ai:EmbeddingProvider` contracts.

Bedrock exposes LLMs through **two endpoints**, and this module gives each its own set of provider
classes so that what an endpoint can and cannot do is visible in the type you construct:

| Endpoint | Inference APIs | Signing scope | IAM |
| --- | --- | --- | --- |
| `bedrock-runtime.{region}.amazonaws.com` **(recommended)** | Converse, InvokeModel, Chat Completions, Responses, Messages | `bedrock` | `bedrock:InvokeModel` |
| `bedrock-mantle.{region}.api.aws` (compatibility) | Chat Completions, Responses, Messages | `bedrock-mantle` | `bedrock-mantle:CreateInference` |

AWS recommends `bedrock-runtime` for new applications and describes `bedrock-mantle` as the
compatibility surface. Reach for a `Mantle*` class only when the model or capability you need
is not on `bedrock-runtime` — GPT-5.4/5.5 and Gemma 4 are Mantle-only, for instance. Guardrails and
cross-region inference are runtime-only. Typed `generate()` works on both endpoints except the Mantle
Anthropic Messages route.

### Key features

- Chat completion through one `ai:ModelProvider` contract, on either endpoint
- `CommonModelProvider` reaches **every** model Bedrock serves on Converse — 15 of AWS's 17
  providers, including the ten with no dedicated class here
- Structured output (`generate()`) by tool-forcing, on every API that supports tool calling
- Text embeddings through the `ai:EmbeddingProvider` contract, with order-preserving batching
- Per-model dialect and SigV4 signing-scope resolution, decided at construction
- The full AWS credential chain (IMDSv2, ECS, EKS IRSA, SSO, profiles, `AssumeRole`) via
  `ballerinax/aws.auth` — zero credential configuration on AWS compute — plus Bedrock API keys (bearer)
- Cross-region inference (CRIS) profiles, provisioned and custom-deployment ARNs
- Guardrail support on Converse, InvokeModel and Chat Completions
- Image input on Converse and Anthropic Messages; a named error, never a silent drop, elsewhere

### Providers

The public surface is split **by endpoint, then by vendor**. Every class is a thin typed facade over one
shared internal spine (resolver → endpoint builder → converter → SigV4 transport).

**Any vendor, Converse** — `CommonModelProvider`. Takes a model id as a plain `string` and reaches
every Converse-capable model, including Meta, Cohere, AI21, MiniMax, Moonshot, NVIDIA, Writer, xAI, Z.AI
and Stability. Start here unless you need a vendor-specific knob or a non-Converse dialect.

**`bedrock-runtime`, per vendor** — `RuntimeAnthropicModelProvider`,
`RuntimeOpenAIModelProvider`, `RuntimeAmazonModelProvider` (Nova),
`RuntimeMistralModelProvider`, `RuntimeQwenModelProvider`,
`RuntimeGoogleModelProvider` (Gemma), `RuntimeDeepSeekModelProvider`.

**`bedrock-mantle`, per vendor** — the same six minus Amazon:
`MantleAnthropicModelProvider`, `MantleOpenAIModelProvider`,
`MantleMistralModelProvider`, `MantleQwenModelProvider`,
`MantleGoogleModelProvider`, `MantleDeepSeekModelProvider`. There is no Amazon Mantle
class because AWS serves no Amazon model on that endpoint.

**Embeddings** — `TitanEmbeddingProvider`, `CohereEmbeddingProvider` (InvokeModel on `bedrock-runtime`).

**Knowledge base** — `ManagedKnowledgeBase` (Bedrock owns the vector store) and
`SelfManagedKnowledgeBase` (you own it), both implementing `ai:KnowledgeBase`. See
[Knowledge bases](#knowledge-bases) and [Self-managed knowledge bases](#self-managed-knowledge-bases).

A model AWS ships before this module updates an enum is still usable — pass its id as a `string`. Every
provider takes `<Vendor><Endpoint>Model|string`, so the enums are autocomplete and documentation, never a
gate. On a runtime class an unrecognised id simply goes on the wire and AWS answers for it. A brand-new
*Mantle* model is the one case that needs a module release, because its request path cannot be derived
from its id.

### Choosing the API family

Runtime classes take an `apiType` argument defaulting to `CONVERSE`. Which families a class offers is a
property of its type, so an unreachable combination does not compile:

| Class | Type of `apiType` | Accepts |
| --- | --- | --- |
| `RuntimeAnthropicModelProvider` | `AnthropicRuntimeApi` | `CONVERSE`, `INVOKE`, `MESSAGES` |
| `RuntimeOpenAIModelProvider` | `OpenAIRuntimeApi` | `CONVERSE`, `INVOKE`, `CHAT_COMPLETIONS`, `RESPONSES` |
| `RuntimeMistralModelProvider` | `MistralRuntimeApi` | `CONVERSE`, `INVOKE`, `CHAT_COMPLETIONS` |
| `RuntimeQwenModelProvider` | `QwenRuntimeApi` | `CONVERSE`, `INVOKE`, `CHAT_COMPLETIONS` |
| `RuntimeGoogleModelProvider` | `GoogleRuntimeApi` | `CONVERSE`, `INVOKE`, `CHAT_COMPLETIONS` |
| `RuntimeDeepSeekModelProvider` | `DeepSeekRuntimeApi` | `CONVERSE`, `INVOKE`, `CHAT_COMPLETIONS` |
| `RuntimeAmazonModelProvider` | `AmazonRuntimeApi` | `CONVERSE`, `INVOKE` |
| `CommonModelProvider` | — | Converse only |
| `Mantle*ModelProvider` | — | the model's own family |

`CHAT_COMPLETIONS` is deliberately not OpenAI-only: AWS serves that family for DeepSeek, Gemma 3, Mistral,
Qwen3 and others. **Mantle classes take no `apiType` argument at all.** Each Mantle model has exactly one route this module
takes, so there is nothing for a caller to choose — the model decides. (`openai.gpt-oss-120b` is
published on both Responses and Chat Completions; this module takes Chat Completions.)

Per-model gaps remain and are left for AWS to report — GPT OSS serves Chat Completions, Converse and
Invoke on `bedrock-runtime` but not Responses, for example.

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

`model`, `auth` and `region` are required. On AWS compute, `auth:DEFAULT_CREDENTIALS` is all the
credential setup you need:

```ballerina
import ballerinax/aws;
import ballerinax/aws.auth;

final ai:ModelProvider claude = check new bedrock:RuntimeAnthropicModelProvider(
        bedrock:CLAUDE_SONNET_4_6, auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);
```

Every runtime class follows the same shape — `(model, auth, region, apiType?, endpoint?,
maxTokens?, temperature?, *Config)`. `model`, `auth` and `region` are required; `apiType` defaults
to `CONVERSE`. `apiType` and `endpoint` sit directly on `init` rather than inside the config record,
because both are decisions you make at the same moment you pick the model and region:

```ballerina
final ai:ModelProvider nova = check new bedrock:RuntimeAmazonModelProvider(
        bedrock:NOVA_PRO, auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);
// GPT-5.4 is Mantle-only, so it takes the Mantle class.
final ai:ModelProvider gpt = check new bedrock:MantleOpenAIModelProvider(
        bedrock:MANTLE_GPT_5_4, auth:DEFAULT_CREDENTIALS, aws:US_EAST_2);
// Any vendor at all, over Converse.
final ai:ModelProvider llama = check new bedrock:CommonModelProvider(
        "us.meta.llama3-3-70b-instruct-v1:0", auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);
final ai:ModelProvider gemma = check new bedrock:RuntimeGoogleModelProvider(
        bedrock:GEMMA_3_27B_IT, auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);
```

`region` is typed `aws:Region|string`, so the enum gives you a checked constant and the string
escape hatch still reaches a region newer than the enum. Nothing is read from the environment:
`AWS_REGION` is **not** consulted for this parameter — pass it explicitly. (Credentials are the
exception, and only because `auth:DEFAULT_CREDENTIALS` asks the AWS SDK to run its own chain.)

### Authentication

`auth` (a `BedrockAuthConfig`) is required — pass `auth:DEFAULT_CREDENTIALS` to walk the standard AWS chain —
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
bedrock:BedrockAuthConfig keys = {accessKeyId: "...", secretAccessKey: "..."};

// Cross-account: assume a role in another account.
bedrock:BedrockAuthConfig role = {
    roleArn: "arn:aws:iam::222222222222:role/IntegratorRole",
    externalId: "optional-for-third-party-access"
};

// A named profile from ~/.aws/credentials.
bedrock:BedrockAuthConfig profile = {profileName: "prod"};

// A Bedrock API key (bearer) — bypasses SigV4 entirely.
bedrock:BedrockAuthConfig apiKey = {apiKey: "..."};

final ai:ModelProvider claude =
    check new bedrock:RuntimeAnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6, role, aws:US_EAST_1);
```

> **Knowledge bases do NOT accept Bedrock API keys.** AWS states API keys "are limited to Amazon
> Bedrock and Amazon Bedrock Runtime actions" and cannot be used with *"Agents for Amazon Bedrock or
> Agents for Amazon Bedrock Runtime API operations"* — and both knowledge base planes
> (`bedrock-agent`, `bedrock-agent-runtime`) are exactly those. `ManagedKnowledgeBase`
> therefore takes `KnowledgeBaseAuthConfig` (SigV4 only), so a bearer token is rejected at
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

> **Typed `generate()` works everywhere except Mantle Messages.** On `bedrock-runtime` and on the
> OpenAI-shaped Mantle routes (Responses, Chat Completions) a typed target is obtained by forcing a
> tool. The one exception is `MantleAnthropicModelProvider`, which resolves to the Anthropic
> Messages API: AWS documents that route as rejecting `output_config.format`, and this module does not
> force a tool there either, so it returns an `ai:Error` for any non-`string` target type, naming the
> model. Claude is dual-homed, so the fix is `RuntimeAnthropicModelProvider` instead — there is no
> silent cross-endpoint fallback.
>
> A `string` target always returns text normally, and `chat()` is unaffected in every case.
>
> Typed generation is also unavailable on Mistral's **text-completion** dialect (see below), which has no
> tool-calling at all. That only bites when you pass `apiType = INVOKE` for those ids — the default
> Converse shape supports typed generation for every Mistral model.

> **With thinking on, the result tool is offered rather than forced.** Anthropic accepts only an
> `auto` tool choice while thinking is on, and `CLAUDE_OPUS_5_5` and `CLAUDE_FABLE_5_1` (and their
> `MANTLE_` twins) reject a forced tool on every request. In those cases `generate()` offers the result
> tool, asks the model to call it, and checks the reply against the expected type. A model that answers
> in plain text instead returns an `ai:LlmInvalidGenerationError`. This applies when `thinking` is set
> to `ADAPTIVE` or `ENABLED`, or when a `thinking` object is passed in `additionalModelRequestFields`.
> Opus 5.5 and Fable 5.1 are recognised by model id, so a provisioned-model or inference-profile ARN
> for them still gets a forced tool, and AWS answers for it.

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
error, no exception, just worse results. Your corpus must be embedded as **`search_document`** and your
queries as **`search_query`**.

By default the provider picks it from the method, which matches how `ai:VectorKnowledgeBase` calls an
embedding provider: **`embed()` sends `search_query`** (a retrieval query) and **`batchEmbed()` sends
`search_document`** (ingestion). One provider serves both sides:

```ballerina
final ai:EmbeddingProvider cohere = check new bedrock:CohereEmbeddingProvider(
    bedrock:COHERE_EMBED_ENGLISH_V3, creds, "us-east-1");
```

**Set `inputType` only to override both methods** — for example if you ingest your corpus one
document at a time through `embed()`, which would otherwise embed it as queries:

```ballerina
final ai:EmbeddingProvider ingest = check new bedrock:CohereEmbeddingProvider(
    bedrock:COHERE_EMBED_ENGLISH_V3, creds, "us-east-1", inputType = bedrock:SEARCH_DOCUMENT);
```

## Routing

You pick the endpoint by picking the class, and the API family with `apiType`. What is left for the module to
resolve is the model id and the request path, and that happens once, at construction — before any
network call.

**There is no automatic endpoint selection.** Earlier versions of this module had an `AUTO` mode that
preferred `bedrock-mantle` for any Mantle-capable model. That is gone: it sent flagship models to the
endpoint with no guardrails, no cross-region inference and no structured output, and — because Mantle
authorizes under a *separate* IAM namespace — produced `AccessDenied` for credentials that were
perfectly valid for Bedrock. The endpoint is now yours to state, and the type system holds you to it.

### On a `Runtime*` class (or `CommonModelProvider`)

| You pass | Resolves to |
| --- | --- |
| a bare id (`amazon.nova-pro-v1:0`) | the `apiType` you asked for; `CONVERSE` by default |
| a CRIS id (`us.anthropic.claude-opus-4-8`) | same, prefix stripped for lookup and re-applied on the wire |
| `provisioned-model/` · `custom-model-deployment/` · `inference-profile/` ARN | same, ARN sent verbatim (URL-encoded) |
| `foundation-model/` ARN | same, stripped to the bare id it carries |
| an unknown id | sent as-is — Converse is model-agnostic, so AWS answers for it |
| `custom-model/` ARN | **not supported** — construction error; pass the deployment ARN |
| `imported-model/` ARN | **not supported** — construction error |

Current Claude models are served on `bedrock-runtime` through cross-region inference profiles only, so
the `AnthropicRuntimeModel` constants carry a `us.` prefix. A bare Claude id here fails with
`on-demand throughput isn't supported`.

### On a `Mantle*` class

| You pass | Resolves to |
| --- | --- |
| a bare id in `MANTLE_CAPABLE` | that model's own published path (`/v1/…`, `/openai/v1/…` or `/anthropic/v1/messages`) |
| a bare id not in the table | **construction error** naming the model |
| a CRIS-prefixed id | **construction error** — cross-region inference is runtime-only |
| any ARN | **construction error** — ARNs name `bedrock-runtime` resources |

### Why Mantle needs a routing table and `bedrock-runtime` does not

On `bedrock-runtime` the request path is a pure function of the **shape** —
`/model/{id}/converse`, `/openai/v1/responses` and the rest never vary by model — so the module derives
it and needs no data at all. Any id you pass just goes on the wire.

On `bedrock-mantle` the **base path is a per-model fact**, and AWS says so on each model card because it
is irregular. Two of its own notes contradict each other across models of the same vendor:

> **gpt-oss-120b** — "On `bedrock-mantle`, both APIs use the `/v1` base path, not `/openai/v1`."
> **GPT-5.6 Sol** — "On `bedrock-mantle`, both APIs use the `/openai/v1` base path, not `/v1`."

`google.gemma-3-*` (`/v1`) versus `google.gemma-4-*` (`/openai/v1`) is the same story. So the base path
follows neither the vendor prefix nor the API family, and something has to record it — that is the entire
job of `MANTLE_CAPABLE`, and the only per-model datum in it. The path suffix, the dialect, the
converter and the auth-header style are all derived from the API family.

The cost is that a Mantle model AWS ships after a release is unreachable until the table carries it.
An id absent from the table is refused by name rather than sent to a guessed URL.

### Escape hatches

```ballerina
// 1. Pick the endpoint by picking the class.
check new bedrock:MantleAnthropicModelProvider("anthropic.claude-haiku-4-5", creds, "us-east-1");

// 2. Pick the wire shape with `apiType`. Only the shapes AWS serves for that vendor compile.
check new bedrock:RuntimeAnthropicModelProvider("us.anthropic.claude-haiku-4-5", creds,
        "us-east-1", apiType = bedrock:MESSAGES);

// 3. Any raw model id string is always accepted — the model enums are
//    conveniences, never a gate. A model AWS shipped after this release works today.
check new bedrock:RuntimeAmazonModelProvider("amazon.nova-something-new-v1:0", creds, "us-east-1");

// 4. A vendor with no class of its own — Converse reaches all of them.
check new bedrock:CommonModelProvider("us.writer.palmyra-x5-v1:0", creds, "us-east-1");
```

The `mantle/`, `converse/` and `invoke/` model-id string prefixes are **gone**. They were a way to
override a resolver that no longer exists; the class and the `apiType` argument say the same thing in
the type system.

**A brand-new model needs no module release on `bedrock-runtime`** — pass its id as a string. The one
exception is a brand-new **Mantle** model: its request path is per-model data that cannot be derived
from the id, so it needs a table entry, and an id absent from `MANTLE_CAPABLE` is refused rather than
guessed at.

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
check new bedrock:RuntimeAnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6, creds, aws:US_GOV_WEST_1,
    endpoint = {fips: true});
// → https://bedrock-runtime-fips.us-gov-west-1.amazonaws.com

// A concrete origin: gateway, LocalStack, or a VPC endpoint
check new bedrock:RuntimeAnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6, creds, aws:US_EAST_1,
    endpoint = {customEndpoint: "http://localhost:4566"});
```

`customEndpoint` replaces the **origin only** — the route-derived request path is still appended —
and it never changes the SigV4 scope: a VPCE or gateway host still signs the route's own region and
service.

> **`customEndpoint` is a global override.** It has the same semantics as the AWS SDK's
> [`AWS_ENDPOINT_URL`](https://docs.aws.amazon.com/sdkref/latest/guide/feature-ss-endpoints.html):
> one URL for **every** service the client talks to. A knowledge base client talks to two
> (`bedrock-agent` and `bedrock-agent-runtime`). That suits a mock or a single gateway; it does
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
- **There is no `bedrock-mantle` FIPS host.** `endpoint = {fips: true}` on any `Mantle*` class
  is a construction error. Use the matching `Runtime*` class for a FIPS-compliant call.
- **`us-gov-west-1` has Mantle; `us-gov-east-1` does not.** We deliberately do not encode region
  lists — they go stale — so a `Mantle*` class on `us-gov-east-1` builds a Mantle host and gets
  AWS's own error at call time, which names the real problem better than a stale list could.

### Partitions

- **China (`cn-`) is rejected at construction, on every API family.** Amazon Bedrock is not offered
  in the AWS China partition at all — not Mantle, not `bedrock-runtime`. The endpoint resolver would
  still happily build a well-formed host (it is a string builder and never fails), so without this
  guard the first call fails with a bare connection error naming nothing.
- **ISO and EU Sovereign partitions** (`us-iso-`, `us-isob-`, `us-isof-`, `eusc-`) reach
  `bedrock-runtime` normally. They serve no Mantle host, so constructing any `Mantle*` class
  there is a construction error naming the partition.

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

> **`serviceTier` / `latencyOptimized` do not exist on the Mantle classes at all.** They live on
> `CommonRuntimeConfig` and not on `CommonMantleConfig`, so setting one on a `Mantle*` class is a
> *compile* error rather than something discovered at construction or, worse, silently dropped on the
> wire. Use the matching `Runtime*` class to send them as Bedrock defines them. Mantle's vendor-compatible surfaces do have a `service_tier` body field, but with the
> **vendor's** value set (`auto|default|flex|fast|priority|ultrafast`) rather than Bedrock's
> (`default|priority|flex|reserved`) — two first-party sources, one field name, different vocabularies —
> so this module will not guess a mapping. If you know your model's, send it through
> `additionalModelRequestFields`.

> **`temperature` has no default, and that is deliberate.** Leave it unset and the field is omitted from
> the request entirely, so the model applies its own default. This is not a style choice: Anthropic
> deprecated sampling parameters on Claude 4.7 and later (`CLAUDE_OPUS_4_8`, `CLAUDE_OPUS_5`,
> `CLAUDE_SONNET_5`): on those models **any** value returns
> `400 temperature is deprecated for this model`, so a module-level default would make them unusable out
> of the box.
>
> Acceptance is per model, not per family — `MANTLE_GPT_5_4` accepts `temperature = 0.5` (verified live
> 2026-09-24), so do not assume the GPT-5.x models refuse it. Set `temperature` when you know the model
> takes it, and let AWS refuse it otherwise.

> **`reasoningEffort` is a `ReasoningEffort` enum, and no member is accepted everywhere.** The members —
> `REASONING_NONE`, `REASONING_MINIMAL`, `REASONING_LOW`, `REASONING_MEDIUM`, `REASONING_HIGH`,
> `REASONING_XHIGH`, `REASONING_MAX` — are the union of every value seen on the OpenAI models on Bedrock.
> Measured on 2026-09-24 in `us-east-1` by sending each value: `openai.gpt-oss-120b` (Invoke) accepted
> `low`, `medium` and `high`; `openai.gpt-5.4` (Mantle Responses) accepted `none`, `low`, `medium`,
> `high` and `xhigh`. **`minimal` was refused by both**, even though gpt-oss lists it as valid in its
> own 400. The module does not enforce a per-model set — which values a model accepts is the model's
> contract and changes over time — so an unsupported value comes back as AWS's 400.

`maxTokens` **does** default (to 4096). It is capped per model — Nova Pro/Lite/Micro top out at 5K output
tokens — and on adaptive-thinking models the thinking pass is billed against the same ceiling, so raise
it for long reasoning tasks.

> **OpenAI models get the cap as `max_completion_tokens`.** On Chat Completions and InvokeModel, OpenAI
> deprecated `max_tokens` and the GPT-6 models refuse it, so `openai.*` models are sent
> `max_completion_tokens` instead. Every other vendor on those APIs still gets `max_tokens`.
>
> **Pass `maxTokens = ()` to drop the field entirely**, the same way an unset `temperature` is left
> out. The Anthropic classes are the exception: Anthropic requires the field, so their `maxTokens` is
> an `int`.
>
> **A `generate()` answer cut off at the token limit is an error**, not a partial value. The
> `ai:LlmInvalidGenerationError` says to raise `maxTokens`; on a thinking model, the thinking counts
> towards the same limit.

## Vendor dialects

### Mistral speaks two InvokeModel dialects

Mistral is the one vendor whose `InvokeModel` wire shape cannot be derived from its vendor prefix:

| Dialect | Models | Wire |
| --- | --- | --- |
| [text completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-text-completion.html) | 7B Instruct, Mixtral 8x7B, **Large 24.02** | `prompt` (`<s>[INST]…[/INST]`) → `outputs[].text`; no tools |
| [chat completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-large-2407.html) | **Large 24.07**, newer ids | `messages`/`tools` → `choices[].message` |

Note that `mistral-large-**2402**` and `mistral-large-**2407**` are the same family four months apart and
speak *opposite* dialects. The module picks by id; an id it has never seen defaults to chat. If it guesses wrong, Bedrock returns a
`ValidationException` — switch to `apiType = bedrock:CONVERSE`, which is model-agnostic and sidesteps
the split entirely.

**Converse (the default) hides all of this** — the split only matters when you pass `apiType = INVOKE`.

> **`MISTRAL_LARGE_2407` is `us-west-2` only.** It is the one id in these enums whose availability is a
> single region: AWS's
> [regional-availability page](https://docs.aws.amazon.com/bedrock/latest/userguide/models-region-compatibility.html)
> lists exactly one row for it, `us-west-2` In-Region, with no Geo or Global profile. Anywhere else the
> endpoint answers `The provided model identifier is invalid`, which reads like a wrong id rather than a
> wrong region. `MISTRAL_LARGE_3` is available far more widely.

> **`The provided model identifier is invalid` is not always about the id.** AWS uses that message for
> a model your account has not been granted access to as well as for one that does not exist in the
> region. If a documented id fails in a region its model card lists — `QWEN3_CODER_480B` in `us-east-1`,
> say — check **Model access** in the Bedrock console before suspecting the id. Access is per endpoint,
> so the Mantle class can work while the runtime class does not.

### DeepSeek does too

Same story, split by generation rather than by date:

| Dialect | Models | Wire |
| --- | --- | --- |
| [text completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-deepseek.html) | **R1** (`deepseek.r1-v1:0`) | `prompt` (DeepSeek's `<｜User｜>` template) → `choices[].text`; no tools |
| [chat completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-v3-2.html) | **V3.1**, **V3.2**, newer ids | `messages`/`tools` → `choices[].message` |

The module picks by id, and an id it has never seen defaults to chat. Again, only relevant when you
pass `apiType = INVOKE` — Converse and the vendor-native shapes are unaffected.

## Knowledge bases

`ManagedKnowledgeBase` implements `ai:KnowledgeBase` against a Bedrock **managed** knowledge
base (`KnowledgeBaseConfiguration.type = MANAGED` — Bedrock owns the vector store; there is nothing
to provision). It spans two additional endpoints beyond the chat/embedding surface —
`bedrock-agent.{region}.amazonaws.com` (control: create/list/get/ingest/delete) and
`bedrock-agent-runtime.{region}.amazonaws.com` (data: retrieve) — both signing as SigV4 service
`bedrock`, same as Converse/InvokeModel.

`SelfManagedKnowledgeBase` implements the same interface against a **self-managed** knowledge base
(`KnowledgeBaseConfiguration.type = VECTOR` — a vector store you provision and own), which is the
console's *Self-managed KB → Unstructured Vector Store KB*. Both classes use the same two endpoints
and the same signing scope; see [Self-managed knowledge bases](#self-managed-knowledge-bases) below
for what differs.

### Two ways to use it

**Attach to a knowledge base you configured in AWS** — pass its id. AWS owns ingestion through its
own native connectors (S3, SharePoint, Confluence, Google Drive, OneDrive, Web Crawler) on their own
sync schedule:

```ballerina
ai:KnowledgeBase kb = check new bedrock:ManagedKnowledgeBase("GKICZMNWRG", creds, "us-east-1");
ai:QueryMatch[] matches = check kb.retrieve("What is our refund policy?", 5);
```

`retrieve()` searches across **every** data source on the knowledge base. `ingest()` and
`deleteByFilter()` need the knowledge base to also have a `CUSTOM` (direct-ingestion) data source —
construction fails, naming why, if it does not have one; add one in the console, or use the
find-or-create path below.

**Create and own it end to end** — pass a `ManagedKnowledgeBaseDefinition`. This class creates the knowledge
base and a `CUSTOM` data source, and every document flows through `ingest()`:

```ballerina
ai:KnowledgeBase kb = check new bedrock:ManagedKnowledgeBase(
    {
        name: "support-docs",
        serviceRoleArn: "arn:aws:iam::123456789012:role/service-role/bedrock-kb-execution-role"
    },
    creds, "us-east-1");

check kb.ingest([{content: "Refunds are processed within 5 business days."}]);
```

**Find-or-create is by NAME.** `CreateKnowledgeBase` has no upsert, so `init` searches for an exact
name match first: exactly one match attaches (no writes); no match creates one (a MANAGED knowledge
base typically reaches `ACTIVE` in well under 5s — Bedrock owns the store; a VECTOR one can take on
the order of a minute, since a customer-owned store has to be provisioned; both are bounded by
`readyTimeout`); more than one match is a construction error naming the candidate ids — pick the id
and pass it as a `string` instead.

> **A name match is VERIFIED against the rest of the definition.** The name is only the lookup key.
> On a match, `init` compares the definition's `serviceRoleArn`, embedding-model configuration, KMS key and
> (for a self-managed knowledge base) `storageConfiguration` against what the knowledge base actually
> has, and fails construction naming each field that differs. Otherwise a definition carrying, say, a
> `serviceRoleArn` from an entirely different account would attach silently and leave the real role in
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
> **The duplicate persists, and it blocks later startups too.** This is an accepted limitation, not a
> transient warning, so it is worth being precise about what it costs. Once two knowledge bases share
> a name, *every* subsequent `init()` that passes a `ManagedKnowledgeBaseDefinition` with that name also
> fails — not just the two that raced — because the name no longer identifies one knowledge base and
> construction refuses to guess which was meant. Startup stays broken until someone deletes one, using
> the command the error names. The module could instead pick a winner silently, but that trades a
> visible, one-command fix for an orphan quietly consuming a knowledge base quota slot that nobody
> is told about.
>
> **So pass an id in anything that starts more than once.** `ManagedKnowledgeBaseDefinition` is a
> find-or-create convenience, and find-or-create is a read-then-write: it suits a single instance, a
> local run, or a first-time setup. For a service with replicas, a restart loop, or any deployment
> where two processes can boot at the same moment, provision the knowledge base once — console, CLI,
> IaC, or one run of this module — and pass its **id** to `init()` from then on. That path does no
> create, has no race, and is unaffected by all of the above.

### Chunking

A `CUSTOM` data source's `chunkingStrategy` is fixed for its lifetime. **`FIXED_SIZE`** (the default
when this class creates one) means Bedrock chunks server-side — pass `chunkingStrategy: NONE` on
`ManagedKnowledgeBaseDefinition.dataSource` to chunk client-side with an `ai:Chunker` instead:

```ballerina
ai:KnowledgeBase kb = check new bedrock:ManagedKnowledgeBase(
    {
        name: "support-docs",
        serviceRoleArn: "arn:...:role/service-role/bedrock-kb-execution-role",
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
presigned content URL). `deleteByFilter` reconstructs one with `Retrieve`, in this order:

1. **Control probe.** One `Retrieve` with a filter no document can match. A store that returns
   anything for it is not applying filters, so **nothing is deleted**, and the error says why. If the
   probe itself fails, the refusal stands — an unverifiable filter is not permission to delete. AWS
   documents this failure mode for MongoDB Atlas ("Metadata filtering doesn't work by default").
2. **Filtered enumeration.** `Retrieve` with your filter, paged. Every candidate document (from
   `ListKnowledgeBaseDocuments`) whose identity appears here is a confirmed match.
3. **Pinned probes** for every candidate the enumeration did not confirm, one group of documents at a
   time:

| the candidate is reached by | meaning | action |
| --- | --- | --- |
| a pinned probe WITH your filter | the filter matched it | delete |
| a pinned probe only WITHOUT your filter | the filter excluded it | skip — sound, not reported |
| no pinned probe at all | nothing can be concluded | indeterminate — named in the error |

Identity is read from what the response carries: the reserved source-uri metadata key when present, or
the documented `location.customDocumentLocation.id`/`location.s3Location.uri` members.

**Scoped to this class's own data source.** `deleteByFilter` only looks at, and only deletes from, the
data source `ingest()` writes to. Every `Retrieve` it makes is filtered to that data source, and each
result is checked against it again: document ids are unique only within a data source, so a document
with the same id on another data source says nothing about the one here. Other data sources on the same
knowledge base — S3, SharePoint, a second CUSTOM source — are never touched and never cause an error.

> **`filters` must contain at least one leaf predicate.** `ai:KnowledgeBase.deleteByFilter` takes
> filters as a required argument, so a caller assembling them from a collection that happened to be
> empty would otherwise get silent total deletion — an unfiltered `deleteByFilter` would match every
> document. An `ai:MetadataFilters` with no leaf predicates is refused. "Delete everything" has to be
> explicit.

**Cost** is a handful of fixed `Retrieve` calls plus two per group of unconfirmed documents — not a
pass over the whole knowledge base. A maintenance operation, not something to put on a request path.
The per-document delete statuses AWS returns are checked, so a document the service did not confirm
deleted is reported rather than counted as a success.

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

`SelfManagedKnowledgeBase` is the sibling of `ManagedKnowledgeBase` for
`KnowledgeBaseConfiguration.type = VECTOR`. Same three methods, same two endpoints, same SigV4 scope.
Use it when you want control over indexing and ranking; use the managed class when you do not want to
run a vector store.

```ballerina
import ballerinax/ai.aws.bedrock;

// Attach to a knowledge base that already exists.
final bedrock:SelfManagedKnowledgeBase kb = check new ("KB1234ABCD");
```

```ballerina
// Or create the knowledge base and its CUSTOM data source from Ballerina.
// The VECTOR STORE ITSELF MUST ALREADY EXIST — see the callout below.
final bedrock:SelfManagedKnowledgeBase kb = check new ({
    name: "support-articles",
    serviceRoleArn: "arn:aws:iam::123456789012:role/service-role/AmazonBedrockExecutionRoleForKnowledgeBase_1",
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

| | `ManagedKnowledgeBase` | `SelfManagedKnowledgeBase` |
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
on the other. Separately, the knowledge base's own `serviceRoleArn` needs permissions on **your** vector store
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

The reconstruction is [the same algorithm as the managed one](#deletebyfilter-is-a-reconstruction)
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


### Request timeouts

`chat()` and `generate()` wait up to **300 seconds** for a response, because a reasoning model can think
for minutes before it answers. Embeddings and knowledge-base calls wait up to **60 seconds**. Set
`httpConfig.timeout` to change either. The HTTP client's own default is 30 seconds, so a `timeout` of
exactly 30 is read as "not set" and replaced by these values.

### `httpConfig.timeout` does not bound connection setup

`http:ClientConfiguration.timeout` is a *response* deadline — Ballerina documents it as "Maximum time
(in seconds) to wait for a response before the request times out" — and it is armed only once the
request has been written. DNS resolution, the TCP connect and the TLS handshake all happen before that,
bounded instead by `httpConfig.socketConfig.connectTimeOut`, which defaults to **15 seconds**. So a very
small `timeout` will not fire quickly on a cold connection; it fires quickly on a warm one.

Measured against `bedrock-runtime.us-east-1.amazonaws.com` with `timeout: 0.001`:

| Setup | Time to the error |
| --- | --- |
| Cold pool, `maxRetries: 0` | ~1.3 s (DNS + TCP + TLS, none of it under `timeout`) |
| Cold pool, module-default retries | ~7.1 s — the 1 + 2 + 4 s backoff, not the deadline |
| Cold pool, `socketConfig: {connectTimeOut: 0.001}` as well | ~8 ms |
| Warm pool, connection reused | ~4 ms |

Two consequences worth knowing. **Set `connectTimeOut` too** if you want a tight overall deadline — the
response timeout alone cannot give you one. And **a timeout is retryable**: it is a transport failure,
so this module's `retryConfig` retries it with exponential backoff, which multiplies the wall-clock
wait. Set `retryConfig = {maxRetries: 0}` when you are measuring the deadline itself. Credential
resolution adds its own one-off cost to the *first* provider you construct (~0.7 s while the AWS
credential chain is walked), which is charged to `init`, not to the call.

## Guardrails

| Route | Mechanism |
| --- | --- |
| Converse | `guardrailConfig` body field |
| Invoke | `X-Amzn-Bedrock-Guardrail*` request headers; the fired signal returns in the response body |
| Mantle | not supported → construction error pointing at `ApplyGuardrail` |

A fired guardrail is never silently dropped on either supported route: the trace's finish reason is
`content_filter`. Every API's stop reason is mapped to the same set on the trace — `stop`, `length`,
`tool_calls`, `content_filter` or `error` — so traces read the same whichever API answered.

## Fails fast, before any network call

Construction errors are reserved for what AWS *cannot* diagnose for you:

- an `imported-model/` ARN (AWS applies no default chat template to imported weights)
- any route in the AWS China partition (`cn-`) — Bedrock is not offered there at all
- a `Mantle*` class on a model with no known Mantle request path
- a `Mantle*` class on a partition that serves no Mantle host (ISO, EU Sovereign); GovCloud and
  commercial **are** supported
- a `Mantle*` class given an ARN, or a cross-region-prefixed id
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

**Supported on the routes below.** Everywhere else an image is refused **per request, before any
network call**, with an `ai:Error` naming the dialect — never silently dropped into the prompt text.

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

## Migrating to the endpoint-split surface

The seven vendor classes were replaced by fourteen endpoint-specific ones. This is a clean break —
there are no deprecated aliases.

**1. Pick the class for the endpoint you want.** `<Vendor>ModelProvider` becomes
`Runtime<Vendor>ModelProvider` in almost every case — that is where AWS recommends you be, and
it is what the old `apiFamily = CONVERSE` produced. Use `Mantle<Vendor>ModelProvider` only for a
model or capability that exists only there.

```ballerina
// before
check new bedrock:AnthropicModelProvider(bedrock:CLAUDE_SONNET_5, creds, aws:US_EAST_1);

// now — and note the id is CRIS-prefixed, which is what bedrock-runtime requires for Claude
check new bedrock:RuntimeAnthropicModelProvider(bedrock:CLAUDE_SONNET_5, creds, aws:US_EAST_1);
```

**2. `apiFamily` became `apiType`, and lost `AUTO` and `MANTLE`.**

```ballerina
apiFamily = bedrock:AUTO       → (removed) pick the class instead
apiFamily = bedrock:CONVERSE   → apiType = bedrock:CONVERSE   // now the default
apiFamily = bedrock:INVOKE     → apiType = bedrock:INVOKE
apiFamily = bedrock:MANTLE     → use the Mantle* class
"mantle/<id>" / "converse/<id>" / "invoke/<id>"  → (removed) use the class and `apiType`
```

`apiType` also gained the three vendor-native shapes — `MESSAGES`, `CHAT_COMPLETIONS` and `RESPONSES` —
which `bedrock-runtime` now serves directly. Which of them a class accepts is part of its type.

**3. Behaviour that changed, not just spelling.**

- **No endpoint is chosen for you.** Previously a bare Mantle-capable id resolved to `bedrock-mantle`,
  which needs the separate `bedrock-mantle:CreateInference` permission. Code that relied on that now
  reaches `bedrock-runtime` unless you construct a Mantle class.
- **`generate()` no longer silently switches endpoints.** It used to resolve a second Converse spine so
  a typed `generate()` worked on a Mantle-routed model — meaning one object needed two IAM permissions.
  One class, one endpoint now: a typed `generate()` on a `Mantle*` class uses that endpoint's own tool
  calling, and returns an `ai:Error` only on the Mantle Anthropic Messages route.
- **`guardrail`, `serviceTier` and `latencyOptimized` are gone from the Mantle config records**, so
  setting them there is now a compile error rather than a construction error.
- **Guardrails are refused on the `RESPONSES` and `MESSAGES` shapes.** AWS states guardrails do not
  apply to the Responses API, and documents no guardrail parameters for `/anthropic/v1/messages`; the
  module refuses rather than sending headers it cannot confirm are honoured.
- **Mantle classes reject ARNs and cross-region-prefixed ids**, both of which are runtime-only concepts.

**4. Model enums split per endpoint.** `<Vendor>Model` became `<Vendor>RuntimeModel` and
`<Vendor>MantleModel`. Runtime constants carry the CRIS prefix where AWS requires one; Mantle constants
are bare. **Mantle enum members are prefixed `MANTLE_`** (`MANTLE_CLAUDE_OPUS_5`, `MANTLE_GPT_5_4`)
because Ballerina enum members share one module namespace.

**5. `anthropic.claude-mythos-preview` was removed** — AWS publishes no model card or endpoint-table row
for it. `anthropic.claude-mythos-5` (bedrock-mantle only) and `anthropic.claude-mythos-5.1`
(bedrock-runtime only) are real and documented; see the endpoint-availability table.

**6. `CommonModelProvider` is new.** If you were passing raw id strings to a vendor class just to
reach a model that class did not enumerate, this is the better home for it — it takes any Converse-
capable id from any vendor.

Embedding and knowledge-base classes are unchanged.

SigV4 signing is unchanged — see [Not implemented](#not-implemented) for why signing stayed in-module.

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
