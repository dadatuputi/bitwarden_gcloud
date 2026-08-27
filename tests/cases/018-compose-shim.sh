# COS gives the shim nowhere conventional to live: bash does not expand aliases
# non-interactively, every PATH entry is on the read-only root, /home and /var
# are both noexec, and ~/.bashrc is not sourced for `ssh --command` (COS's copy
# also returns early for non-interactive shells, so `bash -lc` gets nothing).
# A function in a sourced file is the only form that works in all of them.
ia=$(cat "$ROOT/utilities/install-alias.sh")

assert_contains "$ia" 'HELPER=~/.bwgc-compose.sh'  "installs the shim where the scripts already source it"
assert_contains "$ia" 'docker-compose() { compose "$@"; }' "defines a function, not an alias"
if printf '%s' "$ia" | grep -qE '^NEW_ALIAS=|^\s*alias docker-compose='; then
	fail "no longer installs an alias" "an alias cannot work non-interactively"
else
	pass "no longer installs an alias"
fi
# An alias left by an earlier version would shadow the function interactively.
assert_contains "$ia" 'alias docker-compose=' "still removes an alias left by an earlier version"
# Match the appended block itself, not just the filename, which appears in the
# HELPER assignment too.
assert_contains "$ia" '    . ~/.bwgc-compose.sh' "sources the shim from ~/.bashrc for interactive use"
assert_contains "$ia" 'grep -q '"'"'bwgc-compose.sh'"'"' "$BASHRC"' "does not append the source line twice"

# The maintenance scripts rewrite this same file, so a script run must not strip
# the docker-compose function back out.
extract() { sed -n '/^compose() {/,/^docker-compose()/p' "$1"; }
a=$(extract "$ROOT/utilities/install-alias.sh")
b=$(extract "$ROOT/utilities/migrate-to-data-disk.sh")
c=$(extract "$ROOT/utilities/upgrade-cos.sh")
[ -n "$a" ] && pass "install-alias.sh carries a shim body" || fail "install-alias.sh carries a shim body"
if [ "$a" = "$b" ]; then pass "migrate writes the same shim body"; else fail "migrate writes the same shim body"; fi
if [ "$a" = "$c" ]; then pass "upgrade writes the same shim body"; else fail "upgrade writes the same shim body"; fi

# The shim has to survive an instance being replaced, which is what upgrade-cos.sh
# running install-alias.sh on the new host is for.
assert_contains "$(cat "$ROOT/utilities/upgrade-cos.sh")" "install-alias.sh" \
	"the upgrade reinstalls the shim on the replacement"
