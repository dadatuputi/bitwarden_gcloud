# Applying Container-Optimized OS updates

Two different problems, with two different mechanisms.

| | Mechanism | Covered by |
|---|---|---|
| Patches within your current milestone | staged update + reboot | the timer, below |
| Moving to a newer milestone | rebuild the instance | `upgrade-cos.sh` |

A milestone that has stopped shipping builds needs the second one. The timer
will run correctly and find nothing, indefinitely.

## Nothing here can be installed onto the instance

On Container-Optimized OS, `/etc` is a tmpfs overlay. Files written to
`/etc/systemd/system` work until the first reboot and then disappear. So does
`/etc/fstab`. `/home` and `/var` persist but are mounted `noexec`, so a binary
placed there cannot run either.

Google's documented mechanism is **cloud-init**, supplied through the
instance's `user-data` metadata and reapplied on every boot. Everything this
directory configures — the reboot timer and the vault data disk mount — is
declared there.

`lib-bwgc-cloudinit.sh` generates that cloud-config. The other scripts source
it, so there is one definition rather than several that drift.

## Install the update timer

```sh
./utilities/install-cos-update-reboot.sh
```

This prints the cloud-config and the `gcloud` command to apply it. It installs
nothing itself, for the reasons above. Run it from Cloud Shell.

Verify after the reboot that applies it:

```sh
systemctl list-timers cos-update-reboot.timer --no-pager
sudo systemctl start cos-update-reboot.service   # force one check
journalctl -u cos-update-reboot.service --no-pager | tail -20
```

With nothing staged, expect `nothing staged, not rebooting` and a clean exit.
A real end-to-end test needs a genuinely staged update, which cannot be forced.

## About the old `reboot-on-update.sh`

`reboot-on-update.sh` blocks on `update_engine_client
--block_until_reboot_is_needed` and then calls `shutdown -r`.

Earlier revisions of this repository stated that nothing invoked it. That was
wrong. On instances configured through GCE `startup-script` metadata it runs at
every boot, and on one host inspected in August 2026 the process had been alive
since 2025:

```
root 15071  update_engine_client --block_until_reboot_is_needed   (started 2025)
```

The mechanism works. It is still worth replacing, for reasons that are about
control rather than correctness:

- It holds a blocking process for the life of the boot, so its state is
  invisible unless you go looking for it in `ps`.
- The reboot window is computed once at boot, so a machine that has been up for
  a year reboots against a stale calculation.
- It cannot be tested without waiting for a real update.
- `startup-script` and `user-data` are separate metadata keys, so a deployment
  can end up with one configuring reboots and the other configuring mounts.

The timer replaces it and is declared in the same cloud-config as everything
else. `reboot-on-update.sh` keeps its `eval` fix and is retained for reference;
`migrate-to-data-disk.sh` removes the `startup-script` key when it runs.

## Limits

This applies updates **within the current milestone only**. COS does not move a
running instance across milestones, so a box on 109 stays on 109 no matter how
reliably this timer runs. Use `upgrade-cos.sh` for that, and see the wiki page
[Upgrading Container-Optimized OS](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Upgrading-Container-Optimized-OS).

## Removal

Remove the `user-data` metadata key, or edit the cloud-config to drop the
`write_files` and `runcmd` entries, then reboot. The host simply stops
rebooting itself. No container or vault data is affected.
