-- Guard the five Markdown display/rebuild paths with one shared pipeline.
local file = assert(io.open("koassistant/ui/chatgptviewer.lua", "rb"))
local source = file:read("*a")
file:close()

local count = 0
for _ in source:gmatch("renderChatHTML%(self,") do count = count + 1 end
assert(count == 5, "all five Markdown paths must use renderChatHTML (found " .. count .. ")")
assert(source:find("ChatMarkup.protectImages", 1, true), "image references must be protected")
assert(source:find("ChatMarkup.protectImages(applyMath", 1, true), "math must run in shared pipeline")
assert(source:find("max%-width:%s*100%%"), "images must fit the chat viewport")
assert(source:find("body {%s+margin: 0;%s+line%-height: 1.3;%s+font%-family: 'Noto Sans'"),
    "chat body must request installed Vietnamese-capable font")
assert(source:find("font%-family: 'Droid Sans Mono', 'Noto Sans', 'FreeSerif', monospace"),
    "code must retain Vietnamese and math glyph fallbacks")
assert(source:find("font%-family: 'Noto Sans', 'FreeSerif', sans%-serif"),
    "chat must fall back to installed FreeSerif math glyphs")
assert(source:find("ChatMarkup.linkMermaidBlocks", 1, true), "Mermaid diagrams need a viewer action")
assert(source:find("Mermaid.show", 1, true), "diagram action must render offline")
local resources = 0
for _ in source:gmatch('html_resource_directory = require%("koassistant%.images%.image_generator"%).getImagesDir%(%)') do
    resources = resources + 1
end
assert(resources == 5, "all five HTML paths must resolve local image resources")
assert(source:find('nameFromURI(link.uri)', 1, true), "tap handler must accept MuPDF-normalized local URIs")
assert(source:find('restore_images(ChatMarkup.stripRawImages(html_body))', 1, true),
    "only validated image HTML is restored after Markdown and raw-image filtering")
return true
