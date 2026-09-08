// RDD opens the restricted bridge descriptors before installing its sandbox.
// The child must exec to run that constructor; its seccomp sandbox stays on.
pref("dom.ipc.forkserver.enable", false);
pref("media.ffmpeg.vaapi.enabled", true);
// A delayed VM frame can trip Firefox's slow-decoder heuristic even when the
// hardware decoder is faster on average. Reinitializing midstream then fails
// for HEVC. Keep a working hardware session across those scheduling delays;
// unsupported codecs and failed decoder initialization still use software.
pref("media.ffmpeg.disable-software-fallback", true);
pref("media.hardware-video-decoding.force-enabled", true);
pref("media.ffvpx.enabled", false);
pref("media.hevc.enabled", true);
