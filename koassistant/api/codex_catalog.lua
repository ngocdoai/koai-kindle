-- Pure, best-effort Codex catalog decoding and session-only account-scoped cache.
-- The caller owns OAuth, the verified catalog URL, network gating and async GET.
-- Pass only a successful HTTP response body to cache:put(account_id, body, now).
-- Never persist or log the response or account id; a listed slug is not proof that
-- the model can answer on this account. Do not use this list for automatic picks.
local json = require("json")

local Catalog = {
    -- The catalog includes substantial model instructions: the live 0.160.0
    -- response was 616,484 bytes on 2026-10-04. 256 KiB rejected valid catalogs.
    MAX_BODY_BYTES = 2 * 1024 * 1024,
    MAX_MODELS = 512,
    DEFAULT_TTL_SECONDS = 60 * 60,
}
local Cache = {}
Cache.__index = Cache

local function copy(list)
    local result = {}
    for i, value in ipairs(list) do result[i] = value end
    return result
end

local function validSlug(slug)
    return type(slug) == "string"
        and #slug > 0 and #slug <= 128
        and slug:match("^[A-Za-z0-9][A-Za-z0-9._%-]*$") ~= nil
end

local function validAccount(account_id)
    return type(account_id) == "string" and #account_id > 0 and #account_id <= 256
end

local function validNow(now)
    return type(now) == "number" and now == now and now > -math.huge and now < math.huge
end

-- Returns a fresh ordered list, or nil plus a non-sensitive error code. Only
-- visibility="list" is displayable; unknown/missing visibility fails closed.
-- Ignore unrecognized metadata, never treat id/name fields as a slug.
function Catalog.parse(body)
    if type(body) ~= "string" or #body == 0 or #body > Catalog.MAX_BODY_BYTES then
        return nil, "invalid_size"
    end
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= "table" or type(decoded.models) ~= "table" then
        return nil, "invalid_json"
    end

    local models = decoded.models
    local count = 0
    for key in pairs(models) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return nil, "invalid_models"
        end
        count = count + 1
        if count > Catalog.MAX_MODELS then return nil, "too_many_models" end
    end
    if count == 0 then return nil, "empty_catalog" end

    local ids, seen = {}, {}
    for i = 1, count do
        local model = models[i]
        if model == nil then return nil, "invalid_models" end
        if type(model) == "table" and model.visibility == "list" and validSlug(model.slug)
            and not seen[model.slug] then
            ids[#ids + 1] = model.slug
            seen[model.slug] = true
        end
    end
    if #ids == 0 then return nil, "no_visible_models" end
    return ids
end

local function fallbackList(list)
    local result, seen = {}, {}
    if type(list) ~= "table" then return result end
    for _, slug in ipairs(list) do
        if validSlug(slug) and not seen[slug] then
            result[#result + 1] = slug
            seen[slug] = true
        end
    end
    return result
end

-- The fallback is supplied by the caller (e.g. its existing curated list),
-- copied once, and returned by value. One account is retained at a time; a
-- switch or missing account discards the previous account's catalog.
function Catalog.new(fallback, ttl_seconds)
    local ttl = ttl_seconds
    if type(ttl) ~= "number" or ttl <= 0 or ttl == math.huge or ttl ~= ttl then
        ttl = Catalog.DEFAULT_TTL_SECONDS
    end
    return setmetatable({ fallback = fallbackList(fallback), ttl = ttl }, Cache)
end

function Cache:get(account_id, now)
    if not validAccount(account_id) then
        self.account_id, self.ids, self.expires_at, self.updated_at = nil, nil, nil, nil
        return copy(self.fallback), "fallback"
    end
    if self.account_id ~= account_id then
        self.account_id, self.ids, self.expires_at, self.updated_at = account_id, nil, nil, nil
    end
    now = now == nil and os.time() or now
    if validNow(now) and self.ids and now >= self.updated_at and now < self.expires_at then
        return copy(self.ids), "live"
    end
    return copy(self.fallback), "fallback"
end

function Cache:put(account_id, body, now)
    now = now == nil and os.time() or now
    local ids, reason = Catalog.parse(body)
    if not validAccount(account_id) or not validNow(now) then
        return copy(self.fallback), "fallback", "invalid_context"
    end
    -- A late callback for an account that is no longer active must not evict
    -- the current account's catalog. Call get() when changing accounts; the
    -- first put() in a fresh session can also establish the account.
    if self.account_id and self.account_id ~= account_id then
        return copy(self.fallback), "fallback", "inactive_account"
    end
    local current, source = self:get(account_id, now)
    if not ids then return current, source, reason end
    self.ids, self.updated_at, self.expires_at = copy(ids), now, now + self.ttl
    return copy(ids), "live"
end

return Catalog
