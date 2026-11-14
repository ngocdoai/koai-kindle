-- Synthetic chat-image fixtures; no live URLs are fetched.
package.path = package.path .. ";./?.lua;./?/init.lua"

local Markup = require("koassistant.ui.chat_markup")
local T = { passed = 0, failed = 0 }

function T:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
    else
        self.failed = self.failed + 1
        print("  ✗ " .. name .. ": " .. tostring(err))
    end
end

T:test("image URL becomes an explicit safe link, not an inline fetch", function()
    local masked, restore = Markup.protectImages("Before ![sơ đồ](https://example.invalid/a_(b).png) after")
    assert(not masked:find("example.invalid", 1, true))
    local html = restore(masked)
    assert(html:find('<a href="https://example.invalid/a_(b).png">', 1, true))
    assert(html:find("sơ đồ", 1, true))
    assert(not html:find("<img", 1, true))
end)

T:test("attributes and captions are escaped", function()
    local masked, restore = Markup.protectImages('![<script>](https://example.invalid/a?x=1&y=2)')
    local html = restore(masked)
    assert(html:find("&lt;script&gt;", 1, true))
    assert(html:find("x=1&amp;y=2", 1, true))
end)

T:test("titled Markdown image retains a safe explicit link", function()
    local masked, restore = Markup.protectImages('![chart](https://example.invalid/chart.png "Chart")')
    local html = restore(masked)
    assert(html:find('href="https://example.invalid/chart.png"', 1, true))
    assert(html:find("Image: chart", 1, true))
end)

T:test("four-space indented code is not rewritten as image HTML", function()
    local source = "    ![example](https://example.invalid/code.png)\n![real](https://example.invalid/real.png)"
    local masked, restore = Markup.protectImages(source)
    local html = restore(masked)
    assert(html:find("    ![example](https://example.invalid/code.png)", 1, true))
    assert(html:find("Image: real", 1, true))
end)

T:test("unsafe image URL is not loaded or linked", function()
    local masked, restore = Markup.protectImages("![x](javascript:alert(1))")
    local html = restore(masked)
    assert(not html:find("href=", 1, true))
    assert(not html:find("<img", 1, true))
end)

T:test("code fences and inline code remain literal", function()
    local source = "`![inline](https://example.invalid/i.png)`\n```md\n![fenced](https://example.invalid/f.png)\n```\n![real](https://example.invalid/r.png)"
    local masked, restore = Markup.protectImages(source)
    local html = restore(masked)
    assert(html:find("`![inline](https://example.invalid/i.png)`", 1, true))
    assert(html:find("![fenced](https://example.invalid/f.png)", 1, true))
    assert(html:find("Image: real", 1, true))
end)

T:test("closed Mermaid block gets a view action while retaining its source", function()
    local source = "Before\n```mermaid\nflowchart TB\nA[Đọc] --> B[Xong]\n```\nAfter"
    local captured = {}
    local result = Markup.linkMermaidBlocks(source, function(block)
        captured[#captured + 1] = block
        return #captured
    end, "View diagram")
    assert(#captured == 1 and captured[1]:find("A[Đọc] --> B[Xong]", 1, true))
    assert(result:find("koassistant-mermaid://1", 1, true))
    assert(result:find("```mermaid\nflowchart TB", 1, true))
    assert(result:find("After", 1, true))
end)

T:test("incomplete and oversized Mermaid blocks retain source", function()
    local source = "```mermaid\nflowchart TB\nA-->B"
    assert(Markup.linkMermaidBlocks(source, function() error("not closed") end, "View") == source)
    local complete = source .. "\n```"
    assert(Markup.linkMermaidBlocks(complete, function() return nil end, "View") == complete)
end)

print(string.format("\n  Results: %d passed, %d failed", T.passed, T.failed))
if arg and arg[0] and arg[0]:match("test_chat_markup%.lua$") then
    os.exit(T.failed == 0 and 0 or 1)
end
return T.failed == 0
