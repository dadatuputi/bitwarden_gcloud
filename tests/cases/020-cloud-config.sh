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
assert len(d['bootcmd'])==3, 'bootcmd count'
assert any('cos-update-reboot.sh' in f['path'] for f in d['write_files'])
" 2>"$WORK/yamlerr"; then pass "parses as YAML with the expected structure"
	else fail "parses as YAML with the expected structure" "$(cat "$WORK/yamlerr")"; fi
else
	printf '  skip YAML parse (ruamel.yaml not installed)\n'
fi
