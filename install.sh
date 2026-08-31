#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# Full-auto is the DEFAULT install mode: every command runs start-to-finish with
# no prompts. On a fresh install it generates random admin credentials + a random
# panel path + free ports + an API token and opens the firewall, then prints the
# access info; on an upgrade it keeps existing settings untouched. TCP BBR + fq
# acceleration is enabled by default, unless it was explicitly rolled back on a
# previous install. Set SUI_ACCEL=0 to keep it disabled. To get the old
# interactive flow back, set SUI_AUTO=0 (or n). Examples:
#   bash <(curl -Ls https://raw.githubusercontent.com/gffd01/diandian/main/install.sh)            # auto (default)
#   SUI_AUTO=0 bash <(curl -Ls https://raw.githubusercontent.com/gffd01/diandian/main/install.sh) # interactive
#   SUI_ACCEL=0 bash <(curl -Ls https://raw.githubusercontent.com/gffd01/diandian/main/install.sh) # no BBR + fq
SUI_AUTO="${SUI_AUTO:-1}"
SUI_ACCEL="${SUI_ACCEL:-auto}"

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
        echo -e "${yellow}[自动]${plain} ${__ap}${__ad}"
    else
        read -rp "$__ap" "$__av"
    fi
}

# Alphanumeric random string (URL-safe, no base64 specials).
gen_random_string() {
    local length="$1"
    LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c "$length"
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
    cur_port=$(/usr/local/s-ui/sui setting -show 2>/dev/null | grep -i "Panel port:" | grep -oE '[0-9]+' | head -1)
    cur_sub=$(/usr/local/s-ui/sui setting -show 2>/dev/null | grep -i "Sub port:" | grep -oE '[0-9]+' | head -1)
    if [[ -n "$cur_port" ]] && is_port_in_use "$cur_port"; then
        local np=$(pick_port "$cur_port")
        params="$params -port $np"
        echo -e "${red}[自动] 面板端口 ${cur_port} 已被其他程序占用，已改为 ${np}。${plain}"
    fi
    if [[ -n "$cur_sub" ]] && is_port_in_use "$cur_sub"; then
        local ns=$(pick_port "$cur_sub")
        params="$params -subPort $ns"
        echo -e "${red}[自动] 订阅端口 ${cur_sub} 已被其他程序占用，已改为 ${ns}。${plain}"
    fi
    if [[ -n "$params" ]]; then
        /usr/local/s-ui/sui setting ${params}
        echo -e "${yellow}[自动] 为避免端口冲突，地址已发生变化，请更新订阅链接或书签。${plain}"
    fi
}

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain}请使用 root 用户运行此脚本。\n" && exit 1

# 一键彻底清除入口: bash <(curl -Ls .../install.sh) purge
# 为什么不复用 s-ui.sh 的卸载:安装被中断时 /usr/bin/s-ui 可能压根没铺下去,
# 那条路走不通。这里只依赖 root,不依赖任何已安装的文件,也不做系统检测 ——
# 检测失败就 exit 的话,最需要清理的机器反而清不了。
if [[ "$1" == "purge" || "$1" == "uninstall" || "$1" == "--purge" ]]; then
    echo -e "${yellow}正在彻底删除系统中的 S-UI……${plain}"

    # Restore the exact network values saved by the optional acceleration
    # module before its files and state are removed.
    if [[ -x /usr/local/s-ui/network-acceleration.sh ]]; then
        /usr/local/s-ui/network-acceleration.sh purge || \
            echo -e "${yellow}警告：网络加速回滚未完全成功，需要手动检查。${plain}"
    fi

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

    echo -e "${green}完成，S-UI 已彻底删除。${plain}"
    echo -e "重新安装命令：${green}bash <(curl -Ls https://raw.githubusercontent.com/gffd01/diandian/main/install.sh)${plain}"
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
    echo "无法识别当前操作系统，请检查系统环境。" >&2
    exit 1
fi
echo "当前系统：$release"

arch() {
    case "$(uname -m)" in
    x86_64 | x64 | amd64) echo 'amd64' ;;
    i*86 | x86) echo '386' ;;
    armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
    armv7* | armv7 | arm) echo 'armv7' ;;
    armv6* | armv6) echo 'armv6' ;;
    armv5* | armv5) echo 'armv5' ;;
    s390x) echo 's390x' ;;
    *) echo -e "${red}不支持当前 CPU 架构！${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

echo "CPU 架构：$(arch)"

install_base() {
    case "${release}" in
    centos | almalinux | rocky | oracle)
        yum -y update && yum install -y -q wget curl tar tzdata
        ;;
    fedora)
        dnf -y update && dnf install -y -q wget curl tar tzdata
        ;;
    arch | manjaro | parch)
        pacman -Syu && pacman -Syu --noconfirm wget curl tar tzdata
        ;;
    opensuse-tumbleweed)
        zypper refresh && zypper -q install -y wget curl tar timezone
        ;;
    *)
        apt-get update && apt-get install -y -q wget curl tar tzdata
        ;;
    esac
}

config_after_install() {
    echo -e "${yellow}正在迁移数据……${plain}"
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
            echo -e "${yellow}[自动] 全新安装：正在生成随机账号、密码、面板路径和可用端口……${plain}"
            [[ "$config_port" != "2095" ]] && echo -e "${yellow}[自动] 端口 2095 已占用，面板改用 ${config_port}。${plain}"
            [[ "$config_subPort" != "2096" ]] && echo -e "${yellow}[自动] 端口 2096 已占用，订阅服务改用 ${config_subPort}。${plain}"
            /usr/local/s-ui/sui setting -port "${config_port}" -path "/${config_path}/" -subPort "${config_subPort}"
            /usr/local/s-ui/sui admin -username "${config_account}" -password "${config_password}"
            # Generate an APIv2 token so this server can be managed from another
            # panel out of the box (central management).
            local config_token=$(/usr/local/s-ui/sui token -desc install 2>/dev/null)
            echo -e "###############################################"
            echo -e "${green}管理员用户名：${config_account}${plain}"
            echo -e "${green}管理员密码：${config_password}${plain}"
            echo -e "${green}面板端口：${config_port}${plain}"
            echo -e "${green}面板路径：/${config_path}/${plain}"
            echo -e "${green}订阅端口：${config_subPort}${plain}"
            if [[ -n "$config_token" ]]; then
                echo -e "${green}API Token（请复制下一行）：${plain}"
                echo -e "${config_token}"
            fi
            echo -e "###############################################"
            echo -e "${red}如果忘记登录信息，请在服务器运行 ${green}s-ui${red} 打开管理菜单。${plain}"
        else
            echo -e "${yellow}[自动] 检测到升级，将保留现有设置。${plain}"
            # Guard against a port clash with another panel on the same box.
            resolve_port_clash
            local up_token=$(/usr/local/s-ui/sui token -desc upgrade 2>/dev/null)
            echo -e "###############################################"
            /usr/local/s-ui/sui admin -show 2>/dev/null
            if [[ -n "$up_token" ]]; then
                echo -e "${green}API Token（请复制下一行）：${plain}"
                echo -e "${up_token}"
            fi
            echo -e "${red}如果忘记登录信息，请在服务器运行 ${green}s-ui${red} 打开管理菜单。${plain}"
            echo -e "###############################################"
        fi
        return
    fi

    echo -e "${yellow}安装或更新完成！为确保安全，建议检查并修改面板设置。${plain}"
    read -p "是否现在修改 [y/n]：" config_confirm
    if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
        echo -e "请输入${yellow}面板端口${plain}（留空保持当前值或默认值）："
        read config_port
        echo -e "请输入${yellow}面板路径${plain}（留空保持当前值或默认值）："
        read config_path

        # Sub configuration
        echo -e "请输入${yellow}订阅端口${plain}（留空保持当前值或默认值）："
        read config_subPort
        echo -e "请输入${yellow}订阅路径${plain}（留空保持当前值或默认值）："
        read config_subPath

        # Set configs
        echo -e "${yellow}正在保存设置，请稍候……${plain}"
        params=""
        [ -z "$config_port" ] || params="$params -port $config_port"
        [ -z "$config_path" ] || params="$params -path $config_path"
        [ -z "$config_subPort" ] || params="$params -subPort $config_subPort"
        [ -z "$config_subPath" ] || params="$params -subPath $config_subPath"
        /usr/local/s-ui/sui setting ${params}

        read -p "是否修改管理员账号和密码 [y/n]：" admin_confirm
        if [[ "${admin_confirm}" == "y" || "${admin_confirm}" == "Y" ]]; then
            # First admin credentials
            read -p "请输入管理员用户名：" config_account
            read -p "请输入管理员密码：" config_password

            # Set credentials
            echo -e "${yellow}正在保存设置，请稍候……${plain}"
            /usr/local/s-ui/sui admin -username ${config_account} -password ${config_password}
        else
            echo -e "${yellow}当前管理员信息：${plain}"
            /usr/local/s-ui/sui admin -show
        fi
    else
        echo -e "${red}已取消修改。${plain}"
        if [[ ! -f "/usr/local/s-ui/db/s-ui.db" ]]; then
            local usernameTemp=$(head -c 6 /dev/urandom | base64)
            local passwordTemp=$(head -c 6 /dev/urandom | base64)
            /usr/local/s-ui/sui admin -username ${usernameTemp} -password ${passwordTemp}
            # Mint an APIv2 token even on a plain (non-auto) fresh install, so this
            # panel can be managed centrally out of the box. (qs31)
            local config_token=$(/usr/local/s-ui/sui token -desc install 2>/dev/null)
            echo -e "这是全新安装，将自动生成随机登录信息："
            echo -e "###############################################"
            echo -e "${green}管理员用户名：${usernameTemp}${plain}"
            echo -e "${green}管理员密码：${passwordTemp}${plain}"
            if [[ -n "$config_token" ]]; then
                echo -e "${green}API Token（请复制下一行）：${plain}"
                echo -e "${config_token}"
            fi
            echo -e "###############################################"
            echo -e "${red}如果忘记登录信息，请运行 ${green}s-ui${red} 打开管理菜单。${plain}"
        else
            echo -e "${red}这是升级操作，已保留原设置；如忘记登录信息，请运行 ${green}s-ui${red}。${plain}"
        fi
    fi
}

# Best-effort: open the panel/sub ports and the node port range in the host
# firewall so nodes are reachable out of the box. Full-auto only.
open_firewall() {
    is_auto || return 0
    local panel_port sub_port
    panel_port=$(/usr/local/s-ui/sui setting -show 2>/dev/null | grep -i "Panel port:" | grep -oE '[0-9]+' | head -1)
    sub_port=$(/usr/local/s-ui/sui setting -show 2>/dev/null | grep -i "Sub port:" | grep -oE '[0-9]+' | head -1)
    if command -v ufw > /dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        [[ -n "$panel_port" ]] && ufw allow "${panel_port}/tcp" > /dev/null 2>&1
        [[ -n "$sub_port" ]] && ufw allow "${sub_port}/tcp" > /dev/null 2>&1
        ufw allow 10000:60000/tcp > /dev/null 2>&1
        ufw allow 10000:60000/udp > /dev/null 2>&1
        ufw reload > /dev/null 2>&1
        echo -e "${green}[自动] ufw 防火墙已放行：${panel_port}、${sub_port}、10000-60000 TCP/UDP。${plain}"
    elif command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state > /dev/null 2>&1; then
        [[ -n "$panel_port" ]] && firewall-cmd --permanent --add-port="${panel_port}/tcp" > /dev/null 2>&1
        [[ -n "$sub_port" ]] && firewall-cmd --permanent --add-port="${sub_port}/tcp" > /dev/null 2>&1
        firewall-cmd --permanent --add-port=10000-60000/tcp > /dev/null 2>&1
        firewall-cmd --permanent --add-port=10000-60000/udp > /dev/null 2>&1
        firewall-cmd --reload > /dev/null 2>&1
        echo -e "${green}[自动] firewalld 已放行：${panel_port}、${sub_port}、10000-60000 TCP/UDP。${plain}"
    fi
}

# Acceleration is default-on for fresh installs. "auto" also preserves a user's
# explicit rollback across future upgrades, while SUI_ACCEL=1 and SUI_ACCEL=0
# force the requested state.
configure_acceleration() {
    local module="/usr/local/s-ui/network-acceleration.sh"
    if [[ ! -x "$module" ]]; then
        echo -e "${yellow}[网络加速] 当前安装包不包含加速模块，将保持原网络设置并继续安装。${plain}"
        return 0
    fi

    case "${SUI_ACCEL}" in
    0 | n | N | no | NO | false | FALSE | off | OFF)
        "$module" rollback || \
            echo -e "${yellow}[网络加速] 回滚未完全成功，S-UI 将继续安装。${plain}"
        ;;
    1 | y | Y | yes | YES | true | TRUE | on | ON)
        "$module" enable || \
            echo -e "${yellow}[网络加速] 当前系统无法启用 BBR + fq，S-UI 将继续正常安装。${plain}"
        ;;
    auto | "")
        "$module" auto || \
            echo -e "${yellow}[网络加速] 当前系统无法启用 BBR + fq，S-UI 将继续正常安装。${plain}"
        ;;
    *)
        echo -e "${yellow}[网络加速] 无法识别 SUI_ACCEL=${SUI_ACCEL}，将使用默认自动模式。${plain}"
        "$module" auto || true
        ;;
    esac
}

prepare_services() {
    if [[ -f "/etc/systemd/system/sing-box.service" ]]; then
        echo -e "${yellow}正在停止 sing-box 服务……${plain}"
        systemctl stop sing-box
        rm -f /usr/local/s-ui/bin/sing-box /usr/local/s-ui/bin/runSingbox.sh /usr/local/s-ui/bin/signal
    fi
    if [[ -e "/usr/local/s-ui/bin" ]]; then
        echo -e "###############################################################"
        echo -e "${green}/usr/local/s-ui/bin${red} 目录已经存在！"
        echo -e "请检查其中的内容，并在迁移完成后手动清理。${plain}"
        echo -e "###############################################################"
    fi
    systemctl daemon-reload
}

# Download a GitHub release asset with retry + mirror fallback. A CN VPS often
# reaches github.com (so the version fetch above succeeds) but then gets its
# release-CDN connection reset mid-transfer -- the classic wget "Cannot write to
# '/tmp/...tar.gz' (Success)." followed by "Downloading s-ui failed". So we retry
# the direct URL, then fall back through public GitHub proxy mirrors, and verify
# the result is a real gzip each time so a mirror's HTML error page can't slip
# through as a "successful" download.
# Usage: download_release OUT_FILE GITHUB_URL
download_release() {
    local out="$1" gh_url="$2" src label
    local sources=(
        "$gh_url"
        "https://ghfast.top/$gh_url"
        "https://gh-proxy.com/$gh_url"
        "https://ghproxy.net/$gh_url"
    )
    for src in "${sources[@]}"; do
        if [[ "$src" == "$gh_url" ]]; then
            echo -e "${yellow}正在从 GitHub 直接下载……${plain}"
        else
            label="${src#https://}"; label="${label%%/*}"
            echo -e "${yellow}直接下载失败，正在尝试镜像：${label}${plain}"
        fi
        if wget --no-check-certificate --timeout=30 --tries=2 -O "$out" "$src" \
            && tar -tzf "$out" > /dev/null 2>&1; then
            return 0
        fi
        rm -f "$out"
    done
    return 1
}

install_s-ui() {
    cd /tmp/

    if [ $# == 0 ]; then
        last_version=$(curl -Ls "https://api.github.com/repos/gffd01/diandian/releases/latest" | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
        # Fall back to the most recent release (covers prerelease-only repos:
        # /releases/latest skips prereleases, /releases lists everything).
        if [[ -z "$last_version" ]]; then
            last_version=$(curl -Ls "https://api.github.com/repos/gffd01/diandian/releases" | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
        fi
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}获取 S-UI 版本失败，可能是 GitHub API 限制，请稍后重试。${plain}"
            exit 1
        fi
        echo -e "已获取 S-UI 最新版本：${last_version}，开始安装……"
        if ! download_release /tmp/s-ui-linux-$(arch).tar.gz "https://github.com/gffd01/diandian/releases/download/${last_version}/s-ui-linux-$(arch).tar.gz"; then
            echo -e "${red}直接下载和镜像下载均失败，请确认服务器能访问 GitHub，并检查 /tmp 剩余空间。${plain}"
            exit 1
        fi
    else
        last_version=$1
        url="https://github.com/gffd01/diandian/releases/download/${last_version}/s-ui-linux-$(arch).tar.gz"
        echo -e "开始安装 S-UI v$1……"
        if ! download_release /tmp/s-ui-linux-$(arch).tar.gz "${url}"; then
            echo -e "${red}S-UI v$1 下载失败，请确认该版本存在。${plain}"
            exit 1
        fi
    fi

    if [[ -e /usr/local/s-ui/ ]]; then
        systemctl stop s-ui
    fi

    tar zxvf s-ui-linux-$(arch).tar.gz
    rm s-ui-linux-$(arch).tar.gz -f

    chmod +x s-ui/sui s-ui/s-ui.sh
    [[ -f s-ui/network-acceleration.sh ]] && chmod +x s-ui/network-acceleration.sh
    cp s-ui/s-ui.sh /usr/bin/s-ui
    cp -rf s-ui /usr/local/
    cp -f s-ui/*.service /etc/systemd/system/
    rm -rf s-ui

    config_after_install
    open_firewall
    prepare_services
    configure_acceleration

    systemctl enable s-ui --now

    echo -e "${green}S-UI ${last_version}${plain} 安装完成，服务已启动。"
    echo -e "可通过以下地址访问面板：${green}"
    /usr/local/s-ui/sui uri
    echo -e "${plain}"
    echo -e ""
    s-ui help
}

echo -e "${green}正在执行……${plain}"
install_base
install_s-ui $1
