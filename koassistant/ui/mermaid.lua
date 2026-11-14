-- Small, offline Mermaid subset: flowchart/graph TB or LR, ASCII node IDs,
-- optional [labels], and --> edges (including chains). No Mermaid directives,
-- HTML labels, links, styles, scripts, or external resources are interpreted.
-- parse/toSVG are pure Lua; KOReader modules are required only by show().
local Mermaid = {}
local MAX_SOURCE, MAX_NODES, MAX_EDGES = 8192, 40, 80
local MAX_ID, MAX_LABEL, MAX_DIMENSION = 64, 120, 4096
local parsed_sources = setmetatable({}, { __mode = "k" })

local function validXMLText(s)
    local i = 1
    while i <= #s do
        local a = s:byte(i)
        local code, length
        if a < 0x80 then
            code, length = a, 1
        elseif a >= 0xC2 and a <= 0xDF then
            code, length = a - 0xC0, 2
        elseif a >= 0xE0 and a <= 0xEF then
            code, length = a - 0xE0, 3
        elseif a >= 0xF0 and a <= 0xF4 then
            code, length = a - 0xF0, 4
        else
            return false
        end
        if i + length - 1 > #s then return false end
        for j = 1, length - 1 do
            local b = s:byte(i + j)
            if b < 0x80 or b > 0xBF then return false end
            code = code * 64 + b - 0x80
        end
        if (length == 2 and code < 0x80)
            or (length == 3 and code < 0x800)
            or (length == 4 and code < 0x10000)
            or (code < 0x20 and code ~= 9 and code ~= 10 and code ~= 13)
            or (code >= 0xD800 and code <= 0xDFFF)
            or code > 0x10FFFF or code == 0xFFFE or code == 0xFFFF then
            return false
        end
        i = i + length
    end
    return true
end

local function escapeXML(s)
    return (s:gsub('[&<>"\']', {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
        ['"'] = "&quot;", ["'"] = "&apos;",
    }))
end

--- Return {direction, nodes={{id,label},...}, edges={{from,to},...}} or nil, error.
--- Only a whole, explicitly supported statement is accepted; there is no
--- "best effort" interpretation of directives or truncated input.
function Mermaid.parse(source)
    if type(source) ~= "string" or #source > MAX_SOURCE then
        return nil, "Flowchart source is missing or too large"
    end
    if not validXMLText(source) then
        return nil, "Flowchart contains invalid XML/UTF-8 characters"
    end
    local text = source:gsub("\r\n", "\n")
    if text:find("\r", 1, true) then return nil, "Unsupported line ending" end
    local nodes, edges, by_id, direction = {}, {}, {}, nil
    local line_number = 0

    local function addNode(id, label)
        local node = by_id[id]
        if not node then
            if #nodes >= MAX_NODES then return nil, "Too many flowchart nodes" end
            node = { id = id, label = label or id }
            by_id[id] = node
            nodes[#nodes + 1] = node
        elseif label then
            if node.label ~= id and node.label ~= label then
                return nil, "Conflicting node labels"
            end
            node.label = label
        end
        return node
    end

    for line in (text .. "\n"):gmatch("(.-)\n") do
        line_number = line_number + 1
        if not line:match("^%s*$") and not line:match("^%s*%%%%") then
            if not direction then
                local keyword, orientation = line:match("^%s*(%a+)%s+(%u%u)%s*$")
                if (keyword ~= "flowchart" and keyword ~= "graph")
                    or (orientation ~= "TB" and orientation ~= "TD" and orientation ~= "LR") then
                    return nil, "Expected flowchart/graph TB, TD or LR header"
                end
                direction = orientation == "TD" and "TB" or orientation
            else
                local pos = 1
                local function whitespace()
                    local _, last = line:find("^[ \t]*", pos)
                    pos = (last or pos - 1) + 1
                end
                local function token()
                    whitespace()
                    local id = line:sub(pos):match("^([A-Za-z][A-Za-z0-9_]*)")
                    if not id then return nil, "Expected node ID" end
                    if #id > MAX_ID then return nil, "Node ID is too long" end
                    pos = pos + #id
                    local label
                    if line:sub(pos, pos) == "[" then
                        local close = line:find("]", pos + 1, true)
                        if not close then return nil, "Unclosed node label" end
                        label = line:sub(pos + 1, close - 1):match("^%s*(.-)%s*$")
                        if label == "" or #label > MAX_LABEL or label:find("[", 1, true) then
                            return nil, "Invalid or oversized node label"
                        end
                        pos = close + 1
                    end
                    return id, label
                end
                local id, label = token()
                if not id then return nil, "Invalid flowchart statement on line " .. line_number end
                local node, err = addNode(id, label)
                if not node then return nil, err end
                whitespace()
                while pos <= #line do
                    if line:sub(pos, pos + 2) ~= "-->" then
                        return nil, "Unsupported flowchart syntax on line " .. line_number
                    end
                    pos = pos + 3
                    local next_id, next_label = token()
                    if not next_id then
                        return nil, "Expected target node on line " .. line_number
                    end
                    local target, target_err = addNode(next_id, next_label)
                    if not target then return nil, target_err end
                    if id == next_id then return nil, "Self edges are unsupported" end
                    if #edges >= MAX_EDGES then return nil, "Too many flowchart edges" end
                    edges[#edges + 1] = { from = id, to = next_id }
                    id = next_id
                    whitespace()
                end
            end
        end
    end
    if not direction or #nodes == 0 then return nil, "Flowchart has no nodes" end
    local graph = { direction = direction, nodes = nodes, edges = edges }
    parsed_sources[graph] = source
    return graph
end

-- UTF-8 safe, fixed-width label lines; long words may split, but never a glyph.
local function labelLines(label)
    local lines, current, width = {}, {}, 0
    local i = 1
    while i <= #label do
        local byte = label:byte(i)
        local length = byte < 0x80 and 1 or (byte < 0xE0 and 2 or (byte < 0xF0 and 3 or 4))
        local units = length == 1 and 1 or 2
        if width + units > 26 then
            lines[#lines + 1] = table.concat(current)
            current, width = {}, 0
        end
        current[#current + 1] = label:sub(i, i + length - 1)
        width = width + units
        i = i + length
    end
    if #current > 0 then lines[#lines + 1] = table.concat(current) end
    return lines
end

local function layout(graph)
    local indegree, out, rank = {}, {}, {}
    for _, node in ipairs(graph.nodes) do
        indegree[node.id], out[node.id], rank[node.id] = 0, {}, 0
    end
    for _, edge in ipairs(graph.edges) do
        indegree[edge.to] = indegree[edge.to] + 1
        out[edge.from][#out[edge.from] + 1] = edge.to
    end
    local queue = {}
    for _, node in ipairs(graph.nodes) do
        if indegree[node.id] == 0 then queue[#queue + 1] = node.id end
    end
    local max_rank = 0
    local first = 1
    while first <= #queue do
        local id = queue[first]
        first = first + 1
        for _, to in ipairs(out[id]) do
            rank[to] = math.max(rank[to], rank[id] + 1)
            max_rank = math.max(max_rank, rank[to])
            indegree[to] = indegree[to] - 1
            if indegree[to] == 0 then queue[#queue + 1] = to end
        end
    end
    -- Stable fallback for cycles: each remaining node gets its own rank.
    for _, node in ipairs(graph.nodes) do
        if indegree[node.id] > 0 then
            max_rank = max_rank + 1
            rank[node.id] = max_rank
        end
    end
    local rows, largest = {}, 0
    for _, node in ipairs(graph.nodes) do
        local r = rank[node.id] + 1
        rows[r] = rows[r] or {}
        rows[r][#rows[r] + 1] = node
        largest = math.max(largest, #rows[r])
    end
    local box_w, box_h, gap_x, gap_y, margin = 220, 136, 48, 64, 40
    local count = max_rank + 1
    local width = graph.direction == "TB"
        and 2 * margin + largest * box_w + (largest - 1) * gap_x
        or 2 * margin + count * box_w + (count - 1) * gap_x
    local height = graph.direction == "TB"
        and 2 * margin + count * box_h + (count - 1) * gap_y
        or 2 * margin + largest * box_h + (largest - 1) * gap_y
    if width > MAX_DIMENSION or height > MAX_DIMENSION then
        return nil, "Flowchart layout exceeds image limits"
    end
    local positions = {}
    for r = 1, count do
        local row = rows[r]
        if row then
            for index, node in ipairs(row) do
                local x, y
                if graph.direction == "TB" then
                    x = (width - (#row * box_w + (#row - 1) * gap_x)) / 2
                        + (index - 1) * (box_w + gap_x)
                    y = margin + (r - 1) * (box_h + gap_y)
                else
                    x = margin + (r - 1) * (box_w + gap_x)
                    y = (height - (#row * box_h + (#row - 1) * gap_y)) / 2
                        + (index - 1) * (box_h + gap_y)
                end
                positions[node.id] = { x = x + box_w / 2, y = y + box_h / 2 }
            end
        end
    end
    return { width = width, height = height, positions = positions,
        half_w = box_w / 2, half_h = box_h / 2 }
end

local function draw(graph)
    local geo, err = layout(graph)
    if not geo then return nil, err end
    local width, height, positions = geo.width, geo.height, geo.positions
    local output = {
        string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img" aria-label="Flowchart">',
            width, height, width, height),
        string.format('<rect x="0" y="0" width="%d" height="%d" fill="#fff"/>', width, height),
    }
    -- Put connector lines behind the nodes. All SVG attributes and geometry are
    -- constants/numbers; user strings appear only as XML-escaped text nodes.
    for _, edge in ipairs(graph.edges) do
        local from, to = positions[edge.from], positions[edge.to]
        local dx, dy = to.x - from.x, to.y - from.y
        local d = math.sqrt(dx * dx + dy * dy)
        local ux, uy = dx / d, dy / d
        local begin_scale = math.min(geo.half_w / (math.abs(ux) + 1e-9),
            geo.half_h / (math.abs(uy) + 1e-9))
        local end_scale = begin_scale
        local x1, y1 = from.x + ux * begin_scale, from.y + uy * begin_scale
        local x2, y2 = to.x - ux * end_scale, to.y - uy * end_scale
        output[#output + 1] = string.format(
            '<path d="M %.1f %.1f L %.1f %.1f" stroke="#444" stroke-width="2" fill="none"/>',
            x1, y1, x2, y2)
        output[#output + 1] = string.format(
            '<path d="M %.1f %.1f L %.1f %.1f L %.1f %.1f Z" fill="#444"/>',
            x2, y2, x2 - ux * 12 - uy * 5, y2 - uy * 12 + ux * 5,
            x2 - ux * 12 + uy * 5, y2 - uy * 12 - ux * 5)
    end
    for _, node in ipairs(graph.nodes) do
        local p = positions[node.id]
        output[#output + 1] = string.format(
            '<rect x="%.1f" y="%.1f" width="%d" height="%d" rx="10" fill="#fff" stroke="#222" stroke-width="2"/>',
            p.x - geo.half_w, p.y - geo.half_h, geo.half_w * 2, geo.half_h * 2)
        local lines = labelLines(node.label)
        for i, line in ipairs(lines) do
            output[#output + 1] = string.format(
                '<text x="%.1f" y="%.1f" text-anchor="middle" font-family="sans-serif" font-size="16" fill="#111">%s</text>',
                p.x, p.y + (i - (#lines + 1) / 2) * 20 + 5, escapeXML(line))
        end
    end
    output[#output + 1] = "</svg>"
    return table.concat(output)
end

--- Return self-contained SVG bytes or nil, error. Accept source or an unmodified
--- parse() result; reparse its private source rather than trusting mutable tables.
function Mermaid.toSVG(source_or_graph)
    local source = type(source_or_graph) == "table" and parsed_sources[source_or_graph]
        or source_or_graph
    local graph, err = Mermaid.parse(source)
    if not graph then return nil, err end
    return draw(graph)
end

--- Display in KOReader without creating a file or fetching any resources.
--- The ImageViewer owns and frees the rendered BlitBuffer on close.
function Mermaid.show(source_or_graph, title)
    local svg, err = Mermaid.toSVG(source_or_graph)
    if not svg then return nil, err end
    local image
    local ok, result = pcall(function()
        local RenderImage = require("ui/renderimage")
        local ImageViewer = require("ui/widget/imageviewer")
        local UIManager = require("ui/uimanager")
        local screen = require("device").screen
        image = RenderImage:renderImageData(svg, #svg, false, screen:getWidth(), screen:getHeight())
        if not image then error("KOReader could not render SVG") end
        UIManager:show(ImageViewer:new{
            image = image,
            image_disposable = true,
            scale_factor = 0,
            with_title_bar = true,
            title_text = title or "Flowchart",
            is_doc_page = false,
        })
    end)
    if not ok then
        if image and image.free then pcall(function() image:free() end) end
        return nil, "Unable to display flowchart: " .. tostring(result)
    end
    return true
end

return Mermaid
