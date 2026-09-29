# 020 checks the cloud-config's content. This checks its shape against
# cloud-init's own schema: an unknown key, or a write_files entry missing a
# field, is accepted by a YAML parser and silently ignored on the instance,
# where nothing reports it and the unit it was meant to install never exists.
if command -v cloud-init >/dev/null 2>&1; then
	. "$ROOT/utilities/lib-bwgc-cloudinit.sh"
	emit_cloud_config bwgc-data /mnt/disks/bwgc 06:00 > "$WORK/schema-cc.yaml"
	if out=$(cloud-init schema --config-file "$WORK/schema-cc.yaml" 2>&1); then
		pass "the cloud-config passes cloud-init's schema"
	else
		fail "the cloud-config passes cloud-init's schema" "$(printf '%s' "$out" | head -4)"
	fi

	# The check has teeth: a misspelt top-level key is refused.
	sed 's/^runcmd:/runcmdd:/' "$WORK/schema-cc.yaml" > "$WORK/schema-bad.yaml"
	if cloud-init schema --config-file "$WORK/schema-bad.yaml" >/dev/null 2>&1; then
		fail "the schema check rejects an unknown key" "runcmdd was accepted"
	else
		pass "the schema check rejects an unknown key"
	fi
else
	printf '  skip cloud-init schema (cloud-init not installed)\n'
fi
