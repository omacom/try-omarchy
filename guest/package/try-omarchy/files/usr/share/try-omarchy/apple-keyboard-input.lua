-- Set kb_model from tryomarchy.keyboard=ansi|iso|jis. Leave layout/variant
-- alone. Japanese JIS direct input also needs the standard backslash option.
-- Unknown or missing tokens are a no-op (never guess iso).

local function host_keyboard_geometry()
  local file = io.open("/run/try-omarchy/cmdline", "r")
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

local input = { kb_model = "applealu_" .. geometry }

-- XKB's Apple JIS default gives underscore at both levels of the ro key.
-- Keep yen distinct and provide backslash/underscore for Linux shell input.
-- Preserve custom layouts, variants, keymaps, and explicit Apple JIS options.
if geometry == "jis"
  and hl.get_config("input.kb_layout") == "jp"
  and hl.get_config("input.kb_variant") == ""
  and hl.get_config("input.kb_file") == "" then
  local options = hl.get_config("input.kb_options") or ""
  local has_jis_option = false
  for option in options:gmatch("[^,]+") do
    if option:match("^apple:jp_") then
      has_jis_option = true
    end
  end
  if not has_jis_option then
    input.kb_options = options .. (options == "" and "" or ",") .. "apple:jp_oadg109a"
  end
end

hl.config({ input = input })
