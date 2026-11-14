-- Synthetic response chunks only: bound catalog downloads before accumulation.
package.path = package.path .. ";./?.lua;./?/init.lua;./tests/lib/?.lua"
require("mock_koreader")
local BaseHandler = require("koassistant_api.base")

local chunks = {}
local sink = BaseHandler.limitedSink(chunks, 5)
assert(sink("abc") == 1)
assert(sink("de") == 1)
local ok, reason = sink("f")
assert(ok == nil and reason == "response too large")
assert(table.concat(chunks) == "abcde")

local http, socket = require("socket.http"), require("socket")
local old_request, old_skip = http.request, socket.skip
local passed, failure = pcall(function()
    http.request = function(request)
        assert(request.sink("abc") == 1)
        local accepted, err = request.sink("def")
        assert(accepted == nil and err == "response too large")
        return nil, err
    end
    socket.skip = function(_, _, code, headers) return code, headers end
    local status, body = BaseHandler.fetchInSubprocess("http://example.invalid/catalog", {
        method = "GET", max_response_bytes = 5,
    })
    assert(status == nil and body == "response too large")
end)
http.request, socket.skip = old_request, old_skip
assert(passed, failure)
return true
