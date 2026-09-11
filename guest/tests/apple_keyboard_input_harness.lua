-- Run apple-keyboard-input.lua against a fake /proc/cmdline (arg[1]).
local cmdline = assert(arg[1], "cmdline required")
local overlay = assert(arg[2], "overlay path required")
local recorded = nil

hl = {
  config = function(tbl)
    recorded = tbl
  end,
}

function io.open(path)
  if path == "/proc/cmdline" then
    return {
      read = function()
        return cmdline
      end,
      close = function() end,
    }
  end
  return nil
end

assert(loadfile(overlay))()

if recorded and recorded.input and recorded.input.kb_model then
  io.write(recorded.input.kb_model)
end
