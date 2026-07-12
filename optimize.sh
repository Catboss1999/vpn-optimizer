#!/bin/bash
# ============================================================
# VPN Optimizer - 一键开启 BBR + 安装 Hysteria2
# 适用于任意 VPS，无需域名，解决网络延迟高的问题
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

if [ -z "$BASH_VERSION" ]; then
    echo "[ERROR] 请用 bash 运行此脚本：bash optimize.sh"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    error "请用 root 用户运行此脚本：sudo bash optimize.sh"
    exit 1
fi

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
# 第 2 步：生成自签证书（无需域名）
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 2 步：生成自签证书${PLAIN}"
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
# 第 3 步：生成随机密码和端口
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 3 步：生成配置${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 生成随机密码
HY2_PASSWORD=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)

# 检测已监听的端口，避免冲突
LISTENING_PORTS=$(ss -tuln 2>/dev/null | grep -o ':[0-9]\+' | tr -d ':' | sort -u | tr '\n' ' ')

# 生成随机端口，避开所有已用端口
while true; do
    HY2_PORT=$(shuf -i 20000-50000 -n 1)
    if ! echo "$LISTENING_PORTS" | grep -qw "$HY2_PORT"; then
        break
    fi
done

info "生成随机密码：$HY2_PASSWORD"
info "生成随机端口：$HY2_PORT"

# ============================================================
# 第 4 步：安装 Hysteria2
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 4 步：安装 Hysteria2${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 检查是否已安装
if command -v hysteria &> /dev/null; then
    ok "Hysteria2 已安装"
    HY2_VERSION=$(hysteria version 2>/dev/null | head -1 | grep -o 'v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' || echo "")
    if [[ -n "$HY2_VERSION" ]]; then
        info "当前版本：$HY2_VERSION"
    fi
else
    info "正在安装 Hysteria2..."

    # 获取最新版本
    HY2_LATEST=$(curl -sL https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null | \
        sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p' | head -1)

    if [[ -z "$HY2_LATEST" ]]; then
        HY2_LATEST="v2.6.0"
        warn "无法获取最新版本，使用默认版本 $HY2_LATEST"
    fi

    HY2_VERSION="${HY2_LATEST#v}"
    info "下载版本：$HY2_LATEST"

    # 下载并安装
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  HY2_ARCH="amd64" ;;
        aarch64) HY2_ARCH="arm64" ;;
        armv7l)  HY2_ARCH="armv7" ;;
        *)       HY2_ARCH="amd64" ;;
    esac

    HY2_TAR="hysteria-linux-${HY2_ARCH}.tar.gz"
    HY2_URL="https://github.com/apernet/hysteria/releases/download/${HY2_LATEST}/${HY2_TAR}"

    cd /tmp
    curl -fsSL -o "$HY2_TAR" "$HY2_URL" 2>/dev/null || {
        error "下载 Hysteria2 失败，请检查网络"
        exit 1
    }

    tar -xzf "$HY2_TAR" 2>/dev/null
    mv -f hysteria /usr/local/bin/hysteria 2>/dev/null
    chmod +x /usr/local/bin/hysteria
    rm -f "$HY2_TAR" 2>/dev/null

    if command -v hysteria &> /dev/null; then
        ok "Hysteria2 安装完成"
    else
        error "Hysteria2 安装失败"
        exit 1
    fi
fi

# ============================================================
# 第 5 步：生成 Hysteria2 配置文件
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 5 步：生成 Hysteria2 配置${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

HY2_CONFIG_DIR="/etc/hysteria"
mkdir -p "$HY2_CONFIG_DIR"

cat > "$HY2_CONFIG_DIR/config.yaml" << HY2_CONFIG
listen: :${HY2_PORT}

# 使用自签证书
tls:
  cert: ${CERT_DIR}/hy2_server.crt
  key: ${CERT_DIR}/hy2_server.key
  sniGuard: www.bing.com

# 认证
auth:
  type: password
  password: ${HY2_PASSWORD}

# 传输层设置
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 16777216
  maxConnReceiveWindow: 16777216
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false

# 允许不安全连接（用于自签证书）
masquerade:
  type: string
  string: "Hello World"
  listenHTTPS: :${HY2_PORT}

HY2_CONFIG

ok "Hysteria2 配置文件已生成：$HY2_CONFIG_DIR/config.yaml"

# ============================================================
# 第 6 步：创建 systemd 服务
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 6 步：创建 systemd 服务${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

cat > /etc/systemd/system/hysteria-server.service << SYSTEMD_EOF
[Unit]
Description=Hysteria2 Server Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

systemctl daemon-reload
systemctl enable hysteria-server.service
systemctl start hysteria-server.service
sleep 2

if systemctl is-active --quiet hysteria-server.service; then
    ok "Hysteria2 服务已启动并设为开机自启"
else
    warn "Hysteria2 服务启动失败，尝试手动启动..."
    systemctl restart hysteria-server.service
    sleep 2
    if systemctl is-active --quiet hysteria-server.service; then
        ok "Hysteria2 服务已启动"
    else
        error "Hysteria2 服务启动失败，请检查日志：journalctl -u hysteria-server -n 50"
        exit 1
    fi
fi

# ============================================================
# 第 7 步：开放防火墙端口
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 7 步：开放防火墙端口${PLAIN}"
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
# 完成：输出配置信息
# ============================================================
echo ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}  配置完成！${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo ""

# 获取服务器公网 IP
SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 ip.sb 2>/dev/null || echo "你的服务器IP")

# 一键导入链接
HY2_LINK="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=www.bing.com#Hysteria2-BBR"

echo -e "${YELLOW}一键导入链接（复制到客户端即可）：${PLAIN}"
echo ""
echo -e "  ${CYAN}${HY2_LINK}${PLAIN}"
echo ""

echo -e "${YELLOW}客户端配置说明：${PLAIN}"
echo ""
echo -e "  ${GREEN}Shadowrocket (iOS)：${PLAIN}"
echo -e "    1. 打开 Shadowrocket → 右上角 + → 类型选 Hysteria2"
echo -e "    2. 服务器填：${CYAN}$SERVER_IP${PLAIN}"
echo -e "    3. 端口填：${CYAN}$HY2_PORT${PLAIN}"
echo -e "    4. 密码填：${CYAN}$HY2_PASSWORD${PLAIN}"
echo -e "    5. SNI 填：${CYAN}www.bing.com${PLAIN}"
echo -e "    6. 允许不安全 勾选"
echo -e "    7. 保存 → 连接"
echo ""
echo -e "  ${GREEN}v2rayN / Nekoray (Windows)：${PLAIN}"
echo -e "    1. 服务器 → 添加自定义服务器 → 协议选 Hysteria2"
echo -e "    2. 地址填：${CYAN}$SERVER_IP${PLAIN}"
echo -e "    3. 端口填：${CYAN}$HY2_PORT${PLAIN}"
echo -e "    4. 密码填：${CYAN}$HY2_PASSWORD${PLAIN}"
echo -e "    5. SNI 填：${CYAN}www.bing.com${PLAIN}"
echo -e "    6. 允许不安全 勾选"
echo -e "    7. 保存 → 连接"
echo ""
echo -e "  ${GREEN}Clash Meta (Mac/Windows/Linux)：${PLAIN}"
echo -e "    直接复制下面配置片段到配置文件："
echo ""

cat << CLASH_EOF
  - name: "Hysteria2-BBR"
    type: hysteria2
    server: $SERVER_IP
    port: $HY2_PORT
    password: $HY2_PASSWORD
    sni: www.bing.com
    skip-cert-verify: true

CLASH_EOF

echo -e "${YELLOW}配置摘要：${PLAIN}"
echo -e "  服务器 IP：  ${CYAN}$SERVER_IP${PLAIN}"
echo -e "  端口：       ${CYAN}$HY2_PORT (UDP)${PLAIN}"
echo -e "  密码：       ${CYAN}$HY2_PASSWORD${PLAIN}"
echo -e "  SNI：        ${CYAN}www.bing.com${PLAIN}"
echo -e "  证书：       ${CYAN}${CERT_DIR}/hy2_server.crt${PLAIN}"
echo -e "  密钥：       ${CYAN}${CERT_DIR}/hy2_server.key${PLAIN}"
echo ""
echo -e "${YELLOW}服务管理：${PLAIN}"
echo -e "  查看状态：  ${CYAN}systemctl status hysteria-server${PLAIN}"
echo -e "  查看日志：  ${CYAN}journalctl -u hysteria-server -f${PLAIN}"
echo -e "  重启服务：  ${CYAN}systemctl restart hysteria-server${PLAIN}"
echo -e "  停止服务：  ${CYAN}systemctl stop hysteria-server${PLAIN}"
echo ""
echo -e "${YELLOW}提示：${PLAIN}"
echo -e "  - 原来的 3x-ui 节点（VLESS+Reality 等）仍然可用，两个协议互不干扰"
echo -e "  - Hysteria2 使用 UDP 协议，如果延迟仍然高，可能是 VPS 到国内的线路问题"
echo -e "  - 需要 CN2 GIA 等优质线路才能从根本上降低延迟"
echo ""
