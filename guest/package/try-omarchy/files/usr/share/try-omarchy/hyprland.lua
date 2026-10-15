-- Try Omarchy's Hyprland additions for the Mac VM. Loaded from the user's
-- Omarchy toggles directory (~/.local/state/omarchy/toggles/hypr), which
-- Omarchy reads after the user's own configuration on every reload, so no
-- Omarchy or user file is edited. The try-omarchy package owns this file.

local function host_option(expected)
  local file = io.open("/run/try-omarchy/cmdline", "r")
  if not file then
    return false
  end
  local options = file:read("*a") or ""
  file:close()
  for option in options:gmatch("%S+") do
    if option == expected then
      return true
    end
  end
  return false
end

if host_option("omarchy.qemu_virgl=1") then
  -- QEMU's Cocoa display draws the Mac cursor outside the guest scanout for
  -- immediate motion, so the guest cursor stays hidden. The window's backing
  -- size and refresh rate arrive through Virtio GPU EDID; the sync helper
  -- applies them at start and again after every configuration reload.
  hl.config({ cursor = { invisible = true } })
  o.exec_on_start("/usr/bin/omarchy-native-display-sync")
  hl.on("config.reloaded", function()
    hl.exec_cmd("/usr/bin/omarchy-native-display-sync --once")
  end)
end

pcall(dofile, "/usr/share/try-omarchy/pinch-input.lua")
pcall(dofile, "/usr/share/try-omarchy/apple-keyboard-input.lua")
