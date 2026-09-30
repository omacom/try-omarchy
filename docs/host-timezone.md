# Mac time zone and guest clock

Try Omarchy reads the Mac's current IANA time zone on each launch and initializes
the guest before Omarchy's owner setup or login starts. The setup form's default
comes from the Mac rather than IP geolocation. Choosing a different zone during
setup counts as a manual guest selection.

While the VM runs, a dedicated root-only virtio port (`dev.tryomarchy.timezone`)
receives the Mac's current zone every five seconds. The guest applies changes
through `timedatectl` and refreshes Omarchy's clock. This covers travel, manual
Mac zone changes, and wake without requiring another VM launch. Delivery and
guest scheduling can delay a change beyond the five-second sampling interval.

Changing the zone through Omarchy's timezone picker or `timedatectl` stops host
following. The guest persists that choice across reboots and later Mac changes.
The agent records the identity of `/etc/localtime` after each successful host
update; an outside replacement opts out, even if it points to the same zone.
A guest override detected at the next launch is preserved before applying the
new Mac hint. Unsupported zone names are rejected without changing the guest.

The app supplies this small integration through its existing read-only boot
settings payload, including to older saved guests. On its first installation,
the guest adopts the current Mac zone; earlier guests have no host-following
record that can distinguish a geolocation default from a manual selection.
After that initialization, guest selections take precedence. Factory reset
removes the record and resumes following the current Mac.

The zone determines regional display and daylight-saving rules. Clock accuracy
is independent: `systemd-timesyncd` remains enabled and uses the guest's network
connection for NTP. The virtual RTC stays on its normal UTC policy, and
[clock recovery after Mac sleep](guest-clock-recovery.md) remains responsible
for recovering lost elapsed time. The time-zone channel never sets system time
or changes the Mac.

Check the guest with:

```sh
timedatectl
systemctl status try-omarchy-timezone.service
journalctl -u try-omarchy-timezone.service -b
```

For runtime validation, use a disposable VM: confirm Tokyo is preselected in
owner setup when the Mac is in Tokyo, finish setup without changing it, then
publish another Mac zone and confirm both `timedatectl` and the bar change.
Choose a different zone inside Omarchy, change the Mac again, and reboot the
guest; its manual selection must remain. Confirm NTP stays active throughout.
