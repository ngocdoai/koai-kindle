package.path = "./?.lua;./tests/lib/?.lua;" .. package.path
require("mock_koreader")
package.loaded.mime = package.loaded.mime or {unb64=function(s) return s end}
local T = require("test_runner"):new()
local G = require("koassistant.images.image_generator")
local old_lfs, old_settings = package.loaded["libs/libkoreader-lfs"], package.loaded.luasettings
local old_remove, old_dir = os.remove, G.getImagesDir
local now, files, index, removed, fail, flushes = 2000000, {}, {}, {}, {}, 0
local dir_mode = "directory"
G.getImagesDir=function() return "/fixture/images" end
package.loaded["libs/libkoreader-lfs"]={
    symlinkattributes=function(path, field)
        local a=path=="/fixture/images" and {mode=dir_mode} or files[path:match("([^/]+)$")]
        return field and a and a[field] or (not field and a or nil)
    end,
    dir=function()
        local names={}; for name in pairs(files) do names[#names+1]=name end
        local n=0; return function() n=n+1; return names[n] end
    end,
}
package.loaded.luasettings={open=function() return {
    readSetting=function() return index end,
    saveSetting=function(_,_,value) index=value end,
    flush=function() flushes=flushes+1 end,
} end}
os.remove=function(path)
    assert(path:sub(1,16)=="/fixture/images/")
    local name=path:sub(17)
    if fail[name] then return nil,"busy" end
    removed[name]=true; files[name]=nil; return true
end
local function image(name,age,created,mode)
    files[name]={mode=mode or "file",modification=now-age}
    if created then index[name]={created=created} end
end
T:test("expires at seven days; uses recorded creation and falls back for legacy files",function()
    image("codex-20261004-100000.png",G.IMAGE_TTL)
    image("codex-20261004-100001.png",G.IMAGE_TTL-1)
    image("2026-10-04 10.00.02 tree.png",0,now-G.IMAGE_TTL)
    T:assertEqual(G.cleanupExpired(now),2)
    T:assertTrue(files["codex-20261004-100001.png"]~=nil)
    T:assertEqual(index["2026-10-04 10.00.02 tree.png"],nil)
    T:assertEqual(flushes,1)
end)
T:test("preserves unknown files, symlinks, directories and future timestamps",function()
    image("unrelated.png",G.IMAGE_TTL*2)
    image("koassistant_index.lua",G.IMAGE_TTL*2)
    image("codex-20261004-100003.png",G.IMAGE_TTL*2,nil,"link")
    image("codex-20261004-100004.png",G.IMAGE_TTL*2,nil,"directory")
    image("codex-20261004-100005.png",-100)
    index["../../outside.png"]={created=1}
    T:assertEqual(G.cleanupExpired(now),0)
    T:assertTrue(index["../../outside.png"]~=nil)
    dir_mode="link"
    T:assertEqual(G.cleanupExpired(now),0)
    dir_mode="directory"
end)
T:test("failed deletion retains metadata and retries next sweep",function()
    local name="codex-20261004-100006.png"
    image(name,G.IMAGE_TTL,now-G.IMAGE_TTL); fail[name]=true
    T:assertEqual(G.cleanupExpired(now),0)
    T:assertTrue(index[name]~=nil)
    fail[name]=nil
    T:assertEqual(G.cleanupExpired(now),1)
    T:assertEqual(index[name],nil)
    T:assertEqual(G.cleanupExpired(now),0)
end)
T:test("chat images without a book still record their creation time",function()
    G.recordImage("codex-20261004-100007.png",nil,"synthetic prompt")
    T:assertTrue(type(index["codex-20261004-100007.png"].created)=="number")
end)
T:test("repeated startup schedules only one hourly cleanup",function()
    local ui=package.loaded["ui/uimanager"]
    local count=0
    package.loaded["ui/uimanager"]={scheduleIn=function(_,seconds,task)
        T:assertEqual(seconds,3600); T:assertTrue(type(task)=="function"); count=count+1
    end}
    G.startRetention(); G.startRetention()
    T:assertEqual(count,1)
    G._retentionTask(); T:assertEqual(count,2)
    G._retentionTask=nil; package.loaded["ui/uimanager"]=ui
end)
os.remove, G.getImagesDir = old_remove, old_dir
package.loaded["libs/libkoreader-lfs"], package.loaded.luasettings=old_lfs,old_settings
return T:summary()
