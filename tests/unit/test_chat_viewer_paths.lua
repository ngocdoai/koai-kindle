-- Guard the shared Markdown pipeline and the single final-view widget builder.
local file = assert(io.open("koassistant/ui/chatgptviewer.lua", "rb"))
local source = file:read("*a")
file:close()

local _, widgets = source:gsub("ScrollHtmlWidget:new", "")
assert(widgets == 1, "finished replies and popups must share the HTML widget builder")
assert(source:find("ChatTables.protect(masked", 1, true), "tables must use the shared Markdown pipeline")
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
assert(source:find('ScriptFonts.css(features, html_body, has_preview)', 1, true),
    "the renderer must use the resource root shared by script fonts and local previews")
assert(source:find('nameFromURI(link.uri)', 1, true), "tap handler must accept MuPDF-normalized local URIs")
assert(source:find('restore_images(ChatMarkup.stripRawImages(html_body))', 1, true),
    "only validated image HTML is restored after Markdown and raw-image filtering")
return true
