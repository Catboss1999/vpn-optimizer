#!/bin/bash
# ============================================================
# Hysteria2 温和性能优化（安全优先，折中方案）
# 
# 设计原则：
#   只做零风险的优化 — 不会导致VPS被限流、不会浪费内存、
#   不会跟用户实际带宽冲突、不会搞坏配置文件。
#
# 激进优化（Brutal CC、CPU满频、超大buffer）已移除。
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

info()  { echo -e "${CYAN}[INFO]${PLAIN} $1"; }
ok()    { echo -e "${GREEN}[OK]${PLAIN} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $1"; }

if [[ $EUID -ne 0 ]]; then
    error "请使用 root 用户运行此脚本"
    exit 1
fi

# ============================================================
# 前置检查：Hysteria2 是否已安装
# ============================================================
if ! systemctl is-active --quiet hysteria-server 2>/dev/null; then
    warn "Hysteria2 服务未运行，将自动先部署 Hysteria2..."
    echo ""
    DEPLOY_URL="https://cdn.jsdelivr.net/gh/Catboss1999/vpn-optimizer@main/optimize.sh"
    DEPLOY_SCRIPT="/tmp/deploy-hy2.sh"
    info "正在下载部署脚本..."
    if ! curl -fsSL "$DEPLOY_URL" -o "$DEPLOY_SCRIPT"; then
        curl -fsSL "https://raw.githubusercontent.com/Catboss1999/vpn-optimizer/main/optimize.sh" -o "$DEPLOY_SCRIPT" || {
            error "无法下载部署脚本，请检查网络后重试"
            exit 1
        }
    fi
    chmod +x "$DEPLOY_SCRIPT"
    info "正在部署 Hysteria2（需要交互式输入）..."
    echo ""
    bash "$DEPLOY_SCRIPT"
    if ! systemctl is-active --quiet hysteria-server 2>/dev/null; then
        error "Hysteria2 部署后服务仍未运行"
        exit 1
    fi
    ok "Hysteria2 部署完成，继续优化..."
    echo ""
fi

CONFIG_FILE="/etc/hysteria/config.yaml"

echo ""
echo -e "${YELLOW}========================================${PLAIN}"
echo -e "${YELLOW}   Hysteria2 温和优化（安全优先）${PLAIN}"
echo -e "${YELLOW}========================================${PLAIN}"
echo ""

# ============================================================
# 优化 1：温和的内核参数（全部安全，无副作用）
# ============================================================
info "正在优化内核网络参数（温和模式）..."

cat > /etc/sysctl.d/99-hy2-safe.conf << 'SYSCTL_EOF'
# === BBR 拥塞控制（如果内核支持则启用，不支持则静默跳过） ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === TCP Fast Open（减少握手延迟，已广泛支持） ===
net.ipv4.tcp_fastopen = 3

# === 连接空闲后立即恢复速度（不用慢启动） ===
net.ipv4.tcp_slow_start_after_idle = 0

# === 减少小包延迟（避免因Nagle算法攒包等待） ===
net.ipv4.tcp_notsent_lowat = 16384

# === 适度扩大网卡接收队列（防止突发丢包） ===
net.core.netdev_max_backlog = 50000
SYSCTL_EOF

sysctl --system >/dev/null 2>&1

# 检查 BBR 是否生效
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
if echo "$CURRENT_CC" | grep -q "bbr"; then
    ok "BBR 已启用：$CURRENT_CC"
else
    ok "BBR 未能启用（内核不支持），不影响 Hysteria2 QUIC 性能"
fi

ok "内核参数优化完成（tcp_fastopen + slow_start_after_idle=0）"

# ============================================================
# 优化 2：文件描述符（温和提升，VPS 通常默认 1024）
# ============================================================
info "正在提升文件描述符限制..."

# 65535 对于 Hysteria2 绰绰有余（实际用 ~500）
if ! grep -q "nofile 65535" /etc/security/limits.conf 2>/dev/null; then
    echo "* soft nofile 65535" >> /etc/security/limits.conf
    echo "* hard nofile 65535" >> /etc/security/limits.conf
fi
ulimit -n 65535 2>/dev/null || true
ok "文件描述符限制已提升至 65535"

# ============================================================
# 优化 3：验证 QUIC 窗口配置（仅验证，不修改）
# ============================================================
info "验证 Hysteria2 QUIC 配置..."

if grep -q "initStreamReceiveWindow" "$CONFIG_FILE"; then
    ok "QUIC 窗口优化已配置（deploy 脚本已写入）"
else
    warn "QUIC 窗口未配置，这通常说明 deploy 脚本未正常完成"
    warn "建议重新运行 optimize.sh 部署脚本"
fi

if grep -q "type: file" "$CONFIG_FILE"; then
    ok "masquerade 已是本地文件模式（零延迟）"
fi

# ============================================================
# 诊断：出站代理连通性（帮助排查"XXX 打不开"的问题）
# ============================================================
echo ""
echo -e "${YELLOW}========================================${PLAIN}"
echo -e "${YELLOW}   诊断：出站代理连通性${PLAIN}"
echo -e "${YELLOW}========================================${PLAIN}"
echo ""

HAS_OUTBOUND=0
OUTBOUND_TYPE=""
OUTBOUND_URL=""

if grep -q "^outbounds:" "$CONFIG_FILE" 2>/dev/null; then
    HAS_OUTBOUND=1
    if grep -q "type: http" "$CONFIG_FILE"; then
        OUTBOUND_TYPE="http"
        OUTBOUND_URL=$(grep "url:" "$CONFIG_FILE" | grep "http://" | sed 's/.*url: *//' | tr -d ' ')
    elif grep -q "type: socks5" "$CONFIG_FILE"; then
        OUTBOUND_TYPE="socks5"
    fi
    info "检测到出站代理：$OUTBOUND_TYPE"
fi

if [[ $HAS_OUTBOUND -eq 1 && "$OUTBOUND_TYPE" == "http" && -n "$OUTBOUND_URL" ]]; then
    PROXY_HOST=$(echo "$OUTBOUND_URL" | sed -e 's|http[s]*://||' -e 's|@.*||' -e 's|:.*||' 2>/dev/null || echo "")

    echo -e "${CYAN}[诊断] 测试出站代理连通性...${PLAIN}"

    # 测试 1：代理本身可达性
    if [[ -n "$PROXY_HOST" ]]; then
        PROXY_PORT=$(echo "$OUTBOUND_URL" | grep -o ':[0-9]\+' | tail -1 | tr -d ':')
        info "代理地址：$PROXY_HOST:$PROXY_PORT"
    fi

    # 测试 2：通过代理访问常见网站（VPS 端，curl 直测代理）
    info "测试通过代理访问外网..."
    echo ""
    echo -e "  ${YELLOW}以下测试用于诊断「XX网站打不开」的问题：${PLAIN}"
    echo ""

    # 提取代理认证信息
    PROXY_USER=$(echo "$OUTBOUND_URL" | sed -e 's|http[s]*://||' -e 's|@.*||' -e 's|:.*||' 2>/dev/null || echo "")
    PROXY_PASS=$(echo "$OUTBOUND_URL" | sed -e 's|http[s]*://||' -e 's|.*:||' -e 's|@.*||' 2>/dev/null || echo "")
    PROXY_ADDR=$(echo "$OUTBOUND_URL" | sed -e 's|http[s]*://||' -e 's|.*@||' 2>/dev/null || echo "")

    test_url() {
        local label="$1"
        local url="$2"
        RESULT=$(curl -x "http://${PROXY_USER}:${PROXY_PASS}@${PROXY_ADDR}" \
            -sI --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "FAIL")
        if [[ "$RESULT" =~ ^[23][0-9][0-9]$ ]]; then
            echo -e "  ${GREEN}通过${PLAIN} $label → HTTP $RESULT"
        else
            echo -e "  ${RED}失败${PLAIN} $label → $RESULT"
        fi
    }

    test_url "google.com"   "https://www.google.com"
    test_url "github.com"   "https://github.com"
    test_url "speedtest"    "https://www.speedtest.net"
    test_url "fast.com"     "https://fast.com"

    echo ""
    warn "如果 speedtest.net 或 fast.com 测试失败，说明你的静态IP代理服务商屏蔽了测速网站"
    warn "这是代理服务商的策略（防止用户跑测速消耗带宽），不是配置问题"
    warn "解决方案：用以下命令在 VPS 上直接测速（不走代理）"
    echo ""
    echo -e "  ${CYAN}# CLI 测速（VPS 直连，不走代理）：${PLAIN}"
    echo -e "  curl -s https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 -"
    echo ""
    echo -e "  ${CYAN}# 或下载测试文件测速：${PLAIN}"
    echo -e "  wget -O /dev/null http://speedtest.tele2.net/100MB.zip"
    echo ""

else
    info "未检测到出站代理（直连模式），无诊断需要"
fi

# ============================================================
# 重启服务
# ============================================================
echo -e "${YELLOW}========================================${PLAIN}"
echo -e "${YELLOW}   应用配置${PLAIN}"
echo -e "${YELLOW}========================================${PLAIN}"

info "重启 Hysteria2 服务..."
systemctl restart hysteria-server
sleep 2

if systemctl is-active --quiet hysteria-server; then
    ok "Hysteria2 服务运行正常"
else
    error "Hysteria2 服务启动失败！"
    error "请检查日志：journalctl -u hysteria-server -n 30 --no-pager"
    exit 1
fi

# ============================================================
# 输出结果
# ============================================================
echo ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}   优化完成！${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo ""
echo -e "${YELLOW}已应用的安全优化：${PLAIN}"
echo -e "  1. BBR 拥塞控制（内核支持则自动启用）"
echo -e "  2. TCP Fast Open（减少握手延迟）"
echo -e "  3. tcp_slow_start_after_idle=0（空闲后立即恢复速度）"
echo -e "  4. 网卡队列 + 文件描述符（温和提升）"
echo -e "  5. QUIC 窗口验证 + 出站代理诊断"
echo ""

# === Telegram 各平台代理设置说明 ===
if [[ "$OUTBOUND_TYPE" == "http" ]]; then
    echo -e "${YELLOW}📱 Telegram 连接问题：${PLAIN}"
    echo -e "  HTTP 代理不支持 UDP，Telegram 需要强制用 TCP："
    echo ""
    echo -e "  ${CYAN}iOS：${PLAIN}"
    echo -e "    Telegram → 设置 → 数据与存储 → 使用代理 →"
    echo -e "    添加代理 → 类型选 SOCKS5 → 填入你的代理信息"
    echo -e "    （Telegram iOS 没有直接开关UDP的选项，需配代理）"
    echo ""
    echo -e "  ${CYAN}Android：${PLAIN}"
    echo -e "    Telegram → 设置 → 数据与存储 → 代理设置 →"
    echo -e "    添加代理 → 或开启「使用代理」"
    echo -e "    （Telegram Android 同样需要在代理层面处理）"
    echo ""
    echo -e "  ${CYAN}Desktop (Windows/Mac/Linux)：${PLAIN}"
    echo -e "    Telegram → Settings → Advanced → Network and proxy →"
    echo -e "    Connection type → 选择 「Use custom proxy」→ 添加 SOCKS5/HTTP 代理"
    echo -e "    （Telegram Desktop 3.0 后去掉了独立的「Use TCP」开关）"
    echo ""
    echo -e "  ${CYAN}Mac (旧版)：${PLAIN}"
    echo -e "    Telegram → Preferences → Advanced →"
    echo -e "    勾选 「Use TCP instead of UDP」"
    echo ""

    # 如果用户配了 outbound 但 Telegram 仍不行，给一个绕过方案
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "你的VPS-IP")
    echo -e "  ${YELLOW}💡 终极方案：${PLAIN} 在 Hysteria2 客户端上再套一层 V2Ray/Xray 出站"
    echo -e "  通过 V2Ray/Xray 的 routing 规则，把 Telegram 流量走直连（不走出站代理）"
    echo -e "  但这是进阶操作，一般用户直接在 Telegram 里配 SOCKS5 代理即可"
    echo ""
fi

echo -e "${YELLOW}📊 测速网站打不开？${PLAIN}"
echo -e "  常见原因：静态IP代理服务商屏蔽测速流量（怕用户消耗带宽）"
echo -e "  不是你的配置问题，是代理端的策略"
echo ""
echo -e "  ${CYAN}在 VPS 上直接测速（不走代理）：${PLAIN}"
echo -e "  curl -s https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 -"
echo ""
echo -e "  ${CYAN}下载测试文件测速：${PLAIN}"
echo -e "  wget -O /dev/null http://speedtest.tele2.net/100MB.zip"
echo ""

echo -e "${YELLOW}服务管理：${PLAIN}"
echo -e "  查看状态：  ${CYAN}systemctl status hysteria-server${PLAIN}"
echo -e "  查看日志：  ${CYAN}journalctl -u hysteria-server -f${PLAIN}"
echo -e "  重启服务：  ${CYAN}systemctl restart hysteria-server${PLAIN}"
echo ""
