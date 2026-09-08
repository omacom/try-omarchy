# Sourced by the signed ARM64 Vivaldi launcher's local integration.
source /usr/local/lib/omarchy-video/environment.sh
OMARCHY_VIDEO_FLAGS=()
if omarchy_video_available; then
  omarchy_video_environment
  # Vivaldi's VP9 VA-API path carries the complete compressed frame. Its HEVC
  # and AV1 paths do not use our private FFmpeg bitstream-preservation patch.
  export OMARCHY_VIDEO_VP9_ONLY=1
  export LD_PRELOAD="/usr/local/lib/omarchy-video/arm64-browser-compat.so${LD_PRELOAD:+:$LD_PRELOAD}"
  OMARCHY_VIDEO_FLAGS+=(
    --ozone-platform=wayland --use-gl=angle --use-angle=gles
    --enable-features=AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,VaapiIgnoreDriverChecks
    --ignore-gpu-blocklist
  )
fi
