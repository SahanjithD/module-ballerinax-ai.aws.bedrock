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

# A parsed Bedrock ARN: `arn:partition:service:region:account-id:resource-type/resource-id`.
# Its region and partition override `config.region`.
type ParsedArn record {|
    # `aws` | `aws-cn` | `aws-us-gov`.
    string partition;
    # e.g. `bedrock`.
    string 'service;
    # The region; empty on global ARNs such as foundation-model ones, where the caller's
    # region is used.
    string region;
    # The 12-digit AWS account id; may be empty.
    string accountId;
    # e.g. `imported-model`, `provisioned-model`, `inference-profile`.
    string resourceType;
    # The opaque id after the `/` (or `:`) delimiter; may be empty.
    string resourceId;
|};

// `true` if `model` is an ARN.
isolated function isArn(string model) returns boolean => model.startsWith("arn:");

// Splits an ARN: five `:` segments, then the resource (`type/id`, or rarely `type:id`).
isolated function parseArn(string arn) returns ParsedArn|error {
    if !arn.startsWith("arn:") {
        return error(string `not an ARN: ${arn}`);
    }
    string rest = arn;
    string[] fields = [];
    int count = 0;
    while count < 5 {
        int? idx = rest.indexOf(":");
        if idx is () {
            return error(string `malformed ARN (fewer than 6 segments): ${arn}`);
        }
        fields.push(rest.substring(0, idx));
        rest = rest.substring(idx + 1);
        count += 1;
    }
    // An empty partition or service is malformed. An empty region or account is not.
    if fields[1] == "" {
        return error(string `malformed ARN (empty partition segment): ${arn}`);
    }
    if fields[2] == "" {
        return error(string `malformed ARN (empty service segment): ${arn}`);
    }
    string res = rest;
    string resourceType;
    string resourceId;
    int? slash = res.indexOf("/");
    int? colon = res.indexOf(":");
    if slash is int {
        resourceType = res.substring(0, slash);
        resourceId = res.substring(slash + 1);
    } else if colon is int {
        resourceType = res.substring(0, colon);
        resourceId = res.substring(colon + 1);
    } else {
        resourceType = res;
        resourceId = "";
    }
    return {
        partition: fields[1],
        'service: fields[2],
        region: fields[3],
        accountId: fields[4],
        resourceType,
        resourceId
    };
}
