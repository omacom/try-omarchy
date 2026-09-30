# Mac time zone and guest clock

Owner setup defaults to **Same as macOS**. Keeping this option follows the Mac's
current time zone automatically. Selecting any ordinary zone chooses a fixed
guest zone, even if it currently matches the Mac. The confirmation screen shows
that exact choice; backing out of the form does not save a timezone policy.

**Same as macOS** is also the first entry in Omarchy's timezone
menu. Selecting it immediately applies the latest received Mac zone and resumes
live following, without restarting the guest or app. If the Mac changes while
the picker is open, selecting Same as macOS uses the latest received zone.
Selecting a specific zone immediately stops mirroring and persists that choice
across reboots and later Mac changes.

While mirroring, a dedicated root-only virtio port (`dev.tryomarchy.timezone`)
receives the Mac's current zone every five seconds. The guest applies changes
through `timedatectl` and refreshes Omarchy's clock. This covers travel, manual
Mac zone changes, and wake without requiring another VM launch. Delivery and
guest scheduling can delay a change beyond the five-second sampling interval.
A launch hint seeds the zone before owner provisioning; the live receiver starts
after provisioning completes.

Changing `/etc/localtime` outside the picker also stops mirroring. The agent
records the file identity after each successful host update; an outside
replacement opts out, even if it points to the same zone. A no-op external
`timedatectl` command cannot express a policy change; use the timezone picker
to explicitly select a fixed zone that already matches. Unsupported zone names
are rejected without changing the guest.

**Follow Mac Time Zone** in the application launcher also resumes mirroring.
The action opens a terminal for ordinary guest sudo authorization. The timezone
menu uses the same privileged helper; the Mac is never changed by a guest choice.

The app supplies this integration through its read-only boot settings payload.
An existing configured guest without a tracking record keeps its current zone
as a fixed selection. Existing tracking records retain their auto/manual policy.
New, reset, or still-unprovisioned guests default to mirroring. An older guest's
setup and menu commands receive the reviewed hooks only when their full contents
match the supported upstream version. Customized or unknown commands are left
untouched and logged; the application-launcher action remains available.
Factory hooks are checksummed backports in `guest/spec.json`, and the boot
installer must produce exactly the same command contents.

The zone determines regional display and daylight-saving rules. Clock accuracy
is independent: `systemd-timesyncd` remains enabled and uses the guest's network
connection for NTP. The virtual RTC stays on its normal UTC policy, and
[clock recovery after Mac sleep](guest-clock-recovery.md) remains responsible
for recovering lost elapsed time. The time-zone channel never sets system time.

Check the guest with:

```sh
timedatectl
systemctl status try-omarchy-timezone.service
journalctl -u try-omarchy-timezone.service -b
```

For runtime validation, use a disposable VM: confirm **Same as macOS**
is preselected when the Mac is in Tokyo, finish setup, then publish another Mac
zone and confirm both `timedatectl` and the bar change without a restart. Pick the
current zone explicitly, change the Mac again, and reboot; the fixed selection
must remain. Select Same as macOS in the timezone menu and confirm immediate following,
including subsequent live changes. Confirm NTP stays active throughout.
