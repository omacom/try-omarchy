# Private libraries are scoped to mpv on the active virtual HDR output.
omarchy_hdr_available() {
  [[ -n ${WAYLAND_DISPLAY:-} &&
     -x /usr/local/lib/omarchy-hdr/mpv/bin/mpv &&
     -f /usr/local/lib/omarchy-hdr/mesa/lib/libEGL_mesa.so.0 ]] || return 1
  hyprctl -j monitors 2>/dev/null | python3 -c '
import json, sys
try:
    displays = json.load(sys.stdin)
    ready = any(d.get("name", "").startswith("Virtual-") and
                d.get("colorManagementPreset") == "hdr" and
                d.get("currentFormat") in ("XRGB2101010", "XBGR2101010")
                for d in displays)
except (ValueError, TypeError, AttributeError):
    ready = False
raise SystemExit(0 if ready else 1)
'
}

omarchy_hdr_environment() {
  export LD_LIBRARY_PATH="/usr/local/lib/omarchy-hdr/mesa/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export LIBGL_DRIVERS_PATH=/usr/local/lib/omarchy-hdr/mesa/lib/dri
}
