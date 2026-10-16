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

// No default temperature: Claude 4.7+ and some reasoning models reject any
// value, so the field is left out unless the caller sets it.

// Room for a thinking pass plus an answer, and still under Nova's 5K output cap.
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-amazon-nova-pro.html
const int DEFAULT_MAX_TOKEN_COUNT = 4096;

// Request timeouts in seconds, unless `httpConfig.timeout` is set. A reasoning model
// can think for minutes; embeddings and knowledge-base calls return quickly.
const decimal INFERENCE_TIMEOUT = 300;
const decimal DEFAULT_TIMEOUT = 60;
// `http:ClientConfiguration.timeout`'s own default, which is read as "not set".
const decimal HTTP_CLIENT_DEFAULT_TIMEOUT = 30;

// Anthropic's floor for a manual thinking budget.
// https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-extended-thinking.html
const int MIN_THINKING_BUDGET_TOKENS = 1024;

// Cross-region inference geo prefixes, stripped for lookup and put back on the wire.
// https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html
final readonly & string[] CRIS_PREFIXES = ["global", "us", "eu", "apac", "jp", "au", "us-gov"];

// Models that reject a forced tool choice on every API, so `generate()` offers its
// tool unforced. Matched on the bare id; an ARN hides the model, so AWS answers.
// https://platform.claude.com/docs/en/models/opus-5-5/whats-new-opus-5-5
final readonly & string[] FORCED_TOOL_UNSUPPORTED = [
    "anthropic.claude-opus-5-5",
    "anthropic.claude-fable-5-1"
];

// Takes the wire id, so a cross-region `us.` id matches too.
isolated function refusesForcedToolChoice(string wireModelId) returns boolean {
    [string, string?] [bareId, _] = normalizeModelId(wireModelId);
    return FORCED_TOOL_UNSUPPORTED.indexOf(bareId) is int;
}

// With thinking on, Anthropic accepts only an `auto` or `none` tool choice.
// https://platform.claude.com/docs/en/build-with-claude/extended-thinking
isolated function thinkingEnabled(InferenceParams params) returns boolean {
    ThinkingConfig? thinking = params?.thinking;
    if thinking is ThinkingConfig {
        return thinking.mode != DISABLED;
    }
    AdditionalRequestFields? extra = params?.additionalModelRequestFields;
    json passthrough = extra is AdditionalRequestFields ? extra["thinking"] : ();
    if passthrough is map<json> {
        json kind = passthrough["type"];
        return kind is string && kind != "disabled";
    }
    return false;
}
