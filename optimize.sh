#!/bin/bash
# ============================================================
# VPN Optimizer - 一键开启 BBR + 生成 Hysteria2 配置
# 适用于已安装 3x-ui 的 VPS，解决网络延迟高的问题
# 脚本完成基础环境配置（BBR/证书/防火墙），
# Hysteria2 入站通过 3x-ui 面板手动添加（脚本会给出详细教程）
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

# 只需要 curl 和 openssl（不再需要 sqlite3/jq）
NEED_INSTALL=0
for cmd in curl openssl; do
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
        apt-get install -y curl openssl ca-certificates >/dev/null 2>&1
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        yum install -y curl openssl ca-certificates >/dev/null 2>&1
    else
        warn "未知系统类型 $OS，尝试用 apt 安装..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl openssl ca-certificates >/dev/null 2>&1
    fi

    # 验证安装结果
    INSTALL_OK=1
    for cmd in curl openssl; do
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

# 读取面板配置（多种方式，确保读到正确值）
info "正在读取 3x-ui 面板配置..."
PANEL_INFO=$(x-ui setting -show true 2>&1 || echo "")

# --- 读取面板端口 ---
# 方式 1：从 x-ui setting 输出解析（用 sed 代替 grep -P，兼容性更好）
PANEL_PORT=$(echo "$PANEL_INFO" | sed -n 's/^port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)

# 方式 2：从监听端口检测 x-ui 进程
if [[ -z "$PANEL_PORT" ]]; then
    PANEL_PORT=$(ss -tlnp 2>/dev/null | grep -i 'x-ui' | head -1 | grep -o ':[0-9]\+' | head -1 | tr -d ':')
fi

# 方式 3：从数据库读取（如果 sqlite3 可用）
if [[ -z "$PANEL_PORT" ]] && command -v sqlite3 &> /dev/null && [[ -f /etc/x-ui/x-ui.db ]]; then
    PANEL_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null | head -1)
fi

if [[ -n "$PANEL_PORT" ]]; then
    ok "面板端口：$PANEL_PORT"
else
    PANEL_PORT=2053
    warn "未能自动读取面板端口，使用默认值：$PANEL_PORT"
fi

# --- 读取面板路径 ---
PANEL_PATH=$(echo "$PANEL_INFO" | sed -n 's/^webBasePath:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
if [[ -z "$PANEL_PATH" ]]; then
    # 从数据库读取
    if command -v sqlite3 &> /dev/null && [[ -f /etc/x-ui/x-ui.db ]]; then
        PANEL_PATH=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null | head -1)
    fi
fi
if [[ -z "$PANEL_PATH" ]]; then
    PANEL_PATH="/"
fi

[[ "$PANEL_PATH" != /* ]] && PANEL_PATH="/$PANEL_PATH"
[[ "$PANEL_PATH" != */ ]] && PANEL_PATH="$PANEL_PATH/"

# --- 判断面板是否使用 HTTPS ---
# x-ui setting 输出中有 "Panel is secure with SSL" 或 "not secure with SSL"
if echo "$PANEL_INFO" | grep -q "secure with SSL" && ! echo "$PANEL_INFO" | grep -q "not secure"; then
    PANEL_SCHEME="https"
else
    PANEL_SCHEME="http"
fi

# --- 检查 3x-ui 版本 ---
info "正在检查 3x-ui 版本..."
XUI_VERSION=$(x-ui version 2>&1 | head -1 | sed -n 's/.*\(v\?[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')

if [[ -n "$XUI_VERSION" ]]; then
    info "3x-ui 版本：$XUI_VERSION"
    XUI_MAJOR=$(echo "$XUI_VERSION" | sed 's/v//' | cut -d. -f1)
    XUI_MINOR=$(echo "$XUI_VERSION" | sed 's/v//' | cut -d. -f2)
    if [[ $XUI_MAJOR -lt 2 ]] || [[ $XUI_MAJOR -eq 2 && $XUI_MINOR -lt 9 ]]; then
        warn "3x-ui 版本 $XUI_VERSION 不支持 Hysteria2（需要 v2.9.0+）"
        warn "请先升级 3x-ui：x-ui update"
        exit 1
    else
        ok "3x-ui 版本支持 Hysteria2"
    fi
else
    warn "无法读取 3x-ui 版本，如果面板中没有 hysteria 协议选项，请升级：x-ui update"
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

# 检测已监听的端口，避免冲突（用 ss 代替 sqlite3，不再依赖数据库）
USED_PORTS="$PANEL_PORT"
LISTENING_PORTS=$(ss -tuln 2>/dev/null | grep -o ':[0-9]\+' | tr -d ':' | sort -u | tr '\n' ' ')
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

# ============================================================
# 第 6 步：输出 3x-ui 面板操作教程
# ============================================================
echo ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}  环境配置完成！${PLAIN}"
echo -e "${GREEN}  以下操作请在 3x-ui 面板中完成${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo ""

# 获取服务器公网 IP
SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 ip.sb 2>/dev/null || echo "你的服务器IP")

# 面板地址
PANEL_ADDR="${PANEL_SCHEME}://${SERVER_IP}:${PANEL_PORT}${PANEL_PATH}"

echo -e "${YELLOW}请在 3x-ui 面板中添加 Hysteria2 入站：${PLAIN}"
echo ""
echo -e "  ${GREEN}1.${PLAIN} 打开面板：${CYAN}${PANEL_ADDR}${PLAIN}"
echo ""
echo -e "  ${GREEN}2.${PLAIN} 左侧菜单点「入站列表」，再点右上角「添加入站」"
echo ""
echo -e "  ${GREEN}3.${PLAIN} 填写基本信息："
echo -e "     ${CYAN}备注${PLAIN}      Hysteria2-BBR"
echo -e "     ${CYAN}协议${PLAIN}      hysteria"
echo -e "     ${CYAN}端口${PLAIN}      ${HY2_PORT}"
echo ""
echo -e "  ${GREEN}4.${PLAIN} 客户端设置："
echo -e "     ${CYAN}密码${PLAIN}      ${HY2_PASSWORD}"
echo -e "     （在 auth/password 字段填入上面这串密码）"
echo ""
echo -e "  ${GREEN}5.${PLAIN} 传输设置："
echo -e "     ${CYAN}版本${PLAIN}      2"
echo ""
echo -e "  ${GREEN}6.${PLAIN} TLS 设置（安全选 tls）："
echo -e "     ${CYAN}SNI${PLAIN}       www.bing.com"
echo -e "     ${CYAN}证书路径${PLAIN}  ${CERT_DIR}/hy2_server.crt"
echo -e "     ${CYAN}密钥路径${PLAIN}  ${CERT_DIR}/hy2_server.key"
echo -e "     ${CYAN}ALPN${PLAIN}      h3"
echo -e "     ${CYAN}允许不安全${PLAIN} 勾选"
echo ""
echo -e "  ${GREEN}7.${PLAIN} 点「添加」保存"
echo ""
echo -e "  ${GREEN}8.${PLAIN} 添加完成后，在入站列表点该节点的二维码图标"
echo -e "     可以扫码导入客户端，也可以复制分享链接"
echo ""

# 预生成的分享链接（和面板生成的等效，方便用户直接复制）
HY2_LINK="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=www.bing.com&alpn=h3#Hysteria2-BBR"

echo -e "${YELLOW}一键导入链接（和面板生成的等效，复制到客户端即可）：${PLAIN}"
echo ""
echo -e "  ${CYAN}${HY2_LINK}${PLAIN}"
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

# 配置摘要
echo -e "${YELLOW}配置摘要（供记录）：${PLAIN}"
echo -e "  服务器 IP：  ${CYAN}$SERVER_IP${PLAIN}"
echo -e "  端口：       ${CYAN}$HY2_PORT (UDP)${PLAIN}"
echo -e "  密码：       ${CYAN}$HY2_PASSWORD${PLAIN}"
echo -e "  SNI：        ${CYAN}www.bing.com${PLAIN}"
echo -e "  证书：       ${CYAN}${CERT_DIR}/hy2_server.crt${PLAIN}"
echo -e "  密钥：       ${CYAN}${CERT_DIR}/hy2_server.key${PLAIN}"
echo -e "  面板地址：   ${CYAN}${PANEL_ADDR}${PLAIN}"
echo ""
echo -e "${YELLOW}提示：${PLAIN}"
echo -e "  - 原来的 VLESS+Reality 节点仍然可用，两个协议互不干扰"
echo -e "  - 如果延迟仍然高，可能是 VPS 到国内的线路问题（换 CN2 GIA 线路可解决）"
echo -e "  - 如果面板中没有 hysteria 协议选项，说明 3x-ui 版本太旧，运行 x-ui update 升级"
echo ""
