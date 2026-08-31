#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(git rev-parse --show-toplevel)
module="$repo_root/.github/scripts/network-acceleration.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

fake_sysctl="$test_dir/sysctl"
fake_state="$test_dir/sysctl.state"
test_root="$test_dir/root"

cat > "$fake_sysctl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

state=${FAKE_SYSCTL_STATE:?}

if [[ "${1:-}" == "-n" ]]; then
    key=${2:?}
    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; found=1 } END { exit !found }' "$state"
    exit
fi

if [[ "${1:-}" == "-q" && "${2:-}" == "-w" ]]; then
    assignment=${3:?}
elif [[ "${1:-}" == "-w" ]]; then
    assignment=${2:?}
else
    exit 2
fi

key=${assignment%%=*}
value=${assignment#*=}
temporary="${state}.tmp.$$"
awk -F= -v key="$key" -v value="$value" '
    $1 == key { print key "=" value; found=1; next }
    { print }
    END { if (!found) print key "=" value }
' "$state" > "$temporary"
mv "$temporary" "$state"
SH
chmod +x "$fake_sysctl"

write_initial_state() {
    cat > "$fake_state" <<'EOF'
net.core.default_qdisc=cake
net.ipv4.tcp_congestion_control=cubic
net.ipv4.tcp_available_congestion_control=cubic bbr
EOF
}

value_of() {
    FAKE_SYSCTL_STATE="$fake_state" "$fake_sysctl" -n "$1"
}

run_module() {
    FAKE_SYSCTL_STATE="$fake_state" \
    SUI_ACCEL_TEST_MODE=1 \
    SUI_ACCEL_ROOT="$test_root" \
    SUI_ACCEL_SYSCTL_BIN="$fake_sysctl" \
    SUI_ACCEL_MODPROBE_BIN=true \
        "$module" "$@"
}

assert_equal() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: $label: expected '$expected', got '$actual'" >&2
        exit 1
    fi
}

write_initial_state

# Fresh/default install enables BBR + fq and records the exact previous values.
run_module auto
assert_equal fq "$(value_of net.core.default_qdisc)" "default qdisc after enable"
assert_equal bbr "$(value_of net.ipv4.tcp_congestion_control)" "congestion control after enable"
grep -Fxq 'previous_qdisc=cake' "$test_root/var/lib/s-ui-network-acceleration/network-acceleration.state"
grep -Fxq 'previous_congestion_control=cubic' "$test_root/var/lib/s-ui-network-acceleration/network-acceleration.state"
grep -Fxq 'enabled' "$test_root/var/lib/s-ui-network-acceleration/network-acceleration.preference"
test -f "$test_root/etc/sysctl.d/99-s-ui-network-acceleration.conf"

# Reapplying is idempotent and must not replace the original rollback snapshot.
run_module auto
grep -Fxq 'previous_qdisc=cake' "$test_root/var/lib/s-ui-network-acceleration/network-acceleration.state"
grep -Fxq 'previous_congestion_control=cubic' "$test_root/var/lib/s-ui-network-acceleration/network-acceleration.state"

# Rollback restores the exact saved values and persists the opt-out choice.
run_module rollback
assert_equal cake "$(value_of net.core.default_qdisc)" "qdisc after rollback"
assert_equal cubic "$(value_of net.ipv4.tcp_congestion_control)" "congestion control after rollback"
test ! -e "$test_root/etc/sysctl.d/99-s-ui-network-acceleration.conf"
test ! -e "$test_root/var/lib/s-ui-network-acceleration/network-acceleration.state"
grep -Fxq 'disabled' "$test_root/var/lib/s-ui-network-acceleration/network-acceleration.preference"

# Automatic mode respects a previous rollback, while an explicit enable wins.
run_module auto
assert_equal cake "$(value_of net.core.default_qdisc)" "qdisc after disabled auto mode"
assert_equal cubic "$(value_of net.ipv4.tcp_congestion_control)" "congestion control after disabled auto mode"
run_module enable
assert_equal bbr "$(value_of net.ipv4.tcp_congestion_control)" "explicit enable"

# Purge restores values and removes the preference/state owned by this module.
run_module purge
assert_equal cake "$(value_of net.core.default_qdisc)" "qdisc after purge"
assert_equal cubic "$(value_of net.ipv4.tcp_congestion_control)" "congestion control after purge"
test ! -e "$test_root/var/lib/s-ui-network-acceleration/network-acceleration.preference"

# An unsupported kernel fails safely without leaving config or changing values.
sed -i.bak 's/cubic bbr/cubic/' "$fake_state"
rm -f "$fake_state.bak"
if run_module auto; then
    echo "FAIL: unsupported kernel unexpectedly enabled acceleration" >&2
    exit 1
fi
assert_equal cake "$(value_of net.core.default_qdisc)" "unsupported-kernel qdisc"
assert_equal cubic "$(value_of net.ipv4.tcp_congestion_control)" "unsupported-kernel congestion control"
test ! -e "$test_root/etc/sysctl.d/99-s-ui-network-acceleration.conf"
test ! -e "$test_root/var/lib/s-ui-network-acceleration/network-acceleration.state"

echo "network acceleration tests passed"
