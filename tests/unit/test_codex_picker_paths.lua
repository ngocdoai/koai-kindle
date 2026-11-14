-- The highlight-menu and one-shot picker must use the same Codex catalog.
local file = assert(io.open("koassistant/ui/dialogs.lua", "rb"))
local source = file:read("*a")
file:close()
assert(source:find("ModelLists.getPickerModels(provider_id, discovered)", 1, true),
    "provider/model dialog must include the account catalog")
assert(source:find("plugin:refreshCodexCatalog", 1, true),
    "opening the Codex picker must refresh a stale catalog")
local main_file = assert(io.open("main.lua", "rb"))
local main = main_file:read("*a"); main_file:close()
assert(main:find("Codex catalog refresh is independent of software updates", 1, true),
    "Codex must schedule background catalog refresh separately")
return true
