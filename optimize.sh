#!/bin/bash
# ============================================================
# VPN Optimizer - 一键开启 BBR + 安装 Hysteria2
# 适用于已安装 3x-ui 的 VPS，解决网络延迟高的问题
# 兼容 Ubuntu 18.04+ / Debian 10+ / CentOS 7+
# 作者: Pardo (@你的X账号)
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

# 安装必要的工具（curl、openssl、sqlite3、ca-certificates）
NEED_INSTALL=0
for cmd in curl openssl sqlite3; do
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
        apt-get install -y curl openssl sqlite3 ca-certificates >/dev/null 2>&1
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        yum install -y curl openssl sqlite ca-certificates >/dev/null 2>&1
    else
        warn "未知系统类型 $OS，尝试用 apt 安装..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl openssl sqlite3 ca-certificates >/dev/null 2>&1
    fi

    # 验证安装结果
    INSTALL_OK=1
    for cmd in curl openssl sqlite3; do
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

        # 标记需要重启
        touch /tmp/vpn-optimizer-need-reboot
        info "内核已升级，需要重启服务器才能生效"

        # 自动重启并设置重启后继续运行脚本
        info "将在 5 秒后自动重启服务器，重启后请重新运行此脚本"
        info "脚本会自动检测到内核已升级，跳过升级步骤继续执行"

        # 设置重启后自动运行脚本的标志
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

    # 自动加载 BBR 内核模块
    modprobe tcp_bbr 2>/dev/null || true

    # 确保 BBR 模块开机自动加载
    if ! grep -q "tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null; then
        echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || \
            echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true
    fi

    # 备份原配置（如果没备份过）
    if [[ ! -f /etc/sysctl.conf.bak ]]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak
    fi

    # 写入 sysctl 配置（避免重复写入）
    if ! grep -q "net.core.default_qdisc" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi

    # 立即生效
    sysctl -p >/dev/null 2>&1

    # 验证
    NEW_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if echo "$NEW_CC" | grep -q "bbr"; then
        ok "BBR 已开启：$NEW_CC"
    else
        # 最后手段：强制设置并重试
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
# 第 2 步：安装 Hysteria2
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 2 步：安装 Hysteria2${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 检查是否已安装
if command -v hysteria &> /dev/null; then
    HY2_VERSION=$(hysteria version 2>/dev/null | head -1 || echo "已安装")
    ok "Hysteria2 已安装：$HY2_VERSION"
    info "将重新生成配置..."
else
    info "正在安装 Hysteria2..."

    # 使用官方安装脚本
    bash <(curl -fsSL https://get.hy2.sh/)

    if command -v hysteria &> /dev/null; then
        ok "Hysteria2 安装成功"
    else
        error "Hysteria2 安装失败，请检查网络连接"
        exit 1
    fi
fi

# ============================================================
# 第 3 步：生成自签证书（无需域名）
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 3 步：生成自签证书${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

CERT_DIR="/etc/hysteria"
mkdir -p "$CERT_DIR"

# 每次都重新生成证书（确保有效）
info "正在生成自签证书（无需域名）..."

# 先生成 EC 参数文件，再生成证书（兼容性更好的写法）
openssl ecparam -name prime256v1 -out "$CERT_DIR/ecparam.tmp" 2>/dev/null
openssl req -x509 -nodes -newkey ec:"$CERT_DIR/ecparam.tmp" \
    -keyout "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" \
    -subj "/CN=www.bing.com" -days 36500 2>/dev/null
rm -f "$CERT_DIR/ecparam.tmp"

# 设置权限
chown hysteria:hysteria "$CERT_DIR/server.key" "$CERT_DIR/server.crt" 2>/dev/null || true
chmod 644 "$CERT_DIR/server.crt"
chmod 600 "$CERT_DIR/server.key"

ok "自签证书已生成（有效期 100 年，CN=www.bing.com）"

# ============================================================
# 第 4 步：生成随机密码和端口
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 4 步：生成配置${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 生成随机密码
HY2_PASSWORD=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)

# 检测 3x-ui 面板端口，避免冲突
USED_PORTS=""
if command -v x-ui &> /dev/null; then
    # 尝试从 3x-ui 设置中读取面板端口
    PANEL_PORT=$(x-ui setting -show true 2>/dev/null | grep -oP 'port:\s*\K\d+' || echo "")
    if [[ -n "$PANEL_PORT" ]]; then
        USED_PORTS="$PANEL_PORT"
        info "检测到 3x-ui 面板端口：$PANEL_PORT，将避开"
    fi
fi

# 检测 3x-ui 已使用的 inbound 端口（从数据库读）
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

# 写入配置文件
cat > "$CERT_DIR/config.yaml" << EOF
listen: :$HY2_PORT

tls:
  cert: $CERT_DIR/server.crt
  key: $CERT_DIR/server.key

auth:
  type: password
  password: $HY2_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

# 带宽优化
ignoreClientBandwidth: false

# QUIC 参数优化
quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  maxIncomingStreams: 1024
EOF

ok "配置文件已写入：$CERT_DIR/config.yaml"

# ============================================================
# 第 5 步：开放防火墙端口
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 5 步：开放防火墙端口${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# ufw (Debian/Ubuntu)
if command -v ufw &> /dev/null; then
    ufw allow $HY2_PORT/udp >/dev/null 2>&1
    ok "UFW 已放行 UDP $HY2_PORT"
fi

# firewalld (CentOS)
if command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=$HY2_PORT/udp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    ok "Firewalld 已放行 UDP $HY2_PORT"
fi

# iptables 兜底
iptables -C INPUT -p udp --dport $HY2_PORT -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p udp --dport $HY2_PORT -j ACCEPT 2>/dev/null || true
ok "iptables 已放行 UDP $HY2_PORT"

warn "⚠️  如果你的 VPS 服务商有网页端安全组/防火墙设置，请在那里也放行 UDP $HY2_PORT 端口"
warn "    （这是唯一需要你手动操作的步骤，脚本无法替你操作云服务商网页）"

# ============================================================
# 第 6 步：启动服务
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 6 步：启动 Hysteria2 服务${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

systemctl enable hysteria-server >/dev/null 2>&1
systemctl restart hysteria-server

sleep 2

if systemctl is-active --quiet hysteria-server; then
    ok "Hysteria2 服务已启动"
else
    # 自动诊断常见问题并尝试修复
    info "启动失败，正在自动诊断..."

    # 检查端口是否被占用
    if ss -uln | grep -q ":$HY2_PORT "; then
        warn "端口 $HY2_PORT 被占用，正在重新生成端口..."
        # 重新选端口
        while true; do
            HY2_PORT=$(shuf -i 20000-50000 -n 1)
            if ! ss -uln | grep -q ":$HY2_PORT "; then
                break
            fi
        done
        # 更新配置文件中的端口
        sed -i "s/^listen: :.*/listen: :$HY2_PORT/" "$CERT_DIR/config.yaml"
        # 重新开防火墙
        ufw allow $HY2_PORT/udp >/dev/null 2>&1 || true
        iptables -I INPUT -p udp --dport $HY2_PORT -j ACCEPT 2>/dev/null || true
        systemctl restart hysteria-server
        sleep 2
    fi

    # 检查用户是否存在
    if ! id hysteria &>/dev/null; then
        useradd -r -s /usr/sbin/nologin hysteria 2>/dev/null || true
        chown -R hysteria:hysteria "$CERT_DIR" 2>/dev/null || true
        systemctl restart hysteria-server
        sleep 2
    fi

    if systemctl is-active --quiet hysteria-server; then
        ok "Hysteria2 服务已启动（自动修复后）"
    else
        error "Hysteria2 启动失败"
        info "最后手段：查看日志诊断"
        journalctl -u hysteria-server -e --no-pager | tail -20
        exit 1
    fi
fi

# ============================================================
# 输出结果
# ============================================================
echo ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}  🎉 全部完成！${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo ""

# 获取服务器公网 IP
SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 ip.sb 2>/dev/null || echo "你的服务器IP")

echo -e "${YELLOW}📋 你的 Hysteria2 连接信息：${PLAIN}"
echo ""
echo -e "  服务器 IP：  ${CYAN}$SERVER_IP${PLAIN}"
echo -e "  端口：       ${CYAN}$HY2_PORT${PLAIN}"
echo -e "  密码：       ${CYAN}$HY2_PASSWORD${PLAIN}"
echo -e "  SNI：        ${CYAN}www.bing.com${PLAIN}"
echo -e "  跳过验证：   ${CYAN}是（自签证书）${PLAIN}"
echo ""

# 生成连接链接
HY2_LINK="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=www.bing.com#Hysteria2-Optimized"

echo -e "${YELLOW}🔗 一键导入链接（复制到客户端即可）：${PLAIN}"
echo ""
echo -e "  ${CYAN}${HY2_LINK}${PLAIN}"
echo ""

# 客户端配置说明
echo -e "${YELLOW}📱 客户端配置说明：${PLAIN}"
echo ""
echo -e "  ${GREEN}Shadowrocket (iOS)：${PLAIN}"
echo -e "    类型选 Hysteria2 → 填 IP + 端口 + 密码"
echo -e "    打开「允许不安全」开关"
echo -e "    SNI 填 www.bing.com"
echo ""
echo -e "  ${GREEN}v2rayN / Nekoray (Windows)：${PLAIN}"
echo -e "    添加 Hysteria2 节点 → 填 IP + 端口 + 密码"
echo -e "    勾选 AllowInsecure（跳过证书验证）"
echo -e "    SNI 填 www.bing.com"
echo ""
echo -e "  ${GREEN}Clash Meta / mihomo：${PLAIN}"
echo -e "    proxy 类型选 hysteria2"
echo -e "    skip-cert-verify: true"
echo -e "    SNI 填 www.bing.com"
echo ""

# Clash 配置片段
echo -e "${YELLOW}📄 Clash Meta 配置片段（直接复制）：${PLAIN}"
echo ""
cat << CLASH_EOF
  - name: "Hysteria2-Optimized"
    type: hysteria2
    server: $SERVER_IP
    port: $HY2_PORT
    password: $HY2_PASSWORD
    sni: www.bing.com
    skip-cert-verify: true

CLASH_EOF

echo -e "${YELLOW}💡 提示：${PLAIN}"
echo -e "  • 原来的 VLESS+Reality 节点仍然可用，两个协议互不干扰"
echo -e "  • 如果延迟仍然高，可能是 VPS 到国内的线路问题（换 CN2 GIA 线路可解决）"
echo -e "  • 查看服务状态：systemctl status hysteria-server"
echo -e "  • 配置文件：$CERT_DIR/config.yaml"
echo ""
echo -e "${GREEN}如果觉得有用，关注我的 X 获取更多 AI 工具和实用教程 🎯${PLAIN}"
