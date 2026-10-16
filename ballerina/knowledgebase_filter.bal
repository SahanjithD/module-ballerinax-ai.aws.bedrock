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

import ballerina/ai;

// `ai:MetadataFilters` to a Bedrock `RetrievalFilter`. Each object sets exactly one
// operator, and a group needs at least two members, so a one-member group is flattened.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_RetrievalFilter.html

// `IN` and `NOT_IN` need an array value.
isolated function metadataFilterToRetrievalFilter(ai:MetadataFilter filter) returns json|ai:Error {
    string key = filter.key;
    json value = filter.value;
    if (filter.operator == ai:IN || filter.operator == ai:NOT_IN) && value !is json[] {
        return error ai:Error(
            string `MetadataFilter operator '${filter.operator}' requires an array 'value' (got ` +
            string `${value.toJsonString()}) for key '${key}'`);
    }
    json attribute = {key, value};
    match filter.operator {
        ai:EQUAL => {
            return {'equals: attribute};
        }
        ai:NOT_EQUAL => {
            return {notEquals: attribute};
        }
        ai:GREATER_THAN => {
            return {greaterThan: attribute};
        }
        ai:GREATER_THAN_OR_EQUAL => {
            return {greaterThanOrEquals: attribute};
        }
        ai:LESS_THAN => {
            return {lessThan: attribute};
        }
        ai:LESS_THAN_OR_EQUAL => {
            return {lessThanOrEquals: attribute};
        }
        ai:IN => {
            return {'in: attribute};
        }
        ai:NOT_IN => {
            return {notIn: attribute};
        }
    }
    // Unreachable: every operator is matched above.
    return error ai:Error(string `Unsupported metadata filter operator: '${filter.operator}'`);
}

isolated function metadataFiltersToRetrievalFilter(ai:MetadataFilters filters) returns json?|ai:Error {
    json[] children = [];
    foreach ai:MetadataFilters|ai:MetadataFilter child in filters.filters {
        json? childJson = child is ai:MetadataFilter
            ? check metadataFilterToRetrievalFilter(child)
            : check metadataFiltersToRetrievalFilter(child);
    // `()` is a `json` value, so `childJson is json` would let empty groups through as
    // `null` members.
        if childJson !is () {
            children.push(childJson);
        }
    }
    if children.length() == 0 {
        return ();
    }
    // FLATTEN: a one-element group is not a group at all on the wire — `andAll`/
    // `orAll` reject fewer than 2 entries.
    if children.length() == 1 {
        return children[0];
    }
    string groupKey = filters.condition == ai:OR ? "orAll" : "andAll";
    return {[groupKey]: children};
}

// `deleteByFilter` checks this as well as the encoded filter, so an empty filter can
// never delete everything.
isolated function filterLeafCount(ai:MetadataFilters filters) returns int {
    int count = 0;
    foreach ai:MetadataFilters|ai:MetadataFilter child in filters.filters {
        count += child is ai:MetadataFilter ? 1 : filterLeafCount(child);
    }
    return count;
}
