#!/bin/bash
# ============================================================
# VPN Optimizer - 一键开启 BBR + 通过 3x-ui 面板添加 Hysteria2
# 适用于已安装 3x-ui 的 VPS，解决网络延迟高的问题
# Hysteria2 节点直接在 3x-ui 面板中管理，支持流量统计和分享链接
# 兼容 Ubuntu 18.04+ / Debian 10+ / CentOS 7+
# GitHub: https://github.com/Catboss1999/vpn-optimizer
# ============================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 输出函数
info()  { echo -e "${CYAN}[INFO]${PLAIN} $1"; }
ok()    { echo -e "${GREEN}[OK]${PLAIN} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $1"; }

# ============================================================
# 前置检查
# ============================================================

# 强制用 bash 运行（脚本用了 bash 特有语法）
if [ -z "$BASH_VERSION" ]; then
    echo "[ERROR] 请用 bash 运行此脚本：bash optimize.sh"
    exit 1
fi

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    error "请用 root 用户运行此脚本：sudo bash optimize.sh"
    exit 1
fi

# 检测系统
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    OS_VERSION=$VERSION_ID
else
    error "无法检测操作系统，脚本仅支持 Debian/Ubuntu/CentOS"
    exit 1
fi

info "检测到系统：$OS $OS_VERSION"

# ============================================================
# 第 0 步：自动安装依赖工具
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 0 步：检查并安装依赖工具${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 安装必要的工具（curl、openssl、sqlite3、ca-certificates、jq）
NEED_INSTALL=0
for cmd in curl openssl sqlite3 jq; do
    if ! command -v $cmd &> /dev/null; then
        NEED_INSTALL=1
        info "缺少工具：$cmd"
    fi
done

if [[ $NEED_INSTALL -eq 1 ]]; then
    info "正在自动安装缺失的依赖工具..."

    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl openssl sqlite3 ca-certificates jq >/dev/null 2>&1
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        yum install -y curl openssl sqlite ca-certificates jq >/dev/null 2>&1
    else
        warn "未知系统类型 $OS，尝试用 apt 安装..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl openssl sqlite3 ca-certificates jq >/dev/null 2>&1
    fi

    # 验证安装结果
    INSTALL_OK=1
    for cmd in curl openssl sqlite3 jq; do
        if ! command -v $cmd &> /dev/null; then
            error "安装 $cmd 失败"
            INSTALL_OK=0
        fi
    done

    if [[ $INSTALL_OK -eq 1 ]]; then
        ok "依赖工具安装完成"
    else
        error "部分依赖工具安装失败，请手动安装后重试"
        exit 1
    fi
else
    ok "依赖工具已就绪"
fi

# ============================================================
# 第 1 步：确保内核支持 BBR（不支持则自动升级）
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 1 步：检查内核版本并开启 BBR${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 检查内核版本（BBR 需要 4.9+）
KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
KERNEL_MAJOR=$(echo $KERNEL_VERSION | cut -d. -f1)
KERNEL_MINOR=$(echo $KERNEL_VERSION | cut -d. -f2)

NEED_KERNEL_UPGRADE=0
if [[ $KERNEL_MAJOR -lt 4 ]] || [[ $KERNEL_MAJOR -eq 4 && $KERNEL_MINOR -lt 9 ]]; then
    NEED_KERNEL_UPGRADE=1
fi

if [[ $NEED_KERNEL_UPGRADE -eq 1 ]]; then
    info "当前内核 $KERNEL_VERSION 过低（BBR 需要 4.9+），正在自动升级内核..."

    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y --install-recommends linux-image-generic linux-headers-generic >/dev/null 2>&1

        info "内核已升级，需要重启服务器才能生效"
        info "将在 5 秒后自动重启服务器，重启后请重新运行此脚本"
        info "脚本会自动检测到内核已升级，跳过升级步骤继续执行"

        cat > /etc/cron.d/vpn-optimizer-autorun << CRON_EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
@reboot root sleep 30 && bash <(curl -fsSL https://raw.githubusercontent.com/Catboss1999/vpn-optimizer/main/optimize.sh) >> /var/log/vpn-optimizer.log 2>&1
CRON_EOF

        ok "已设置重启后自动继续运行脚本"
        echo ""
        warn "服务器即将重启..."
        sleep 5
        reboot
        exit 0
    else
        warn "CentOS/RHEL 系统内核升级较复杂，尝试安装 ELRepo..."
        if [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
            yum install -y elrepo-release >/dev/null 2>&1
            yum --enablerepo=elrepo-kernel install -y kernel-ml >/dev/null 2>&1
            grub2-set-default 0 >/dev/null 2>&1

            cat > /etc/cron.d/vpn-optimizer-autorun << CRON_EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
@reboot root sleep 30 && bash <(curl -fsSL https://raw.githubusercontent.com/Catboss1999/vpn-optimizer/main/optimize.sh) >> /var/log/vpn-optimizer.log 2>&1
CRON_EOF

            ok "已设置重启后自动继续运行脚本"
            echo ""
            warn "服务器即将重启..."
            sleep 5
            reboot
            exit 0
        fi
    fi
fi

# 清理自动运行 cron 任务（如果存在，说明是重启后继续运行的）
if [[ -f /etc/cron.d/vpn-optimizer-autorun ]]; then
    rm -f /etc/cron.d/vpn-optimizer-autorun
    info "检测到重启后自动运行，继续执行..."
fi

# 检查是否已开启 BBR
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
if echo "$CURRENT_CC" | grep -q "bbr"; then
    ok "BBR 已经开启"
else
    info "正在开启 BBR..."

    modprobe tcp_bbr 2>/dev/null || true

    if ! grep -q "tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null; then
        echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || \
            echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true
    fi

    if [[ ! -f /etc/sysctl.conf.bak ]]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak
    fi

    if ! grep -q "net.core.default_qdisc" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi

    sysctl -p >/dev/null 2>&1

    NEW_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if echo "$NEW_CC" | grep -q "bbr"; then
        ok "BBR 已开启：$NEW_CC"
    else
        sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
        FINAL_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
        if echo "$FINAL_CC" | grep -q "bbr"; then
            ok "BBR 已强制开启：$FINAL_CC"
        else
            warn "BBR 开启失败（内核可能不支持），不影响后续 Hysteria2 的使用"
        fi
    fi
fi

# ============================================================
# 第 2 步：检查 3x-ui 面板状态
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 2 步：检查 3x-ui 面板状态${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 检查 3x-ui 是否已安装
if ! command -v x-ui &> /dev/null; then
    error "未检测到 3x-ui 面板，请先安装 3x-ui"
    info "安装命令：bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
    exit 1
fi

ok "3x-ui 面板已安装"

# 检查 3x-ui 服务状态
if ! systemctl is-active --quiet x-ui 2>/dev/null; then
    warn "3x-ui 服务未运行，正在启动..."
    systemctl start x-ui 2>/dev/null
    sleep 2
    if systemctl is-active --quiet x-ui; then
        ok "3x-ui 服务已启动"
    else
        error "3x-ui 服务启动失败，请手动检查：systemctl status x-ui"
        exit 1
    fi
else
    ok "3x-ui 服务运行中"
fi

# 读取 3x-ui 面板配置
info "正在读取 3x-ui 面板配置..."

# 从 x-ui 命令读取面板设置
PANEL_INFO=$(x-ui setting -show true 2>/dev/null || echo "")

# 提取面板端口
PANEL_PORT=$(echo "$PANEL_INFO" | grep -oP 'port:\s*\K\d+' || echo "")
if [[ -z "$PANEL_PORT" ]]; then
    PANEL_PORT=2053
    warn "未能自动读取面板端口，使用默认值：$PANEL_PORT"
fi

# 提取面板路径
PANEL_PATH=$(echo "$PANEL_INFO" | grep -oP 'webBasePath:\s*\K\S+' || echo "")
if [[ -z "$PANEL_PATH" ]]; then
    PANEL_PATH="/"
    warn "未能自动读取面板路径，使用默认值：$PANEL_PATH"
fi

# 提取用户名和密码
PANEL_USER=$(echo "$PANEL_INFO" | grep -oP 'username:\s*\K\S+' || echo "")
PANEL_PASS=$(echo "$PANEL_INFO" | grep -oP 'password:\s*\K\S+' || echo "")

if [[ -z "$PANEL_USER" || -z "$PANEL_PASS" ]]; then
    error "未能读取 3x-ui 面板用户名或密码"
    info "请手动运行 'x-ui setting -show true' 确认面板配置"
    exit 1
fi

# 确保路径以 / 开头且以 / 结尾（用于 URL 拼接）
[[ "$PANEL_PATH" != /* ]] && PANEL_PATH="/$PANEL_PATH"
[[ "$PANEL_PATH" != */ ]] && PANEL_PATH="$PANEL_PATH/"

# 判断面板是否使用 HTTPS
PANEL_CERT=$(echo "$PANEL_INFO" | grep -oP 'certFile:\s*\K\S+' || echo "")
PANEL_KEY=$(echo "$PANEL_INFO" | grep -oP 'keyFile:\s*\K\S+' || echo "")
if [[ -n "$PANEL_CERT" && -n "$PANEL_KEY" && -f "$PANEL_CERT" && -f "$PANEL_KEY" ]]; then
    PANEL_SCHEME="https"
else
    PANEL_SCHEME="http"
fi

PANEL_URL="${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}${PANEL_PATH}"
info "面板地址：$PANEL_URL"
info "面板用户：$PANEL_USER"

# 检查 3x-ui 版本是否支持 Hysteria2
info "正在检查 3x-ui 版本..."
XUI_VERSION=$(x-ui version 2>/dev/null | head -1 | grep -oP 'v?\d+\.\d+\.\d+' || echo "")

if [[ -n "$XUI_VERSION" ]]; then
    info "3x-ui 版本：$XUI_VERSION"
    # 提取主版本号和次版本号
    XUI_MAJOR=$(echo "$XUI_VERSION" | sed 's/v//' | cut -d. -f1)
    XUI_MINOR=$(echo "$XUI_VERSION" | sed 's/v//' | cut -d. -f2)
    # Hysteria2 支持从 2.9.0 开始（2026年4月）
    if [[ $XUI_MAJOR -lt 2 ]] || [[ $XUI_MAJOR -eq 2 && $XUI_MINOR -lt 9 ]]; then
        warn "3x-ui 版本 $XUI_VERSION 可能不支持 Hysteria2（需要 v2.9.0+）"
        warn "建议升级 3x-ui：x-ui update"
        info "继续尝试，如果失败请先升级 3x-ui"
    else
        ok "3x-ui 版本支持 Hysteria2"
    fi
else
    warn "无法读取 3x-ui 版本，继续尝试..."
fi

# ============================================================
# 第 3 步：生成自签证书（无需域名）
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 3 步：生成自签证书${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

CERT_DIR="/root/cert"
mkdir -p "$CERT_DIR"

info "正在生成自签证书（无需域名）..."

openssl ecparam -name prime256v1 -out "$CERT_DIR/hy2_ecparam.tmp" 2>/dev/null
openssl req -x509 -nodes -newkey ec:"$CERT_DIR/hy2_ecparam.tmp" \
    -keyout "$CERT_DIR/hy2_server.key" \
    -out "$CERT_DIR/hy2_server.crt" \
    -subj "/CN=www.bing.com" -days 36500 2>/dev/null
rm -f "$CERT_DIR/hy2_ecparam.tmp"

chmod 644 "$CERT_DIR/hy2_server.crt"
chmod 600 "$CERT_DIR/hy2_server.key"

ok "自签证书已生成（有效期 100 年，CN=www.bing.com）"
info "证书路径：$CERT_DIR/hy2_server.crt"
info "密钥路径：$CERT_DIR/hy2_server.key"

# ============================================================
# 第 4 步：生成随机密码和端口
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 4 步：生成配置${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 生成随机密码
HY2_PASSWORD=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)

# 检测 3x-ui 已使用的 inbound 端口（从数据库读）
USED_PORTS="$PANEL_PORT"
if [[ -f /etc/x-ui/x-ui.db ]]; then
    DB_PORTS=$(sqlite3 /etc/x-ui/x-ui.db "SELECT port FROM inbounds;" 2>/dev/null || echo "")
    if [[ -n "$DB_PORTS" ]]; then
        USED_PORTS="$USED_PORTS $DB_PORTS"
        info "检测到 3x-ui 已用端口：$(echo $DB_PORTS | tr '\n' ' ')"
    fi
fi

# 检测已监听的端口
LISTENING_PORTS=$(ss -tuln 2>/dev/null | grep -oP ':\K\d+' | sort -u | tr '\n' ' ')
if [[ -n "$LISTENING_PORTS" ]]; then
    USED_PORTS="$USED_PORTS $LISTENING_PORTS"
fi

# 生成随机端口，避开所有已用端口
while true; do
    HY2_PORT=$(shuf -i 20000-50000 -n 1)
    if ! echo "$USED_PORTS" | grep -qw "$HY2_PORT"; then
        break
    fi
done

info "生成随机密码：$HY2_PASSWORD"
info "生成随机端口：$HY2_PORT"

# ============================================================
# 第 5 步：开放防火墙端口
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 5 步：开放防火墙端口${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

if command -v ufw &> /dev/null; then
    ufw allow $HY2_PORT/udp >/dev/null 2>&1
    ok "UFW 已放行 UDP $HY2_PORT"
fi

if command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=$HY2_PORT/udp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    ok "Firewalld 已放行 UDP $HY2_PORT"
fi

iptables -C INPUT -p udp --dport $HY2_PORT -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p udp --dport $HY2_PORT -j ACCEPT 2>/dev/null || true
ok "iptables 已放行 UDP $HY2_PORT"

warn "如果你的 VPS 服务商有网页端安全组/防火墙设置，请在那里也放行 UDP $HY2_PORT 端口"
warn "    （这是唯一需要你手动操作的步骤，脚本无法替你操作云服务商网页）"

# ============================================================
# 第 6 步：通过 3x-ui API 添加 Hysteria2 入站
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 6 步：通过 3x-ui 面板添加 Hysteria2 入站${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 登录 3x-ui 面板获取 session cookie
info "正在登录 3x-ui 面板..."

COOKIE_FILE="/tmp/x-ui-cookie-$$"
LOGIN_RESP=$(curl -sk -c "$COOKIE_FILE" -X POST "${PANEL_URL}login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${PANEL_USER}&password=${PANEL_PASS}" 2>/dev/null || echo "")

# 检查登录是否成功
LOGIN_SUCCESS=$(echo "$LOGIN_RESP" | jq -r '.success // false' 2>/dev/null || echo "false")
if [[ "$LOGIN_SUCCESS" != "true" ]]; then
    error "3x-ui 面板登录失败"
    info "请检查面板用户名和密码是否正确"
    info "可通过 'x-ui setting -show true' 查看当前配置"
    rm -f "$COOKIE_FILE"
    exit 1
fi

ok "3x-ui 面板登录成功"

# 构建 Hysteria2 inbound 的 JSON 数据
# 3x-ui 中 Hysteria2 使用 protocol="hysteria"，通过 streamSettings.version=2 区分
info "正在创建 Hysteria2 入站..."

# 构建 settings JSON（包含客户端认证信息）
SETTINGS_JSON=$(cat << EOF
{
    "clients": [
        {
            "auth": "${HY2_PASSWORD}",
            "email": "hy2-user",
            "enable": true,
            "limitIp": 0,
            "totalGB": 0,
            "expiryTime": 0,
            "reset": 0,
            "subId": ""
        }
    ],
    "version": 2,
    "obfs": "",
    "obfsPassword": ""
}
EOF
)

# 构建 streamSettings JSON
# network=hysteria, security=tls, 自签证书
# allowInsecure 在服务端不设（客户端侧设置 insecure=1）
STREAM_JSON=$(cat << EOF
{
    "network": "hysteria",
    "security": "tls",
    "tlsSettings": {
        "serverName": "www.bing.com",
        "minVersion": "1.3",
        "maxVersion": "1.3",
        "cipherSuites": "",
        "certificates": [
            {
                "certificateFile": "${CERT_DIR}/hy2_server.crt",
                "keyFile": "${CERT_DIR}/hy2_server.key",
                "ocspStapling": 3600
            }
        ],
        "alpn": ["h3"],
        "settings": {
            "allowInsecure": true,
            "fingerprint": "chrome"
        }
    },
    "hysteriaSettings": {
        "version": 2,
        "auth": "${HY2_PASSWORD}",
        "udpIdleTimeout": 60
    }
}
EOF
)

# 构建 sniffing JSON
SNIFFING_JSON='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'

# 构建完整的 inbound 请求体
INBOUND_DATA=$(cat << EOF
{
    "up": 0,
    "down": 0,
    "total": 0,
    "remark": "Hysteria2-BBR",
    "enable": true,
    "expiryTime": 0,
    "listen": "",
    "port": ${HY2_PORT},
    "protocol": "hysteria",
    "settings": $(echo "$SETTINGS_JSON" | jq -c .),
    "streamSettings": $(echo "$STREAM_JSON" | jq -c .),
    "sniffing": $(echo "$SNIFFING_JSON" | jq -c .),
    "allocate": "{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":3}"
}
EOF
)

# 发送 API 请求添加 inbound
ADD_RESP=$(curl -sk -b "$COOKIE_FILE" -X POST "${PANEL_URL}panel/api/inbounds/add" \
    -H "Content-Type: application/json" \
    -d "$INBOUND_DATA" 2>/dev/null || echo "")

# 检查是否添加成功
ADD_SUCCESS=$(echo "$ADD_RESP" | jq -r '.success // false' 2>/dev/null || echo "false")

if [[ "$ADD_SUCCESS" == "true" ]]; then
    INBOUND_ID=$(echo "$ADD_RESP" | jq -r '.obj.id // empty' 2>/dev/null || echo "")
    ok "Hysteria2 入站已添加到 3x-ui 面板（ID: $INBOUND_ID）"
else
    error "通过 API 添加 Hysteria2 入站失败"
    error_msg=$(echo "$ADD_RESP" | jq -r '.msg // "未知错误"' 2>/dev/null || echo "未知错误")
    info "错误信息：$error_msg"

    # 如果 API 方式失败，提示用户手动添加
    info ""
    info "API 方式失败，你可以手动在 3x-ui 面板中添加："
    info "  1. 打开 3x-ui 面板网页"
    info "  2. 入站列表 -> 添加入站"
    info "  3. 协议选择 hysteria"
    info "  4. 端口填：$HY2_PORT"
    info "  5. 传输选 hysteria，版本选 2"
    info "  6. 安全选 TLS，证书路径填：$CERT_DIR/hy2_server.crt 和 $CERT_DIR/hy2_server.key"
    info "  7. SNI 填 www.bing.com，勾选 allowInsecure"
    info "  8. 客户端 auth 密码填：$HY2_PASSWORD"
    rm -f "$COOKIE_FILE"
    exit 1
fi

# 重启 x-ui 使配置生效
info "正在重启 3x-ui 服务使配置生效..."
systemctl restart x-ui 2>/dev/null
sleep 3

if systemctl is-active --quiet x-ui; then
    ok "3x-ui 服务已重启"
else
    warn "3x-ui 重启后状态异常，请手动检查：systemctl status x-ui"
fi

# 清理 cookie 文件
rm -f "$COOKIE_FILE"

# ============================================================
# 输出结果
# ============================================================
echo ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}  全部完成！${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo ""

# 获取服务器公网 IP
SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 ip.sb 2>/dev/null || echo "你的服务器IP")

echo -e "${YELLOW}Hysteria2 节点信息（也可在 3x-ui 面板中查看）：${PLAIN}"
echo ""
echo -e "  服务器 IP：  ${CYAN}$SERVER_IP${PLAIN}"
echo -e "  端口：       ${CYAN}$HY2_PORT${PLAIN}"
echo -e "  密码：       ${CYAN}$HY2_PASSWORD${PLAIN}"
echo -e "  SNI：        ${CYAN}www.bing.com${PLAIN}"
echo -e "  跳过验证：   ${CYAN}是（自签证书）${PLAIN}"
echo -e "  协议：       ${CYAN}Hysteria2${PLAIN}"
echo ""

# 生成连接链接
HY2_LINK="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=www.bing.com&alpn=h3#Hysteria2-BBR"

echo -e "${YELLOW}一键导入链接（复制到客户端即可）：${PLAIN}"
echo ""
echo -e "  ${CYAN}${HY2_LINK}${PLAIN}"
echo ""

# 客户端配置说明
echo -e "${YELLOW}客户端配置说明：${PLAIN}"
echo ""
echo -e "  ${GREEN}Shadowrocket (iOS)：${PLAIN}"
echo -e "    类型选 Hysteria2 -> 填 IP + 端口 + 密码"
echo -e "    打开「允许不安全」开关"
echo -e "    SNI 填 www.bing.com"
echo ""
echo -e "  ${GREEN}v2rayN / Nekoray (Windows)：${PLAIN}"
echo -e "    添加 Hysteria2 节点 -> 填 IP + 端口 + 密码"
echo -e "    勾选 AllowInsecure（跳过证书验证）"
echo -e "    SNI 填 www.bing.com"
echo ""
echo -e "  ${GREEN}Clash Meta / mihomo：${PLAIN}"
echo -e "    proxy 类型选 hysteria2"
echo -e "    skip-cert-verify: true"
echo -e "    SNI 填 www.bing.com"
echo ""

# Clash 配置片段
echo -e "${YELLOW}Clash Meta 配置片段（直接复制）：${PLAIN}"
echo ""
cat << CLASH_EOF
  - name: "Hysteria2-BBR"
    type: hysteria2
    server: $SERVER_IP
    port: $HY2_PORT
    password: $HY2_PASSWORD
    sni: www.bing.com
    skip-cert-verify: true
    alpn:
      - h3

CLASH_EOF

echo -e "${YELLOW}提示：${PLAIN}"
echo -e "  - Hysteria2 节点已添加到 3x-ui 面板，可在面板中查看流量、管理客户端"
echo -e "  - 原来的 VLESS+Reality 节点仍然可用，两个协议互不干扰"
echo -e "  - 如果延迟仍然高，可能是 VPS 到国内的线路问题（换 CN2 GIA 线路可解决）"
echo -e "  - 在 3x-ui 面板中可查看节点二维码和分享链接"
echo -e "  - 面板地址：${PANEL_SCHEME}://${SERVER_IP}:${PANEL_PORT}${PANEL_PATH}"
echo ""
