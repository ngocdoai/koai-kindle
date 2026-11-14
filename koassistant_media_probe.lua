-- One-shot, opt-in Codex SSE metadata probe. Never persist events, text, image data,
-- URLs, authorization or request bodies. This does NOT implement image support.
local Probe = {}
local MAX_ROWS, MAX_VALUE_BYTES = 24, 10485760

local function pathsForDevice()
    local ok, device = pcall(require, "device")
    local home = ok and device and device.home_dir
    -- The MTP-visible home must be known; do not fall back to settings/auth storage.
    if type(home) ~= "string" or home:sub(1, 1) ~= "/" or home == "/" then return nil end
    return { arm = home .. "/koassistant_media_probe.arm",
        report = home .. "/koassistant_media_probe.txt" }
end

local function safeType(value, prefix)
    if type(value) ~= "string" or #value > 64 then return "other" end
    if prefix then
        if value:match("^response%.[a-z][a-z0-9_.]*$") then return value end
    elseif value:match("^[a-z][a-z0-9_]*$") then
        return value
    end
    return "other"
end

local function safeMime(value)
    if value == "image/png" or value == "image/jpeg" or value == "image/webp"
        or value == "image/gif" then return value end
    return nil
end

local function payloadLength(source, image_event)
    if type(source) ~= "table" or not image_event then return nil end
    -- Whitelist encoded/binary payload *fields*, never inspect URL/text fields.
    for _, key in ipairs({ "partial_image_b64", "b64_json", "result", "image", "data" }) do
        if type(source[key]) == "string" then
            return math.min(#source[key], MAX_VALUE_BYTES), #source[key] > MAX_VALUE_BYTES
        end
    end
    if type(source.delta) == "string" then
        return math.min(#source.delta, MAX_VALUE_BYTES), #source.delta > MAX_VALUE_BYTES
    end
    return nil
end

local function addRow(session, event_type, item_type, part_type, source, image_event)
    local mime = type(source) == "table" and safeMime(source.mime_type or source.mime) or nil
    local bytes, over = payloadLength(source, image_event)
    -- Deduplicate by *shape*, not size: many differently sized partial-image
    -- chunks must not crowd out the completion/output-item observations.
    local label = "event=" .. event_type
        .. (item_type and " item=" .. item_type or "")
        .. (part_type and " part=" .. part_type or "")
        .. (mime and " mime=" .. mime or "")
    local row = session.seen[label]
    if not row then
        if #session.rows == MAX_ROWS then
            session.omitted = true
            if not image_event then return end
            -- Reserve space for the diagnostic signal even after many ordinary
            -- lifecycle events; do not let a crowded report imply "no image".
            for i, previous in ipairs(session.rows) do
                if not previous.image_event then
                    session.seen[previous.label] = nil
                    table.remove(session.rows, i)
                    break
                end
            end
            if #session.rows == MAX_ROWS then return end
        end
        row = { label = label, image_event = image_event }
        session.seen[label] = row
        session.rows[#session.rows + 1] = row
    end
    row.image_event = row.image_event or image_event
    if bytes and (not row.bytes or bytes > row.bytes or over) then
        row.bytes, row.over = bytes, over
    end
end

local function imageType(value)
    return value ~= "other" and value:find("image", 1, true) ~= nil
end

local function observeItem(session, event_type, item)
    if type(item) ~= "table" then return end
    local item_type = safeType(item.type)
    local is_image = imageType(item_type)
    addRow(session, event_type, item_type, nil, item, is_image)
    if type(item.content) == "table" then
        for i = 1, math.min(#item.content, 16) do
            local part = item.content[i]
            if type(part) == "table" then
                local part_type = safeType(part.type)
                addRow(session, event_type, item_type, part_type, part,
                    is_image or imageType(part_type))
            end
        end
    end
end

-- `paths` is for the synthetic unit test; production always uses Device.home_dir.
function Probe.start(provider, settings, paths)
    if provider ~= "openai_codex" or type(settings) ~= "table"
        or settings.provider_name ~= "openai_codex" or settings.debug then return nil end
    paths = paths or pathsForDevice()
    if not paths then return nil end
    local f = io.open(paths.arm, "rb")
    if not f then return nil end
    -- Exact opt-in marker; never read more than a few bytes or log its contents.
    local marker, extra = f:read(4), f:read(1)
    f:close()
    if marker ~= "RUN\n" or extra ~= nil then return nil end
    if not os.remove(paths.arm) then return nil end -- consume BEFORE sending request
    -- A previous report must not masquerade as the outcome of this attempt.
    os.remove(paths.report)
    return { rows = {}, seen = {}, paths = paths, events = 0, omitted = false }
end

function Probe.observe(session, event)
    if not session or session.finished or type(event) ~= "table" then return end
    session.events = math.min(session.events + 1, 999999)
    local event_type = safeType(event.type, true)
    local is_image = imageType(event_type)
    addRow(session, event_type, nil, nil, event, is_image)
    observeItem(session, event_type, event.item)
    if type(event.part) == "table" then
        local part_type = safeType(event.part.type)
        addRow(session, event_type, nil, part_type, event.part, is_image or imageType(part_type))
    end
    -- Terminal Responses SSE can carry the complete output, even if item events
    -- were missed. Visit only a bounded number of items and parts, never recurse.
    if (event_type == "response.completed" or event_type == "response.incomplete"
        or event_type == "response.failed") and type(event.response) == "table"
        and type(event.response.output) == "table" then
        for i = 1, math.min(#event.response.output, 16) do
            observeItem(session, event_type, event.response.output[i])
        end
    end
end

function Probe.finish(session, status)
    if not session or session.finished then return end
    session.finished = true
    local outcome = (status == "completed" or status == "cancelled") and status or "failed"
    local lines = { "KOAssistant Codex media probe (metadata only; not image support)",
        "outcome=" .. outcome, "events_seen=" .. tostring(session.events),
        "sizes=encoded field byte lengths, capped at 10485760 (+ means larger)",
        "payload_present reports only whitelisted image field names (not URLs)",
    }
    for _, row in ipairs(session.rows) do
        lines[#lines + 1] = row.label
            .. " payload_present=" .. (row.bytes and "true" or "false")
            .. (row.bytes and " payload_bytes=" .. tostring(row.bytes)
                .. (row.over and "+" or "") or "")
    end
    if session.omitted then lines[#lines + 1] = "additional_event_shapes=omitted" end
    -- No JSON serialization of provider data, no logger calls. The report is the
    -- only retained state and contains exclusively constant labels and sanitized metadata.
    local f = io.open(session.paths.report, "wb")
    if not f then return end
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
end

return Probe
