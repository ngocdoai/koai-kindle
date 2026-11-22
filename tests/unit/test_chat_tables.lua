package.path = "./?.lua;./tests/lib/?.lua;" .. package.path
local T = require("test_runner"):new()
local Tables = require("koassistant.ui.chat_tables")

local function render(text, available_em)
    local masked, restore = Tables.protect(text, function(cell) return cell end, available_em)
    local html = masked:gsub("(KOATABLEPLACEHOLDERX*%d+X)", "<p>%1</p>")
    return restore(html), masked
end

T:test("empty cells keep their positions and short rows keep their column count", function()
    local html = render("| A | B | C |\n| --- | :---: | ---: |\n| One || Three |\n| Only |", 32)
    T:assertTrue(html:find('<td style="text-align:left">One</td><td style="text-align:center"></td><td style="text-align:right">Three</td>', 1, true) ~= nil)
    T:assertTrue(html:find('<td style="text-align:left">Only</td><td style="text-align:center"></td><td style="text-align:right"></td>', 1, true) ~= nil)
end)

T:test("escaped pipes and code spans stay in their own cells", function()
    local html = render("| A | B |\n| --- | --- |\n| a\\|b | `c|d` |", 32)
    T:assertTrue(html:find('<td style="text-align:left">a|b</td><td style="text-align:left">`c|d`</td>', 1, true) ~= nil)
end)

T:test("layout adapts to viewport width and long tokens", function()
    local text = "| A | B | C | D |\n| --- | --- | --- | --- |\n| 1 | 2 | 3 | 4 |"
    T:assertTrue(render(text, 32):find("<table", 1, true) ~= nil)
    local narrow = render(text, 20)
    T:assertTrue(narrow:find('<div class="koa-table-row">', 1, true) ~= nil)
    T:assertTrue(narrow:find("<strong>D:</strong> 4", 1, true) ~= nil)
    local long = "| A | B |\n| --- | --- |\n| x | " .. string.rep("W", 40) .. " |"
    T:assertTrue(render(long, 32):find('<div class="koa-table-row">', 1, true) ~= nil)
end)

T:test("fenced samples and invalid dividers remain ordinary Markdown", function()
    local text = "```md\n| A | B |\n| --- | --- |\n```\n~~~\n| A | B |\n| --- | --- |\n~~~\n\nA | B\n--- | :"
    local html, masked = render(text, 32)
    T:assertEqual(masked, text)
    T:assertEqual(html, text)
end)

T:test("header-only tables and the paragraph after a table stay visible", function()
    local html = render("| A | B |\n| --- | --- |\n\nAfter the table.", 10)
    T:assertTrue(html:find('<p class="koa-table-cell">A</p><p class="koa-table-cell">B</p>', 1, true) ~= nil)
    T:assertTrue(html:find("After the table.", 1, true) ~= nil)
end)

return T:summary()
