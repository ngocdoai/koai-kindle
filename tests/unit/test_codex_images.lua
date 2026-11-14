package.path = package.path .. ";./?.lua;./tests/lib/?.lua"
require("mock_koreader")
local T = require("test_runner"):new()
local Images = require("koassistant.images.codex_images")
local Handler = require("koassistant.api.openai_codex")
local Parser = require("koassistant.api.response_parser")
local json = require("json")
local original_mime = package.loaded.mime
package.loaded.mime = { unb64 = function(value)
    if value == "iVBORw0KGgo=" then return "\137PNG\r\n\26\n" end
    return "not an image"
end }
local function item(id)
    return { type = "image_generation_call", id = id, status = "completed", result = "iVBORw0KGgo=" }
end
local function config(features)
    return { model = "gpt-6.1-sol", api_key = "synthetic-access-token",
        oauth = { chatgpt_account_id = "synthetic-account" }, features = features or {} }
end

T:test("Codex chat declares hosted image tool with OAuth and no forced image", function()
    local request = Handler:buildRequestBody({{ role = "user", content = "draw a tree" }}, config())
    T:assertEqual(request.body.tools[1].type, "image_generation")
    T:assertEqual(request.body.tools[1].model, nil)
    T:assertEqual(request.body.tool_choice, nil)
    T:assertEqual(request.body.max_output_tokens, nil)
    T:assertEqual(request.headers.Authorization, "Bearer synthetic-access-token")
    T:assertEqual(request.headers["ChatGPT-Account-ID"], "synthetic-account")
end)
T:test("opt-out removes image tool and book-tool rounds keep their contract", function()
    T:assertEqual(Handler:buildRequestBody({}, config({codex_chat_images = false})).body.tools, nil)
    local c = config()
    c.tools = { specs = {}, mode = "NONE" }
    local body = Handler:buildRequestBody({}, c).body
    T:assertEqual(#body.tools, 0)
    T:assertEqual(body.tool_choice, "none")
end)
T:test("image tab forces image generation while retaining the chosen chat model", function()
    local request = Images.request("a small tree", "gpt-6.1-sol", {})
    T:assertEqual(request.model, "gpt-6.1-sol")
    T:assertEqual(request.tool_choice.type, "image_generation")
    T:assertEqual(request.input[1].content, "a small tree")
    T:assertEqual(request.stream, true)
    T:assertEqual(request.store, false)
    T:assertEqual(Images.tool({image_gen_model_openai_codex = "auto"}).model, nil)
    T:assertEqual(Images.tool({image_gen_model_openai_codex = "gpt-image-2.5-flare"}).model, "gpt-image-2.5-flare")
end)
T:test("completed SSE image is saved once and only a local link reaches chat", function()
    local state, saves = {}, 0
    local function save(value)
        T:assertEqual(value.result, "iVBORw0KGgo=")
        saves = saves + 1
        return "codex-20261004-120000.png"
    end
    T:assertEqual(Images.event(state, {type="response.image_generation_call.partial_image", partial_image_b64="ignored"}, save), nil)
    local text = Images.event(state, {type="response.output_item.done", output_index=0, item=item("image_1")}, save)
    T:assertTrue(text:find("koassistant-image://", 1, true) ~= nil)
    T:assertTrue(text:find("iVBOR", 1, true) == nil)
    T:assertEqual(Images.event(state, {type="response.completed", response={output={item("image_1")}}}, save), nil)
    T:assertEqual(saves, 1)
    local terminal = Images.event(state, {type="response.completed", response={output={item("image_2")}}}, save)
    T:assertTrue(terminal ~= nil)
    T:assertEqual(saves, 2)
end)
T:test("failed, malformed and oversized images are rejected before writing", function()
    local invalid = item("bad")
    invalid.status = "failed"
    T:assertEqual(Images.decode(invalid), nil)
    invalid.status, invalid.result = "completed", "not base64!"
    T:assertEqual(Images.decode(invalid), nil)
    invalid.result = "AAAA"
    T:assertEqual(Images.decode(invalid), nil)
    local limit = Images.MAX_BASE64_BYTES
    Images.MAX_BASE64_BYTES = 4
    T:assertEqual(Images.decode(item("large")), nil)
    Images.MAX_BASE64_BYTES = limit
    local bytes, ext = Images.decode(item("ok"))
    T:assertEqual(bytes, "\137PNG\r\n\26\n")
    T:assertEqual(ext, "png")
end)
T:test("non-streaming image-only Responses SSE becomes a successful chat reply", function()
    local raw = "data: " .. json.encode({type="response.output_item.done", output_index=0, item=item("image_1")})
        .. "\n\ndata: " .. json.encode({type="response.completed", response={status="completed", output={item("image_1")}}}) .. "\n\n"
    local response = json.decode(Parser.collectResponsesSSE(raw))
    local save = Images.save
    Images.save = function() return "codex-20261004-120000.png" end
    Images.prepareResponse(response)
    Images.save = save
    local success, text = Parser:parseResponse(response, "openai_responses")
    T:assertTrue(success)
    T:assertTrue(text:find("koassistant-image://", 1, true) ~= nil)
    T:assertTrue(json.encode(response):find("iVBOR", 1, true) == nil)
end)
T:test("image provider follows Codex sign-in without an API key", function()
    local generator = require("koassistant.images.image_generator")
    local oauth = require("koassistant.api.openai_codex_oauth")
    local read = oauth.readAuth
    oauth.readAuth = function() return {refresh_token="synthetic-refresh", chatgpt_account_id="synthetic-account"} end
    local provider = generator.effectiveProvider({}, "openai_codex", {})
    T:assertEqual(provider, "openai_codex")
    T:assertEqual(generator.effectiveProvider({image_gen_provider="openai_codex"}, "anthropic", {}), "openai_codex")
    local no_key_settings = {readSetting=function(_, key)
        assert(key == "features", "must not read API keys")
        return {}
    end}
    for _, pick in ipairs({"auto", "openai", "xai", "gemini", "openai_codex"}) do
        T:assertEqual(generator.effectiveProvider({image_gen_provider=pick}, "openai", no_key_settings), "openai_codex")
    end
    oauth.readAuth = function() return nil end
    local missing, reason = generator.effectiveProvider({}, "openai_codex", {})
    T:assertEqual(missing, nil)
    T:assertEqual(reason, "no_oauth")
    local fallback, why = generator.effectiveProvider({image_gen_provider="openai"}, "openai", no_key_settings)
    T:assertEqual(fallback, nil)
    T:assertEqual(why, "no_oauth")
    oauth.readAuth = read
end)
T:test("image tab requests the hosted tool on the Codex backend and reads its picture", function()
    local generator = require("koassistant.images.image_generator")
    local request = generator.buildRequest("openai_codex", "gpt-5.6-terra", "draw a tree",
        {image_gen_model_openai_codex = "gpt-image-2.5-flare"})
    T:assertEqual(request.url, "https://chatgpt.com/backend-api/codex/responses")
    T:assertEqual(request.key_header, "Authorization")
    T:assertEqual(request.headers.Accept, "text/event-stream")
    T:assertEqual(request.body.model, "gpt-5.6-terra")
    T:assertEqual(request.body.tool_choice.type, "image_generation")
    T:assertEqual(request.body.tools[1].model, "gpt-image-2.5-flare")
    local picture = generator.parseResponse("openai_codex", json.encode({output = {item("ig_1")}}))
    T:assertEqual(picture.bytes, "\137PNG\r\n\26\n")
    local none, why = generator.parseResponse("openai_codex", json.encode({output = {}}))
    T:assertEqual(none, nil)
    T:assertTrue(why:find("no API-key fallback", 1, true) ~= nil)
end)
T:test("image links cannot traverse outside generated image storage", function()
    T:assertEqual(Images.path("../../settings.lua"), nil)
    T:assertEqual(Images.path("codex-20261004-120000.png/../../settings.lua"), nil)
    T:assertEqual(Images.path("codex-20261004-120000.lua"), nil)
    T:assertTrue(Images.path("codex-20261004-120000-2.png") ~= nil)
end)
package.loaded.mime = original_mime
return T:summary()
