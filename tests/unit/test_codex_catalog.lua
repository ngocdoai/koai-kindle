local function setupPaths()
    local path = debug.getinfo(1, "S").source:match("@?(.*)"):gsub("\\", "/")
    local unit_dir = path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({ plugin_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path }, ";")
end

setupPaths()
require("mock_koreader")
local Catalog = require("koassistant_codex_catalog")
local json = require("json")
local TestRunner = require("test_runner"):new()

-- Synthetic catalog only: no account, authorization, or live response material.
local CATALOG = [[{"models":[
    {"slug":"gpt-example-a","visibility":"list","extra":"ignored"},
    {"slug":"gpt-example-hidden","visibility":"hide"},
    {"slug":"gpt-example-b","visibility":"list"},
    {"slug":"gpt-example-a","visibility":"list"},
    {"slug":"gpt-example-internal","visibility":"internal"},
    {"slug":"gpt-example-missing"},
    {"slug":"../unsafe","visibility":"list"},
    {"slug":"gpt-example-c","visibility":"list"}
]}]]
local FALLBACK = { "gpt-fallback", "gpt-backup" }

local function assertIds(ids, expected, label)
    TestRunner:assertEqual(#ids, #expected, label .. " count")
    for i, id in ipairs(expected) do
        TestRunner:assertEqual(ids[i], id, label .. " index " .. i)
    end
end

TestRunner:test("synthetic catalog accepts only listed safe slugs in source order", function()
    local ids, reason = Catalog.parse(CATALOG)
    assertIds(ids, { "gpt-example-a", "gpt-example-b", "gpt-example-c" }, "listed")
    TestRunner:assertEqual(reason, nil, "no parse error")
end)

TestRunner:test("rejects malformed or unbounded response without interpreting other fields", function()
    for _, body in ipairs({ "{", "null", "[]", "{}", '{"data":[{"id":"other"}]}',
        '{"models":{}}', '{"models":[{"id":"not-a-slug","visibility":"list"}]}',
        string.rep("x", Catalog.MAX_BODY_BYTES + 1),
        '{"models":[{"slug":"gpt-example","visibility":"hide"}]}',
    }) do
        local ids, reason = Catalog.parse(body)
        TestRunner:assertEqual(ids, nil, "invalid response has no models")
        TestRunner:assertTrue(type(reason) == "string", "safe error code")
        TestRunner:assertFalse(reason:find(body, 1, true), "no raw response in error")
    end
    TestRunner:assertEqual(Catalog.parse(false), nil, "non-string body")
end)

TestRunner:test("rejects oversized arrays rather than truncating source order", function()
    local entries = {}
    for i = 1, Catalog.MAX_MODELS + 1 do
        entries[i] = '{"slug":"model-' .. i .. '","visibility":"list"}'
    end
    local ids = Catalog.parse('{"models":[' .. table.concat(entries, ",") .. "]}")
    TestRunner:assertEqual(ids, nil, "entry count bound")
end)

TestRunner:test("per-session cache uses fallback until refreshed and expires at TTL", function()
    local cache = Catalog.new(FALLBACK, 60)
    local initial, source = cache:get("account-a", 100)
    assertIds(initial, FALLBACK, "uncached fallback")
    TestRunner:assertEqual(source, "fallback", "uncached source")
    local live, refreshed_source = cache:put("account-a", CATALOG, 100)
    assertIds(live, { "gpt-example-a", "gpt-example-b", "gpt-example-c" }, "fresh")
    TestRunner:assertEqual(refreshed_source, "live", "refreshed source")
    assertIds(cache:get("account-a", 159), live, "inside TTL")
    local expired, expired_source = cache:get("account-a", 160)
    assertIds(expired, FALLBACK, "TTL boundary")
    TestRunner:assertEqual(expired_source, "fallback", "expired source")
end)

TestRunner:test("bad refresh preserves unexpired models, then falls back safely", function()
    local cache = Catalog.new(FALLBACK, 60)
    cache:put("account-a", CATALOG, 100)
    local still_live, source, reason = cache:put("account-a", "{", 110)
    assertIds(still_live, { "gpt-example-a", "gpt-example-b", "gpt-example-c" }, "failed refresh")
    TestRunner:assertEqual(source, "live", "fresh cache remains")
    TestRunner:assertTrue(type(reason) == "string", "safe failure code")
    assertIds(cache:get("account-a", 160), FALLBACK, "failed refresh does not extend TTL")
end)

TestRunner:test("account switching and missing account never expose another account's catalog", function()
    local cache = Catalog.new(FALLBACK, 60)
    cache:put("account-a", CATALOG, 100)
    local switched, switched_source = cache:get("account-b", 101)
    assertIds(switched, FALLBACK, "new account")
    TestRunner:assertEqual(switched_source, "fallback", "new account source")
    assertIds(cache:get("account-a", 102), FALLBACK, "old account evicted on switch")
    assertIds(cache:get(nil, 103), FALLBACK, "missing account")
    local anonymous, anonymous_source = cache:put(nil, CATALOG, 104)
    assertIds(anonymous, FALLBACK, "anonymous response ignored")
    TestRunner:assertEqual(anonymous_source, "fallback", "anonymous source")
end)

TestRunner:test("late refresh from prior account cannot evict active account", function()
    local cache = Catalog.new(FALLBACK, 60)
    cache:get("account-a", 100)
    cache:get("account-b", 101)
    local late, source = cache:put("account-a", CATALOG, 102)
    assertIds(late, FALLBACK, "late response ignored")
    TestRunner:assertEqual(source, "fallback", "late response source")
    local current, current_source = cache:put("account-b", CATALOG, 103)
    assertIds(current, { "gpt-example-a", "gpt-example-b", "gpt-example-c" }, "active account refreshed")
    TestRunner:assertEqual(current_source, "live", "active account source")
    cache:put("account-a", CATALOG, 104)
    assertIds(cache:get("account-b", 105), current, "active account retained")
end)

TestRunner:test("returned arrays cannot mutate either cache or caller fallback", function()
    local cache = Catalog.new(FALLBACK, 60)
    FALLBACK[1] = "external-edit"
    local fallback = cache:get("account-a", 100)
    assertIds(fallback, { "gpt-fallback", "gpt-backup" }, "copied fallback")
    fallback[1] = "mutated"
    local result = cache:put("account-a", CATALOG, 100)
    result[1] = "mutated"
    local live = cache:get("account-a", 101)
    assertIds(live, { "gpt-example-a", "gpt-example-b", "gpt-example-c" }, "copied live")
end)

-- Synthetic client fixture: the OAuth token, account, and model ids below are
-- invented for tests; no live account or raw catalog response is committed.
local Client = require("koassistant_codex_catalog_client")
local function makeSettings(auth)
    return { readSetting = function(_, key)
        if key == "features" then return { openai_codex_oauth = auth } end
    end }
end

TestRunner:test("catalog client authenticates an async GET and updates only its picker cache", function()
    local auth = { access_token = "synthetic-token", refresh_token = "synthetic-refresh", chatgpt_account_id = "synthetic-account" }
    local pending, calls = {}, 0
    local client = Client.new(makeSettings(auth), FALLBACK, {
        is_online = function() return true end,
        resolve_token = function(_, done) done(auth) end,
        fetch = function(url, opts, done)
            calls = calls + 1
            TestRunner:assertEqual(url, "https://chatgpt.com/backend-api/codex/models?client_version=0.160.0", "pinned URL")
            TestRunner:assertEqual(opts.method, "GET", "GET method")
            TestRunner:assertEqual(opts.max_response_bytes, Catalog.MAX_BODY_BYTES, "bounded transport")
            TestRunner:assertEqual(opts.headers.Authorization, "Bearer synthetic-token", "bearer")
            TestRunner:assertEqual(opts.headers["ChatGPT-Account-ID"], "synthetic-account", "account header")
            TestRunner:assertEqual(opts.body, nil, "no request body")
            pending[#pending + 1] = done
        end,
    })
    assertIds(client:models(), FALLBACK, "initial fallback")
    client:refresh()
    local notified = 0
    client:refresh(function(_, _, _, updated)
        if updated then notified = notified + 1 end
    end) -- duplicate entry must subscribe without a second request
    TestRunner:assertEqual(calls, 1, "deduplicated")
    pending[1](200, CATALOG)
    TestRunner:assertEqual(notified, 1, "late picker refresh notified")
    assertIds(client:models(), { "gpt-example-a", "gpt-example-b", "gpt-example-c" }, "live picker")
    TestRunner:assertEqual(calls, 1, "reading cached models does not fetch")
end)

TestRunner:test("catalog client stays offline and falls back after failed or oversized HTTP", function()
    local auth = { access_token = "synthetic-token", refresh_token = "synthetic-refresh", chatgpt_account_id = "synthetic-account" }
    local online, fetches = false, 0
    local client = Client.new(makeSettings(auth), FALLBACK, {
        is_online = function() return online end,
        resolve_token = function(_, done) done(auth) end,
        fetch = function(_, _, done) fetches = fetches + 1; done(403, '{"error":"synthetic-secret"}') end,
    })
    client:refresh()
    TestRunner:assertEqual(fetches, 0, "offline: no OAuth or GET")
    online = true
    local ids, source = client:models()
    assertIds(ids, FALLBACK, "offline fallback")
    TestRunner:assertEqual(source, "fallback", "fallback source")
    client:refresh()
    TestRunner:assertEqual(fetches, 1, "one GET")
    assertIds(client:models(), FALLBACK, "HTTP error fallback")
end)

TestRunner:test("display overlay leaves curated defaults and tier picks untouched", function()
    local lists = require("koassistant_model_lists")
    local default = lists.openai_codex[1]
    local tier = lists._tiers.standard.openai_codex
    local discovered = { "gpt-new-synthetic" }
    local merged = lists.getPickerModels("openai_codex", discovered)
    TestRunner:assertEqual(merged[1], discovered[1], "account order first")
    TestRunner:assertEqual(merged[2], default, "curated models remain available")
    TestRunner:assertEqual(#merged, #lists.openai_codex + 1, "union without duplicates")
    local duplicate = lists.getPickerModels("openai_codex", { default })
    TestRunner:assertEqual(#duplicate, #lists.openai_codex, "overlap deduplicated")
    assertIds(lists.getPickerModels("openai_codex"), lists.openai_codex, "curated fallback")
    TestRunner:assertEqual(lists.openai_codex[1], default, "unchanged default")
    TestRunner:assertEqual(lists._tiers.standard.openai_codex, tier, "unchanged tier")
    TestRunner:assertEqual(lists.getPickerModels("openai", discovered)[1], lists.openai[1], "other provider isolated")
end)

TestRunner:test("oversized catalog and failed refresh keep only bounded, unexpired display data", function()
    local auth = { access_token = "synthetic-token", refresh_token = "synthetic-refresh", chatgpt_account_id = "synthetic-account" }
    local pending = {}
    local client = Client.new(makeSettings(auth), FALLBACK, {
        is_online = function() return true end,
        resolve_token = function(_, done) done(auth) end,
        fetch = function(_, _, done) pending[#pending + 1] = done end,
    })
    client:refresh()
    pending[1](200, CATALOG)
    client:refresh(nil, true)
    pending[2](200, string.rep("x", Catalog.MAX_BODY_BYTES + 1))
    assertIds(client:models(), { "gpt-example-a", "gpt-example-b", "gpt-example-c" }, "failed refresh preserves live list")
    client:refresh(nil, true)
    pending[3](403, '{"token":"synthetic-secret"}')
    assertIds(client:models(), { "gpt-example-a", "gpt-example-b", "gpt-example-c" }, "HTTP failure preserves live list")
end)

TestRunner:test("catalog client ignores late results after account change or disconnect", function()
    local a = { access_token = "synthetic-a", refresh_token = "refresh-a", chatgpt_account_id = "account-a" }
    local b = { access_token = "synthetic-b", refresh_token = "refresh-b", chatgpt_account_id = "account-b" }
    local current, pending = a, {}
    local settings = { readSetting = function() return { openai_codex_oauth = current } end }
    local client = Client.new(settings, FALLBACK, {
        is_online = function() return true end,
        resolve_token = function(_, done) done(current) end,
        fetch = function(_, _, done) pending[#pending + 1] = done end,
    })
    client:refresh()
    current = b
    assertIds(client:models(), FALLBACK, "other account before callback")
    pending[1](200, CATALOG)
    assertIds(client:models(), FALLBACK, "old account ignored")
    client:refresh()
    current = nil
    assertIds(client:models(), FALLBACK, "disconnect clears cache")
    pending[2](200, CATALOG)
    assertIds(client:models(), FALLBACK, "disconnected callback ignored")
end)

TestRunner:test("realistic instruction-heavy catalog above 256 KiB remains usable", function()
    local body = json.encode({ models = {
        { slug = "gpt-6.1-sol", visibility = "list", instructions = string.rep("x", 620000) },
        { slug = "private-review", visibility = "hide" },
    } })
    local models = Catalog.parse(body)
    assertIds(models, { "gpt-6.1-sol" }, "large catalog keeps only listed model IDs")
end)

return TestRunner:summary()
