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
body={f['path']: f['content'] for f in d['write_files']}
run=[str(x) for x in d['runcmd']]

for p in ('/var/lib/bwgc/compose.sh','/var/lib/bwgc/start-stack.sh',
          '/var/lib/bwgc/supervise-stack.sh','/var/lib/bwgc/cos-update-reboot.sh',
          '/etc/systemd/system/bwgc.service','/etc/systemd/system/bwgc-supervise.timer',
          '/etc/systemd/system/cos-update-reboot.timer'):
    assert p in paths, 'missing '+p

# The daemon starts an always/unless-stopped/on-failure container about twenty
# seconds before cloud-init mounts the disk, so the stack must be started here
# instead, once the mount exists.
assert any('daemon-reload' in x for x in run), 'units never reloaded'
assert run.index('systemctl daemon-reload')==0, 'reload must precede enabling units'
assert any('bwgc.service' in x for x in run), 'stack service never started'
assert any('bwgc-supervise.timer' in x for x in run), 'supervisor never started'

st=body['/var/lib/bwgc/start-stack.sh']
assert 'mountpoint -q' in st, 'start does not check the mount'
assert 'exit 1' in st, 'start does not fail when the mount is missing'
# compose up alone leaves an already-running container on its stale bind.
assert 'down' in st and 'up -d' in st, 'start does not recreate the stack'
assert st.index('down') < st.index('up -d'), 'start brings up before tearing down'

sup=body['/var/lib/bwgc/supervise-stack.sh']
assert 'up -d' in sup, 'supervisor never starts anything'
assert 'down' not in sup, 'supervisor tears the stack down'

# /var is mounted noexec on COS: execve on a script there fails 203/EXEC, so
# every reference to one must go through an interpreter.
for unit in [p for p in paths if p.startswith('/etc/systemd/')]:
    for line in body[unit].splitlines():
        if line.startswith(('ExecStart=','ExecStop=')):
            cmd=line.split('=',1)[1].split()[0]
            assert cmd in ('/bin/sh','sh','/bin/bash'), unit+' execs '+cmd+' directly'
for script in [p for p in paths if p.startswith('/var/lib/bwgc/')]:
    for line in body[script].splitlines():
        t=line.strip()
        if '/var/lib/bwgc/' in t and not t.startswith('#'):
            assert t.startswith(('sh ','/bin/sh ')) or t.startswith(('BWGC_DIR=','MOUNT=')), \
                script+' calls a noexec path directly: '+t
for x in run:
    if '/var/lib/bwgc/' in x:
        assert x.split()[0] in ('sh','/bin/sh'), 'runcmd execs a noexec path: '+x
" 2>"$WORK/yamlerr"; then pass "parses as YAML with the expected structure"
	else fail "parses as YAML with the expected structure" "$(cat "$WORK/yamlerr")"; fi
else
	printf '  skip YAML parse (ruamel.yaml not installed)\n'
fi
