-- GFM-style pipe tables for KOReader's Markdown renderer.
local ChatTables = {}

local function splitRow(line)
    line = line:match("^%s*(.-)%s*$")
    local cells, parts = {}, {}
    local pos, last_pipe = 1, nil
    while pos <= #line do
        local next_pos = line:find("[\\|`]", pos)
        parts[#parts + 1] = line:sub(pos, next_pos and next_pos - 1 or #line)
        if not next_pos then break end
        pos = next_pos + 1
        local char = line:sub(next_pos, next_pos)
        if char == "|" then
            last_pipe = next_pos
            if next_pos ~= 1 then
                cells[#cells + 1] = table.concat(parts):match("^%s*(.-)%s*$")
            end
            parts = {}
        elseif char == "\\" and line:sub(pos, pos):match("[|\\]") then
            parts[#parts + 1] = line:sub(pos, pos)
            pos = pos + 1
        elseif char == "`" then
            local ticks = line:match("^`+", next_pos)
            local close = next_pos + #ticks
            while true do
                local first, last = line:find("`+", close)
                if not first then break end
                close = last + 1
                if last - first + 1 == #ticks then
                    pos = close
                    break
                end
            end
            if pos == next_pos + 1 then pos = next_pos + #ticks end
            parts[#parts + 1] = line:sub(next_pos, pos - 1):gsub("\\|", "|")
        else
            parts[#parts + 1] = char
        end
    end
    if last_pipe ~= #line then
        cells[#cells + 1] = table.concat(parts):match("^%s*(.-)%s*$")
    end
    return cells, last_pipe
end

local function alignments(line, width)
    local cells = splitRow(line)
    if #cells ~= width then return nil end
    local align = {}
    for i, cell in ipairs(cells) do
        if not cell:match("^:?%-+:?$") then return nil end
        local left, right = cell:sub(1, 1) == ":", cell:sub(-1) == ":"
        align[i] = right and (left and "center" or "right") or "left"
    end
    return align
end

local function fenceStart(line)
    return line:match("^ ? ? ?(```+)") or line:match("^ ? ? ?(~~~+)")
end

local function isBlockStart(line)
    return line:match("^ ? ? ?[#>]")
        or line:match("^ ? ? ?[-+*]%s")
        or line:match("^ ? ? ?%d+[.)]%s")
        or line:match("^    ") or line:match("^\t")
        or fenceStart(line)
end

-- MuPDF sizes columns using the longest unbroken text in each column.
-- Estimate that minimum in ems, including padding and enough room for prose.
local function gridFits(rows, columns, available_em)
    local total = 0
    for col = 1, columns do
        local min_width = 6
        for _, row in ipairs(rows) do
            local visible = row[col]:gsub("<[bB][rR]%s*/?>", " "):gsub("<[^>]*>", "")
                :gsub("&[#%w]+;", "x"):gsub("[\128-\191]", "")
            for word in visible:gmatch("%S+") do
                min_width = math.max(min_width, #word + 1)
            end
        end
        total = total + min_width
        if total > available_em then return false end
    end
    return true
end

local function renderTable(rows, align, available_em)
    local header = rows[1]
    local out = {}
    if gridFits(rows, #header, available_em) then
        out[1] = '<table class="koa-table"><thead>'
        for r, cells in ipairs(rows) do
            if r == 2 then out[#out + 1] = "</thead><tbody>" end
            out[#out + 1] = "<tr>"
            local tag = r == 1 and "th" or "td"
            for c, cell in ipairs(cells) do
                out[#out + 1] = string.format('<%s align="%s">%s</%s>', tag, align[c], cell, tag)
            end
            out[#out + 1] = "</tr>"
        end
        out[#out + 1] = (#rows == 1 and "</thead>" or "</tbody>") .. "</table>"
    else
        for r = #rows == 1 and 1 or 2, #rows do
            out[#out + 1] = '<div class="koa-table-row">'
            for c, cell in ipairs(rows[r]) do
                local label = r > 1 and header[c] ~= "" and ("<strong>" .. header[c] .. ":</strong> ") or ""
                out[#out + 1] = "<p>" .. label .. (cell ~= "" and cell or "&#160;") .. "</p>"
            end
            out[#out + 1] = "</div>"
        end
    end
    return table.concat(out)
end

-- Use standalone paragraphs as placeholders. Inserting block HTML after
-- Markdown conversion keeps luamd from wrapping tables in a <p>.
function ChatTables.protect(text, render_cell, available_em)
    if not text:find("|", 1, true) then return text, function(html) return html end end
    local marker = "KOATABLEPLACEHOLDER"
    while text:find(marker, 1, true) do marker = marker .. "X" end
    local lines, out, tables = {}, {}, {}
    for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    local i, fence = 1, nil
    while i <= #lines do
        local line = lines[i]
        local ticks = fenceStart(line)
        local header, pipe, align
        if fence then
            if ticks and ticks:sub(1, 1) == fence:sub(1, 1) and #ticks >= #fence
                and line:match("^%s*[`~]+%s*$") then
                fence = nil
            end
        elseif ticks then
            fence = ticks
        elseif lines[i + 1] and line:find("|", 1, true) and not isBlockStart(line) then
            header, pipe = splitRow(line)
            if pipe and #header > 0 then align = alignments(lines[i + 1], #header) end
        end
        if not align then
            out[#out + 1] = line
            i = i + 1
        else
            local rows = { header }
            i = i + 2
            while lines[i] and lines[i]:find("|", 1, true) and not isBlockStart(lines[i]) do
                local row, delimiter = splitRow(lines[i])
                if not delimiter then break end
                rows[#rows + 1] = row
                i = i + 1
            end
            for _, row in ipairs(rows) do
                for c = 1, #align do row[c] = render_cell(row[c] or "") end
                for c = #row, #align + 1, -1 do row[c] = nil end
            end
            tables[#tables + 1] = renderTable(rows, align, available_em)
            out[#out + 1] = "\n" .. marker .. #tables .. "X\n"
        end
    end

    return table.concat(out, "\n"), function(html)
        return (html:gsub("<p>" .. marker .. "(%d+)X%s*</p>", function(id)
            return tables[tonumber(id)]
        end))
    end
end

return ChatTables
