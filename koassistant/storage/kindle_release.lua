-- Public release channel for the Kindle fork.
local Release = {
    REPO = "ngocdoai/koai-kindle",
    ASSET = "koassistant.koplugin.zip",
}
local API = "https://api.github.com/repos/" .. Release.REPO
Release.LIST_URL = API .. "/releases?per_page=20"

function Release.version(tag)
    return type(tag) == "string" and tag:match("^v(%d+%.%d+%.%d+%-kindle%.[1-9]%d*)$") or nil
end

function Release.assetInfo(assets, version)
    if type(assets) ~= "table" or type(version) ~= "string" or not Release.version("v" .. version) then return nil end
    for _, asset in ipairs(assets) do
        if type(asset) == "table" and asset.name == Release.ASSET and asset.state == "uploaded" then
            local size = asset.size
            local digest = type(asset.digest) == "string" and asset.digest:match("^sha256:(%x+)$")
            if type(size) == "number" and size > 0 and size <= 32 * 1024 * 1024 and size % 1 == 0
                and digest and #digest == 64 then
                return {
                    url = "https://github.com/" .. Release.REPO .. "/releases/download/v" .. version .. "/" .. Release.ASSET,
                    size = size, sha256 = digest,
                }
            end
        end
    end
end

local CDN_HOSTS = {
    ["release-assets.githubusercontent.com"] = true,
    ["objects.githubusercontent.com"] = true,
    ["github-releases.githubusercontent.com"] = true,
}

local function releaseHost(url, kind)
    if type(url) ~= "string" then return nil end
    if kind == "list" then
        return url == Release.LIST_URL and "api.github.com" or nil
    end
    if kind == "asset" then
        local slug = Release.REPO:gsub("%-", "%%-")
        return url:match("^https://github%.com/" .. slug
            .. "/releases/download/v%d+%.%d+%.%d+%-kindle%.[1-9]%d*/koassistant%.koplugin%.zip$")
            and "github.com" or nil
    end
    local host = url:match("^https://([%w%.%-]+)/[^%s]+$")
    return CDN_HOSTS[host] and host or nil
end

function Release.matchesHost(host, names)
    if type(names) ~= "table" then return false end
    local parent = host:match("^[^.]+(%..+)$")
    for _, name in ipairs(names) do
        if type(name) == "string" then
            name = name:lower()
            if name == host or (parent and name == "*" .. parent) then return true end
        end
    end
    return false
end

-- LuaSec verifies the trust chain. Its HTTPS wrapper leaves hostname checks
-- to the caller, so check the certificate SAN before HTTP can send headers.
local function request(url, kind, accept, limit, sink, timeout)
    local host = releaseHost(url, kind)
    if not host then return nil, "invalid update URL" end
    local https, http = require("ssl.https"), require("socket.http")
    https.TIMEOUT = timeout
    local tcp = https.tcp{
        verify = "peer",
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
        cafile = require("datastorage"):getDataDir() .. "/data/ca-bundle.crt",
    }
    local headers = {
        ["User-Agent"] = "KOAssistant-Kindle",
        ["Accept"] = accept,
        ["Accept-Encoding"] = "identity",
    }
    local bytes = 0
    local ok, code, response_headers = http.request{
        url = url, port = 443, redirect = false, proxy = false, headers = headers,
        create = function()
            local conn = tcp()
            local connect = conn.connect
            function conn:connect(actual_host, port)
                if actual_host ~= host or tonumber(port) ~= 443 then return nil, "unexpected host" end
                local connected, err = connect(self, actual_host, port)
                if not connected then return nil, err end
                local cert = self:getpeercertificate()
                local exts = cert and cert:extensions()
                local san = exts and exts["2.5.29.17"]
                if not Release.matchesHost(host, san and san.dNSName) then
                    self:close()
                    return nil, "TLS hostname verification failed"
                end
                return connected
            end
            return conn
        end,
        sink = function(chunk, err)
            if not chunk then
                if err then return nil, err end
                return 1
            end
            bytes = bytes + #chunk
            if bytes > limit then return nil, "response too large" end
            return sink(chunk)
        end,
    }
    return ok and code or nil, ok and response_headers or tostring(code)
end

function Release.fetch()
    local parts = {}
    local code, headers = request(Release.LIST_URL, "list", "application/vnd.github+json", 1024 * 1024,
        function(chunk) parts[#parts + 1] = chunk; return 1 end, 8)
    if code ~= 200 then return nil, code and ("HTTP " .. code) or headers end
    return table.concat(parts)
end

function Release.download(url, dest, size)
    if not releaseHost(url, "asset") then return nil, "invalid Kindle release asset URL" end
    local function downloadFrom(location, kind)
        local file = io.open(dest, "wb")
        if not file then return nil, "could not open download file" end
        local ok, code, headers = pcall(request, location, kind, "application/octet-stream", size,
            function(chunk) return file:write(chunk) end, 60)
        local closed = file:close()
        if not ok then return nil, "download connection failed" end
        if not closed then return nil, "could not save download" end
        return code, headers
    end
    local code, headers = downloadFrom(url, "asset")
    if code == 302 or code == 303 or code == 307 then
        local location = headers and headers.location
        if not releaseHost(location) then return nil, "unexpected GitHub download redirect" end
        code, headers = downloadFrom(location, "cdn")
    end
    if code ~= 200 then return nil, code and ("HTTP " .. code) or headers end
    return true
end

return Release
