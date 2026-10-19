> Historical brightness measurements from the earlier local integration.
> Factory/upgrade integration has since been included and qualified; see the
> [current integration record](native-opengl-hdr-integration.md). The tables
> below have not been remeasured on the new factory.

# HDR brightness validation — 2026-10-18

These are local measurements of the accelerated Cocoa/OpenGL HDR prototype on
an Apple M3 Max built-in display. They qualify a separately patched persistent
guest, not the ordinary factory image or every Mac/display. No private app
screenshots, filesystem paths, credentials, or raw environment dumps are included.

## Diagnosis and deployed corrections

1. The host and guest now use a paired **100-nit encoding reference**. The
   presenter requests EDR; on macOS 26 it also requests high dynamic range and
   10x content headroom. This is an encoding contract, not measured panel nits.
2. Stock mpv 0.41.0 rendered PQ through Wayland OpenGL without attaching a PQ
   surface description. Protocol and numeric pixel tracing established that
   Hyprland interpreted those unlabelled pixels as sRGB. The isolated mpv patch
   in `guest/hdr/` explicitly labels the test surface; system mpv was retained.
3. Hyprland treated PQ's 10,000-nit encoding range as the content peak. The
   content-peak patch uses MaxCLL, then mastering peak, for the tone-mapping
   decision, retaining the previous fallback when those values are absent.
   Both compositor patches were built/deployed as local Hyprland 0.56.2-7.322.
4. On the tested Vivaldi build, `UseDisplaySDRMaxLuminanceNits` removed an
   additional 100/203 scaling of HDR10 PQ video. This is a tested local flag,
   not a factory-wide browser policy; HLG and AGTM were not qualified.

## Pixel-value verification after correction

The 75-second synthetic clip has black surround and a central 10%-area patch;
15 seconds each of black, 100, 203, 600 and 1,000 encoded nits. Numeric traces
sampled the final host OpenGL pass, before physical display output. The browser
used a VP9 profile 2 rendition with the same patch levels.

| Encoded patch (nits) | Expected linear value, reference 100 | Corrected mpv | Corrected Vivaldi |
| --- | ---: | ---: | ---: |
| 100 | 1.00 | 0.982910 | 0.992188 |
| 203 | 2.03 | 2.027344 | 2.027344 |
| 600 | 6.00 | 5.980469 | 5.925781 |
| 1,000 | 10.00 | 9.984375 | 9.984375 |

Ordinary browser SDR white remained approximately 0.992188. These are numeric
render values, not measured panel nits. Vivaldi retained ANGLE/OpenGL on VirGL;
the guest reported 4112×2576 at 120 Hz, XRGB2101010 and hdredid. Pixel tracing
was disabled after qualification. These observations do not prove hardware
video decoding or physical presentation cadence.

## Historical before-correction physical measurements

The first controlled run exposed the combined player/compositor faults above.
It must not be read as a host-shader-only defect. Each row is the median of nine
instantaneous meter samples, 4–12 seconds after the first transition sample.
The VM black baseline was 0.1 lux; native was 0.0 lux. The percentage subtracts
those baselines. Foot-candles use 1 fc = 10.7639104167 lux.

| Encoded patch (nits) | Earlier native QuickTime (lux) | Earlier VM (lux) | Earlier VM (fc) | VM/native, baseline corrected |
| --- | ---: | ---: | ---: | ---: |
| 100 | 149.3 | 37.5 | 3.48 | 25.1% |
| 203 | 299.2 | 50.1 | 4.65 | 16.7% |
| 600 | 818.5 | 74.3 | 6.90 | 9.1% |
| 1,000 | 1,309.5 | 86.9 | 8.07 | 6.6% |

## Fresh matched-brightness pair after correction

The tester identified the corrected VM player and native QuickTime recordings
and confirmed the same macOS brightness setting for this pair, collected about
five minutes apart. Settled medians use the same method; both black baselines
were 0.0 lux. No independent geometry, sensor-placement or ambient-light audit
was performed for these user-recorded measurements.

| Encoded patch (nits) | Native QuickTime (lux / fc) | Corrected VM (lux / fc) | VM relative to native |
| --- | ---: | ---: | ---: |
| 100 | 180.8 / 16.80 | 217.0 / 20.16 | +20.0% |
| 203 | 344.6 / 32.01 | 434.4 / 40.36 | +26.1% |
| 600 | 863.1 / 80.18 | 1,234.0 / 114.64 | +43.0% |
| 1,000 | 1,333.6 / 123.90 | 1,400.7 / 130.13 | +5.0% |

The severe brightness deficit is absent in this corrected-player test. The
curves are not identical: from 600 to 1,000 the VM increases by 13.5%, versus
54.5% in QuickTime. The VM drives lower/middle patches more brightly and
converges toward native at the highest patch. This is not evidence for another
global brightness boost, nor proof that the remaining flattening is an
unavoidable panel limit. Meter illuminance does not establish physical panel
luminance in nits.

The earlier and later pairs were recorded hours apart. Their brightness
settings are not established as identical across rounds, so no cross-round
absolute improvement multiplier is claimed. The after table is the valid
same-setting VM/native comparison. The physical after run used the corrected
test player, not Vivaldi; browser photometry remains a separate gate.

## Validation and open gates

On the deployed v1.0.1 local integration: full runtime/app builds and signing,
432 Swift tests plus the remaining repository suites, real GPU/shared-context
FP16 shader tests, and HDR/SDR diskless startup smoke tests passed. The isolated
mpv build passed nine built-in tests; Hyprland compiled and its running binary
matched the installed corrected package. These are local integration results,
not automatically proof of this older draft branch's complete factory image.

At that stage, remaining work included factory registration/package integration,
exact native tone-curve matching, matched browser physical measurements,
QuickTime–VM–QuickTime repeatability controls, other Macs/external displays,
host sleep/wake and live HDR/SDR transitions, and physical frame pacing.

On the updated draft PR branch itself, `make test` passed (424 Swift tests in
86 suites plus all remaining suites); `make runtime` completed a fresh pinned
source build and validated 17 self-contained macOS 15-compatible Mach-O images.
`python3 tests/native-opengl-hdr.py` passed with tracing disabled and enabled,
and `python3 tests/native-opengl-hdr-smoke.py` passed HDR/SDR startup, QMP status
and clean exit with that freshly built runtime. `git diff --check` passed.
