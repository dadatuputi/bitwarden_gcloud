# The cloud-config is the only thing that survives a reboot on COS, so its
# contents are load-bearing rather than cosmetic.
. "$ROOT/utilities/lib-bwgc-cloudinit.sh"
cc=$(emit_cloud_config bwgc-data /mnt/disks/bwgc 06:00)

assert_contains "$cc" "#cloud-config"                      "starts with the cloud-config header"
assert_contains "$cc" "google-bwgc-data"                   "references the disk by stable by-id name"
assert_not_contains "$cc" "/dev/sdb"                       "never uses attach-order device names"
assert_contains "$cc" "mkdir -p /mnt/disks/bwgc"           "recreates the mountpoint (｜/mnt/disks is tmpfs)"
assert_contains "$cc" "fsck.ext4"                          "checks the filesystem before mounting"
assert_contains "$cc" "cos-update-reboot.timer"            "declares the update timer"
assert_contains "$cc" "OnCalendar=*-*-* 06:00:00"          "honours the requested reboot window"
assert_contains "$cc" "UPDATE_STATUS_UPDATED_NEED_REBOOT"  "reboots only on a staged update"

# The mount must be ordered before Docker, or containers start against an empty
# directory and vaultwarden creates a fresh empty vault.
assert_before "$cc" "bootcmd" "runcmd"                     "bootcmd runs before runcmd"

if command -v python3 >/dev/null 2>&1 && python3 -c "import ruamel.yaml" 2>/dev/null; then
	printf '%s' "$cc" > "$WORK/cc.yaml"
	if python3 -c "
import io,sys
from ruamel.yaml import YAML
d=YAML(typ='safe').load(io.open('$WORK/cc.yaml'))
b=[str(x) for x in d['bootcmd']]
assert len(b)==3, 'bootcmd count'
assert any(x.startswith('mount ') for x in b), 'no mount command'
paths=[f['path'] for f in d['write_files']]
assert any('cos-update-reboot.sh' in p for p in paths)
# Docker starts before cloud-init and COS sets live-restore, so containers
# created before the mount keep a stale bind until each one is restarted.
rb='/var/lib/bwgc/rebind-containers.sh'
assert rb in paths, 'no rebind script'
run=[str(x) for x in d['runcmd']]
hit=[i for i,x in enumerate(run) if rb in x]
assert hit, 'rebind script never runs'
assert hit[0]==0, 'rebind must run before anything else in runcmd'
body=[f['content'] for f in d['write_files'] if f['path']==rb][0]
assert 'mountpoint -q' in body, 'rebind does not check the mount'
assert 'docker restart' in body, 'rebind never restarts containers'
# The containers that failed on a stale bind have already exited, so listing
# only running ones skips exactly the containers that need rebinding.
assert 'docker ps -aq' in body, 'rebind skips exited containers'
# /var is mounted noexec on COS: execve on a script there fails 203/EXEC, so
# every script under it must be handed to an interpreter.
assert run[0].split()[0] in ('sh','/bin/sh','bash'), 'rebind is exec\'d directly from noexec /var'
svc=[f['content'] for f in d['write_files'] if f['path'].endswith('cos-update-reboot.service')][0]
ex=[l for l in svc.splitlines() if l.startswith('ExecStart=')][0]
assert ex.split('=',1)[1].split()[0] in ('/bin/sh','sh','/bin/bash'), 'unit exec\'s a script from noexec /var'
" 2>"$WORK/yamlerr"; then pass "parses as YAML with the expected structure"
	else fail "parses as YAML with the expected structure" "$(cat "$WORK/yamlerr")"; fi
else
	printf '  skip YAML parse (ruamel.yaml not installed)\n'
fi
