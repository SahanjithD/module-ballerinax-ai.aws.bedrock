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

// An error's message followed by every message in its cause chain. User-facing
// messages are kept short and the detail is carried in the cause, so a test that
// checks for a detail reads the whole chain rather than the top message alone.
function errorText(error e) returns string {
    string text = e.message();
    error? cause = e.cause();
    while cause is error {
        text += " | " + cause.message();
        cause = cause.cause();
    }
    return text;
}
