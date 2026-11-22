package.path = "./?.lua;./tests/lib/?.lua;" .. package.path
local T = require("test_runner"):new()
local Release = require("koassistant.storage.kindle_release")

T:test("accepts only numbered Kindle release versions and fine-grained GitHub tokens", function()
    T:assertEqual(Release.version("v0.25.0-kindle.10"), "0.25.0-kindle.10")
    T:assertEqual(Release.version("v0.26.0"), nil)
    T:assertEqual(Release.version("v0.25.0-kindle.0"), nil)
    T:assertEqual(Release.normalizeToken(" github_pat_fake_for_tests "), "github_pat_fake_for_tests")
    T:assertEqual(Release.normalizeToken("ghp_test"), nil)
    T:assertEqual(Release.normalizeToken("github_pat_fake\r\nInjected: yes"), nil)
end)

T:test("selects the exact asset and constructs its URL in the private repo", function()
    local asset = { name = Release.ASSET, state = "uploaded", id = 123, size = 3,
        digest = "sha256:" .. string.rep("a", 64), url = "https://example.invalid/file" }
    T:assertEqual(Release.assetInfo({ asset }).url,
        "https://api.github.com/repos/ngocdoai/koai-kindle/releases/assets/123")
    asset.digest = "sha256:bad"
    T:assertEqual(Release.assetInfo({ asset }), nil)
end)

T:test("certificates match an exact DNS name or one wildcard label", function()
    T:assertTrue(Release.matchesHost("api.github.com", { "API.GITHUB.COM" }))
    T:assertTrue(Release.matchesHost("api.github.com", { "*.github.com" }))
    T:assertTrue(not Release.matchesHost("api.github.com", { "*.com", "api.github.com.evil" }))
    T:assertTrue(not Release.matchesHost("deep.api.github.com", { "*.github.com" }))
end)

T:test("auth follows certificate checks and is dropped on a verified GitHub CDN redirect", function()
    local modules = package.loaded
    local saved_http, saved_https, saved_storage = modules["socket.http"], modules["ssl.https"], modules.datastorage
    local path = os.tmpname()
    local asset_url = "https://api.github.com/repos/ngocdoai/koai-kindle/releases/assets/123"
    local cdn_url = "https://release-assets.githubusercontent.com/example?sig=abc"
    local token = "github_pat_fake_for_tests"
    local requests, cert_override, redirect = {}, nil, cdn_url
    local ok, err = pcall(function()
        modules.datastorage = { getDataDir = function() return "/reader" end }
        modules["ssl.https"] = { tcp = function(params)
            T:assertEqual(params.verify, "peer")
            T:assertEqual(params.cafile, "/reader/data/ca-bundle.crt")
            return function()
                return {
                    connect = function(self, host) self.host = host; return 1 end,
                    getpeercertificate = function(self)
                        return { extensions = function()
                            return { ["2.5.29.17"] = { dNSName = { cert_override or self.host } } }
                        end }
                    end,
                    close = function() end,
                }
            end
        end }
        modules["socket.http"] = { request = function(req)
            local conn = req.create()
            local connected, failure = conn:connect(req.url:match("^https://([^/]+)"), req.port)
            if not connected then return nil, failure end
            requests[#requests + 1] = req
            T:assertEqual(req.redirect, false)
            if req.url == Release.LIST_URL then
                req.sink("[]")
                return 1, 200, {}
            elseif req.url == asset_url then
                req.sink("old")
                return 1, 302, { location = redirect }
            end
            T:assertEqual(req.url, cdn_url)
            req.sink("ZIP")
            return 1, 200, {}
        end }
        T:assertEqual(Release.fetch(token), "[]")
        T:assertTrue(Release.download(asset_url, token, path, 3))
        T:assertEqual(requests[1].headers.Authorization, "Bearer " .. token)
        T:assertEqual(requests[2].headers.Authorization, "Bearer " .. token)
        T:assertEqual(requests[3].headers.Authorization, nil)
        local file = assert(io.open(path, "rb"))
        T:assertEqual(file:read("*a"), "ZIP")
        file:close()
        redirect = "https://example.invalid/asset"
        T:assertEqual(Release.download(asset_url, token, path, 3), nil)
        T:assertEqual(#requests, 4)
        cert_override = "example.invalid"
        T:assertEqual(Release.fetch(token), nil)
        T:assertEqual(#requests, 4)
    end)
    modules["socket.http"], modules["ssl.https"], modules.datastorage = saved_http, saved_https, saved_storage
    os.remove(path)
    if not ok then error(err) end
end)

return T:summary()
