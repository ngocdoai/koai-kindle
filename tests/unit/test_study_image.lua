package.path = "./?.lua;./tests/lib/?.lua;" .. package.path
require("mock_koreader")
local T = require("test_runner"):new()
package.loaded.mime = package.loaded.mime or { unb64 = function(s) return s end }
local Generator = require("koassistant.images.image_generator")
local Images = require("koassistant.images.codex_images")
local Actions = require("koassistant.prompts.actions")

T:test("one-tap study image action is included in highlight defaults", function()
    local action = Actions.highlight.image_explain
    T:assertEqual(action.local_handler, "image_explain")
    T:assertEqual(action.context, "highlight")
    T:assertTrue(type(action.in_highlight_menu) == "number")
    T:assertTrue(action.requires_image_provider)
    T:assertTrue(action.builtin)
end)
T:test("learning prompt explains relationships and is readable on grayscale", function()
    local text = Generator.buildPrompt("Water evaporates and condenses.", {
        purpose = "study", language = "Vietnamese",
        book_metadata = {title="Water cycle"}, window={prev="Weather",next="Rain"},
    }, {})
    for _, part in ipairs({ "Water evaporates and condenses.", "educational image", "relationships",
        "Vietnamese", "grayscale Kindle", "do not invent facts", "Context only", "Water cycle" }) do
        T:assertTrue(text:find(part, 1, true) ~= nil, part)
    end
    T:assertTrue(text:find("do not render any text", 1, true) == nil, "short labels are permitted")
end)
T:test("study button joins an existing highlight menu and respects later dismissal", function()
    local data = { highlight_menu_actions={"explain"}, features={provider="openai_codex"} }
    local settings = { readSetting=function(_,key) return data[key] end,
        saveSetting=function(_,key,value) data[key]=value end, flush=function() end }
    local service = require("koassistant.prompts.action_service"):new(settings)
    service.Actions = Actions
    local ids = service:getHighlightMenuActions()
    local found = 0
    for _, id in ipairs(ids) do if id == "image_explain" then found = found + 1 end end
    T:assertEqual(found, 1, "new built-in inserted exactly once")
    data.highlight_menu_actions = {"explain"}
    data._dismissed_highlight_menu_actions = {"image_explain"}
    ids = service:getHighlightMenuActions()
    for _, id in ipairs(ids) do T:assertTrue(id ~= "image_explain", "dismissal is respected") end
end)
T:test("study framing toggles remove book context without removing learning prompt", function()
    local text = Generator.buildPrompt("Selected text", {purpose="study",book_metadata={title="Hidden book"},window={prev="Hidden context"}},
        {image_gen_frame_identity=false,image_gen_frame_context=false,primary_language="French"})
    T:assertTrue(text:find("educational image", 1, true) ~= nil)
    T:assertTrue(text:find("French", 1, true) ~= nil)
    T:assertTrue(text:find("Hidden", 1, true) == nil)
    T:assertEqual(Generator.buildPrompt("a tree", nil, {}), "a tree", "ordinary image action retains its prompt")
end)
T:test("study action details use the real prompt builder", function()
    local text = Generator.promptTemplateText({}, "study", "Vietnamese")
    T:assertTrue(text:find("Selected passage:\n{selected text}", 1, true) ~= nil)
    T:assertTrue(text:find("educational image", 1, true) ~= nil)
end)
T:test("Codex image progress is display-only and clears on image receipt", function()
    local state = {}
    T:assertEqual(Images.event(state, {type="response.image_generation_call.generating"}), nil)
    state.started = 100
    local text = Images.progressText(state, 281)
    T:assertTrue(text:find("3:01", 1, true) ~= nil)
    T:assertTrue(text:find("Generating image", 1, true) ~= nil)
    local link = Images.event(state, {type="response.output_item.done",item={type="image_generation_call",id="ig1"}},
        function() return "codex-20261004-120000.png" end)
    T:assertTrue(link:find("koassistant-image://", 1, true) ~= nil)
    T:assertTrue(link:find("Generating image", 1, true) == nil)
    T:assertEqual(Images.progressText(state, 300), nil)
end)
return T:summary()
