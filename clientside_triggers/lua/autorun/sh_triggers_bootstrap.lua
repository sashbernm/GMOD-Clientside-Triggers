local kAddonRoot = "clientside_triggers/"

local kSharedFiles = {
  "sh_trigger_multiple_fix.lua",
  "sh_trigger_teleport_fix.lua"
}

local function FullPath(path)
  return kAddonRoot .. path
end

local function IncludeShared(path)
  local full_path = FullPath(path)

  if SERVER then
    AddCSLuaFile(full_path)
  end

  include(full_path)
end

local function IncludeList(files, include_func)
  for _, path in ipairs(files) do
    include_func(path)
  end
end


IncludeList(kSharedFiles, IncludeShared)
