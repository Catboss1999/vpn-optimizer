#!/bin/bash
# ============================================================
# VPN Optimizer - 一键开启 BBR + 安装 Hysteria2
# 适用于已安装 3x-ui 的 VPS，解决网络延迟高的问题
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

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    error "请用 root 用户运行此脚本：sudo bash optimize.sh"
    exit 1
fi

# 检测系统
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    error "无法检测操作系统，脚本仅支持 Debian/Ubuntu/CentOS"
    exit 1
fi

info "检测到系统：$OS $VERSION_ID"

# ============================================================
# 第一步：开启 BBR
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 1 步：开启 BBR 拥塞控制${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 检查是否已开启 BBR
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
if echo "$CURRENT_CC" | grep -q "bbr"; then
    ok "BBR 已经开启，跳过"
else
    info "正在开启 BBR..."
    
    # 写入 sysctl 配置
    if ! grep -q "net.core.default_qdisc" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    
    # 立即生效
    sysctl -p >/dev/null 2>&1
    
    # 验证
    NEW_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
    if echo "$NEW_CC" | grep -q "bbr"; then
        ok "BBR 已开启：$NEW_CC"
    else
        warn "BBR 开启失败，你的内核可能不支持，不影响后续步骤"
    fi
fi

# ============================================================
# 第二步：安装 Hysteria2
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 2 步：安装 Hysteria2${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 检查是否已安装
if command -v hysteria &> /dev/null; then
    HY2_VERSION=$(hysteria version 2>/dev/null | head -1 || echo "已安装")
    ok "Hysteria2 已安装：$HY2_VERSION"
    info "如需重新配置，请先运行: systemctl stop hysteria-server"
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
# 第三步：生成自签证书（无需域名）
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 3 步：生成自签证书${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

CERT_DIR="/etc/hysteria"
mkdir -p "$CERT_DIR"

if [[ -f "$CERT_DIR/server.crt" && -f "$CERT_DIR/server.key" ]]; then
    ok "证书已存在，跳过生成"
else
    info "正在生成自签证书（无需域名）..."
    
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.crt" \
        -subj "/CN=www.bing.com" -days 36500 2>/dev/null
    
    chown hysteria:hysteria "$CERT_DIR/server.key" "$CERT_DIR/server.crt" 2>/dev/null || true
    chmod 644 "$CERT_DIR/server.crt"
    chmod 600 "$CERT_DIR/server.key"
    
    ok "自签证书已生成（有效期 100 年，CN=www.bing.com）"
fi

# ============================================================
# 第四步：生成随机密码和端口
# ============================================================
echo ""
echo -e "${CYAN}========================================${PLAIN}"
echo -e "${CYAN}  第 4 步：生成配置${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}"

# 生成随机密码
HY2_PASSWORD=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)

# 随机端口（避开常见端口）
HY2_PORT=$(shuf -i 20000-50000 -n 1)

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

# 带宽优化（根据服务器实际情况，可后续调整）
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
# 第五步：开放防火墙端口
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

# ============================================================
# 第六步：启动服务
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
    error "Hysteria2 启动失败，查看日志：journalctl -u hysteria-server -e"
    exit 1
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
echo -e "    sni: www.bing.com"
echo ""

# Clash 配置片段
echo -e "${YELLOW}📄 Clash Meta 配置片段：${PLAIN}"
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
echo -e "  • 查看日志：journalctl -u hysteria-server -e"
echo -e "  • 配置文件：$CERT_DIR/config.yaml"
echo ""
echo -e "${GREEN}如果觉得有用，关注我的 X 获取更多 AI 工具和实用教程 🎯${PLAIN}"
