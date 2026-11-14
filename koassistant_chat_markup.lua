-- Keep image references out of the linkifier and the bracket escape pass.
-- Remote images are links opened on request, never fetched while laying out chat.
local ChatMarkup = {}

local function escapeHTML(value)
    return value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        :gsub('"', "&quot;"):gsub("'", "&#39;")
end

function ChatMarkup.protectImages(text, resolve_local)
    if type(text) ~= "string" then return text, function(value) return value end end
    local marker = "KOAIMAGEPLACEHOLDER"
    while text:find(marker, 1, true) do marker = marker .. "X" end
    local images = {}
    local function protect(html)
        images[#images + 1] = html
        return marker .. #images .. "X"
    end

    local function replaceImages(segment)
        segment = segment:gsub("(!?)%[([^%]]*)%](%b())", function(bang, alt, paren)
            local url = paren:sub(2, -2)
            url = url:match('^([^%s]+)%s+"[^"]*"$')
                or url:match("^([^%s]+)%s+'[^']*'$") or url
            local label = escapeHTML(alt ~= "" and alt or "image")
            local html
            if resolve_local and url:match("^koassistant%-image:") then
                html = resolve_local(url) or ('Image unavailable: ' .. label)
            elseif bang ~= "!" then
                return nil -- ordinary Markdown link
            elseif url:match("^https://[%w%._~:/%?#%[%]@!$&'()*+,;=%-]+$")
                and #url <= 2048 then
                html = '<a href="' .. escapeHTML(url) .. '">Image: ' .. label .. '</a>'
            else
                html = 'Image unavailable: ' .. label
            end
            return protect(html)
        end)
        if resolve_local then
            segment = segment:gsub("^koassistant%-image:/+[^%s%)<>\"']+", function(uri)
                local html = resolve_local(uri)
                return html and protect(html) or nil
            end)
            segment = segment:gsub("(%s)(koassistant%-image:/+[^%s%)<>\"']+)", function(space, uri)
                local html = resolve_local(uri)
                return html and (space .. protect(html)) or nil
            end)
        end
        return segment
    end

    local function processLine(line)
        local parts, at, code_ticks = {}, 1, nil
        while true do
            local first, last = line:find("`+", at)
            local segment = line:sub(at, first and first - 1 or nil)
            parts[#parts + 1] = code_ticks and segment or replaceImages(segment)
            if not first then break end
            local ticks = last - first + 1
            if not code_ticks then
                code_ticks = ticks
            elseif ticks == code_ticks then
                code_ticks = nil
            end
            parts[#parts + 1] = line:sub(first, last)
            at = last + 1
        end
        return table.concat(parts)
    end

    local lines, fence = {}, nil
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local ticks = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
        if ticks then
            if not fence then
                fence = ticks
            elseif ticks:sub(1, 1) == fence:sub(1, 1) and #ticks >= #fence then
                fence = nil
            end
            lines[#lines + 1] = line
        else
            lines[#lines + 1] = (fence or line:match("^    ") or line:match("^\t"))
                and line or processLine(line)
        end
    end

    return table.concat(lines, "\n"), function(value)
        return (value:gsub(marker .. "(%d+)X", function(index)
            return images[tonumber(index)] or ""
        end))
    end
end

-- Only renderer-created, validated local images may load from the resource
-- directory. Call before restoring our protected image placeholders.
function ChatMarkup.stripRawImages(html)
    return (html:gsub("<[iI][mM][gG]%f[%s/>][^>]*>", ""))
end

-- An explicit viewer link keeps the raw Mermaid source available in chat.
function ChatMarkup.linkMermaidBlocks(text, register, label)
    if type(text) ~= "string" then return text end
    return (text:gsub("```mermaid[ \t]*\r?\n(.-)\r?\n```", function(source)
        local id = register(source)
        if not id then return nil end -- leave unsupported or oversized blocks untouched
        return "\n[" .. label .. "](koassistant-mermaid://" .. id .. ")\n\n```mermaid\n"
            .. source .. "\n```"
    end))
end

return ChatMarkup
