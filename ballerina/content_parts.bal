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
import ballerina/http;
import ballerina/lang.array;

// Flattens an `ai:Prompt` into ordered parts (text and images) once, before any
// converter runs. All I/O (fetching image URLs) happens here, so the converters stay
// pure. Images are kept as bytes plus a MIME type, the one form every API can be built
// from: Converse has no URL source, and Anthropic on Bedrock takes base64 only.
// https://platform.claude.com/docs/en/build-with-claude/vision

# One part of a user turn after its `ai:Prompt` has been flattened.
type ContentPart TextPart|ImagePart;

# Literal text.
type TextPart record {|
    # Discriminator.
    readonly "text" kind = "text";
    # The text.
    string text;
|};

# An image, always as raw bytes plus a concrete IANA type.
type ImagePart record {|
    # Discriminator.
    readonly "image" kind = "image";
    # Concrete type — never a wildcard. Both Converse's `format` and Anthropic's
    # `media_type` are derived from this, and neither accepts `image/*`.
    string mimeType;
    # UNencoded bytes. Each emitter base64-encodes at its own wire boundary.
    byte[] data;
|};

# A user message whose content has been resolved to parts. Assistant and function
# messages are unchanged — neither can carry an image.
type ResolvedUserMessage record {|
    # Always `ai:USER`.
    ai:USER role = ai:USER;
    # The message content, in order.
    ContentPart[] parts;
|};

# A chat message ready for a converter: user content resolved to parts, others unchanged.
type ResolvedMessage ResolvedUserMessage|ai:ChatAssistantMessage|ai:ChatFunctionMessage;

// The only image formats any Bedrock API accepts.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_ImageBlock.html
final readonly & map<string> MIME_TO_CONVERSE_FORMAT = {
    "image/png": "png",
    "image/jpeg": "jpeg",
    "image/gif": "gif",
    "image/webp": "webp"
};

const MAX_IMAGE_DOWNLOAD_BYTES = 20 * 1024 * 1024; // 20 MiB
const MAX_IMAGE_REDIRECTS = 5;

// ---------------------------------------------------------------------------
// Resolution (does I/O)
// ---------------------------------------------------------------------------

// Hoists system content as text and resolves each user turn to parts.
isolated function resolveMessages(ai:ChatMessage[] messages)
        returns [string?, ResolvedMessage[]]|ai:Error {
    string[] systemParts = [];
    ResolvedMessage[] rest = [];
    foreach ai:ChatMessage m in messages {
        if m is ai:ChatSystemMessage {
            // No API takes an image in the system prompt, so it is refused.
            systemParts.push(check contentToText(m.content, "a system message"));
        } else if m is ai:ChatUserMessage {
            rest.push({parts: check contentToParts(m.content)});
        } else if m is ai:ChatAssistantMessage|ai:ChatFunctionMessage {
            rest.push(m);
        }
    }
    string? system = systemParts.length() == 0 ? () : string:'join("\n\n", ...systemParts);
    return [system, rest];
}

// A user turn's content as ordered parts. Adjacent text is merged, so a text-only
// prompt is one part.
isolated function contentToParts(string|ai:Prompt content) returns ContentPart[]|ai:Error {
    if content is string {
        return content == "" ? [] : [{text: content}];
    }
    string[] & readonly strings = content.strings;
    anydata[] insertions = content.insertions;
    ContentPart[] parts = [];
    string text = strings.length() > 0 ? strings[0] : "";

    foreach int i in 0 ..< insertions.length() {
        anydata insertion = insertions[i];
        if insertion is ai:Document|ai:Chunk {
            text = flushText(text, parts);
            check appendDocument(insertion, parts);
        } else if insertion is (ai:Document|ai:Chunk)[] {
            text = flushText(text, parts);
            foreach ai:Document|ai:Chunk doc in insertion {
                check appendDocument(doc, parts);
            }
        } else {
            text += insertion.toString();
        }
        if i + 1 < strings.length() {
            text += strings[i + 1];
        }
    }
    _ = flushText(text, parts);
    return parts;
}

// Content as plain text; an image is refused, naming `sink`.
isolated function contentToText(string|ai:Prompt content, string sink) returns string|ai:Error {
    ContentPart[] parts = check contentToParts(content);
    string text = "";
    foreach ContentPart part in parts {
        if part is ImagePart {
            return error ai:Error(string `Images are not supported in ${sink}. ` +
                "Move the image into a user message on a Converse or Anthropic route.");
        }
        text += part.text;
    }
    return text;
}

// Text and images only; other document types are out of scope.
isolated function appendDocument(ai:Document|ai:Chunk doc, ContentPart[] parts) returns ai:Error? {
    if doc is ai:TextDocument|ai:TextChunk {
        string text = doc.content;
        if text != "" {
            parts.push({text});
        }
        return;
    }
    if doc is ai:ImageDocument {
        parts.push(check toImagePart(doc));
        return;
    }
    return error ai:Error("Only text and image documents are supported.");
}

isolated function toImagePart(ai:ImageDocument doc) returns ImagePart|ai:Error {
    ai:Url|byte[] content = doc.content;
    byte[] data;
    string? mimeType = normalizeMimeType(doc.metadata?.mimeType);
    if content is ai:Url {
        // Bedrock never fetches a URL itself, so the module does.
        [byte[], string?] [downloaded, contentType] = check downloadImage(content);
        data = downloaded;
        mimeType = mimeType ?: normalizeMimeType(contentType);
    } else {
        data = content;
    }
    // An explicit `metadata.mimeType` wins; sniffing is the fallback.
    string? resolved = mimeType ?: sniffImageMime(data);
    if resolved is () {
        return error ai:Error("Could not determine the image type. Set " +
            "'metadata.mimeType' to one of image/png, image/jpeg, image/gif, image/webp.");
    }
    if !MIME_TO_CONVERSE_FORMAT.hasKey(resolved) {
        return error ai:Error(string `Unsupported image type '${resolved}'. Bedrock ` +
            "accepts image/png, image/jpeg, image/gif and image/webp.");
    }
    return {mimeType: resolved, data};
}

isolated function flushText(string text, ContentPart[] parts) returns string {
    if text != "" {
        parts.push({text});
    }
    return "";
}

// ---------------------------------------------------------------------------
// MIME handling
// ---------------------------------------------------------------------------

// Lowercases, drops parameters, and maps `image/jpg` to `image/jpeg`.
isolated function normalizeMimeType(string? raw) returns string? {
    if raw is () {
        return ();
    }
    string value = raw.trim().toLowerAscii();
    int? semi = value.indexOf(";");
    if semi is int {
        value = value.substring(0, semi).trim();
    }
    if value == "" || value == "image/*" || value == "application/octet-stream" {
        // Too vague (e.g. `image/*`); sniff instead.
        return ();
    }
    return value == "image/jpg" ? "image/jpeg" : value;
}

// Identifies the four supported formats from their magic bytes.
isolated function sniffImageMime(byte[] data) returns string? {
    if startsWithBytes(data, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
        return "image/png";
    }
    if startsWithBytes(data, [0xFF, 0xD8, 0xFF]) {
        return "image/jpeg";
    }
    if startsWithBytes(data, [0x47, 0x49, 0x46, 0x38]) { // "GIF8"
        return "image/gif";
    }
    // WebP: "RIFF", a size, then "WEBP".
    if startsWithBytes(data, [0x52, 0x49, 0x46, 0x46]) && data.length() >= 12
        && data[8] == 0x57 && data[9] == 0x45 && data[10] == 0x42 && data[11] == 0x50 {
        return "image/webp";
    }
    return ();
}

isolated function startsWithBytes(byte[] data, int[] prefix) returns boolean {
    if data.length() < prefix.length() {
        return false;
    }
    foreach int i in 0 ..< prefix.length() {
        if <int>data[i] != prefix[i] {
            return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Download (the only I/O here)
// ---------------------------------------------------------------------------

// Fetches an image URL. Redirects are followed by hand so every hop is checked; this
// connector holds AWS credentials, so it must not be bounced to an internal address.
isolated function downloadImage(string url) returns [byte[], string?]|ai:Error {
    string target = url;
    int redirects = 0;
    while true {
        check validateDownloadTarget(target);
        [string, string] [origin, path] = check splitUrl(target);
        http:Client|error cl = new (origin, {followRedirects: {enabled: false}});
        if cl is error {
            return error ai:Error(string `Could not open a connection to '${origin}'`, cl);
        }
        http:Response|error resp = cl->get(path);
        if resp is error {
            return error ai:Error(string `Failed to download the image from '${target}'`, resp);
        }
        int status = resp.statusCode;
        if status >= 300 && status < 400 {
            if redirects >= MAX_IMAGE_REDIRECTS {
                return error ai:Error(string `Too many redirects (>${MAX_IMAGE_REDIRECTS}) ` +
                    string `while downloading '${url}'`);
            }
            string|error location = resp.getHeader("Location");
            if location is error {
                return error ai:Error(string `Redirect from '${target}' had no Location header`);
            }
            target = resolveRedirect(target, location);
            redirects += 1;
            continue;
        }
        if status < 200 || status >= 300 {
            return error ai:Error(string `Downloading '${target}' returned HTTP ${status}`);
        }
        byte[]|error payload = resp.getBinaryPayload();
        if payload is error {
            return error ai:Error(string `Could not read the image bytes from '${target}'`, payload);
        }
        if payload.length() > MAX_IMAGE_DOWNLOAD_BYTES {
            return error ai:Error(string `Image at '${target}' exceeds the ` +
                string `${MAX_IMAGE_DOWNLOAD_BYTES} byte download limit`);
        }
        string|error contentType = resp.getHeader("Content-Type");
        return [payload, contentType is string ? contentType : ()];
    }
}

// Only http and https may be fetched.
isolated function validateDownloadTarget(string url) returns ai:Error? {
    string lower = url.toLowerAscii();
    if lower.startsWith("https://") || lower.startsWith("http://") {
        return;
    }
    return error ai:Error(string `Only http(s) image URLs can be downloaded; got '${url}'. ` +
        "Pass the image as a byte array instead.");
}

// Splits an absolute URL into [origin, path-with-query].
isolated function splitUrl(string url) returns [string, string]|ai:Error {
    int? schemeEnd = url.indexOf("://");
    if schemeEnd is () {
        return error ai:Error(string `Malformed image URL '${url}'`);
    }
    int hostStart = schemeEnd + 3;
    string rest = url.substring(hostStart);
    int? slash = rest.indexOf("/");
    if slash is () {
        return [url, "/"];
    }
    return [url.substring(0, hostStart + slash), rest.substring(slash)];
}

// Resolves a Location header against the URL it came from (absolute or root-relative).
isolated function resolveRedirect(string base, string location) returns string {
    string target = location.trim();
    if target.toLowerAscii().startsWith("http://") || target.toLowerAscii().startsWith("https://") {
        return target;
    }
    [string, string]|ai:Error parts = splitUrl(base);
    if parts is ai:Error {
        return target;
    }
    string origin = parts[0];
    return target.startsWith("/") ? origin + target : origin + "/" + target;
}

// ---------------------------------------------------------------------------
// Per-API emitters (pure).
// ---------------------------------------------------------------------------

// Converse and Nova InvokeModel image blocks.
// https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_ImageBlock.html
isolated function converseContentBlocks(ContentPart[] parts) returns json[] {
    json[] blocks = [];
    foreach ContentPart part in parts {
        if part is TextPart {
            blocks.push({"text": part.text});
        } else {
            blocks.push({
                "image": {
                    // A bare token, not the MIME type.
                    "format": MIME_TO_CONVERSE_FORMAT.get(part.mimeType),
                    "source": {"bytes": array:toBase64(part.data)}
                }
            });
        }
    }
    return blocks;
}

// Anthropic Messages content blocks (InvokeModel and Messages).
// https://platform.claude.com/docs/en/api/messages
isolated function anthropicContentBlocks(ContentPart[] parts) returns json[] {
    json[] blocks = [];
    foreach ContentPart part in parts {
        if part is TextPart {
            blocks.push({"type": "text", "text": part.text});
        } else {
            blocks.push({
                "type": "image",
                "source": {
                    "type": "base64", // Bedrock does not accept the `url` source type.
                    "media_type": part.mimeType,
                    "data": array:toBase64(part.data)
                }
            });
        }
    }
    return blocks;
}

// OpenAI Chat Completions content, also used by Mistral chat. A plain string when
// there is no image, as text-only models expect.
isolated function openAIContentParts(ContentPart[] parts) returns json {
    if !hasImage(parts) {
        return partsText(parts);
    }
    json[] out = [];
    foreach ContentPart part in parts {
        if part is TextPart {
            out.push({"type": "text", "text": part.text});
        } else {
            out.push({"type": "image_url", "image_url": {"url": dataUri(part)}});
        }
    }
    return out;
}

// OpenAI Responses content; `image_url` is a string here, unlike Chat Completions.
isolated function responsesContentParts(ContentPart[] parts) returns json[] {
    json[] out = [];
    foreach ContentPart part in parts {
        if part is TextPart {
            out.push({"type": "input_text", "text": part.text});
        } else {
            out.push({"type": "input_image", "image_url": dataUri(part)});
        }
    }
    return out;
}

isolated function dataUri(ImagePart part) returns string
    => string `data:${part.mimeType};base64,${array:toBase64(part.data)}`;

isolated function hasImage(ContentPart[] parts) returns boolean {
    foreach ContentPart part in parts {
        if part is ImagePart {
            return true;
        }
    }
    return false;
}

// The OpenAI-shaped Mantle and InvokeModel APIs and Mistral chat: no AWS page confirms
// image input there. Set in Config.toml:
//     [ballerinax.ai.aws.bedrock]
//     enableUnverifiedImageRoutes = true

# Sends images on APIs where AWS does not document image support. Experimental.
public configurable boolean enableUnverifiedImageRoutes = false;

// Refuses an image on an API that cannot carry one, or whose image support is
// unverified (`unverifiedOnly`, which `enableUnverifiedImageRoutes` lifts), before the
// body is built.
isolated function rejectImagesIn(ResolvedMessage[] messages, string dialect,
        boolean unverifiedOnly = false) returns ai:Error? {
    if unverifiedOnly && enableUnverifiedImageRoutes {
        return;
    }
    foreach ResolvedMessage m in messages {
        if m is ResolvedUserMessage && hasImage(m.parts) {
            return error ai:Error(string `Image input is not supported on ${dialect}. ` +
                "Use 'apiType = CONVERSE', or an Anthropic model — both accept images.");
        }
    }
}

// The text of parts already checked by `rejectImagesIn`.
isolated function partsText(ContentPart[] parts) returns string {
    string text = "";
    foreach ContentPart part in parts {
        if part is TextPart {
            text += part.text;
        }
    }
    return text;
}

// Parts for a span, with images reduced to a placeholder.
isolated function partsForSpan(ContentPart[] parts) returns string {
    string text = "";
    foreach ContentPart part in parts {
        if part is TextPart {
            text += part.text;
        } else {
            text += string `[image ${part.mimeType}, ${part.data.length()} bytes]`;
        }
    }
    return text;
}
