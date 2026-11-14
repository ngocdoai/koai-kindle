-- Kindle build: the Codex tiers and default model follow the account's catalog.
package.path = "./?.lua;./tests/lib/?.lua;" .. package.path
require("mock_koreader")
local T = require("test_runner"):new()
local ModelLists = require("koassistant.request.model_lists")
local Defaults = require("koassistant.api.defaults")

T:test("each family's newest listed model takes its tiers", function()
    local picks = ModelLists.codexAccountTiers({
        "gpt-5.6-terra", "gpt-6-terra", "gpt-6-sol", "gpt-6.1-sol", "gpt-6.10-sol",
        "gpt-6-luna", "gpt-5.6-luna", "gpt-6-luna-mini", "codex-auto", "gpt-6-astra",
    })
    T:assertEqual(picks.standard, "gpt-6-terra")
    T:assertEqual(picks.flagship, "gpt-6.10-sol")
    T:assertEqual(picks.frontier, "gpt-6-astra")
    T:assertEqual(picks.fast, "gpt-6-luna")
    T:assertEqual(picks.ultrafast, "gpt-6-luna")
end)

T:test("a family the account does not list keeps the curated pick", function()
    local curated_flagship = ModelLists._tiers.flagship.openai_codex
    local default = ModelLists.applyCodexAccountTiers(ModelLists.codexAccountTiers({ "gpt-7-terra" }))
    T:assertEqual(default, "gpt-7-terra")
    T:assertEqual(ModelLists._tiers.standard.openai_codex, "gpt-7-terra")
    T:assertEqual(ModelLists._tiers.flagship.openai_codex, curated_flagship)
    T:assertEqual(ModelLists.openai_codex[1], "gpt-7-terra")
    T:assertEqual(Defaults.ProviderDefaults.openai_codex.model, "gpt-7-terra")
end)

T:test("no picks restores the curated ladder and default", function()
    local default = ModelLists.applyCodexAccountTiers(nil)
    T:assertEqual(default, "gpt-5.6-terra")
    T:assertEqual(ModelLists._tiers.flagship.openai_codex, "gpt-6.1-sol")
    T:assertEqual(ModelLists.openai_codex[1], "gpt-5.6-terra")
    local seen = 0
    for _idx, m in ipairs(ModelLists.openai_codex) do
        if m == "gpt-7-terra" then seen = seen + 1 end
    end
    T:assertEqual(seen, 1, "a model put first stays listed once")
end)

return T:summary()
