/*
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
package io.ballerina.lib.ai.aws.bedrock;

import io.ballerina.runtime.api.Environment;
import io.ballerina.runtime.api.Module;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BError;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BTypedesc;

import java.lang.reflect.Method;

/**
 * Native shim for {@code ModelProvider.generate()} (design §3, §8). It derives
 * the JSON schema from the expected typedesc (reusing ballerina/ai's native
 * generator, present on the runtime classpath) and delegates to the Ballerina
 * {@code generateLlmResponse} function, whose {@code anydata} result the runtime
 * coerces to the caller's expected type.
 *
 * @since 0.1.0
 */
public final class Generator {

    private static final String AI_NATIVE_CLASS = "io.ballerina.stdlib.ai.wso2.Native";
    private static final String AI_SCHEMA_METHOD = "generateJsonSchemaForTypedescNative";

    private Generator() {
    }

    public static Object generate(Environment env, BObject modelProvider,
                                  BObject prompt, BTypedesc expectedResponseTypedesc) {
        Object schema = deriveJsonSchema(expectedResponseTypedesc);
        return env.getRuntime().callFunction(
                new Module("ballerinax", "ai.aws.bedrock", "0"), "generateLlmResponse", null,
                modelProvider.get(StringUtils.fromString("supportsStructuredOutput")),
                modelProvider.get(StringUtils.fromString("family")),
                modelProvider.get(StringUtils.fromString("codec")),
                modelProvider.get(StringUtils.fromString("transport")),
                modelProvider.get(StringUtils.fromString("wireModelId")),
                modelProvider.get(StringUtils.fromString("extraHeaders")),
                modelProvider.get(StringUtils.fromString("params")),
                prompt, expectedResponseTypedesc, schema);
    }

    // Reflectively invokes ballerina/ai's schema generator so this module carries
    // no compile-time dependency on ai's internal native class. Returns the schema
    // BMap, or null for simple types / when the generator is unavailable.
    private static Object deriveJsonSchema(BTypedesc expectedResponseTypedesc) {
        try {
            Class<?> nativeClass = Class.forName(AI_NATIVE_CLASS);
            Method method = nativeClass.getMethod(AI_SCHEMA_METHOD, BTypedesc.class);
            Object result = method.invoke(null, expectedResponseTypedesc);
            return result instanceof BError ? null : result;
        } catch (ReflectiveOperationException | RuntimeException e) {
            return null;
        }
    }
}
