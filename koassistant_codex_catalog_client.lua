-- Best-effort, display-only Codex model discovery. No settings writes, request
-- probes, updater integration, or response/credential logging.
local Catalog = require("koassistant_codex_catalog")
local OAuth = require("koassistant_openai_codex_oauth")
local BaseHandler = require("koassistant_api.base")
local ffi = require("ffi")
local ffiutil = require("ffi/util")

local Client = {}
Client.__index = Client

-- Pinned to installed Codex CLI 0.160.0; HTTP 200 and listed slugs verified
-- using local Codex OAuth on 2026-10-04. Kindle account availability may differ.
Client.URL = "https://chatgpt.com/backend-api/codex/models?client_version=0.160.0"
Client.RETRY_SECONDS = 5 * 60
local MAX_PIPE_BYTES = Catalog.MAX_BODY_BYTES + 16

local function online()
    local ok, manager = pcall(require, "ui/network/manager")
    return ok and manager and manager.isWifiOn and manager:isWifiOn() or false
end

-- Fetch in a child so DNS is resolved before fork (macOS) and the UI never
-- blocks on HTTP. Only a successful, size-checked body is sent across the pipe.
-- BaseHandler currently accumulates the HTTP body before returning; the limit
-- here bounds IPC and parsing, not peak memory within that transport.
local function fetch(url, opts, on_done)
    local resolved_ip = BaseHandler.resolveForSubprocess(url)
    local worker = function(pid, write_fd)
        if not pid or not write_fd then return end
        local ok, status, body = pcall(BaseHandler.fetchInSubprocess, url, {
            method = "GET", headers = opts.headers, timeout = 12, resolved_ip = resolved_ip,
            max_response_bytes = opts.max_response_bytes,
        })
        if not ok or tonumber(status) ~= 200 or type(body) ~= "string"
            or #body > Catalog.MAX_BODY_BYTES then
            BaseHandler.writeAllToFD(write_fd, "0\n")
        else
            BaseHandler.writeAllToFD(write_fd, "200\n" .. body)
        end
        ffi.C.close(write_fd)
        pcall(function() ffi.C._exit(0) end)
    end
    local pid, read_fd = ffiutil.runInSubProcess(worker, true)
    if not pid then on_done(nil, nil); return end

    local UIManager = require("ui/uimanager")
    local buffer = ffi.new("char[65536]")
    local parts, bytes = {}, 0
    local function finish()
        ffi.C.close(read_fd)
        local raw = table.concat(parts)
        local status, body = raw:match("^(%d+)\n(.*)$")
        on_done(tonumber(status), body)
    end
    local function poll()
        while true do
            local available = ffiutil.getNonBlockingReadSize(read_fd) or 0
            if available > 0 then
                local n = tonumber(ffi.C.read(read_fd, buffer, math.min(available, 65536)))
                if not n or n <= 0 then finish(); return end
                bytes = bytes + n
                if bytes > MAX_PIPE_BYTES then
                    ffiutil.terminateSubProcess(pid)
                    finish()
                    return
                end
                parts[#parts + 1] = ffi.string(buffer, n)
            elseif ffiutil.isSubProcessDone(pid) then
                -- Drain remaining bytes after exit, before closing the pipe.
                local n = tonumber(ffi.C.read(read_fd, buffer, 65536))
                if n and n > 0 then
                    bytes = bytes + n
                    if bytes > MAX_PIPE_BYTES then finish(); return end
                    parts[#parts + 1] = ffi.string(buffer, n)
                else
                    finish()
                    return
                end
            else
                UIManager:scheduleIn(0.15, poll)
                return
            end
        end
    end
    UIManager:scheduleIn(0.15, poll)
end

function Client.new(settings, fallback, dependencies)
    dependencies = dependencies or {}
    return setmetatable({
        settings = settings,
        cache = Catalog.new(fallback),
        is_online = dependencies.is_online or online,
        resolve_token = dependencies.resolve_token or OAuth.resolveAccessTokenAsync,
        fetch = dependencies.fetch or fetch,
    }, Client)
end

function Client:account()
    local auth = OAuth.readAuth(self.settings)
    return auth and type(auth.refresh_token) == "string" and auth.refresh_token ~= ""
        and type(auth.chatgpt_account_id) == "string" and auth.chatgpt_account_id ~= ""
        and auth.chatgpt_account_id or nil
end

function Client:models()
    local account = self:account()
    if account ~= self.active_account then
        self.active_account = account
        self.pending = nil
        self.waiters = nil
        self.retry_at = nil
        self.generation = (self.generation or 0) + 1
    end
    return self.cache:get(account)
end

-- callback(models, source, error_code, updated) receives safe status codes only. A
-- refresh never chooses the model, changes defaults/tiers, or persists anything.
function Client:refresh(callback, force)
    local _, source = self:models()
    local account = self.active_account
    local now = os.time()
    local function done(reason, updated)
        local current, current_source = self:models()
        local waiters = self.waiters or {}
        self.waiters = nil
        if callback then callback(current, current_source, reason, updated) end
        for _, waiting in ipairs(waiters) do
            waiting(current, current_source, reason, updated)
        end
    end
    if not account then done("not_connected"); return end
    if source == "live" and not force then done(nil); return end
    if self.pending then
        if callback then
            self.waiters = self.waiters or {}
            self.waiters[#self.waiters + 1] = callback
        end
        return
    end
    if not self.is_online() then done("offline"); return end
    if not force and self.retry_at and now < self.retry_at then done("retry_later"); return end

    local generation = self.generation
    self.pending = true
    local function failed(reason)
        if self.generation ~= generation then return end
        self.pending = nil
        self.retry_at = os.time() + Client.RETRY_SECONDS
        done(reason)
    end
    local ok = pcall(self.resolve_token, self.settings, function(auth)
        self:models() -- Observe disconnects and account changes before accepting a callback.
        if self.generation ~= generation then return end
        if type(auth) ~= "table" or type(auth.access_token) ~= "string"
            or auth.access_token == "" or auth.chatgpt_account_id ~= account then
            failed("auth_unavailable")
            return
        end
        local headers = {
            Authorization = "Bearer " .. auth.access_token,
            ["ChatGPT-Account-ID"] = account,
            Accept = "application/json",
            originator = "koassistant",
        }
        local fetch_ok = pcall(self.fetch, Client.URL, {
            method = "GET", headers = headers, max_response_bytes = Catalog.MAX_BODY_BYTES,
        }, function(status, body)
            self:models()
            if self.generation ~= generation then return end
            if status ~= 200 or type(body) ~= "string" or #body > Catalog.MAX_BODY_BYTES then
                failed("fetch_failed")
                return
            end
            local _, new_source, parse_error = self.cache:put(account, body)
            self.pending = nil
            if parse_error or new_source ~= "live" then
                self.retry_at = os.time() + Client.RETRY_SECONDS
                done("invalid_catalog")
            else
                self.retry_at = nil
                done(nil, true)
            end
        end)
        if not fetch_ok then failed("fetch_failed") end
    end)
    if not ok then failed("auth_unavailable") end
end

return Client
