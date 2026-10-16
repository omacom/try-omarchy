# Mac time zone and guest clock

Omarchy's first-boot setup form lists `timedatectl list-timezones`,
preselects `tzupdate -p`, and applies the choice with `timedatectl
set-timezone`. The `try-omarchy` package puts small stand-ins for both
commands on the setup service's `PATH` only (`/usr/lib/try-omarchy/shims`):
the list starts with **Same as macOS**, which is preselected, and the choice
goes to `try-omarchy-timezone --select`. **Same as macOS** sets the Mac's zone
(from the `tryomarchy.timezone` host setting) and follows it; any named zone,
even the Mac's current one, is a fixed guest zone. The policy is recorded in
`/var/lib/try-omarchy/timezone.json` (`auto` or `manual`) during setup.
Everything else reaches the real commands.

While following, a dedicated root-only virtio port (`dev.tryomarchy.timezone`)
receives the Mac's current zone every five seconds. The guest applies changes
through `timedatectl` and refreshes Omarchy's clock. This covers travel, manual
Mac zone changes, and wake without requiring another VM launch. Delivery and
guest scheduling can delay a change beyond the five-second sampling interval.

Changing `/etc/localtime` outside the agent stops following. The agent records
the file's target and inode after each update; an outside replacement opts
out, even if it points to the same zone. Relinking the same zone, as setup
does, does not. Unsupported zone names are rejected without changing the
guest.

**Same as macOS** is the first row of the time zone picker opened by the
Omarchy menu's **Update → Timezone** row. Choosing it turns following back on;
choosing any zone there fixes the guest zone. Try Omarchy doesn't patch
Omarchy: its menu extension carries Omarchy's own Timezone row with the action
pointing at `try-omarchy-timezone-menu`, and a sudoers rule lets the picker apply the
choice without a password, as Omarchy's own picker does. The Mac is never
changed by a guest choice.

The clock's middle-click still opens Omarchy's plain list, and a choice there
is a fixed zone. Offering **Same as macOS** there too needs an upstream
extension point, such as an automatic time zone choice with a per-platform
provider.

The zone determines regional display and daylight-saving rules. Clock accuracy
is independent: `systemd-timesyncd` remains enabled and uses the guest's network
connection for NTP. The virtual RTC stays on its normal UTC policy, and
[clock recovery after Mac sleep](guest-clock-recovery.md) remains responsible
for recovering lost elapsed time. The time-zone channel never sets system time.

Check the guest with:

```sh
timedatectl
cat /var/lib/try-omarchy/timezone.json
systemctl status try-omarchy-timezone.service
journalctl -u try-omarchy-timezone.service -b
```

In a fresh VM, setup preselected the Mac's zone (Asia/Tokyo). Following live
Mac changes, the fixed-zone opt-out and **Same as macOS** in the setup form
and the menu have not been verified in the current guest yet. To verify, use a disposable VM: finish setup
with the preselected zone, change the Mac's zone and confirm both `timedatectl`
and the bar change without a restart. Pick a zone in Omarchy's timezone menu,
change the Mac again, and reboot; the fixed selection must remain. Choose
**Same as macOS** in the same menu and confirm immediate following without a
password prompt. Confirm NTP stays
active throughout.
