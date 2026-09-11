-- Set kb_model from tryomarchy.keyboard=ansi|iso|jis. Leave layout/variant
-- alone. Unknown or missing tokens are a no-op (never guess iso).

local function host_keyboard_geometry()
  local file = io.open("/proc/cmdline", "r")
  if not file then
    return nil
  end
  local cmdline = file:read("*a") or ""
  file:close()

  for token in cmdline:gmatch("%S+") do
    local value = token:match("^tryomarchy%.keyboard=(%w+)$")
    if value == "ansi" or value == "iso" or value == "jis" then
      return value
    end
  end
  return nil
end

local geometry = host_keyboard_geometry()
if not geometry then
  return
end

hl.config({
  input = {
    kb_model = "applealu_" .. geometry,
  },
})
