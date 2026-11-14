package.path = "./?.lua;./tests/lib/?.lua;" .. package.path
require("mock_koreader")
package.loaded.datastorage={getDataDir=function() return "/fixture/koreader" end,
    getSettingsDir=function() return "/fixture/koreader/settings" end}
package.loaded.koassistant_storage_registry=nil
package.loaded.koassistant_image_generator=nil
package.loaded.mime=package.loaded.mime or {unb64=function(v) return v end}
local registry=require("koassistant.storage.storage_registry")
local expected={images_dir="images",backups_dir="backups",exports_dir="exports",
    notebooks_vault_dir="notebooks",chats_v1_dir="chats",chats_backup_dir="chats.backup"}
for _,entry in ipairs(registry.all()) do
    if expected[entry.id] then
        assert(registry.resolvePath(entry)=="/fixture/koreader/data/koassistant/"..expected[entry.id],entry.id)
        expected[entry.id]=nil
    elseif entry.location=="settings_dir" then
        assert(registry.resolvePath(entry):find("^/fixture/koreader/settings/")==1)
    end
end
assert(next(expected)==nil)
assert(require("koassistant.images.image_generator").getImagesDir()=="/fixture/koreader/data/koassistant/images")
return true
