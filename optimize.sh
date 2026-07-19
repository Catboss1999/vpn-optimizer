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

# 保存脚本到本地（用于内核升级后重启续跑，不依赖 CDN）
SCRIPT_LOCAL="/root/optimize.sh"
curl -fsSL "https://cdn.jsdelivr.net/gh/Catboss1999/vpn-optimizer/main/optimize.sh" -o "$SCRIPT_LOCAL" 2>/dev/null || true
chmod +x "$SCRIPT_LOCAL" 2>/dev/null || true

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
# 第 0 步：系统更新 + 安装依赖
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 0 步：更新系统 + 安装依赖${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

echo ""
echo -e "${YELLOW}>> apt-get update${PLAIN}"
apt-get update
echo ""
echo -e "${YELLOW}>> apt-get upgrade -y${PLAIN}"
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confold" upgrade
echo ""
echo -e "${YELLOW}>> apt-get install -y curl openssl ca-certificates${PLAIN}"
apt-get install -y curl openssl ca-certificates

echo ""
INSTALL_OK=1
for cmd in curl openssl; do
    if ! command -v $cmd &> /dev/null; then
        error "安装 $cmd 失败"
        INSTALL_OK=0
    fi
done

if [[ $INSTALL_OK -eq 1 ]]; then
    ok "系统更新完成，依赖工具就绪"
else
    error "部分依赖工具安装失败，请手动安装后重试"
    exit 1
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
@reboot root sleep 30 && bash /root/optimize.sh >> /var/log/vpn-optimizer.log 2>&1
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
@reboot root sleep 30 && bash /root/optimize.sh >> /var/log/vpn-optimizer.log 2>&1
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
    # 高延迟链路优化：启用 TCP Fast Open + 扩大缓冲区
    if ! grep -q "net.ipv4.tcp_fastopen" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
        sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
    fi
    if ! grep -q "net.core.rmem_max" /etc/sysctl.conf; then
        echo "net.core.rmem_max=134217728" >> /etc/sysctl.conf
        echo "net.core.wmem_max=134217728" >> /etc/sysctl.conf
        sysctl -w net.core.rmem_max=134217728 >/dev/null 2>&1 || true
        sysctl -w net.core.wmem_max=134217728 >/dev/null 2>&1 || true
    fi
    info "已应用高延迟链路优化（TCP Fast Open + 大缓冲区）"
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
            # 高延迟链路优化
            if ! grep -q "net.ipv4.tcp_fastopen" /etc/sysctl.conf; then
                echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
            fi
            if ! grep -q "net.core.rmem_max" /etc/sysctl.conf; then
                echo "net.core.rmem_max=134217728" >> /etc/sysctl.conf
                echo "net.core.wmem_max=134217728" >> /etc/sysctl.conf
            fi
            sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
            sysctl -w net.core.rmem_max=134217728 >/dev/null 2>&1 || true
            sysctl -w net.core.wmem_max=134217728 >/dev/null 2>&1 || true
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

# 准备本地 masquerade 文件（比远程代理更快，无网络依赖）
info "准备本地伪装页面..."
mkdir -p /var/www/html
cat > /var/www/html/index.html << 'MASQUERADE_HTML'
<!DOCTYPE html>
<html><head><title>404 Not Found</title></head>
<body><h1>404 Not Found</h1><p>The requested URL was not found.</p></body></html>
MASQUERADE_HTML
ok "本地伪装页面已就绪"

# ============================================================
# 第 3 步：生成随机密码和端口
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 3 步：生成配置${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 检测已有配置，复用端口和密码（避免重复部署时端口变更导致安全组不通）
EXISTING_CONFIG="/etc/hysteria/config.yaml"
if [[ -f "$EXISTING_CONFIG" ]]; then
    EXISTING_PORT=$(grep '^listen:' "$EXISTING_CONFIG" | grep -o '[0-9]\+' | head -1)
    EXISTING_PASS=$(grep '  password:' "$EXISTING_CONFIG" | sed 's/.*password: *//' | tr -d ' ')
    if [[ -n "$EXISTING_PORT" && -n "$EXISTING_PASS" ]]; then
        HY2_PORT="$EXISTING_PORT"
        HY2_PASSWORD="$EXISTING_PASS"
        info "检测到已有配置，复用端口：$HY2_PORT 密码：$HY2_PASSWORD"
    else
        HY2_PASSWORD=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
        # 检测已监听的端口，避免冲突
        LISTENING_PORTS=$(ss -tuln 2>/dev/null | grep -o ':[0-9]\+' | tr -d ':' | sort -u | tr '\n' ' ')
        while true; do
            HY2_PORT=$(shuf -i 20000-50000 -n 1)
            if ! echo "$LISTENING_PORTS" | grep -qw "$HY2_PORT"; then
                break
            fi
        done
        info "生成随机密码：$HY2_PASSWORD"
        info "生成随机端口：$HY2_PORT"
    fi
else
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
fi

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

    # 先测试网络连通性
    info "测试网络连通性..."
    NET_OK=0
    for TEST_URL in "https://get.hy2.sh/" "https://github.com" "https://raw.githubusercontent.com"; do
        if curl -sI --connect-timeout 5 -o /dev/null "$TEST_URL" 2>/dev/null; then
            ok "可达：$TEST_URL"
            NET_OK=1
            break
        else
            warn "不可达：$TEST_URL"
        fi
    done

    if [[ $NET_OK -eq 0 ]]; then
        error "所有下载源均不可达，可能是 VPS 网络或 DNS 问题"
        info "诊断命令："
        info "  1. curl -v https://get.hy2.sh/  （看具体错误）"
        info "  2. nslookup get.hy2.sh          （测试 DNS）"
        info "  3. ping -c 3 github.com         （测试连通性）"
        exit 1
    fi

    # 方式 1：官方安装脚本
    INSTALL_OK=0
    if curl -sI --connect-timeout 5 -o /dev/null "https://get.hy2.sh/" 2>/dev/null; then
        info "使用官方安装脚本..."
        if curl -fsSL https://get.hy2.sh/ | bash -s -- 2>&1 | tail -5; then
            if command -v hysteria &> /dev/null; then
                INSTALL_OK=1
                ok "官方脚本安装成功"
            fi
        fi
    fi

    # 方式 2：GitHub 直连下载二进制
    if [[ $INSTALL_OK -eq 0 ]]; then
        warn "官方脚本失败，尝试 GitHub 直连..."
        HY2_LATEST=$(curl -sL --connect-timeout 10 https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null | \
            sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p' | head -1)
        [[ -z "$HY2_LATEST" ]] && HY2_LATEST="v2.6.0"
        info "目标版本：$HY2_LATEST"

        ARCH=$(uname -m)
        case $ARCH in
            x86_64)  HY2_ARCH="amd64" ;;
            aarch64) HY2_ARCH="arm64" ;;
            armv7l)  HY2_ARCH="armv7" ;;
            *)       HY2_ARCH="amd64" ;;
        esac

        HY2_TAR="hysteria-linux-${HY2_ARCH}.tar.gz"

        for URL in \
            "https://github.com/apernet/hysteria/releases/download/${HY2_LATEST}/${HY2_TAR}" \
            "https://ghfast.top/https://github.com/apernet/hysteria/releases/download/${HY2_LATEST}/${HY2_TAR}" \
            "https://mirror.ghproxy.com/https://github.com/apernet/hysteria/releases/download/${HY2_LATEST}/${HY2_TAR}"; do
            info "尝试：$URL"
            cd /tmp
            if curl -fsSL --connect-timeout 15 -o "$HY2_TAR" "$URL" 2>&1; then
                tar -xzf "$HY2_TAR" 2>/dev/null
                mv -f hysteria /usr/local/bin/hysteria 2>/dev/null
                chmod +x /usr/local/bin/hysteria
                rm -f "$HY2_TAR" 2>/dev/null
                if command -v hysteria &> /dev/null; then
                    INSTALL_OK=1
                    ok "二进制下载安装成功"
                    break
                fi
            fi
        done
    fi

    # 方式 3：Go 安装（最后手段）
    if [[ $INSTALL_OK -eq 0 ]]; then
        warn "二进制下载失败，尝试 Go 编译安装..."
        if ! command -v go &> /dev/null; then
            info "安装 Go 编译环境..."
            if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get install -y golang >/dev/null 2>&1
            else
                yum install -y golang >/dev/null 2>&1
            fi
        fi
        if command -v go &> /dev/null; then
            GOPROXY=https://goproxy.cn,direct go install github.com/apernet/hysteria/v2@latest 2>/dev/null
            cp ~/go/bin/hysteria /usr/local/bin/hysteria 2>/dev/null || true
            if command -v hysteria &> /dev/null; then
                INSTALL_OK=1
                ok "Go 编译安装成功"
            fi
        fi
    fi

    if [[ $INSTALL_OK -eq 0 ]]; then
        error "所有安装方式均失败"
        info "请手动安装："
        info "  curl -fsSL https://get.hy2.sh/ | bash -s --"
        info "  或从 https://github.com/apernet/hysteria/releases 手动下载"
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

# 询问是否配置出口代理
echo ""
echo -e "${YELLOW}是否配置静态IP出口代理？${PLAIN}"
echo -e "  如果你有购买的静态IP代理，所有流量将通过该代理出去"
echo -e "  目标网站看到的是你的静态IP，而不是VPS的IP"
echo -e "  ${CYAN}y${PLAIN} = 配置出口代理    ${CYAN}n${PLAIN} = 直连（默认，直接用VPS IP出去）"
read -p "请选择 [y/N]: " USE_OUTBOUND

OUTBOUND_TYPE=""
OUTBOUND_ADDR=""
OUTBOUND_USER=""
OUTBOUND_PASS=""

if [[ "$USE_OUTBOUND" == "y" || "$USE_OUTBOUND" == "Y" ]]; then
    echo ""
    echo -e "  代理类型："
    echo -e "    ${CYAN}1${PLAIN} = HTTP 代理（大多数静态住宅IP服务商默认提供这个）"
    echo -e "    ${CYAN}2${PLAIN} = SOCKS5 代理"
    read -p "请选择 [1/2]（默认 1）: " PROXY_CHOICE

    if [[ "$PROXY_CHOICE" == "2" ]]; then
        OUTBOUND_TYPE="socks5"
        read -p "SOCKS5 代理地址（格式 IP:端口）: " OUTBOUND_ADDR
        while [[ -z "$OUTBOUND_ADDR" ]]; do
            warn "代理地址不能为空"
            read -p "SOCKS5 代理地址（格式 IP:端口）: " OUTBOUND_ADDR
        done
        read -p "SOCKS5 用户名（无认证则留空回车）: " OUTBOUND_USER
        if [[ -n "$OUTBOUND_USER" ]]; then
            read -s -p "SOCKS5 密码: " OUTBOUND_PASS
            echo ""
        fi
    else
        OUTBOUND_TYPE="http"
        read -p "HTTP 代理地址（格式 IP:端口）: " OUTBOUND_ADDR
        while [[ -z "$OUTBOUND_ADDR" ]]; do
            warn "代理地址不能为空"
            read -p "HTTP 代理地址（格式 IP:端口）: " OUTBOUND_ADDR
        done
        read -p "HTTP 代理用户名: " OUTBOUND_USER
        while [[ -z "$OUTBOUND_USER" ]]; do
            warn "用户名不能为空"
            read -p "HTTP 代理用户名: " OUTBOUND_USER
        done
        read -s -p "HTTP 代理密码: " OUTBOUND_PASS
        echo ""
    fi

    ok "出口代理配置已记录"
    info "代理类型：$OUTBOUND_TYPE"
    info "代理地址：$OUTBOUND_ADDR"
    if [[ "$OUTBOUND_TYPE" == "http" ]]; then
        warn "注意：HTTP 代理不支持 UDP 转发，Telegram、游戏等 UDP 应用可能无法连接"
        warn "  解决方案："
        warn "    iOS: Telegram → 设置 → 数据与存储 → 代理 → 添加 SOCKS5"
        warn "    Android: Telegram → 设置 → 数据与存储 → 代理"
        warn "    Desktop: Settings → Advanced → Network and proxy → Use custom proxy"
        warn "    (Telegram Desktop 3.0+ 已去掉独立的「使用 TCP」开关)"
        warn "  或联系代理服务商获取 SOCKS5 地址（支持 UDP）"
    fi
else
    info "未配置出口代理，使用 VPS IP 直连"
fi

# 生成基础配置
cat > "$HY2_CONFIG_DIR/config.yaml" << HY2_CONFIG
listen: :${HY2_PORT}

# 使用自签证书
tls:
  cert: ${CERT_DIR}/hy2_server.crt
  key: ${CERT_DIR}/hy2_server.key

# 认证
auth:
  type: password
  password: ${HY2_PASSWORD}

# QUIC 优化：高带宽延迟积链路（中美跨境等）
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 12500000
  maxConnReceiveWindow: 25000000

# 伪装策略（本地静态文件，无网络延迟）
masquerade:
  type: file
  file:
    dir: /var/www/html

HY2_CONFIG

# 如果配置了出口代理，追加 outbounds
if [[ -n "$OUTBOUND_ADDR" ]]; then
    cat >> "$HY2_CONFIG_DIR/config.yaml" << OUTBOUND_EOF
# 出口代理（所有流量通过静态IP出去）
outbounds:
  - name: static-ip
    type: ${OUTBOUND_TYPE}
OUTBOUND_EOF
    if [[ "$OUTBOUND_TYPE" == "socks5" ]]; then
        echo "    socks5:" >> "$HY2_CONFIG_DIR/config.yaml"
        echo "      addr: ${OUTBOUND_ADDR}" >> "$HY2_CONFIG_DIR/config.yaml"
        if [[ -n "$OUTBOUND_USER" ]]; then
            echo "      username: ${OUTBOUND_USER}" >> "$HY2_CONFIG_DIR/config.yaml"
            echo "      password: ${OUTBOUND_PASS}" >> "$HY2_CONFIG_DIR/config.yaml"
        fi
    else
        # HTTP 代理：认证信息写在 URL 里
        echo "    http:" >> "$HY2_CONFIG_DIR/config.yaml"
        echo "      url: http://${OUTBOUND_USER}:${OUTBOUND_PASS}@${OUTBOUND_ADDR}" >> "$HY2_CONFIG_DIR/config.yaml"
    fi
fi

ok "Hysteria2 配置文件已生成：$HY2_CONFIG_DIR/config.yaml"

# ============================================================
# 第 6 步：创建 systemd 服务
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 6 步：创建 systemd 服务${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 官方安装脚本可能已创建 systemd 服务，这里确保配置正确
cat > /etc/systemd/system/hysteria-server.service << 'SYSTEMD_EOF'
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
systemctl restart hysteria-server.service
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

# 获取服务器公网 IP（客户端直连 VPS 的 Hysteria2 服务）
SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 ip.sb 2>/dev/null || echo "你的服务器IP")

# 一键导入链接（入口地址 = VPS IP，客户端直连 VPS）
HY2_LINK="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=www.bing.com#Hysteria2-BBR"

echo -e "${YELLOW}一键导入链接（复制到客户端即可）：${PLAIN}"
echo ""
echo -e "  ${CYAN}${HY2_LINK}${PLAIN}"
echo ""

echo -e "${YELLOW}客户端导入方式：${PLAIN}"
echo ""
echo -e "  ${GREEN}Shadowrocket (iOS)：${PLAIN}"
echo -e "    复制上面的链接 → 打开 Shadowrocket → 左上角 + → 粘贴 → 保存"
echo ""
echo -e "  ${GREEN}Clash (Mac/Windows/Linux/Android)：${PLAIN}"
echo -e "    1. 打开 https://sub.asailor.org/"
echo -e "    2. 粘贴上面的链接 → 转换 → 复制转换结果"
echo -e "    3. 粘贴到 Clash 配置中 → 保存"
echo ""
echo -e "  ${GREEN}v2rayN (Windows)：${PLAIN}"
echo -e "    复制上面的链接 → 打开 v2rayN → 服务器 → 从剪贴板导入"
echo -e "    （需要 v2rayN 6.0+，自带 sing-box 内核支持 Hysteria2）"
echo ""
echo -e "${YELLOW}配置摘要：${PLAIN}"
echo -e "  连接地址：  ${CYAN}$SERVER_IP:$HY2_PORT (UDP)${PLAIN}"
echo -e "  密码：       ${CYAN}$HY2_PASSWORD${PLAIN}"
echo -e "  SNI：        ${CYAN}www.bing.com${PLAIN}"
if [[ -n "$OUTBOUND_ADDR" ]]; then
    OUTBOUND_IP=$(echo "$OUTBOUND_ADDR" | cut -d: -f1)
    echo -e "  出口代理：   ${CYAN}$OUTBOUND_TYPE://$OUTBOUND_ADDR${PLAIN}"
    if [[ -n "$OUTBOUND_USER" ]]; then
        echo -e "  代理认证：   ${CYAN}$OUTBOUND_USER${PLAIN}"
    fi
    echo -e "  ${GREEN}入口IP（客户端连接）：$SERVER_IP${PLAIN}"
    echo -e "  ${GREEN}出口IP（目标网站看到）：$OUTBOUND_IP${PLAIN}"
fi
echo ""
if [[ -n "$OUTBOUND_ADDR" && "$OUTBOUND_TYPE" == "http" ]]; then
    echo -e "  ${YELLOW}Telegram 用户必读：${PLAIN}"
    echo -e "  ${CYAN}HTTP 代理不支持 UDP，Telegram 需强制 TCP 连接${PLAIN}"
    echo -e "  ${CYAN}iOS: 设置 → 数据与存储 → 代理 → 添加 SOCKS5${PLAIN}"
    echo -e "  ${CYAN}Android: 设置 → 数据与存储 → 代理${PLAIN}"
    echo -e "  ${CYAN}Desktop: Settings → Advanced → Network and proxy → Use custom proxy${PLAIN}"
    echo ""
fi
echo -e "${YELLOW}服务管理：${PLAIN}"
echo -e "  查看状态：  ${CYAN}systemctl status hysteria-server${PLAIN}"
echo -e "  重启服务：  ${CYAN}systemctl restart hysteria-server${PLAIN}"
echo ""
