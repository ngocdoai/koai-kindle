package.path = "./?.lua;./tests/lib/?.lua;" .. package.path
require("mock_koreader")
local T = require("test_runner"):new()
local Markup = require("koassistant_chat_markup")
local Images = require("koassistant_codex_images")
local saved_generator = package.loaded.koassistant_image_generator
local saved_lfs = package.loaded["libs/libkoreader-lfs"]
local attr = { mode="file", size=1024 }
package.loaded.koassistant_image_generator = { getImagesDir=function() return "/safe/images" end }
package.loaded["libs/libkoreader-lfs"] = { symlinkattributes=function(path)
    assert(path == "/safe/images/codex-20261004-120000.png")
    return attr
end }
local name = "codex-20261004-120000.png"
local uri = "koassistant-image://" .. name
local function render(text)
    local state = {}
    local masked, restore = Markup.protectImages(text, function(value) return Images.inlineHTML(value, state) end)
    return restore(Markup.stripRawImages(masked)), masked
end

T:test("existing saved chat links become inline image HTML without altering saved text", function()
    local source = "Before\n[Open generated image](" .. uri .. ")\nAfter"
    local html, masked = render(source)
    T:assertTrue(html:find('<img src="' .. name .. '"', 1, true) ~= nil)
    T:assertTrue(html:find('href="koassistant-image:/' .. name .. '"', 1, true) ~= nil)
    T:assertTrue(html:find("Before", 1, true) ~= nil and html:find("After", 1, true) ~= nil)
    T:assertTrue(masked:find(uri, 1, true) == nil, "URL does not pass through Markdown/linkifier")
    T:assertTrue(source:find("[Open generated image]", 1, true) ~= nil)
end)
T:test("Markdown images and bare local links also render", function()
    T:assertTrue(render("![image](" .. uri .. ")"):find("<img", 1, true) ~= nil)
    T:assertTrue(render("koassistant-image:/" .. name):find("<img", 1, true) ~= nil)
    T:assertTrue(render("Image: " .. uri):find("<img", 1, true) ~= nil)
end)
T:test("single and double slash link taps resolve to the same safe image", function()
    T:assertEqual(Images.nameFromURI(uri), name)
    T:assertEqual(Images.nameFromURI("koassistant-image:/" .. name), name)
    T:assertEqual(Images.nameFromURI("koassistant-image:/../../settings.lua"), nil)
    T:assertEqual(Images.nameFromURI("koassistant-image:/%2e%2e/settings.lua"), nil)
    T:assertEqual(Images.nameFromURI("file:///safe/images/" .. name), nil)
    T:assertEqual(Images.nameFromURI(uri .. "?other=1"), nil)
end)
T:test("code samples remain literal and remote images are still explicit links", function()
    local text = "`[example](" .. uri .. ")`\n```md\n![example](" .. uri .. ")\n```"
    T:assertEqual(render(text), text)
    local html = render("![remote](https://example.invalid/image.png)")
    T:assertTrue(html:find("<img", 1, true) == nil)
    T:assertTrue(html:find('href="https://example.invalid/image.png"', 1, true) ~= nil)
end)
T:test("raw img tags cannot load arbitrary files from the resource directory", function()
    local html = render('<img src="../../settings.lua"><IMG src="https://example.invalid/a.png"/>\n[image](' .. uri .. ')')
    T:assertTrue(html:find("settings.lua", 1, true) == nil)
    T:assertTrue(html:find("example.invalid", 1, true) == nil)
    T:assertTrue(html:find('<img src="' .. name, 1, true) ~= nil)
end)
T:test("deleted files and symlinks get a readable fallback without loading", function()
    attr = nil
    T:assertTrue(render("[image](" .. uri .. ")"):find("unavailable", 1, true) ~= nil)
    attr = {mode="link",size=1024}
    T:assertTrue(render("[image](" .. uri .. ")"):find("<img", 1, true) == nil)
    attr = {mode="file",size=1024}
end)
T:test("large files retain a full-view link while preview budget is bounded", function()
    attr = {mode="file",size=13*1024*1024}
    local html = render("[image](" .. uri .. ")")
    T:assertTrue(html:find("<img", 1, true) == nil)
    T:assertTrue(html:find("Open generated image", 1, true) ~= nil)
    attr = {mode="file",size=1024}
    T:assertTrue(Images.inlineHTML(uri, {bytes=32*1024*1024}):find("<img", 1, true) == nil)
end)
package.loaded.koassistant_image_generator = saved_generator
package.loaded["libs/libkoreader-lfs"] = saved_lfs
return T:summary()
