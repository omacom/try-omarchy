# Host battery

Try Omarchy mirrors the Mac's battery into the guest as a real
`/sys/class/power_supply` device: `BAT0` and `ADP0`. Omarchy Quattro's bar is
Quickshell, and Quickshell's `UPower` bindings read that sysfs tree, so the bar
shows the Mac's battery charge and charging state with no configuration. The
time estimates reach sysfs but not the bar; see "Time estimates" below. The
device is honest about where it comes from — manufacturer `Apple`, model
`Mac Battery` — but named `BAT0`/`ADP0` because those are the names status
tools special-case.

State flows one way, host to guest. The guest may only ask for a fresh
snapshot; nothing it sends can change Mac power state. On a Mac with no
internal battery, the guest keeps `ADP0` and sees no `BAT0`, so the bar shows
nothing.

## Protocol

A dedicated virtio-serial port, `dev.tryomarchy.battery` (`nr=7`), carries
newline-delimited JSON. There is one message type — a complete snapshot every
time, never a delta — so a restarted or late-joining agent is never
half-informed:

```json
{"type":"state","present":true,"percentage":57,"state":"discharging",
 "acConnected":false,"timeToEmptySeconds":8100,"timeToFullSeconds":null}
```

`state` is one of `charging`, `discharging`, `full`, `not-charging`,
`unknown`. `percentage` is an integer 0-100, and is `null` when `present` is
`false`. The time fields are integer seconds or `null` when the host has no
estimate. A Mac with no internal battery sends `"present":false` with
`"acConnected":true`.

`macos/Sources/OmarchyVMHelper/NativeBatteryBridge.swift` builds these
snapshots from `IOPSCopyPowerSourcesInfo` and `IOPSGetPowerSourceDescription`,
and sends one on every coalesced IOKit change and every 30 seconds regardless,
as a safety net against a missed notification. A guest opening the virtio port
is not observable on the host's socket chardev, so
`omarchy-native-battery-bridge`, the guest agent, sends one request line on
start, `{"type":"refresh"}`, and the host answers with a fresh snapshot. The
host ignores any other guest input.

## Sysfs contract

The DKMS module `try-omarchy-battery` (`guest/native-module/try-omarchy-battery/`)
exposes one writable attribute,
`/sys/devices/platform/try-omarchy-battery/state`, mode 0600 root-only. The
guest agent writes it as one whole snapshot per write:

```text
present=1 status=discharging capacity=57 ac=0 time_to_empty=8100 time_to_full=-1
present=0 ac=1
```

The first form is used whenever `present` is true, and carries `status`
(the same token set the protocol's `state` field uses, passed through
unchanged), `capacity` (0-100), `ac`, and both time fields. The second, short
form is used when the host reports no internal battery: only `present=0` and
`ac` are written, and every battery-only key is omitted. `-1` in a time field
means no estimate.

One write is one consistent snapshot and triggers at most one
`power_supply_changed()` per supply that actually moved — consumers can never
observe a new percentage next to a stale charging flag. A malformed line, or
one missing a required key for the state it declares, is rejected whole and
the module keeps the previous state. `BAT0` is registered on the first
`present=1` write and unregistered on the next `present=0`, so a desktop Mac
never creates it and the bar has nothing to render.

## Time estimates

The module publishes the host's estimates as `time_to_empty_avg` and
`time_to_full_avg` under `/sys/class/power_supply/BAT0/`. The pinned
`upower 1.91.4` does not read those two properties, and the device carries no
energy, charge or power values for UPower to derive an estimate from, so the
time remaining does not appear in the Omarchy bar. Percentage, charge state
and AC presence do. Tools that read sysfs directly, such as `acpi` and
fastfetch, show the estimates.

## Critical battery policy

`/etc/UPower/UPower.conf.d/90-try-omarchy.conf` sets two keys:

```ini
[UPower]
AllowRiskyCriticalPowerAction=true
CriticalPowerAction=Ignore
```

Both are required. Setting only `CriticalPowerAction=Ignore` is not enough:
the pinned `upower 1.91.4` classifies `Ignore` itself as a risky action, and
without `AllowRiskyCriticalPowerAction=true` it silently refuses to honor the
setting and falls back through HybridSleep, then Hibernate, then PowerOff —
the guest would suspend or shut itself down on a low reading with no warning
that the configured policy had been overridden. With both keys set, Omarchy
still shows its low- and critical-battery warnings, but the VM never acts on
them. The Mac's own power handling is the only authority over what actually
happens to the battery.

## Retrofitting an existing guest

App updates keep an existing guest's persistent disk, so an already-running VM
does not get the new kernel module from an app update alone — it does get the
virtio port immediately, because QEMU's command line comes from the host at
launch. No factory reset is needed: images from v0.3.0 onward carry `dkms`,
`gcc`, `make`, `kmod`, and headers matching the pinned kernel, so the guest can
build the module itself.

Install it with the app's [VM integrations](integration-updates.md): open
**VM integrations > Review…** in the launcher, or **Setup > Try Omarchy
Integrations** inside Omarchy, and choose **Install/update integration
support**. The integration runs
`guest/scripts/install-battery-into-existing-guest.sh` from the app's read-only
integration bundle. It installs eight files (the three DKMS sources under
`/usr/src/try-omarchy-battery-1.0.0/`, the bridge and its unit, and the udev,
module-load, and UPower drop-ins), runs `dkms install try-omarchy-battery/1.0.0`,
loads the module, reloads udev, and enables
`omarchy-native-battery-bridge.service`. Because the module is installed
through DKMS, the pacman DKMS hook rebuilds it whenever a later `pacman -Syu`
bumps the guest kernel, so the retrofit survives guest kernel updates — a
factory reset is never required.

A guest that already has the module, from the factory image or an earlier
retrofit, is left untouched. When the module cannot be built — no DKMS on an
image before v0.3.0, or a kernel update that has not been followed by a restart
— the battery reports `disabled` with the reason and the other integrations
still install.

Without the integration bundle, the same script can run against files staged
through the shared Mac folder instead of the network. Stage these repo paths,
preserving the layout:

```text
native-module/try-omarchy-battery/{try-omarchy-battery.c,Makefile,dkms.conf}
native-overlay/usr/local/bin/omarchy-native-battery-bridge
native-overlay/usr/lib/systemd/system/omarchy-native-battery-bridge.service
native-overlay/etc/udev/rules.d/95-omarchy-native-battery.rules
native-overlay/etc/modules-load.d/95-try-omarchy-battery.conf
native-overlay/etc/UPower/UPower.conf.d/90-try-omarchy.conf
```

Then, in the guest:

```sh
sudo ~/<folder>/battery-retrofit/install-battery-into-existing-guest.sh
```

## Failure modes

All are non-fatal to the VM, matching the camera bridge's posture:

| Condition | Behavior |
| --- | --- |
| Mac has no internal battery | `present:false`; guest keeps `ADP0` only; bar shows nothing |
| Host bridge dies | Agent writes `status=unknown`, exits; systemd restarts it; launcher restarts the bridge |
| Module absent (un-retrofitted guest) | The unit's `ConditionPathExists` on the sysfs attribute fails; the agent never starts, and a later retrofit brings it up |
| Malformed JSON line or state line | Rejected; previous state retained |
| Host sleep and wake | Fresh snapshot on the next notification or the 30-second tick |
| Critically low Mac battery | Omarchy warns; the VM does not suspend or power off |
