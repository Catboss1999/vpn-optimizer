#!/bin/bash
# Hysteria2 一键部署 + 性能优化脚本
# 用途：新 VPS 零准备 → 自动部署 Hysteria2 + 性能优化
# 使用：bash optimize-performance.sh

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

info()  { echo -e "${CYAN}[INFO]${PLAIN} $1"; }
ok()    { echo -e "${GREEN}[OK]${PLAIN} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $1"; }

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    error "请使用 root 用户运行此脚本"
    exit 1
fi

# 检查 Hysteria2 是否已安装
if ! systemctl is-active --quiet hysteria-server 2>/dev/null; then
    warn "Hysteria2 服务未运行，将自动先部署 Hysteria2..."
    echo ""
    
    # 下载并运行主部署脚本
    DEPLOY_URL="https://cdn.jsdelivr.net/gh/Catboss1999/vpn-optimizer@main/optimize.sh"
    DEPLOY_SCRIPT="/tmp/deploy-hy2.sh"
    
    info "正在下载部署脚本..."
    if ! curl -fsSL "$DEPLOY_URL" -o "$DEPLOY_SCRIPT"; then
        # 回退：raw git
        curl -fsSL "https://raw.githubusercontent.com/Catboss1999/vpn-optimizer/main/optimize.sh" -o "$DEPLOY_SCRIPT" || {
            error "无法下载部署脚本，请检查网络后重试"
            exit 1
        }
    fi
    chmod +x "$DEPLOY_SCRIPT"
    
    info "正在部署 Hysteria2（需要你交互式输入配置）..."
    echo ""
    bash "$DEPLOY_SCRIPT"
    
    # 部署脚本内部会 reboot（如果升级了内核），
    # 如果没 reboot，说明系统已就绪，继续优化
    if ! systemctl is-active --quiet hysteria-server 2>/dev/null; then
        error "Hysteria2 部署后服务仍未运行，请检查部署日志"
        exit 1
    fi
    
    ok "Hysteria2 部署完成，继续优化..."
    echo ""
fi

CONFIG_FILE="/etc/hysteria/config.yaml"

echo ""
echo -e "${YELLOW}========================================${PLAIN}"
echo -e "${YELLOW}   Hysteria2 性能优化脚本${PLAIN}"
echo -e "${YELLOW}========================================${PLAIN}"
echo ""

# ============================================
# 优化 1：BBR + TCP 缓冲区 + Fast Open
# ============================================
info "正在优化内核网络参数..."

# 确保 BBR 已开启
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
if echo "$CURRENT_CC" | grep -q "bbr"; then
    ok "BBR 已开启"
else
    # 尝试加载 BBR 模块
    modprobe tcp_bbr 2>/dev/null || true
    
    # 写入 sysctl 配置（持久化）
    cat > /etc/sysctl.d/99-hy2-optimize.conf << SYSCTL_EOF
# BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP Fast Open
net.ipv4.tcp_fastopen = 3

# 大缓冲区（高 BDP 链路优化）
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 67108864
net.core.wmem_default = 67108864
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_mtu_probing = 1
SYSCTL_EOF

    sysctl --system >/dev/null 2>&1
    FINAL_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if echo "$FINAL_CC" | grep -q "bbr"; then
        ok "BBR 已开启：$FINAL_CC"
    else
        warn "BBR 未能开启（内核可能不支持），跳过"
    fi
fi

ok "内核网络参数优化完成"

# ============================================
# 优化 2：Hysteria2 QUIC 窗口 + masquerade 本地化
# ============================================
info "正在优化 Hysteria2 配置..."

# 备份当前配置
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
ok "已备份原配置"

# 2a. 添加 QUIC 窗口优化（如果不存在）
if ! grep -q "initStreamReceiveWindow" "$CONFIG_FILE"; then
    info "添加 QUIC 窗口优化配置..."
    
    # 在 auth 段之后插入 QUIC 配置
    sed -i '/^auth:/,/password:/{/password:/a\
\
# QUIC 优化：高带宽延迟积链路（中美跨境等）\
quic:\
  initStreamReceiveWindow: 8388608\
  maxStreamReceiveWindow: 16777216\
  initConnReceiveWindow: 12500000\
  maxConnReceiveWindow: 25000000
}' "$CONFIG_FILE"
    ok "QUIC 窗口优化已添加"
else
    ok "QUIC 窗口优化已存在，跳过"
fi

# 2b. masquerade 改为本地静态文件（消除远程代理延迟）
if grep -q "type: proxy" "$CONFIG_FILE"; then
    info "将 masquerade 从远程代理改为本地文件（消除延迟）..."
    
    # 准备伪装用静态文件
    MASQ_DIR="/var/www/hy2-masq"
    mkdir -p "$MASQ_DIR"
    cat > "$MASQ_DIR/index.html" << 'HTML_EOF'
<!DOCTYPE html>
<html>
<head><title>404 Not Found</title></head>
<body><h1>404 Not Found</h1><p>The requested URL was not found on this server.</p></body>
</html>
HTML_EOF
    
    # 替换 masquerade 配置
    # 先删除整个 masquerade 段，再追加新的
    sed -i '/^masquerade:/,/^[^ ]/{
        /^masquerade:/!{
            /^[^ ]/!d
        }
    }' "$CONFIG_FILE"
    # 删除 masquerade 段的所有子行
    sed -i '/^masquerade:/,${
        /^masquerade:/!d
    }' "$CONFIG_FILE"
    # 删除 masquerade 行本身
    sed -i '/^masquerade:/d' "$CONFIG_FILE"
    
    # 追加新的 masquerade 配置
    cat >> "$CONFIG_FILE" << MASQ_EOF

# 伪装策略（本地静态文件，零延迟）
masquerade:
  type: file
  file:
    dir: ${MASQ_DIR}
MASQ_EOF
    
    ok "masquerade 已改为本地文件"
else
    ok "masquerade 已是本地文件或不存在，跳过"
fi

# 2c. 验证配置文件 YAML 格式
info "验证配置文件..."
if command -v hysteria &>/dev/null; then
    if hysteria -c "$CONFIG_FILE" check 2>/dev/null; then
        ok "配置文件验证通过"
    else
        warn "配置文件验证失败，请检查 $CONFIG_FILE"
        warn "备份文件已保存，可手动恢复"
        exit 1
    fi
else
    ok "跳过验证（hysteria 命令不可用）"
fi

# ============================================
# 重启服务
# ============================================
info "重启 Hysteria2 服务..."
systemctl restart hysteria-server
sleep 2

if systemctl is-active --quiet hysteria-server; then
    ok "Hysteria2 服务已重启，配置已生效"
else
    error "Hysteria2 服务启动失败！"
    error "请检查日志：journalctl -u hysteria-server -n 30 --no-pager"
    warn "如需回滚，恢复备份配置后重启服务"
    exit 1
fi

# ============================================
# 输出结果
# ============================================
echo ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}   优化完成！${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo ""
echo -e "${YELLOW}已优化项：${PLAIN}"
echo -e "  1. BBR 拥塞控制 + fq 队列"
echo -e "  2. TCP Fast Open"
echo -e "  3. 大缓冲区（高 BDP 链路优化）"
echo -e "  4. QUIC 窗口调优（8MB/16MB）"
echo -e "  5. masquerade 本地化（消除远程延迟）"
echo ""
echo -e "${YELLOW}Telegram 用户必读：${PLAIN}"
echo -e "  如果 Telegram 一直转圈，请在手机端设置："
echo -e "  Telegram 设置 → 高级 → 启用 TCP 连接"
echo -e "  （HTTP 代理不支持 UDP，强制 TCP 即可解决）"
echo ""
echo -e "${YELLOW}关于延迟：${PLAIN}"
echo -e "  v2rayN 显示的 300ms 是物理延迟（中国到美国光速）"
echo -e "  本次优化提升的是吞吐量和稳定性，不是延迟数字"
echo -e "  要降低延迟数字，需换新加坡/日本等近距离 VPS"
echo ""
