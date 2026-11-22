-- Hosted image generation over the existing Codex OAuth Responses connection.
-- No API-key fallback, remote image downloads, or base64 in chat history.
local Images = { MAX_BASE64_BYTES = 16 * 1024 * 1024, MAX_IMAGES = 4 }

function Images.tool(features)
    features = features or {}
    local tool = { type = "image_generation", output_format = "png" }
    local model = features.image_gen_model_openai_codex
    if type(model) == "string" and model ~= "" and model ~= "default" and model ~= "auto" then
        tool.model = model
    end
    return tool
end

function Images.enabled(config)
    -- Book-tool gather/final rounds must retain their own tool-choice contract.
    return not config.tools and not (config.features and config.features.codex_chat_images == false)
end

function Images.request(prompt, model, features)
    return {
        model = model, store = false, stream = true,
        instructions = "Generate the image requested by the user using the image_generation tool.",
        input = {{ role = "user", content = prompt }},
        tools = { Images.tool(features) },
        tool_choice = { type = "image_generation" },
    }
end

function Images.decode(item)
    if type(item) ~= "table" or item.type ~= "image_generation_call" then return nil, "Not an image result" end
    if item.status and item.status ~= "completed" then return nil, "Image generation did not complete" end
    local data = item.result
    if type(data) ~= "string" or data == "" then return nil, "Codex returned no image data" end
    if #data > Images.MAX_BASE64_BYTES then return nil, "Generated image exceeds the Kindle size limit" end
    if #data % 4 ~= 0 or data:find("[^A-Za-z0-9+/=]") or not data:match("^[A-Za-z0-9+/]*=?=?$") then
        return nil, "Invalid image encoding"
    end
    local ok, bytes = pcall(require("mime").unb64, data)
    if not ok or type(bytes) ~= "string" then return nil, "Cannot decode generated image" end
    local ext
    if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then ext = "png"
    elseif bytes:sub(1, 3) == "\255\216\255" then ext = "jpg"
    elseif bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then ext = "webp" end
    if not ext then return nil, "Unsupported generated image format" end
    return bytes, ext
end

function Images.save(item, book_info, prompt)
    local bytes, ext = Images.decode(item)
    if not bytes then return nil, ext end
    local generator = require("koassistant.images.image_generator")
    local lfs = require("libs/libkoreader-lfs")
    local dir = generator.getImagesDir()
    if not lfs.attributes(dir, "mode") then lfs.mkdir(dir) end
    local stem = "codex-" .. os.date("%Y%m%d-%H%M%S")
    local n, name = 1, stem .. "." .. ext
    while lfs.attributes(dir .. "/" .. name, "mode") do
        n = n + 1
        name = stem .. "-" .. n .. "." .. ext
    end
    local path = dir .. "/" .. name
    local file = io.open(path, "wb")
    if not file then return nil, "Cannot save generated image" end
    local written = file:write(bytes)
    local closed = file:close()
    if not written or not closed then os.remove(path); return nil, "Cannot save generated image" end
    generator.recordImage(name, book_info, prompt or "Codex chat image")
    return name
end

function Images.path(name)
    -- Links may originate in model text: never allow them to open arbitrary files.
    if type(name) ~= "string" or not name:match("^codex%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d[%-0-9]*%.[a-z]+$") then return nil end
    local ext = name:match("%.([a-z]+)$")
    if ext ~= "png" and ext ~= "jpg" and ext ~= "webp" then return nil end
    return require("koassistant.images.image_generator").getImagesDir() .. "/" .. name
end

function Images.show(name)
    local path = Images.path(name)
    local lfs = require("libs/libkoreader-lfs")
    if not path or lfs.symlinkattributes(path, "mode") ~= "file" then return false end
    require("ui/uimanager"):show(require("ui/widget/imageviewer"):new{
        file = path, with_title_bar = true, title_text = "Generated image", is_doc_page = false,
    })
    return true
end

function Images.nameFromURI(uri)
    if type(uri) ~= "string" then return nil end
    -- MuPDF can normalize a custom scheme from :// to :/ on tapped links.
    local name = uri:match("^koassistant%-image:/+([^/]+)$")
    return name and Images.path(name) and name or nil
end

function Images.hasReference(text)
    if type(text) ~= "string" then return false end
    for uri in text:gmatch("koassistant%-image:/+[^%s%)<>\"']+") do
        if Images.nameFromURI(uri) then return true end
    end
    return false
end

function Images.inlineHTML(uri, state)
    local name = Images.nameFromURI(uri)
    if not name then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local path = Images.path(name)
    local attr = lfs.symlinkattributes(path)
    local _ = require("koassistant.core.gettext")
    if not attr or attr.mode ~= "file" then
        return '<span>' .. _("Generated image is unavailable or has been deleted.") .. '</span>'
    end
    state = state or {}
    state.bytes = state.bytes or 0
    local link = 'koassistant-image:/' .. name
    -- Bound native image loading across a long history; full-size viewing is
    -- still available for images beyond the inline budget.
    if type(attr.size) ~= "number" or attr.size > 12 * 1024 * 1024
            or state.bytes + attr.size > 32 * 1024 * 1024 then
        return '<a href="' .. link .. '">' .. _("Open generated image") .. '</a>'
    end
    state.bytes = state.bytes + attr.size
    local anchor = '<a href="' .. link .. '">'
    local preview = anchor .. '<img src="' .. name .. '" alt="Generated image" /></a>'
    return preview, '<div class="koa-generated-image"><p>' .. preview .. '</p>'
        .. '<p class="koa-image-caption">' .. anchor .. _("Open full image") .. '</a></p></div>'
end

function Images.consume(state, item, index, save)
    if type(item) ~= "table" or item.type ~= "image_generation_call" then return nil end
    state.seen = state.seen or {}
    local key = type(item.id) == "string" and item.id or tostring(index or 0)
    if state.seen[key] then return nil end
    state.seen[key] = true
    state.count = (state.count or 0) + 1
    if state.count > Images.MAX_IMAGES then return "\n\nAdditional image omitted (Kindle limit).\n\n" end
    local ok, name, err = pcall(save or Images.save, item)
    if not ok then return "\n\nCould not save the generated image.\n\n" end
    if not name then return "\n\nImage generation: " .. tostring(err) .. ".\n\n" end
    return "\n\n[Open generated image](koassistant-image://" .. name .. ")\n\n"
end

function Images.event(state, event, save)
    if type(event.type) == "string" and event.type:match("^response%.image_generation_call%.")
            or (event.type == "response.output_item.added" and type(event.item) == "table"
                and event.item.type == "image_generation_call") then
        state.started = state.started or os.time()
        state.active = true
    end
    if event.type == "response.output_item.done" then
        local text = Images.consume(state, event.item, event.output_index, save)
        if text then state.active = false end
        return text
    elseif (event.type == "response.completed" or event.type == "response.incomplete")
            and type(event.response) == "table" and type(event.response.output) == "table" then
        state.active = false
        local links = {}
        for i, item in ipairs(event.response.output) do
            local link = Images.consume(state, item, i - 1, save)
            if link then links[#links + 1] = link end
        end
        return #links > 0 and table.concat(links) or nil
    end
end

function Images.progressText(state, now)
    if not (state and state.active and state.started) then return nil end
    local _ = require("koassistant.core.gettext")
    local elapsed = math.max(0, (now or os.time()) - state.started)
    return _("Generating image with Codex...") .. "\n" .. string.format("%d:%02d", math.floor(elapsed / 60), elapsed % 60)
        .. "\n" .. _("The image will appear when generation finishes. Stop cancels this request.")
end

function Images.prepareResponse(response)
    if type(response.output) ~= "table" then return end
    local state = {}
    for i, item in ipairs(response.output) do
        local link = Images.consume(state, item, i - 1)
        if link then
            response.output[i] = { type = "message", role = "assistant",
                content = {{ type = "output_text", text = link }} }
        end
    end
end

return Images
