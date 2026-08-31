#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

function LOGD() {
    echo -e "${yellow}[调试] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[错误] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[信息] $* ${plain}"
}

[[ $EUID -ne 0 ]] && LOGE "必须使用 root 用户运行此脚本！\n" && exit 1

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

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -p "$1 [默认 $2]: " temp
        if [[ x"${temp}" == x"" ]]; then
            temp=$2
        fi
    else
        read -p "$1 [y/n]: " temp
    fi
    if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "是否重启 ${1} 服务" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车键返回主菜单：${plain}" && read temp
    show_menu
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/gffd01/diandian/main/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    confirm "更新会重新安装最新版本，但不会丢失面板数据，是否继续" "n"
    if [[ $? != 0 ]]; then
        LOGE "操作已取消"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/gffd01/diandian/main/install.sh)
    if [[ $? == 0 ]]; then
        LOGI "更新完成，面板已自动重启"
        exit 0
    fi
}

custom_version() {
    echo "请输入面板版本号（例如 0.0.1）："
    read panel_version

    if [ -z "$panel_version" ]; then
        echo "版本号不能为空，操作已退出。"
    exit 1
    fi

    download_link="https://raw.githubusercontent.com/gffd01/diandian/main/install.sh"

    install_command="bash <(curl -Ls $download_link) $panel_version"

    echo "正在下载并安装面板版本 $panel_version……"
    eval $install_command
}

uninstall() {
    confirm "确定要卸载面板吗" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    systemctl stop s-ui
    systemctl disable s-ui
    if [[ -x /usr/local/s-ui/network-acceleration.sh ]]; then
        /usr/local/s-ui/network-acceleration.sh purge || \
            LOGE "网络加速回滚未完全成功，需要手动检查"
    fi
    # Kill anything still running from a deleted binary so the port frees up.
    pkill -9 -f '/usr/local/s-ui' 2>/dev/null
    rm -f /etc/systemd/system/s-ui.service
    rm -f /etc/systemd/system/multi-user.target.wants/s-ui.service
    systemctl daemon-reload
    systemctl reset-failed
    rm -rf /etc/s-ui/
    rm -rf /usr/local/s-ui/
    # The menu script itself is /usr/bin/s-ui; remove it too so `s-ui` is gone
    # after uninstall (the running copy lives in memory, so this is safe).
    rm -f /usr/bin/s-ui

    echo ""
    echo -e "${green}卸载完成：程序、数据库、系统服务和 S-UI 菜单脚本均已删除。${plain}"
    echo ""

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

reset_admin() {
    echo "不建议长期使用默认管理员账号和密码。"
    confirm "确定要把管理员账号和密码恢复为默认值吗" "n"
    if [[ $? == 0 ]]; then
        /usr/local/s-ui/sui admin -reset
    fi
    before_show_menu
}

set_admin() {
    echo "用户名和密码请避免使用脚本难以处理的特殊字符。"
    read -p "请输入管理员用户名：" config_account
    read -p "请输入管理员密码：" config_password
    /usr/local/s-ui/sui admin -username ${config_account} -password ${config_password}
    before_show_menu
}

show_api_token() {
    # Print the central-management APIv2 token. Without -new this reuses the
    # existing token (idempotent), so viewing it never piles up new tokens.
    local token=$(/usr/local/s-ui/sui token -desc menu 2>/dev/null)
    if [[ -n "$token" ]]; then
        echo -e "${green}API Token（请复制下一行）：${plain}"
        echo -e "${token}"
    fi
}

view_admin() {
    /usr/local/s-ui/sui admin -show
    show_api_token
    before_show_menu
}

reset_setting() {
    confirm "确定要把面板设置恢复为默认值吗" "n"
    if [[ $? == 0 ]]; then
        /usr/local/s-ui/sui setting -reset
    fi
    before_show_menu
}

set_setting() {
    echo -e "请输入${yellow}面板端口${plain}（留空保持当前值或默认值）："
    read config_port
    echo -e "请输入${yellow}面板路径${plain}（留空保持当前值或默认值）："
    read config_path

    echo -e "请输入${yellow}订阅端口${plain}（留空保持当前值或默认值）："
    read config_subPort
    echo -e "请输入${yellow}订阅路径${plain}（留空保持当前值或默认值）："
    read config_subPath

    echo -e "${yellow}正在保存设置，请稍候……${plain}"
    params=""
    [ -z "$config_port" ] || params="$params -port $config_port"
    [ -z "$config_path" ] || params="$params -path $config_path"
    [ -z "$config_subPort" ] || params="$params -subPort $config_subPort"
    [ -z "$config_subPath" ] || params="$params -subPath $config_subPath"
    /usr/local/s-ui/sui setting ${params}
    before_show_menu
}

view_setting() {
    /usr/local/s-ui/sui setting -show
    view_uri
    show_api_token
    before_show_menu
}

view_uri() {
    info=$(/usr/local/s-ui/sui uri)
    if [[ $? != 0 ]]; then
        LOGE "获取面板访问地址失败"
        before_show_menu
    fi
    LOGI "可通过以下地址访问面板："
    echo -e "${green}${info}${plain}"
}

start() {
    check_status $1
    if [[ $? == 0 ]]; then
        echo ""
        LOGI "${1} 已在运行，无需重复启动；如有需要请选择重启。"
    else
        systemctl start $1
        sleep 2
        check_status $1
        if [[ $? == 0 ]]; then
            LOGI "${1} 启动成功"
        else
            LOGE "${1} 启动失败或启动时间超过两秒，请稍后查看日志。"
        fi
    fi

    if [[ $# == 1 ]]; then
        before_show_menu
    fi
}

stop() {
    check_status $1
    if [[ $? == 1 ]]; then
        echo ""
        LOGI "${1} 已停止，无需重复操作。"
    else
        systemctl stop $1
        sleep 2
        check_status
        if [[ $? == 1 ]]; then
            LOGI "${1} 已成功停止"
        else
            LOGE "${1} 停止失败或停止时间超过两秒，请稍后查看日志。"
        fi
    fi

    if [[ $# == 1 ]]; then
        before_show_menu
    fi
}

restart() {
    systemctl restart $1
    sleep 2
    check_status $1
    if [[ $? == 0 ]]; then
        LOGI "${1} 重启成功"
    else
        LOGE "${1} 重启失败或启动时间超过两秒，请稍后查看日志。"
    fi
    if [[ $# == 1 ]]; then
        before_show_menu
    fi
}

status() {
    systemctl status s-ui -l
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    systemctl enable $1
    if [[ $? == 0 ]]; then
        LOGI "已设置 ${1} 开机自动启动"
    else
        LOGE "设置 ${1} 开机自动启动失败"
    fi

    if [[ $# == 1 ]]; then
        before_show_menu
    fi
}

disable() {
    systemctl disable $1
    if [[ $? == 0 ]]; then
        LOGI "已取消 ${1} 开机自动启动"
    else
        LOGE "取消 ${1} 开机自动启动失败"
    fi

    if [[ $# == 1 ]]; then
        before_show_menu
    fi
}

show_log() {
    journalctl -u $1.service -e --no-pager -f
    if [[ $# == 1 ]]; then
        before_show_menu
    fi
}

update_shell() {
    wget -O /usr/bin/s-ui -N --no-check-certificate https://github.com/gffd01/diandian/raw/main/s-ui.sh
    if [[ $? != 0 ]]; then
        echo ""
        LOGE "菜单脚本下载失败，请检查服务器能否连接 GitHub。"
        before_show_menu
    else
        chmod +x /usr/bin/s-ui
        LOGI "菜单脚本更新成功，请重新运行 s-ui。" && exit 0
    fi
}

check_status() {
    if [[ ! -f "/etc/systemd/system/$1.service" ]]; then
        return 2
    fi
    temp=$(systemctl status "$1" | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
    if [[ x"${temp}" == x"running" ]]; then
        return 0
    else
        return 1
    fi
}

check_enabled() {
    temp=$(systemctl is-enabled $1)
    if [[ x"${temp}" == x"enabled" ]]; then
        return 0
    else
        return 1
    fi
}

check_uninstall() {
    check_status s-ui
    if [[ $? != 2 ]]; then
        echo ""
        LOGE "面板已经安装，请勿重复安装。"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status s-ui
    if [[ $? == 2 ]]; then
        echo ""
        LOGE "请先安装面板。"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status $1
    case $? in
    0)
        echo -e "${1} 状态：${green}运行中${plain}"
        show_enable_status $1
        ;;
    1)
        echo -e "${1} 状态：${yellow}未运行${plain}"
        show_enable_status $1
        ;;
    2)
        echo -e "${1} 状态：${red}未安装${plain}"
        ;;
    esac
}

show_enable_status() {
    check_enabled $1
    if [[ $? == 0 ]]; then
        echo -e "${1} 开机自启：${green}已开启${plain}"
    else
        echo -e "${1} 开机自启：${red}未开启${plain}"
    fi
}

check_s-ui_status() {
    count=$(ps -ef | grep "sui" | grep -v "grep" | wc -l)
    if [[ count -ne 0 ]]; then
        return 0
    else
        return 1
    fi
}

show_s-ui_status() {
    check_s-ui_status
    if [[ $? == 0 ]]; then
        echo -e "S-UI 状态：${green}运行中${plain}"
    else
        echo -e "S-UI 状态：${red}未运行${plain}"
    fi
}

run_acceleration() {
    local action="${1:-status}"
    local module="/usr/local/s-ui/network-acceleration.sh"
    if [[ ! -x "$module" ]]; then
        LOGE "缺少网络加速模块，请先运行 s-ui update。"
        return 1
    fi
    "$module" "$action"
}

acceleration_menu() {
    echo -e "${green}当前网络加速状态：${plain}"
    run_acceleration status || true
    echo ""
    echo -e "${green}\t1.${plain} 开启 BBR + fq"
    echo -e "${green}\t2.${plain} 恢复加速前的网络设置"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -p "请选择：" choice
    case "$choice" in
    0)
        show_menu
        ;;
    1)
        run_acceleration enable
        before_show_menu
        ;;
    2)
        run_acceleration rollback
        before_show_menu
        ;;
    *)
        LOGE "选项无效"
        before_show_menu
        ;;
    esac
}

install_acme() {
    cd ~
    LOGI "正在安装 acme.sh……"
    curl https://get.acme.sh | sh
    if [ $? -ne 0 ]; then
        LOGE "acme.sh 安装失败"
        return 1
    else
        LOGI "acme.sh 安装成功"
    fi
    return 0
}

ssl_cert_issue_main() {
    echo -e "${green}\t1.${plain} 申请 SSL 证书"
    echo -e "${green}\t2.${plain} 吊销证书"
    echo -e "${green}\t3.${plain} 强制续签证书"
    echo -e "${green}\t4.${plain} 生成自签名证书"
    read -p "请选择：" choice
    case "$choice" in
        1) ssl_cert_issue ;;
        2) 
            local domain=""
            read -p "请输入需要吊销证书的域名：" domain
            ~/.acme.sh/acme.sh --revoke -d ${domain}
            LOGI "证书已吊销"
            ;;
        3)
            local domain=""
            read -p "请输入需要强制续签证书的域名：" domain
            ~/.acme.sh/acme.sh --renew -d ${domain} --force ;;
        4)
            generate_self_signed_cert
            ;;
        *) echo "选项无效" ;;
    esac
}

ssl_cert_issue() {
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        echo "未找到 acme.sh，准备自动安装。"
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "acme.sh 安装失败，请查看日志。"
            exit 1
        fi
    fi
    case "${release}" in
    ubuntu | debian | armbian)
        apt update && apt install socat -y
        ;;
    centos | almalinux | rocky | oracle)
        yum -y update && yum -y install socat
        ;;
    fedora)
        dnf -y update && dnf -y install socat
        ;;
    arch | manjaro | parch)
        pacman -Sy --noconfirm socat
        ;;
    *)
        echo -e "${red}暂不支持当前操作系统，请手动安装所需软件包。${plain}\n"
        exit 1
        ;;
    esac
    if [ $? -ne 0 ]; then
        LOGE "socat 安装失败，请查看日志。"
        exit 1
    else
        LOGI "socat 安装成功"
    fi

    local domain=""
    read -p "请输入域名：" domain
    LOGD "正在检查域名：${domain}"
    local currentCert=$(~/.acme.sh/acme.sh --list | tail -1 | awk '{print $1}')

    if [ ${currentCert} == ${domain} ]; then
        local certInfo=$(~/.acme.sh/acme.sh --list)
        LOGE "当前目录已经存在证书，不能重复申请；现有证书信息如下："
        LOGI "$certInfo"
        exit 1
    else
        LOGI "域名检查通过，可以开始申请证书。"
    fi

    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    local WebPort=80
    read -p "请输入申请证书使用的端口（默认 80）：" WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        LOGE "输入的端口 ${WebPort} 无效，将使用默认端口。"
    fi
    LOGI "将使用端口 ${WebPort} 申请证书，请确认该端口已开放。"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d ${domain} --standalone --httpport ${WebPort}
    if [ $? -ne 0 ]; then
        LOGE "证书申请失败，请查看日志。"
        rm -rf ~/.acme.sh/${domain}
        exit 1
    else
        LOGI "证书申请成功，正在安装……"
    fi
    ~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem

    if [ $? -ne 0 ]; then
        LOGE "证书安装失败，操作退出。"
        rm -rf ~/.acme.sh/${domain}
        exit 1
    else
        LOGI "证书安装成功，正在开启自动续签……"
    fi

    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        LOGE "自动续签设置失败，证书信息如下："
        ls -lah cert/*
        chmod 755 $certPath/*
        exit 1
    else
        LOGI "自动续签设置成功，证书信息如下："
        ls -lah cert/*
        chmod 755 $certPath/*
    fi
}

ssl_cert_issue_CF() {
    echo -E ""
    LOGD "******Cloudflare 证书管理******"
    echo "1) 申请新证书"
    echo "2) 强制续签现有证书"
    echo "3) 返回主菜单"
    read -p "请输入选项 [1-3]：" choice

    certPath="/root/cert-CF"

    case $choice in
        1|2)
            force_flag=""
            if [ "$choice" -eq 2 ]; then
                force_flag="--force"
                echo "正在强制重新签发 SSL 证书……"
            else
                echo "正在申请 SSL 证书……"
            fi
            
            LOGD "******使用说明******"
            LOGI "此脚本需要以下信息："
            LOGI "1. Cloudflare 注册邮箱"
            LOGI "2. Cloudflare Global API Key"
            LOGI "3. 已通过 Cloudflare DNS 解析到当前服务器的域名"
            LOGI "4. 证书默认保存到 /root/cert"
            confirm "以上信息是否确认无误" "y"
            if [ $? -eq 0 ]; then
                if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
                    echo "未找到 acme.sh，正在安装……"
                    install_acme
                    if [ $? -ne 0 ]; then
                        LOGE "acme.sh 安装失败，请查看日志。"
                        exit 1
                    fi
                fi

                CF_Domain=""
                if [ ! -d "$certPath" ]; then
                    mkdir -p $certPath
                else
                    rm -rf $certPath
                    mkdir -p $certPath
                fi

                LOGD "请设置域名："
                read -p "请输入域名：" CF_Domain
                LOGD "当前域名：${CF_Domain}"

                CF_GlobalKey=""
                CF_AccountEmail=""
                LOGD "请设置 API Key："
                read -p "请输入 API Key：" CF_GlobalKey
                LOGD "API Key 已记录。"

                LOGD "请设置 Cloudflare 注册邮箱："
                read -p "请输入邮箱：" CF_AccountEmail
                LOGD "当前注册邮箱：${CF_AccountEmail}"

                ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
                if [ $? -ne 0 ]; then
                    LOGE "设置默认证书机构 Let's Encrypt 失败，操作退出。"
                    exit 1
                fi

                export CF_Key="${CF_GlobalKey}"
                export CF_Email="${CF_AccountEmail}"

                ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${CF_Domain} -d *.${CF_Domain} $force_flag --log
                if [ $? -ne 0 ]; then
                    LOGE "证书签发失败，操作退出。"
                    exit 1
                else
                    LOGI "证书签发成功，正在安装……"
                fi

                mkdir -p ${certPath}/${CF_Domain}
                if [ $? -ne 0 ]; then
                    LOGE "无法创建目录：${certPath}/${CF_Domain}"
                    exit 1
                fi

                ~/.acme.sh/acme.sh --installcert -d ${CF_Domain} -d *.${CF_Domain} \
                    --fullchain-file ${certPath}/${CF_Domain}/fullchain.pem \
                    --key-file ${certPath}/${CF_Domain}/privkey.pem

                if [ $? -ne 0 ]; then
                    LOGE "证书安装失败，操作退出。"
                    exit 1
                else
                    LOGI "证书安装成功，正在开启自动续签……"
                fi

                ~/.acme.sh/acme.sh --upgrade --auto-upgrade
                if [ $? -ne 0 ]; then
                    LOGE "自动续签设置失败，操作退出。"
                    exit 1
                else
                    LOGI "证书已安装，并已开启自动续签。"
                    ls -lah ${certPath}/${CF_Domain}
                    chmod 755 ${certPath}/${CF_Domain}
                fi
            fi
            show_menu
            ;;
        3)
            echo "正在返回……"
            show_menu
            ;;
        *)
            echo "选项无效，请重新选择。"
            show_menu
            ;;
    esac
}

generate_self_signed_cert() {
    cert_dir="/etc/sing-box"
    mkdir -p "$cert_dir"
    LOGI "请选择证书密钥类型："
    echo -e "${green}\t1.${plain} Ed25519（推荐）"
    echo -e "${green}\t2.${plain} RSA 2048"
    echo -e "${green}\t3.${plain} RSA 4096"
    echo -e "${green}\t4.${plain} ECDSA prime256v1"
    echo -e "${green}\t5.${plain} ECDSA secp384r1"
    read -p "请输入选项 [1-5，默认 1]：" cert_type
    cert_type=${cert_type:-1}

    case "$cert_type" in
        1)
            algo="ed25519"
            key_opt="-newkey ed25519"
            ;;
        2)
            algo="rsa"
            key_opt="-newkey rsa:2048"
            ;;
        3)
            algo="rsa"
            key_opt="-newkey rsa:4096"
            ;;
        4)
            algo="ecdsa"
            key_opt="-newkey ec -pkeyopt ec_paramgen_curve:prime256v1"
            ;;
        5)
            algo="ecdsa"
            key_opt="-newkey ec -pkeyopt ec_paramgen_curve:secp384r1"
            ;;
        *)
            algo="ed25519"
            key_opt="-newkey ed25519"
            ;;
    esac

    LOGI "正在生成自签名证书（$algo）……"
    sudo openssl req -x509 -nodes -days 3650 $key_opt \
        -keyout "${cert_dir}/self.key" \
        -out "${cert_dir}/self.crt" \
        -subj "/CN=myserver"
    if [[ $? -eq 0 ]]; then
        sudo chmod 600 "${cert_dir}/self."*
        LOGI "自签名证书生成成功！"
        LOGI "证书路径：${cert_dir}/self.crt"
        LOGI "私钥路径：${cert_dir}/self.key"
    else
        LOGE "自签名证书生成失败。"
    fi
    before_show_menu
}

show_usage() {
    echo -e "S-UI 管理命令说明"
    echo -e "------------------------------------------"
    echo -e "可用命令："
    echo -e "s-ui                - 打开管理菜单"
    echo -e "s-ui start          - 启动 S-UI"
    echo -e "s-ui stop           - 停止 S-UI"
    echo -e "s-ui restart        - 重启 S-UI"
    echo -e "s-ui status         - 查看 S-UI 状态"
    echo -e "s-ui enable         - 开启开机自启"
    echo -e "s-ui disable        - 关闭开机自启"
    echo -e "s-ui log            - 查看运行日志"
    echo -e "s-ui update         - 更新 S-UI"
    echo -e "s-ui install        - 安装 S-UI"
    echo -e "s-ui uninstall      - 卸载 S-UI"
    echo -e "s-ui accel status   - 查看 TCP 加速状态"
    echo -e "s-ui accel enable   - 开启 BBR + fq"
    echo -e "s-ui accel rollback - 恢复加速前的网络设置"
    echo -e "s-ui help           - 查看命令说明"
    echo -e "------------------------------------------"
}

show_menu() {
  echo -e "
  ${green}S-UI 管理菜单${plain}
————————————————————————————————
  ${green}0.${plain} 退出
————————————————————————————————
  ${green}1.${plain} 安装 S-UI
  ${green}2.${plain} 更新 S-UI
  ${green}3.${plain} 安装指定版本
  ${green}4.${plain} 卸载 S-UI
————————————————————————————————
  ${green}5.${plain} 恢复默认管理员账号和密码
  ${green}6.${plain} 设置管理员账号和密码
  ${green}7.${plain} 查看管理员信息
————————————————————————————————
  ${green}8.${plain} 恢复默认面板设置
  ${green}9.${plain} 设置面板参数
  ${green}10.${plain} 查看面板设置
————————————————————————————————
  ${green}11.${plain} 启动 S-UI
  ${green}12.${plain} 停止 S-UI
  ${green}13.${plain} 重启 S-UI
  ${green}14.${plain} 查看 S-UI 状态
  ${green}15.${plain} 查看 S-UI 日志
  ${green}16.${plain} 开启开机自启
  ${green}17.${plain} 关闭开机自启
————————————————————————————————
  ${green}18.${plain} 网络加速管理（BBR + fq）
  ${green}19.${plain} SSL 证书管理
  ${green}20.${plain} Cloudflare SSL 证书
————————————————————————————————
  ${green}21.${plain} 更新管理菜单脚本
————————————————————————————————
 "
    show_status s-ui
    echo && read -p "请输入选项 [0-21]：" num

    case "${num}" in
    0)
        exit 0
        ;;
    1)
        check_uninstall && install
        ;;
    2)
        check_install && update
        ;;
    3)
        check_install && custom_version
        ;;
    4)
        # 卸载不设前置检查:装到一半失败时面板状态就是「未安装」,
        # 再挡一道就成了死锁 —— 残留文件反而永远清不掉。
        uninstall
        ;;
    5)
        check_install && reset_admin
        ;;
    6)
        check_install && set_admin
        ;;
    7)
        check_install && view_admin
        ;;
    8)
        check_install && reset_setting
        ;;
    9)
        check_install && set_setting
        ;;
    10)
        check_install && view_setting
        ;;
    11)
        check_install && start s-ui
        ;;
    12)
        check_install && stop s-ui
        ;;
    13)
        check_install && restart s-ui
        ;;
    14)
        check_install && status s-ui
        ;;
    15)
        check_install && show_log s-ui
        ;;
    16)
        check_install && enable s-ui
        ;;
    17)
        check_install && disable s-ui
        ;;
    18)
        acceleration_menu
        ;;
    19)
        ssl_cert_issue_main
        ;;
    20)
        ssl_cert_issue_CF
        ;;
    21)
        update_shell
        ;;
    *)
        LOGE "请输入正确的选项 [0-21]"
        ;;
    esac
}

if [[ $# > 0 ]]; then
    case $1 in
    "start")
        check_install 0 && start s-ui 0
        ;;
    "stop")
        check_install 0 && stop s-ui 0
        ;;
    "restart")
        check_install 0 && restart s-ui 0
        ;;
    "status")
        check_install 0 && status 0
        ;;
    "enable")
        check_install 0 && enable s-ui 0
        ;;
    "disable")
        check_install 0 && disable s-ui 0
        ;;
    "log")
        check_install 0 && show_log s-ui 0
        ;;
    "update")
        check_install 0 && update 0
        ;;
    "install")
        check_uninstall 0 && install 0
        ;;
    "uninstall")
        uninstall 0
        ;;
    "accel")
        run_acceleration "${2:-status}"
        ;;
    *) show_usage ;;
    esac
else
    show_menu
fi
