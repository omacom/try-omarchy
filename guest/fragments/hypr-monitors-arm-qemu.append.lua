
-- BEGIN OMARCHY ARM QEMU VIRGL PROFILE
-- QEMU's Cocoa frontend publishes the live window's backing-pixel size and
-- host refresh rate through Virtio GPU EDID. Keep Quattro's preceding automatic
-- monitor rule authoritative so window resizing, Retina/non-Retina displays,
-- fullscreen, and 60/120 Hz hosts remain dynamic. Only hide the guest cursor:
-- Cocoa composes the host cursor outside the guest scanout for immediate motion.
local function omarchy_kernel_option_enabled(expected_option)
  if type(io) ~= "table" or type(io.open) ~= "function" then
    return false
  end

  local opened, cmdline_file = pcall(io.open, "/proc/cmdline", "r")
  if not opened or not cmdline_file then
    return false
  end

  local read_ok, cmdline = pcall(cmdline_file.read, cmdline_file, "*a")
  pcall(cmdline_file.close, cmdline_file)
  if not read_ok or type(cmdline) ~= "string" then
    return false
  end

  for option in cmdline:gmatch("%S+") do
    if option == expected_option then
      return true
    end
  end
  return false
end

if omarchy_kernel_option_enabled("omarchy.qemu_virgl=1") then
  hl.config({ cursor = { invisible = true } })
  o.exec_on_start("/usr/local/bin/omarchy-native-display-sync")
  -- A config reload restores the cached preferred mode without a DRM hotplug.
  -- Apply the live EDID after the reload has completed, using the same helper.
  hl.on("config.reloaded", function()
    hl.exec_cmd("/usr/local/bin/omarchy-native-display-sync --once")
  end)
end
-- END OMARCHY ARM QEMU VIRGL PROFILE
