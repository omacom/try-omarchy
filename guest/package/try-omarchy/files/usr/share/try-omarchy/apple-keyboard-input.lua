-- Set kb_model from tryomarchy.keyboard=ansi|iso|jis. Leave layouts alone and
-- variants too, except where that model would pick legends Apple no longer
-- ships. Japanese JIS direct input also needs the standard backslash option.
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

-- With an applealu_* model, an empty variant takes these layouts from XKB's
-- Macintosh vendor symbols, which describe keyboards Apple no longer sells:
-- macintosh_vndr/it is the QZERTY typewriter layout, where M types a comma.
-- Name the variant that matches Apple's current keyboard for that layout.
-- An explicit variant (it(mac) for QZERTY) and custom keymaps are kept.
local current_apple_variants = { it = "basic" }

local function comma_list(value)
  local items = {}
  for item in ((value or "") .. ","):gmatch("([^,]*),") do
    items[#items + 1] = item
  end
  return items
end

if hl.get_config("input.kb_file") == "" then
  local variants = comma_list(hl.get_config("input.kb_variant"))
  local changed = false
  for index, layout in ipairs(comma_list(hl.get_config("input.kb_layout"))) do
    variants[index] = variants[index] or ""
    if variants[index] == "" and current_apple_variants[layout] then
      variants[index] = current_apple_variants[layout]
      changed = true
    end
  end
  if changed then
    input.kb_variant = table.concat(variants, ",")
  end
end

hl.config({ input = input })
