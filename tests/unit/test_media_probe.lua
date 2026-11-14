-- Synthetic/redacted Codex SSE fixtures. No live prompts, tokens, URLs, or image bytes.
local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
package.path = root .. "/?.lua;" .. package.path

local Probe = require("koassistant_media_probe")
local fixture = {
    { type = "response.output_item.added", item = { type = "image_generation_call" } },
    { type = "response.image_generation_call.partial_image", partial_image_b64 = "SYNTHETIC_BASE64_NEVER_STORE", mime_type = "image/png" },
    { type = "response.output_item.done", item = { type = "message", content = {
        { type = "output_text", text = "SYNTHETIC_PRIVATE_ANSWER_NEVER_STORE" },
        { type = "output_image", image = "SYNTHETIC_IMAGE_NEVER_STORE", mime_type = "image/png" },
    } } },
    { type = "response.completed", response = { output = {
        { type = "image_generation_call", result = "SYNTHETIC_RESULT_NEVER_STORE",
            authorization = "SYNTHETIC_TOKEN_NEVER_STORE", image_url = "SYNTHETIC_URL_NEVER_STORE" },
    } } },
}

local function contains(haystack, needle)
    assert(haystack:find(needle, 1, true), "missing " .. needle)
end
local function excludes(haystack, needle)
    assert(not haystack:find(needle, 1, true), "leaked forbidden content: " .. needle)
end

local arm_path = os.tmpname()
local report_path = os.tmpname()
os.remove(arm_path)
os.remove(report_path)
local paths = { arm = arm_path, report = report_path }

-- Must not read or consume the trigger for other providers or without a real stream.
local arm = assert(io.open(arm_path, "wb")); arm:write("RUN\n"); arm:close()
assert(Probe.start("openai", { provider_name = "openai" }, paths) == nil)
assert(Probe.start("openai_codex", { provider_name = "openai" }, paths) == nil)
assert(Probe.start("openai_codex", { provider_name = "openai_codex", debug = true }, paths) == nil)
assert(io.open(arm_path, "rb"), "other provider or debug mode must leave trigger untouched"):close()

local session = assert(Probe.start("openai_codex", { provider_name = "openai_codex" }, paths))
assert(io.open(arm_path, "rb") == nil, "trigger must be consumed before request")
assert(Probe.start("openai_codex", { provider_name = "openai_codex" }, paths) == nil,
    "only one stream per trigger")
for _, event in ipairs(fixture) do Probe.observe(session, event) end
for i = 1, 100 do
    Probe.observe(session, { type = "response.image_generation_call.partial_image",
        partial_image_b64 = string.rep("x", i) })
end
Probe.observe(session, { type = "response.output_text.delta", delta = "SYNTHETIC_PRIVATE_ANSWER_NEVER_STORE" })
Probe.observe(session, { type = "response.unsafe/SYNTHETIC_URL_NEVER_STORE", item = { type = "private value" } })
Probe.finish(session, "completed")
Probe.finish(session, "failed") -- idempotent: no second write
local report = assert(io.open(report_path, "rb"))
local text = report:read("*a"); report:close()
contains(text, "response.output_item.added")
contains(text, "image_generation_call")
contains(text, "output_image")
contains(text, "image/png")
contains(text, "payload_bytes=")
contains(text, "completed")
for _, forbidden in ipairs({ "SYNTHETIC_BASE64_NEVER_STORE", "SYNTHETIC_PRIVATE_ANSWER_NEVER_STORE",
    "SYNTHETIC_IMAGE_NEVER_STORE", "SYNTHETIC_RESULT_NEVER_STORE", "SYNTHETIC_URL_NEVER_STORE",
    "SYNTHETIC_TOKEN_NEVER_STORE" }) do
    excludes(text, forbidden)
end
assert(#text < 8192, "report must be bounded")
os.remove(report_path)

-- Even crafted values in type/MIME cannot be written verbatim.
local bad = assert(io.open(arm_path, "wb")); bad:write("RUN\n"); bad:close()
local second = assert(Probe.start("openai_codex", { provider_name = "openai_codex" }, paths))
Probe.observe(second, { type = "response.output_item.added\nBearer SYNTHETIC_SECRET_NEVER_STORE",
    item = { type = "output_image\nSYNTHETIC_SECRET_NEVER_STORE", mime_type = "image/png\nSYNTHETIC_SECRET_NEVER_STORE",
        result = string.rep("x", 11000000) } })
Probe.finish(second, "failed")
local fh = assert(io.open(report_path, "rb")); text = fh:read("*a"); fh:close()
excludes(text, "SYNTHETIC_SECRET_NEVER_STORE")
assert(#text < 8192)
os.remove(report_path)

local third_arm = assert(io.open(arm_path, "wb")); third_arm:write("RUN\n"); third_arm:close()
local third = assert(Probe.start("openai_codex", { provider_name = "openai_codex" }, paths))
for i = 1, 100 do
    Probe.observe(third, { type = "response.synthetic_" .. i })
end
Probe.finish(third, "cancelled")
local bounded = assert(io.open(report_path, "rb")); text = bounded:read("*a"); bounded:close()
contains(text, "additional_event_shapes=omitted")
assert(#text < 8192)
os.remove(report_path)
local fourth_arm = assert(io.open(arm_path, "wb")); fourth_arm:write("RUN\n"); fourth_arm:close()
local fourth = assert(Probe.start("openai_codex", { provider_name = "openai_codex" }, paths))
for i = 1, 100 do Probe.observe(fourth, { type = "response.synthetic_" .. i }) end
Probe.observe(fourth, { type = "response.output_item.done",
    item = { type = "image_generation_call", result = "SYNTHETIC_BYTES_NEVER_STORE" } })
Probe.finish(fourth, "completed")
local last = assert(io.open(report_path, "rb")); text = last:read("*a"); last:close()
contains(text, "image_generation_call")
excludes(text, "SYNTHETIC_BYTES_NEVER_STORE")
os.remove(report_path)
local invalid = assert(io.open(arm_path, "wb")); invalid:write("RUN\nextra"); invalid:close()
assert(Probe.start("openai_codex", { provider_name = "openai_codex" }, paths) == nil,
    "invalid marker must not arm")
assert(io.open(arm_path, "rb"), "invalid marker must not be removed"):close()
os.remove(arm_path)
local source_file = assert(io.open("stream_handler.lua", "rb"))
local handler = source_file:read("*a"); source_file:close()
assert(not handler:find('logger.warn("Failed to parse NDJSON line:", line)', 1, true),
    "armed probe must not log malformed raw NDJSON")
assert(not handler:find('logger.warn("Unrecognized line format:", line)', 1, true),
    "armed probe must not log raw unrecognized lines")
assert(not handler:find('logger.dbg("Unrecognized line format:", line)', 1, true),
    "armed probe must not debug-log raw unrecognized lines")
print("media probe synthetic tests passed")
return true
