#!/usr/bin/env bash

# S-UI managed TCP acceleration. This module owns only its sysctl drop-in and
# state files, so enabling and rolling back never rewrites the user's existing
# /etc/sysctl.conf or other tuning files.

set -u

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

root_prefix="${SUI_ACCEL_ROOT:-}"
sysctl_bin="${SUI_ACCEL_SYSCTL_BIN:-sysctl}"
modprobe_bin="${SUI_ACCEL_MODPROBE_BIN:-modprobe}"
state_dir="${root_prefix}/var/lib/s-ui-network-acceleration"
state_file="${state_dir}/network-acceleration.state"
preference_file="${state_dir}/network-acceleration.preference"
sysctl_dir="${root_prefix}/etc/sysctl.d"
sysctl_file="${sysctl_dir}/99-s-ui-network-acceleration.conf"

info() { echo -e "${green}[网络加速]${plain} $*"; }
warn() { echo -e "${yellow}[网络加速]${plain} $*"; }
error() { echo -e "${red}[网络加速]${plain} $*" >&2; }

require_root() {
    if [[ "${SUI_ACCEL_TEST_MODE:-0}" != "1" && $EUID -ne 0 ]]; then
        error "请使用 root 用户运行此命令。"
        return 1
    fi
}

sysctl_get() {
    "$sysctl_bin" -n "$1" 2>/dev/null
}

sysctl_set() {
    "$sysctl_bin" -q -w "$1=$2" >/dev/null 2>&1
}

valid_sysctl_value() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

write_preference() {
    mkdir -p "$state_dir" || return 1
    printf '%s\n' "$1" > "$preference_file"
}

read_preference() {
    if [[ -f "$preference_file" ]]; then
        head -n 1 "$preference_file" 2>/dev/null
    fi
}

save_previous_state() {
    local previous_qdisc previous_cc
    previous_qdisc=$(sysctl_get net.core.default_qdisc) || return 1
    previous_cc=$(sysctl_get net.ipv4.tcp_congestion_control) || return 1

    if ! valid_sysctl_value "$previous_qdisc" || ! valid_sysctl_value "$previous_cc"; then
        error "无法安全保存当前网络设置。"
        return 1
    fi

    umask 077
    mkdir -p "$state_dir" || return 1
    {
        printf 'previous_qdisc=%s\n' "$previous_qdisc"
        printf 'previous_congestion_control=%s\n' "$previous_cc"
    } > "$state_file"
}

load_previous_state() {
    previous_qdisc=""
    previous_congestion_control=""
    [[ -f "$state_file" ]] || return 1

    local key value
    while IFS='=' read -r key value; do
        case "$key" in
        previous_qdisc) previous_qdisc="$value" ;;
        previous_congestion_control) previous_congestion_control="$value" ;;
        esac
    done < "$state_file"

    valid_sysctl_value "$previous_qdisc" \
        && valid_sysctl_value "$previous_congestion_control"
}

has_congestion_control() {
    local wanted="$1" available item
    available=$(sysctl_get net.ipv4.tcp_available_congestion_control) || return 1
    for item in $available; do
        [[ "$item" == "$wanted" ]] && return 0
    done
    return 1
}

load_kernel_modules() {
    if command -v "$modprobe_bin" >/dev/null 2>&1; then
        "$modprobe_bin" tcp_bbr >/dev/null 2>&1 || true
        "$modprobe_bin" sch_fq >/dev/null 2>&1 || true
    fi
}

runtime_is_accelerated() {
    [[ "$(sysctl_get net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" \
        && "$(sysctl_get net.core.default_qdisc 2>/dev/null)" == "fq" ]]
}

restore_saved_runtime() {
    load_previous_state || return 1
    sysctl_set net.core.default_qdisc "$previous_qdisc" || return 1
    sysctl_set net.ipv4.tcp_congestion_control "$previous_congestion_control" || return 1
}

enable_acceleration() {
    require_root || return 1

    load_kernel_modules
    if ! has_congestion_control bbr; then
        error "当前内核不支持 TCP BBR，S-UI 将跳过加速并继续运行。"
        return 1
    fi

    if [[ ! -f "$state_file" ]]; then
        save_previous_state || {
            error "无法保存当前网络设置，本次未做任何修改。"
            return 1
        }
    fi

    mkdir -p "$sysctl_dir" || return 1
    local temporary_file="${sysctl_file}.tmp.$$"
    {
        echo '# 由 S-UI 管理。需要恢复时请运行 `s-ui accel rollback`，不要直接修改此文件。'
        echo 'net.core.default_qdisc = fq'
        echo 'net.ipv4.tcp_congestion_control = bbr'
    } > "$temporary_file" || return 1
    chmod 0644 "$temporary_file"
    mv -f "$temporary_file" "$sysctl_file"

    if ! sysctl_set net.core.default_qdisc fq \
        || ! sysctl_set net.ipv4.tcp_congestion_control bbr \
        || ! runtime_is_accelerated; then
        rm -f "$sysctl_file"
        restore_saved_runtime >/dev/null 2>&1 || true
        rm -f "$state_file"
        error "内核无法应用 BBR + fq，已恢复原来的网络设置。"
        return 1
    fi

    write_preference enabled || return 1
    info "TCP 加速已开启：BBR + fq。"
}

rollback_acceleration() {
    require_root || return 1
    local purge_preference="${1:-}"
    local had_state=0
    [[ -f "$state_file" ]] && had_state=1

    rm -f "$sysctl_file"

    if [[ $had_state -eq 1 ]]; then
        if ! restore_saved_runtime; then
            error "已删除加速配置，但恢复原网络参数失败，请手动检查。"
            return 1
        fi
        rm -f "$state_file"
        info "已恢复加速前的网络设置。"
    else
        warn "没有找到 S-UI 加速记录，未修改现有网络参数。"
    fi

    if [[ "$purge_preference" == "--purge" ]]; then
        rm -f "$preference_file"
        rmdir "$state_dir" >/dev/null 2>&1 || true
    else
        write_preference disabled || return 1
        info "已关闭自动加速，后续 S-UI 升级会保持关闭。"
    fi
}

show_status() {
    local qdisc cc preference preference_label
    qdisc=$(sysctl_get net.core.default_qdisc 2>/dev/null || echo unknown)
    cc=$(sysctl_get net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    preference=$(read_preference)
    [[ -n "$preference" ]] || preference="default-enabled"
    case "$preference" in
    enabled) preference_label="已开启" ;;
    disabled) preference_label="已手动关闭" ;;
    *) preference_label="默认开启" ;;
    esac

    echo "TCP 拥塞控制算法：$cc"
    echo "默认队列算法：$qdisc"
    echo "S-UI 加速设置：$preference_label"
    if runtime_is_accelerated; then
        info "加速当前正在生效。"
    else
        warn "加速当前未生效。"
    fi
}

auto_enable() {
    if [[ "$(read_preference)" == "disabled" ]]; then
        warn "检测到此前已手动回滚，本次升级继续保持关闭。"
        return 0
    fi
    enable_acceleration
}

case "${1:-status}" in
enable) enable_acceleration ;;
auto) auto_enable ;;
disable | rollback) rollback_acceleration ;;
purge) rollback_acceleration --purge ;;
status) show_status ;;
*)
    echo "用法：$0 {status|enable|auto|rollback|purge}" >&2
    exit 2
    ;;
esac
