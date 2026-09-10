# Guest clock recovery after Mac sleep

A host sleep can pause guest execution without advancing Linux's system clock by
all the elapsed wall time. The virtual PL031 hardware clock can remain correct
while `timedatectl` still reports `NTPSynchronized=yes` from an earlier successful
network synchronization. Signed Touch ID approvals then appear to come from the
future and are correctly rejected. Network timers and other applications can
also be affected.

The guest clock recovery timer checks every ten seconds of guest runtime, with
one second of timer accuracy allowance. On a normally scheduled guest this gives
recovery shortly after wake; it is not an instantaneous host wake notification.
The service also runs shortly after guest boot.

The helper only acts with the Try Omarchy kernel marker and the expected PL031
RTC. It reads the RTC through sysfs and advances system time only when it is more
than five seconds behind. Whole-second RTC precision and slow samples are
accounted for; samples taking over two seconds are rejected. It never writes to
the RTC or moves system time backward. Small offsets and backward corrections
remain the responsibility of network time synchronization. Following a forward
step, it requests a restart of the already-running time-sync service.

This relies on the VM's virtual hardware clock tracking host time. It does not
establish an independent trusted time source if the Mac clock is wrong. No
network service, authentication approval, or guest application supplies the
correction. The helper runs as root with only `CAP_SYS_TIME` retained. Signed
approval verification and expiry windows are unchanged.

## Existing guests

App updates do not install new services inside an existing VM. Copy this checkout
into the guest and run:

```sh
sudo guest/scripts/install-clock-recovery.sh
```

If clock drift is already preventing Touch ID sudo approval, use the guest
password fallback for this installation. The installer immediately runs recovery,
enables the timer for later boots, and retains replaced files under
`/var/lib/try-omarchy/clock-recovery-backup.*`. It does not modify PAM or enrollment.

Check the result with:

```sh
date
timedatectl show -p TimeUSec -p RTCTimeUSec -p NTPSynchronized
systemctl status try-omarchy-clock-recovery.timer
journalctl -u try-omarchy-clock-recovery.service -b
```

After a real Mac sleep/wake cycle, compare system time with the hardware clock
again, allow a timer interval, and test Touch ID authentication. A successful
fingerprint read alone does not prove the guest accepted the signed approval.

To disable only this recovery mechanism:

```sh
sudo systemctl disable --now try-omarchy-clock-recovery.timer
```

Network time synchronization remains enabled.
