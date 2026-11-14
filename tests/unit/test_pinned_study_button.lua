package.path = "./?.lua;./tests/lib/?.lua;" .. package.path
require("mock_koreader")
local T = require("test_runner"):new()
local file = assert(io.open("main.lua", "rb"))
local source = file:read("*a"); file:close()
local body = assert(source:match("(function AskGPT:registerHighlightMenuActions%(%).-\nend)\r?\n"))
local AskGPT = {}
local calls = {}
local compile = loadstring or load
assert(compile([[return function(AskGPT, Device, Constants, ActionService, Dialogs)
]] .. body .. "\n" .. [[
end]]))()(AskGPT, {hasClipboard=function() return false end},
    {koaLabel=function(text) return text end},
    {getActionDisplayText=function(action) return action.text end},
    {fetchSelectionContextWindow=function() return {prev="Context"} end})
local function setup(features, actions)
    local factories = {}
    local plugin = setmetatable({
        ui={document={file="test.epub"}, highlight={addToHighlightDialog=function(_,id,fn) factories[id]=fn end}},
        settings={readSetting=function() return features end},
        action_service={getHighlightMenuActionObjects=function() return actions end},
        updateConfigFromSettings=function() calls.updated=true end,
        executeQuickAction=function(_,action,text,context,selection,window)
            calls.action=action.id; calls.text=text; calls.window=window
        end,
    }, {__index=AskGPT})
    plugin:registerHighlightMenuActions()
    return factories
end
T:test("study shortcut stays visible and enabled without provider, clipboard or quick actions", function()
    local factories=setup({show_quick_actions_in_highlight=false}, {})
    local row=factories["90_00_koassistant_slot"]({})
    T:assertEqual(row.text, "Explain as image")
    T:assertTrue(row.enabled)
    T:assertEqual(row.show_in_highlight_dialog_func, nil)
    T:assertEqual(row.hold_callback, nil)
end)
T:test("full menu keeps one study button plus all fifteen ordinary slots", function()
    local actions={require("koassistant.prompts.actions").highlight.image_explain}
    for i=1,15 do actions[#actions+1]={id="action"..i,text="Action "..i} end
    local factories=setup({},actions)
    T:assertEqual(factories["90_00_koassistant_slot"]({}).text,"Explain as image")
    T:assertEqual(factories["90_01_koassistant_slot"]({}).text,"Action 1")
    T:assertEqual(factories["90_15_koassistant_slot"]({}).text,"Action 15")
    T:assertEqual(#actions,16)
end)
T:test("tap captures selected passage before closing and dispatches the study action", function()
    local factories=setup({}, {})
    local reader={selected_text={text="Water cycle"},onClose=function(self) self.selected_text=nil; calls.closed=true end}
    factories["90_00_koassistant_slot"](reader).callback()
    T:assertTrue(calls.closed and calls.updated)
    T:assertEqual(calls.action,"image_explain")
    T:assertEqual(calls.text,"Water cycle")
    T:assertEqual(calls.window.prev,"Context")
end)
return T:summary()
