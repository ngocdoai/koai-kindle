-- Synthetic offline flowchart fixtures; no KOReader modules are needed for parsing.
local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
package.path = root .. "/?.lua;" .. package.path

local Mermaid = require("koassistant.ui.mermaid")
local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  PASS " .. name)
    else
        failed = failed + 1
        print("  FAIL " .. name .. ": " .. tostring(err))
    end
end
local function contains(s, part)
    assert(s and s:find(part, 1, true), "missing " .. part)
end
local function rejects(s)
    local graph, err = Mermaid.parse(s)
    assert(graph == nil and type(err) == "string" and #err > 0, "expected parse error")
    assert(Mermaid.toSVG(s) == nil, "invalid input must not render")
end

-- Redacted/synthetic fixture: labels are invented, not sourced from a conversation.
local fixture = "flowchart TB\nalpha[Draft & review] --> beta[Publish]\nbeta --> gamma[Done]"
test("parses synthetic TB graph, ordered nodes and edges", function()
    local g, err = Mermaid.parse(fixture)
    assert(g, err)
    assert(g.direction == "TB" and #g.nodes == 3 and #g.edges == 2)
    assert(g.nodes[1].id == "alpha" and g.nodes[1].label == "Draft & review")
    assert(g.edges[2].from == "beta" and g.edges[2].to == "gamma")
end)
test("renders viewable standalone SVG with literal escaped labels and arrows", function()
    local svg, err = Mermaid.toSVG(fixture)
    assert(svg, err)
    contains(svg, '<svg xmlns="http://www.w3.org/2000/svg"')
    contains(svg, "Draft &amp; review")
    contains(svg, "<text")
    contains(svg, "<path")
    assert(not svg:find("<script", 1, true))
    assert(not svg:find("https://", 1, true))
end)
test("accepts graph LR and labels on either side of repeated edges", function()
    local g = assert(Mermaid.parse("graph LR\nA --> B[Second]\nA[First] --> C\nB --> C"))
    assert(g.direction == "LR" and #g.nodes == 3 and #g.edges == 3)
    assert(g.nodes[1].label == "First" and g.nodes[2].label == "Second")
    assert(Mermaid.toSVG(g))
end)
test("common TD direction maps to top-to-bottom layout", function()
    local g = assert(Mermaid.parse("flowchart TD\nA[Đầu] --> B[Cuối]"))
    assert(g.direction == "TB")
    assert(Mermaid.toSVG(g))
end)
test("standalone nodes, CRLF, comments and Unicode labels", function()
    local g = assert(Mermaid.parse("flowchart TB\r\n%% explanation\r\nA[Écrire]\r\nB\r\nA --> B\r\n"))
    assert(#g.nodes == 2 and g.nodes[1].label == "Écrire")
end)
test("SVG escapes XML metacharacters, never interpolates label markup", function()
    local svg = assert(Mermaid.toSVG("flowchart TB\n" .. [=[A[<script>alert('x') & "test"</script>] --> B[<&>]]=]))
    contains(svg, "&lt;script&gt;")
    contains(svg, "&amp;")
    contains(svg, "&quot;")
    contains(svg, "&apos;")
    assert(not svg:find("<script", 1, true))
    assert(not svg:find("<image", 1, true))
end)
test("render and layout are deterministic across calls", function()
    local a = assert(Mermaid.toSVG(fixture))
    assert(a == assert(Mermaid.toSVG(fixture)))
end)
test("rejects unsupported Mermaid directives, arrows and trailing tokens", function()
    rejects("sequenceDiagram\nA->B")
    rejects("flowchart TB\nA --- B")
    rejects("flowchart TB\nA --> B; click A https://example.com")
    rejects("flowchart TB\nclassDef dangerous fill:red")
    rejects("flowchart TB\nsubgraph child\nA --> B\nend")
    rejects("flowchart TB\nA --> B %% inline comment")
end)
test("rejects missing nodes, empty labels, conflicting labels and self edges", function()
    rejects("flowchart TB")
    rejects("flowchart LR\nA[]")
    rejects("flowchart LR\nA[one]\nA[two]")
    rejects("flowchart LR\nA --> A")
    rejects("flowchart LR\nA -->")
end)
test("rejects unbounded input, identifiers, graph size and malformed UTF-8", function()
    rejects("flowchart TB\nA[" .. string.rep("x", 9000) .. "]")
    rejects("flowchart TB\n" .. string.rep("a", 65))
    local lines = { "flowchart TB" }
    for i = 1, 41 do lines[#lines + 1] = "n" .. i end
    rejects(table.concat(lines, "\n"))
    rejects("flowchart TB\nA[" .. string.char(0xC0, 0xAF) .. "]")
    rejects("flowchart TB\nA[bad" .. string.char(0) .. "byte]")
end)
test("caps edges and image dimensions without partial SVG", function()
    local edges = { "flowchart LR" }
    for i = 1, 81 do edges[#edges + 1] = "A --> B" end
    rejects(table.concat(edges, "\n"))
    local wide = { "flowchart TB" }
    for i = 1, 20 do wide[#wide + 1] = "n" .. i end
    local graph = assert(Mermaid.parse(table.concat(wide, "\n")))
    local svg, err = Mermaid.toSVG(graph)
    assert(svg == nil and type(err) == "string")
end)
test("cycles render deterministically with bounded layout", function()
    local graph = "graph LR\nA --> B\nB --> A"
    assert(Mermaid.toSVG(graph) == Mermaid.toSVG(graph))
end)
test("rejects forged graph tables rather than using unchecked dimensions/labels", function()
    local svg, err = Mermaid.toSVG({ direction = "TB", nodes = { { id = "x", label = "<script>" } }, edges = {} })
    assert(svg == nil and err, "toSVG should only accept source or parsed graph")
end)
test("no KOReader dependencies loaded for parse and toSVG", function()
    assert(package.loaded["ui/renderimage"] == nil)
    assert(package.loaded["ui/widget/imageviewer"] == nil)
end)
test("show renders SVG bytes in memory and opens disposable ImageViewer", function()
    local sentinel = {}
    local captured
    package.loaded["ui/renderimage"] = { renderImageData = function(_, data, size, frames, width, height)
        assert(data:find("<svg", 1, true))
        assert(size == #data and frames == false and width > 0 and height > 0)
        return sentinel
    end }
    package.loaded["ui/widget/imageviewer"] = { new = function(_, opts)
        captured = opts
        return opts
    end }
    package.loaded["ui/uimanager"] = { show = function(_, viewer) assert(viewer == captured) end }
    package.loaded["device"] = { screen = { getWidth = function() return 800 end, getHeight = function() return 1000 end } }
    local ok, err = Mermaid.show(fixture, "Synthetic flowchart")
    assert(ok, err)
    assert(captured.image == sentinel and captured.image_disposable == true)
    assert(captured.with_title_bar == true and captured.title_text == "Synthetic flowchart")
    assert(captured.file == nil)
end)
test("show fails cleanly for unsupported source without invoking renderer", function()
    local ok, err = Mermaid.show("sequenceDiagram\nA->B")
    assert(ok == nil and err)
end)

print(string.format("Mermaid: %d passed, %d failed", passed, failed))
return failed == 0
