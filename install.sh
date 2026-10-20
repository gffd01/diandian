#!/usr/bin/env bash

set -Eeuo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# Full-auto is the DEFAULT install mode: every command runs start-to-finish with
# no prompts. On a fresh install it generates random admin credentials + a random
# panel path + free ports. The panel listens on localhost, API access is disabled,
# and the firewall is left unchanged unless explicitly enabled. On an upgrade it
# keeps existing settings untouched. To get the old interactive flow back, set
# SUI_AUTO=0 (or n). Examples after reviewing this file:
#   sudo ./install.sh             # auto (default)
#   SUI_AUTO=0 sudo ./install.sh  # interactive
SUI_AUTO="${SUI_AUTO:-1}"
SUI_REPO="${SUI_REPO:-gffd01/diandian}"
SUI_ENABLE_API_TOKEN="${SUI_ENABLE_API_TOKEN:-0}"
SUI_API_TOKEN_DAYS="${SUI_API_TOKEN_DAYS:-30}"
SUI_OPEN_FIREWALL="${SUI_OPEN_FIREWALL:-0}"
SUI_NODE_PORTS="${SUI_NODE_PORTS:-}"
SUI_ENABLE_TUNING="${SUI_ENABLE_TUNING:-1}"
SUI_PANEL_LISTEN="${SUI_PANEL_LISTEN:-127.0.0.1}"
SUI_SUB_LISTEN="${SUI_SUB_LISTEN:-0.0.0.0}"
install_tmp_dir=""

cleanup_install_tmp() {
    if [[ -n "$install_tmp_dir" && "$install_tmp_dir" == /tmp/s-ui-install.* ]]; then
        rm -rf -- "$install_tmp_dir"
    fi
}
trap cleanup_install_tmp EXIT

is_auto() {
    [[ "$SUI_AUTO" != "0" && "$SUI_AUTO" != "n" && "$SUI_AUTO" != "N" ]]
}

# auto_read VAR DEFAULT PROMPT
# In auto mode: assign DEFAULT to VAR (caller scope) and echo the choice.
# Otherwise behave like the plain `read -rp PROMPT VAR` it replaces.
auto_read() {
    local __av="$1" __ad="$2" __ap="$3"
    if is_auto; then
        printf -v "$__av" '%s' "$__ad"
        echo -e "${yellow}[auto]${plain} ${__ap}${__ad}"
    else
        read -rp "$__ap" "$__av"
    fi
}

# Alphanumeric random string (URL-safe, no base64 specials).
gen_random_string() {
    local length="$1"
    { LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c "$length"; } || true
}

# Is a TCP port currently being listened on? (used to avoid clashing with an
# existing panel such as 3x-ui, whose default sub port is also 2096.)
is_port_in_use() {
    # 整行匹配「:端口 + 空白/行尾」,不按第几列取 —— 不同版本 ss/netstat 列数不一样,
    # 按列取会悄悄失效,而失效表现是「误判端口空闲」、装完照样起不来,比报错更难查。
    # 末尾的边界防止 12096 / 20960 被误判成 2096。
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | grep -qE "[:.]${port}([[:space:]]|$)"
        return
    fi
    if command -v netstat > /dev/null 2>&1; then
        netstat -lnt 2> /dev/null | grep -qE "[:.]${port}([[:space:]]|$)"
        return
    fi
    if command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    fi
    return 1
}

# Echo a free port: prefer $1, else fall back to a random high port. Keeps the
# nice default when it's free, only deviates when something already holds it.
pick_port() {
    local preferred="$1" p
    if ! is_port_in_use "$preferred"; then
        echo "$preferred"
        return
    fi
    for _ in $(seq 1 30); do
        p=$(shuf -i 20000-60000 -n 1)
        if ! is_port_in_use "$p"; then
            echo "$p"
            return
        fi
    done
    echo "$preferred"
}

# On upgrade s-ui was just stopped, so anything still holding our panel/sub port
# is a DIFFERENT process (classically a 3x-ui install also defaulting to sub port
# 2096). Left alone, s-ui crash-loops on "bind: address already in use" and the
# panel 503s. Detect the clash and migrate the affected port to a free one.
resolve_port_clash() {
    local cur_port cur_sub params=""
    cur_port=$(/usr/local/s-ui/sui setting -show 2>/dev/null | grep -i "Panel port:" | grep -oE '[0-9]+' | head -1 || true)
    cur_sub=$(/usr/local/s-ui/sui setting -show 2>/dev/null | grep -i "Sub port:" | grep -oE '[0-9]+' | head -1 || true)
    if [[ -n "$cur_port" ]] && is_port_in_use "$cur_port"; then
        local np=$(pick_port "$cur_port")
        params="$params -port $np"
        echo -e "${red}[auto] Panel port ${cur_port} is already in use by another process; moving the panel to ${np}.${plain}"
    fi
    if [[ -n "$cur_sub" ]] && is_port_in_use "$cur_sub"; then
        local ns=$(pick_port "$cur_sub")
        params="$params -subPort $ns"
        echo -e "${red}[auto] Sub port ${cur_sub} is already in use (another panel? e.g. 3x-ui on 2096); moving subscriptions to ${ns}.${plain}"
    fi
    if [[ -n "$params" ]]; then
        /usr/local/s-ui/sui setting ${params}
        echo -e "${yellow}[auto] Ports changed to avoid a clash. Update any subscription links / bookmarks accordingly.${plain}"
    fi
}

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}Fatal error: ${plain} Please run this script with root privilege \n " && exit 1

# 完整清除入口: sudo ./install.sh purge
# 为什么不复用 s-ui.sh 的卸载:安装被中断时 /usr/bin/s-ui 可能压根没铺下去,
# 那条路走不通。这里只依赖 root,不依赖任何已安装的文件,也不做系统检测 ——
# 检测失败就 exit 的话,最需要清理的机器反而清不了。
if [[ "${1:-}" == "purge" || "${1:-}" == "uninstall" || "${1:-}" == "--purge" ]]; then
    echo -e "${yellow}Removing every trace of s-ui from this system...${plain}"

    # 每一步独立执行、失败不影响后面:装坏的机器上服务和文件往往只存在一部分。
    systemctl stop s-ui >/dev/null 2>&1
    systemctl disable s-ui >/dev/null 2>&1
    # 二进制被删掉后残留的进程会占着端口,先杀干净
    pkill -9 -f '/usr/local/s-ui' >/dev/null 2>&1
    rm -f /etc/systemd/system/s-ui.service
    rm -f /etc/systemd/system/multi-user.target.wants/s-ui.service
    systemctl daemon-reload >/dev/null 2>&1
    systemctl reset-failed >/dev/null 2>&1

    rm -rf /etc/s-ui/
    rm -rf /usr/local/s-ui/
    rm -f /usr/bin/s-ui

    echo -e "${green}Done. s-ui has been completely removed.${plain}"
    echo -e "Reinstall from a reviewed repository checkout with: ${green}sudo ./install.sh${plain}"
    exit 0
fi


# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi
echo "The OS release is: $release"

arch() {
    case "$(uname -m)" in
    x86_64 | x64 | amd64) echo 'amd64' ;;
    i*86 | x86) echo '386' ;;
    armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
    armv7* | armv7 | arm) echo 'armv7' ;;
    armv6* | armv6) echo 'armv6' ;;
    armv5* | armv5) echo 'armv5' ;;
    s390x) echo 's390x' ;;
    *) echo -e "${red}Unsupported CPU architecture.${plain}" && exit 1 ;;
    esac
}

echo "arch: $(arch)"

install_base() {
    case "${release}" in
    centos | almalinux | rocky | oracle)
        yum install -y -q ca-certificates curl tar tzdata coreutils iproute
        ;;
    fedora)
        dnf install -y -q ca-certificates curl tar tzdata coreutils iproute
        ;;
    arch | manjaro | parch)
        pacman -Sy --noconfirm ca-certificates curl tar tzdata coreutils iproute2
        ;;
    opensuse-tumbleweed)
        zypper refresh && zypper -q install -y ca-certificates curl tar timezone coreutils iproute2
        ;;
    *)
        apt-get update && apt-get install -y -q ca-certificates curl tar tzdata coreutils iproute2
        ;;
    esac
}

# Conservative host tuning for high connection counts. It does not promise a
# faster route; it only removes avoidable server-side queue/file-descriptor
# bottlenecks. A separate sysctl file makes the change easy to audit or remove.
apply_network_tuning() {
    [[ "$SUI_ENABLE_TUNING" == "1" ]] || return 0

    cat > /etc/sysctl.d/99-s-ui-network.conf <<'EOF'
fs.file-max = 1048576
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOF

    if modprobe tcp_bbr >/dev/null 2>&1 \
        && sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        cat >> /etc/sysctl.d/99-s-ui-network.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    fi

    sysctl --system >/dev/null 2>&1 || true
}

config_after_install() {
    echo -e "${yellow}Migration... ${plain}"
    /usr/local/s-ui/sui migrate

    # Full-auto mode: no prompts. Fresh install -> random credentials + random
    # panel path; upgrade -> keep existing settings untouched.
    if is_auto; then
        if [[ ! -f "/usr/local/s-ui/db/s-ui.db" ]]; then
            local config_account=$(gen_random_string 10)
            local config_password=$(gen_random_string 12)
            local config_path=$(gen_random_string 15)
            # Pick free ports so we don't clash with an existing panel (e.g. a
            # 3x-ui install already on 2096). Keep the defaults when they're free.
            local config_port=$(pick_port 2095)
            local config_subPort=$(pick_port 2096)
            echo -e "${yellow}[auto] Fresh install: generating random credentials, panel path and free ports...${plain}"
            [[ "$config_port" != "2095" ]] && echo -e "${yellow}[auto] Port 2095 busy, using ${config_port} for the panel.${plain}"
            [[ "$config_subPort" != "2096" ]] && echo -e "${yellow}[auto] Port 2096 busy, using ${config_subPort} for subscriptions.${plain}"
            /usr/local/s-ui/sui setting -listen "${SUI_PANEL_LISTEN}" -port "${config_port}" -path "/${config_path}/" \
                -subListen "${SUI_SUB_LISTEN}" -subPort "${config_subPort}"
            /usr/local/s-ui/sui admin -username "${config_account}" -password "${config_password}"
            # APIv2 is full remote administration, not a read-only monitor.
            # Keep it disabled unless the operator explicitly opts in.
            local config_token=""
            if [[ "$SUI_ENABLE_API_TOKEN" == "1" ]]; then
                config_token=$(/usr/local/s-ui/sui token -desc install -days "$SUI_API_TOKEN_DAYS" 2>/dev/null || true)
            fi
            echo -e "###############################################"
            echo -e "${green}username:${config_account}${plain}"
            echo -e "${green}password:${config_password}${plain}"
            echo -e "${green}panel port:${config_port}${plain}"
            echo -e "${green}panel path:/${config_path}/${plain}"
            echo -e "${green}sub port:${config_subPort}${plain}"
            if [[ "$SUI_PANEL_LISTEN" == "127.0.0.1" || "$SUI_PANEL_LISTEN" == "::1" ]]; then
                echo -e "${yellow}panel access: localhost only (secure default). Use an SSH tunnel or configure HTTPS before public access.${plain}"
            fi
            if [[ -n "$config_token" ]]; then
                echo -e "${green}API token (copy the line below):${plain}"
                echo -e "${config_token}"
            fi
            echo -e "###############################################"
            echo -e "${red}If you forget your login info, type ${green}s-ui${red} on the server for the menu.${plain}"
        else
            echo -e "${yellow}[auto] Upgrade detected: keeping existing settings.${plain}"
            # Guard against a port clash with another panel on the same box.
            resolve_port_clash
            echo -e "###############################################"
            /usr/local/s-ui/sui admin -show 2>/dev/null
            echo -e "${red}If you forget your login info, type ${green}s-ui${red} on the server for the menu.${plain}"
            echo -e "###############################################"
        fi
        return
    fi

    echo -e "${yellow}Install/update finished! For security it's recommended to modify panel settings ${plain}"
    read -p "Do you want to continue with the modification [y/n]? ": config_confirm
    if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
        echo -e "Enter the ${yellow}panel port${plain} (leave blank for existing/default value):"
        read config_port
        echo -e "Enter the ${yellow}panel path${plain} (leave blank for existing/default value):"
        read config_path

        # Sub configuration
        echo -e "Enter the ${yellow}subscription port${plain} (leave blank for existing/default value):"
        read config_subPort
        echo -e "Enter the ${yellow}subscription path${plain} (leave blank for existing/default value):" 
        read config_subPath

        # Set configs
        echo -e "${yellow}Initializing, please wait...${plain}"
        params=""
        [ -z "$config_port" ] || params="$params -port $config_port"
        [ -z "$config_path" ] || params="$params -path $config_path"
        [ -z "$config_subPort" ] || params="$params -subPort $config_subPort"
        [ -z "$config_subPath" ] || params="$params -subPath $config_subPath"
        /usr/local/s-ui/sui setting ${params}

        read -p "Do you want to change admin credentials [y/n]? ": admin_confirm
        if [[ "${admin_confirm}" == "y" || "${admin_confirm}" == "Y" ]]; then
            # First admin credentials
            read -p "Please set up your username:" config_account
            read -rsp "Please set up your password:" config_password
            echo

            # Set credentials
            echo -e "${yellow}Initializing, please wait...${plain}"
            /usr/local/s-ui/sui admin -username "$config_account" -password "$config_password"
        else
            echo -e "${yellow}Your current admin credentials: ${plain}"
            /usr/local/s-ui/sui admin -show
        fi
    else
        echo -e "${red}cancel...${plain}"
        if [[ ! -f "/usr/local/s-ui/db/s-ui.db" ]]; then
            local usernameTemp=$(head -c 6 /dev/urandom | base64)
            local passwordTemp=$(head -c 6 /dev/urandom | base64)
            /usr/local/s-ui/sui admin -username ${usernameTemp} -password ${passwordTemp}
            local config_token=""
            if [[ "$SUI_ENABLE_API_TOKEN" == "1" ]]; then
                config_token=$(/usr/local/s-ui/sui token -desc install -days "$SUI_API_TOKEN_DAYS" 2>/dev/null || true)
            fi
            echo -e "this is a fresh installation,will generate random login info for security concerns:"
            echo -e "###############################################"
            echo -e "${green}username:${usernameTemp}${plain}"
            echo -e "${green}password:${passwordTemp}${plain}"
            if [[ -n "$config_token" ]]; then
                echo -e "${green}API token (copy the line below):${plain}"
                echo -e "${config_token}"
            fi
            echo -e "###############################################"
            echo -e "${red}if you forgot your login info,you can type ${green}s-ui${red} for configuration menu${plain}"
        else
            echo -e "${red} this is your upgrade,will keep old settings,if you forgot your login info,you can type ${green}s-ui${red} for configuration menu${plain}"
        fi
    fi
}

# Best-effort: open the panel/sub ports and the node port range in the host
# firewall so nodes are reachable out of the box. Full-auto only.
open_firewall() {
    [[ "$SUI_OPEN_FIREWALL" == "1" ]] || {
        echo -e "${yellow}[secure] Host firewall was not changed. Open only the ports you actually use.${plain}"
        return 0
    }
    local panel_port sub_port
    panel_port=$(/usr/local/s-ui/sui setting -show 2>/dev/null | grep -i "Panel port:" | grep -oE '[0-9]+' | head -1 || true)
    sub_port=$(/usr/local/s-ui/sui setting -show 2>/dev/null | grep -i "Sub port:" | grep -oE '[0-9]+' | head -1 || true)
    if command -v ufw > /dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if [[ "$SUI_PANEL_LISTEN" != "127.0.0.1" && "$SUI_PANEL_LISTEN" != "::1" ]]; then
            [[ -n "$panel_port" ]] && ufw allow "${panel_port}/tcp" > /dev/null 2>&1
        fi
        [[ -n "$sub_port" ]] && ufw allow "${sub_port}/tcp" > /dev/null 2>&1
        if [[ -n "$SUI_NODE_PORTS" ]]; then
            IFS=',' read -ra node_ports <<< "$SUI_NODE_PORTS"
            for p in "${node_ports[@]}"; do
                [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( p >= 1 && p <= 65535 )) || continue
                ufw allow "${p}/tcp" > /dev/null 2>&1
                ufw allow "${p}/udp" > /dev/null 2>&1
            done
        fi
        ufw reload > /dev/null 2>&1
        echo -e "${green}[secure] Firewall opened only for the panel, subscription and explicitly supplied node ports.${plain}"
    elif command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state > /dev/null 2>&1; then
        if [[ "$SUI_PANEL_LISTEN" != "127.0.0.1" && "$SUI_PANEL_LISTEN" != "::1" ]]; then
            [[ -n "$panel_port" ]] && firewall-cmd --permanent --add-port="${panel_port}/tcp" > /dev/null 2>&1
        fi
        [[ -n "$sub_port" ]] && firewall-cmd --permanent --add-port="${sub_port}/tcp" > /dev/null 2>&1
        if [[ -n "$SUI_NODE_PORTS" ]]; then
            IFS=',' read -ra node_ports <<< "$SUI_NODE_PORTS"
            for p in "${node_ports[@]}"; do
                [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( p >= 1 && p <= 65535 )) || continue
                firewall-cmd --permanent --add-port="${p}/tcp" > /dev/null 2>&1
                firewall-cmd --permanent --add-port="${p}/udp" > /dev/null 2>&1
            done
        fi
        firewall-cmd --reload > /dev/null 2>&1
        echo -e "${green}[secure] Firewall opened only for the panel, subscription and explicitly supplied node ports.${plain}"
    fi
}

prepare_services() {
    if [[ -f "/etc/systemd/system/sing-box.service" ]]; then
        echo -e "${yellow}Stopping sing-box service... ${plain}"
        systemctl stop sing-box
        rm -f /usr/local/s-ui/bin/sing-box /usr/local/s-ui/bin/runSingbox.sh /usr/local/s-ui/bin/signal
    fi
    if [[ -e "/usr/local/s-ui/bin" ]]; then
        echo -e "###############################################################"
        echo -e "${green}/usr/local/s-ui/bin${red} directory exists yet!"
        echo -e "Please check the content and delete it manually after migration ${plain}"
        echo -e "###############################################################"
    fi
    systemctl daemon-reload
}

# Download only from GitHub over verified TLS and require the release checksum.
# A gzip-format check alone cannot detect a malicious replacement archive.
# Usage: download_release OUT_FILE GITHUB_URL CHECKSUM_URL ASSET_NAME
download_release() {
    local out="$1" gh_url="$2" checksum_url="$3" asset_name="$4"
    local sums expected
    sums=$(mktemp)
    if ! curl --fail --show-error --location --retry 3 --proto '=https' --tlsv1.2 -o "$out" "$gh_url"; then
        rm -f "$out" "$sums"
        return 1
    fi
    if ! curl --fail --show-error --location --retry 3 --proto '=https' --tlsv1.2 -o "$sums" "$checksum_url"; then
        rm -f "$out" "$sums"
        return 1
    fi
    expected=$(awk -v name="$asset_name" '$2 == name || $2 == "*" name { print $1; exit }' "$sums")
    [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || {
        echo -e "${red}No valid SHA256 entry was found for ${asset_name}.${plain}"
        rm -f "$out" "$sums"
        return 1
    }
    if ! printf '%s  %s\n' "$expected" "$out" | sha256sum --check --status \
        || ! tar -tzf "$out" > /dev/null; then
        rm -f "$out" "$sums"
        return 1
    fi
    rm -f "$sums"
}

install_s-ui() {
    install_tmp_dir=$(mktemp -d /tmp/s-ui-install.XXXXXX)
    chmod 0700 "$install_tmp_dir"
    cd "$install_tmp_dir"

    if [ $# == 0 ]; then
        last_version=$(curl --fail --silent --show-error --location "https://api.github.com/repos/${SUI_REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
        # Fall back to the most recent release (covers prerelease-only repos:
        # /releases/latest skips prereleases, /releases lists everything).
        if [[ -z "$last_version" ]]; then
            last_version=$(curl --fail --silent --show-error --location "https://api.github.com/repos/${SUI_REPO}/releases" 2>/dev/null | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
        fi
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}Failed to fetch s-ui version, it maybe due to Github API restrictions, please try it later${plain}"
            exit 1
        fi
        echo -e "Got s-ui latest version: ${last_version}, beginning the installation..."
        asset_name="s-ui-linux-$(arch).tar.gz"
        release_base="https://github.com/${SUI_REPO}/releases/download/${last_version}"
        if ! download_release "${install_tmp_dir}/${asset_name}" "${release_base}/${asset_name}" "${release_base}/SHA256SUMS" "$asset_name"; then
            echo -e "${red}Verified download failed. The installer will not use an untrusted mirror or unsigned archive.${plain}"
            exit 1
        fi
    else
        last_version=$1
        asset_name="s-ui-linux-$(arch).tar.gz"
        release_base="https://github.com/${SUI_REPO}/releases/download/${last_version}"
        url="${release_base}/${asset_name}"
        echo -e "Beginning the install s-ui v$1"
        if ! download_release "${install_tmp_dir}/${asset_name}" "${url}" "${release_base}/SHA256SUMS" "$asset_name"; then
            echo -e "${red}Verified download of s-ui v$1 failed.${plain}"
            exit 1
        fi
    fi

    if [[ -e /usr/local/s-ui/ ]]; then
        systemctl stop s-ui
    fi

    tar --extract --gzip --file "$asset_name" --no-same-owner --no-same-permissions
    [[ -f s-ui/sui && -f s-ui/s-ui.sh && -f s-ui/s-ui.service && -f s-ui/install.sh ]] || {
        echo -e "${red}Release archive is missing required files.${plain}"
        exit 1
    }

    chmod +x s-ui/sui s-ui/s-ui.sh
    cp s-ui/s-ui.sh /usr/bin/s-ui
    cp -rf s-ui /usr/local/
    cp -f s-ui/*.service /etc/systemd/system/
    cd /
    cleanup_install_tmp
    install_tmp_dir=""

    config_after_install
    open_firewall
    apply_network_tuning
    prepare_services

    systemctl enable s-ui --now

    echo -e "${green}s-ui ${last_version}${plain} installation finished, it is up and running now..."
    echo -e "You may access the Panel with following URL(s):${green}"
    /usr/local/s-ui/sui uri
    echo -e "${plain}"
    echo -e ""
    s-ui help
}

echo -e "${green}Executing...${plain}"
install_base
if (( $# > 0 )); then
    install_s-ui "$1"
else
    install_s-ui
fi
