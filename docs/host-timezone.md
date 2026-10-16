# Mac time zone and guest clock

Omarchy's first-boot setup form preselects the time zone from `tzupdate -p`.
The `try-omarchy` package puts a small `tzupdate` shim on the setup service's
`PATH` only (`/usr/lib/try-omarchy/shims`), which answers with the Mac's zone
from the `tryomarchy.timezone` host setting. Keeping that zone means the guest
follows the Mac. Choosing any other zone selects a fixed guest zone.

On its first start after setup, `try-omarchy-timezone.service` records the
policy in `/var/lib/try-omarchy/timezone.json`: following (`auto`) when
`/etc/localtime` points at the Mac's zone, fixed (`manual`) otherwise.

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
Omarchy: its menu extension row overrides only that row's action, pointing it
at `try-omarchy-timezone-menu`, and a sudoers rule lets the picker apply the
choice without a password, as Omarchy's own picker does. **Follow Mac Time
Zone** in the application launcher (`try-omarchy-timezone --follow-mac`) does
the same as **Same as macOS**. The Mac is never changed by a guest choice.

Two Omarchy entry points still show Omarchy's plain list: the clock's
middle-click and the first-boot setup form. In setup, the Mac's zone is
preselected and keeping it follows the Mac. A choice in the clock's list is a
fixed zone. Offering **Same as macOS** there too needs an upstream extension
point, such as an automatic time zone choice with a per-platform provider.

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
Mac changes, the fixed-zone opt-out, **Same as macOS** and **Follow Mac Time
Zone** have not been verified in the current guest yet. To verify, use a disposable VM: finish setup
with the preselected zone, change the Mac's zone and confirm both `timedatectl`
and the bar change without a restart. Pick a zone in Omarchy's timezone menu,
change the Mac again, and reboot; the fixed selection must remain. Choose
**Same as macOS** in the same menu and confirm immediate following without a
password prompt. Confirm NTP stays
active throughout.
