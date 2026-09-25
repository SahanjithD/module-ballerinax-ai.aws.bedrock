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
compatibility surface. Reach for a `BedrockMantle*` class only when the model or capability you need
is not on `bedrock-runtime` — GPT-5.4/5.5 and Gemma 4 are Mantle-only, for instance. Guardrails,
cross-region inference and structured output are all runtime-only.

### Key features

- Chat completion through one `ai:ModelProvider` contract, on either endpoint
- `BedrockCommonModelProvider` reaches **every** model Bedrock serves on Converse — 15 of AWS's 17
  providers, including the ten with no dedicated class here
- Structured output (`generate()`) by tool-forcing on Converse and InvokeModel
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

**Any vendor, Converse** — `BedrockCommonModelProvider`. Takes a model id as a plain `string` and reaches
every Converse-capable model, including Meta, Cohere, AI21, MiniMax, Moonshot, NVIDIA, Writer, xAI, Z.AI
and Stability. Start here unless you need a vendor-specific knob or a non-Converse dialect.

**`bedrock-runtime`, per vendor** — `BedrockRuntimeAnthropicModelProvider`,
`BedrockRuntimeOpenAIModelProvider`, `BedrockRuntimeAmazonModelProvider` (Nova),
`BedrockRuntimeMistralModelProvider`, `BedrockRuntimeQwenModelProvider`,
`BedrockRuntimeGoogleModelProvider` (Gemma), `BedrockRuntimeDeepSeekModelProvider`.

**`bedrock-mantle`, per vendor** — the same six minus Amazon:
`BedrockMantleAnthropicModelProvider`, `BedrockMantleOpenAIModelProvider`,
`BedrockMantleMistralModelProvider`, `BedrockMantleQwenModelProvider`,
`BedrockMantleGoogleModelProvider`, `BedrockMantleDeepSeekModelProvider`. There is no Amazon Mantle
class because AWS serves no Amazon model on that endpoint.

**Embeddings** — `TitanEmbeddingProvider`, `CohereEmbeddingProvider` (InvokeModel on `bedrock-runtime`).

**Knowledge base** — `BedrockManagedKnowledgeBase` (Bedrock owns the vector store) and
`BedrockVectorKnowledgeBase` (you own it), both implementing `ai:KnowledgeBase`. See
[Knowledge bases](#knowledge-bases) and [Self-managed knowledge bases](#self-managed-knowledge-bases).

A model AWS ships before this module updates an enum is still usable — pass its id as a `string`. Every
provider takes `<Vendor><Endpoint>Model|string`, so the enums are autocomplete and documentation, never a
gate. On a runtime class an unrecognised id simply goes on the wire and AWS answers for it. A brand-new
*Mantle* model is the one case that needs a module release, because its request path cannot be derived
from its id.

### Choosing the API family

Runtime classes take an `api` argument defaulting to `CONVERSE`. Which families a class offers is a
property of its type, so an unreachable combination does not compile:

| Class | Type of `api` | Accepts |
| --- | --- | --- |
| `BedrockRuntimeAnthropicModelProvider` | `AnthropicRuntimeApi` | `CONVERSE`, `INVOKE`, `MESSAGES` |
| `BedrockRuntimeOpenAIModelProvider` | `OpenAIRuntimeApi` | `CONVERSE`, `INVOKE`, `CHAT_COMPLETIONS`, `RESPONSES` |
| `BedrockRuntimeMistralModelProvider` | `MistralRuntimeApi` | `CONVERSE`, `INVOKE`, `CHAT_COMPLETIONS` |
| `BedrockRuntimeQwenModelProvider` | `QwenRuntimeApi` | `CONVERSE`, `INVOKE`, `CHAT_COMPLETIONS` |
| `BedrockRuntimeGoogleModelProvider` | `GoogleRuntimeApi` | `CONVERSE`, `INVOKE`, `CHAT_COMPLETIONS` |
| `BedrockRuntimeDeepSeekModelProvider` | `DeepSeekRuntimeApi` | `CONVERSE`, `INVOKE`, `CHAT_COMPLETIONS` |
| `BedrockRuntimeAmazonModelProvider` | `AmazonRuntimeApi` | `CONVERSE`, `INVOKE` |
| `BedrockCommonModelProvider` | — | Converse only |
| `BedrockMantle*ModelProvider` | — | the model's own family |

`CHAT_COMPLETIONS` is deliberately not OpenAI-only: AWS serves that family for DeepSeek, Gemma 3, Mistral,
Qwen3 and others. **Mantle classes take no `api` argument at all.** Each Mantle model has exactly one route this module
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

Only the model is required. Region falls back to `AWS_REGION`/`AWS_DEFAULT_REGION`, and credentials
to the AWS credential chain — so on AWS compute this is the whole thing:

```ballerina
import ballerinax/aws;
import ballerinax/aws.auth;

final ai:ModelProvider claude = check new bedrock:BedrockRuntimeAnthropicModelProvider(
        bedrock:CLAUDE_SONNET_4_6, auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);
```

Every runtime class follows the same shape — `(model, credentials, region, api?, endpoint?,
maxTokens?, temperature?, *Config)`. `model`, `credentials` and `region` are required; `api` defaults
to `CONVERSE`. `api` and `endpoint` sit directly on `init` rather than inside the config record,
because both are decisions you make at the same moment you pick the model and region:

```ballerina
final ai:ModelProvider nova = check new bedrock:BedrockRuntimeAmazonModelProvider(
        bedrock:NOVA_PRO, auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);
// GPT-5.4 is Mantle-only, so it takes the Mantle class.
final ai:ModelProvider gpt = check new bedrock:BedrockMantleOpenAIModelProvider(
        bedrock:MANTLE_GPT_5_4, auth:DEFAULT_CREDENTIALS, aws:US_EAST_2);
// Any vendor at all, over Converse.
final ai:ModelProvider llama = check new bedrock:BedrockCommonModelProvider(
        "us.meta.llama3-3-70b-instruct-v1:0", auth:DEFAULT_CREDENTIALS, aws:US_EAST_1);
final ai:ModelProvider gemma = check new bedrock:BedrockRuntimeGoogleModelProvider(
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
    check new bedrock:BedrockRuntimeAnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6, role, aws:US_EAST_1);
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

> **Typed `generate()` works everywhere except Mantle Messages.** On `bedrock-runtime` and on the
> OpenAI-shaped Mantle routes (Responses, Chat Completions) a typed target is obtained by forcing a
> tool. The one exception is `BedrockMantleAnthropicModelProvider`, which resolves to the Anthropic
> Messages API: that route rejects both `output_config.format` and `strict: true` on tools, so it
> returns an `ai:Error` for any non-`string` target type, naming the model and saying so.
>
> There is no silent cross-endpoint fallback — the class you constructed is the endpoint you talk to.
> Claude is dual-homed, so the fix is `BedrockRuntimeAnthropicModelProvider` instead.
>
> A `string` target is plain text on every class and never hits this.
>
> A `string` target always returns text normally, and `chat()` is unaffected in every case.
>
> Typed generation is also unavailable on Mistral's **text-completion** dialect (see below), which has no
> tool-calling at all. That only bites when you pass `api = INVOKE` for those ids — the default Converse
> shape supports typed generation for every Mistral model.

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

You pick the endpoint by picking the class, and the API family with `api`. What is left for the module to
resolve is the model id and the request path, and that happens once, at construction — before any
network call.

**There is no automatic endpoint selection.** Earlier versions of this module had an `AUTO` mode that
preferred `bedrock-mantle` for any Mantle-capable model. That is gone: it sent flagship models to the
endpoint with no guardrails, no cross-region inference and no structured output, and — because Mantle
authorizes under a *separate* IAM namespace — produced `AccessDenied` for credentials that were
perfectly valid for Bedrock. The endpoint is now yours to state, and the type system holds you to it.

### On a `BedrockRuntime*` class (or `BedrockCommonModelProvider`)

| You pass | Resolves to |
| --- | --- |
| a bare id (`amazon.nova-pro-v1:0`) | the `api` shape you asked for; `CONVERSE` by default |
| a CRIS id (`us.anthropic.claude-opus-4-8`) | same, prefix stripped for lookup and re-applied on the wire |
| `provisioned-model/` · `custom-model-deployment/` · `inference-profile/` ARN | same, ARN sent verbatim (URL-encoded) |
| `foundation-model/` ARN | same, stripped to the bare id it carries |
| an unknown id | sent as-is — Converse is model-agnostic, so AWS answers for it |
| `custom-model/` ARN | **not supported** — construction error; pass the deployment ARN |
| `imported-model/` ARN | **not supported** — construction error |

Current Claude models are served on `bedrock-runtime` through cross-region inference profiles only, so
the `AnthropicRuntimeModel` constants carry a `us.` prefix. A bare Claude id here fails with
`on-demand throughput isn't supported`.

### On a `BedrockMantle*` class

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
check new bedrock:BedrockMantleAnthropicModelProvider("anthropic.claude-haiku-4-5", creds, "us-east-1");

// 2. Pick the wire shape with `api`. Only the shapes AWS serves for that vendor compile.
check new bedrock:BedrockRuntimeAnthropicModelProvider("us.anthropic.claude-haiku-4-5", creds,
        "us-east-1", api = bedrock:MESSAGES);

// 3. Any raw model id string is always accepted — the model enums are
//    conveniences, never a gate. A model AWS shipped after this release works today.
check new bedrock:BedrockRuntimeAmazonModelProvider("amazon.nova-something-new-v1:0", creds, "us-east-1");

// 4. A vendor with no class of its own — Converse reaches all of them.
check new bedrock:BedrockCommonModelProvider("us.writer.palmyra-x5-v1:0", creds, "us-east-1");
```

The `mantle/`, `converse/` and `invoke/` model-id string prefixes are **gone**. They were a way to
override a resolver that no longer exists; the class and the `api` argument say the same thing in the
type system.

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
check new bedrock:BedrockRuntimeAnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6, creds, aws:US_GOV_WEST_1,
    endpoint = {fips: true});
// → https://bedrock-runtime-fips.us-gov-west-1.amazonaws.com

// A concrete origin: gateway, LocalStack, or a VPC endpoint
check new bedrock:BedrockRuntimeAnthropicModelProvider(bedrock:CLAUDE_SONNET_4_6, creds, aws:US_EAST_1,
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
- **There is no `bedrock-mantle` FIPS host.** `endpoint = {fips: true}` on any `BedrockMantle*` class
  is a construction error. Use the matching `BedrockRuntime*` class for a FIPS-compliant call.
- **`us-gov-west-1` has Mantle; `us-gov-east-1` does not.** We deliberately do not encode region
  lists — they go stale — so a `BedrockMantle*` class on `us-gov-east-1` builds a Mantle host and gets
  AWS's own error at call time, which names the real problem better than a stale list could.

### Partitions

- **China (`cn-`) is rejected at construction, on every API family.** Amazon Bedrock is not offered
  in the AWS China partition at all — not Mantle, not `bedrock-runtime`. The endpoint resolver would
  still happily build a well-formed host (it is a string builder and never fails), so without this
  guard the first call fails with a bare connection error naming nothing.
- **ISO and EU Sovereign partitions** (`us-iso-`, `us-isob-`, `us-isof-`, `eusc-`) reach
  `bedrock-runtime` normally. They serve no Mantle host, so constructing any `BedrockMantle*` class
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
> `CommonRuntimeConfig` and not on `CommonMantleConfig`, so setting one on a `BedrockMantle*` class is a
> *compile* error rather than something discovered at construction or, worse, silently dropped on the
> wire. Use the matching `BedrockRuntime*` class to send them as Bedrock defines them. Mantle's vendor-compatible surfaces do have a `service_tier` body field, but with the
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

> **Pass `maxTokens = ()` to drop the field entirely.** Some models reject a token cap rather than
> honouring it: OpenAI deprecated the Chat Completions `max_tokens` parameter in favour of
> `max_completion_tokens` and marks it *"not compatible with o-series models"*, and the GPT-6 models
> refuse it. An explicit `()` now means *omit it*, on every dialect, the same way an unset `temperature`
> does — before this it was silently coerced back to 4096, which made those models unreachable. If you
> still want a cap on such a model, send the parameter it does accept through the passthrough:
> `additionalModelRequestFields = {"max_completion_tokens": 4096}`.

## Vendor dialects

### Mistral speaks two InvokeModel dialects

Mistral is the one vendor whose `InvokeModel` wire shape cannot be derived from its vendor prefix:

| Dialect | Models | Wire |
| --- | --- | --- |
| [text completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-text-completion.html) | 7B Instruct, Mixtral 8x7B, **Large 24.02** | `prompt` (`<s>[INST]…[/INST]`) → `outputs[].text`; no tools |
| [chat completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-mistral-large-2407.html) | **Large 24.07**, newer ids | `messages`/`tools` → `choices[].message` |

Note that `mistral-large-**2402**` and `mistral-large-**2407**` are the same family four months apart and
speak *opposite* dialects. The module picks by id; an id it has never seen defaults to chat. If it guesses wrong, Bedrock returns a
`ValidationException` — switch to `api = bedrock:CONVERSE`, which is model-agnostic and sidesteps
the split entirely.

**Converse (the default) hides all of this** — the split only matters when you pass `api = INVOKE`.

### DeepSeek does too

Same story, split by generation rather than by date:

| Dialect | Models | Wire |
| --- | --- | --- |
| [text completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-deepseek.html) | **R1** (`deepseek.r1-v1:0`) | `prompt` (DeepSeek's `<｜User｜>` template) → `choices[].text`; no tools |
| [chat completion](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-v3-2.html) | **V3.1**, **V3.2**, newer ids | `messages`/`tools` → `choices[].message` |

The module picks by id, and an id it has never seen defaults to chat. Again, only relevant when you
pass `api = INVOKE` — Converse and the vendor-native shapes are unaffected.

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
> **The duplicate persists, and it blocks later startups too.** This is an accepted limitation, not a
> transient warning, so it is worth being precise about what it costs. Once two knowledge bases share
> a name, *every* subsequent `init()` that passes a `KnowledgeBaseDefinition` with that name also
> fails — not just the two that raced — because the name no longer identifies one knowledge base and
> construction refuses to guess which was meant. Startup stays broken until someone deletes one, using
> the command the error names. The module could instead pick a winner silently, but that trades a
> visible, one-command fix for an orphan quietly consuming a knowledge base quota slot that nobody
> is told about.
>
> **So pass an id in anything that starts more than once.** `KnowledgeBaseDefinition` is a
> find-or-create convenience, and find-or-create is a read-then-write: it suits a single instance, a
> local run, or a first-time setup. For a service with replicas, a restart loop, or any deployment
> where two processes can boot at the same moment, provision the knowledge base once — console, CLI,
> IaC, or one run of this module — and pass its **id** to `init()` from then on. That path does no
> create, has no race, and is unaffected by all of the above.

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
- a `BedrockMantle*` class on a model with no known Mantle request path
- a `BedrockMantle*` class on a partition that serves no Mantle host (ISO, EU Sovereign); GovCloud and
  commercial **are** supported
- a `BedrockMantle*` class given an ARN, or a cross-region-prefixed id
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

## Migrating to the endpoint-split surface

The seven vendor classes were replaced by fourteen endpoint-specific ones. This is a clean break —
there are no deprecated aliases.

**1. Pick the class for the endpoint you want.** `<Vendor>ModelProvider` becomes
`BedrockRuntime<Vendor>ModelProvider` in almost every case — that is where AWS recommends you be, and
it is what the old `apiFamily = CONVERSE` produced. Use `BedrockMantle<Vendor>ModelProvider` only for a
model or capability that exists only there.

```ballerina
// before
check new bedrock:AnthropicModelProvider(bedrock:CLAUDE_SONNET_5, creds, aws:US_EAST_1);

// now — and note the id is CRIS-prefixed, which is what bedrock-runtime requires for Claude
check new bedrock:BedrockRuntimeAnthropicModelProvider(bedrock:CLAUDE_SONNET_5, creds, aws:US_EAST_1);
```

**2. `apiFamily` became `api`, and lost `AUTO` and `MANTLE`.**

```ballerina
apiFamily = bedrock:AUTO       → (removed) pick the class instead
apiFamily = bedrock:CONVERSE   → api = bedrock:CONVERSE   // now the default
apiFamily = bedrock:INVOKE     → api = bedrock:INVOKE
apiFamily = bedrock:MANTLE     → use the BedrockMantle* class
"mantle/<id>" / "converse/<id>" / "invoke/<id>"  → (removed) use the class and `api`
```

`api` also gained the three vendor-native shapes — `MESSAGES`, `CHAT_COMPLETIONS` and `RESPONSES` —
which `bedrock-runtime` now serves directly. Which of them a class accepts is part of its type.

**3. Behaviour that changed, not just spelling.**

- **No endpoint is chosen for you.** Previously a bare Mantle-capable id resolved to `bedrock-mantle`,
  which needs the separate `bedrock-mantle:CreateInference` permission. Code that relied on that now
  reaches `bedrock-runtime` unless you construct a Mantle class.
- **`generate()` no longer silently switches endpoints.** It used to resolve a second Converse spine so
  a typed `generate()` worked on a Mantle-routed model — meaning one object needed two IAM permissions.
  One class, one endpoint now: a typed `generate()` on a `BedrockMantle*` class returns an `ai:Error`.
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

**6. `BedrockCommonModelProvider` is new.** If you were passing raw id strings to a vendor class just to
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
