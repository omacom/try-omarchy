# Sourced by the native-video launchers; never changes the global loader path.
omarchy_video_available() {
  [[ -c /dev/virtio-ports/dev.tryomarchy.video && -S /run/omarchy-video.sock &&
     -r /run/omarchy-video.sock && -w /run/omarchy-video.sock &&
     -f /usr/lib/dri/omarchy_drv_video.so ]]
}

omarchy_video_environment() {
  export LIBVA_DRIVER_NAME=omarchy
  export LIBVA_DRIVERS_PATH=/usr/lib/dri
}

omarchy_video_private_ffmpeg() {
  local program=$1
  # An Arch update may change FFmpeg's ABI. In that case use the system stack
  # until the matching bridge package is installed.
  if ldd "$program" 2>/dev/null | grep -q 'libavcodec\.so\.63 '; then
    export LD_LIBRARY_PATH="/usr/local/lib/omarchy-video/ffmpeg/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    return 0
  fi
  return 1
}
