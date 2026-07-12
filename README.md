# VPN Optimizer - 一键开启 BBR + Hysteria2

解决 3x-ui VPN 延迟高的问题。一条命令，自动完成 BBR 加速 + Hysteria2 安装配置，无需域名和证书。

## 为什么需要这个

如果你用 3x-ui 搭了 VPN，但发现延迟高、速度慢，大概率是两个原因：

1. **没开 BBR** — Linux 默认的拥塞控制算法（CUBIC）在高延迟线路上效率差
2. **协议走的 TCP** — VLESS+Reality 基于 TCP，丢包就卡；Hysteria2 基于 QUIC/UDP，对高延迟、高丢包线路优化极好

这个脚本一次解决两个问题。

## 一键使用

SSH 登录你的 VPS，执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Catboss1999/vpn-optimizer/main/optimize.sh)
```

或者在已下载的仓库目录中：

```bash
sudo bash optimize.sh
```

## 脚本做了什么

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 开启 BBR | 修改 sysctl 配置，启用 Google BBR 拥塞控制算法 |
| 2 | 安装 Hysteria2 | 使用官方安装脚本 |
| 3 | 生成自签证书 | 用 OpenSSL 生成，CN=www.bing.com，有效期 100 年 |
| 4 | 生成随机密码和端口 | 随机 16 位密码 + 20000-50000 随机端口 |
| 5 | 开放防火墙 | UFW / Firewalld / iptables 自动放行 UDP 端口 |
| 6 | 启动服务 | systemctl enable + restart |

运行结束后会自动输出连接信息和一键导入链接。

## 关于自签证书

本脚本使用自签证书，客户端需要开启「跳过证书验证」(insecure / skip-cert-verify)。

**安全性说明**：
- 自签证书不验证服务端身份，理论上存在中间人攻击风险
- 对于个人翻墙使用，风险可接受
- 如果你有域名，可以在 Hysteria2 配置中替换为 Let's Encrypt 证书，关闭 insecure

## 客户端配置

### Shadowrocket (iOS)
1. 添加节点 → 类型选 Hysteria2
2. 填写 IP、端口、密码
3. 打开「允许不安全」开关
4. SNI 填 `www.bing.com`

### v2rayN / Nekoray (Windows)
1. 添加 Hysteria2 节点
2. 填写 IP、端口、密码
3. 勾选 `AllowInsecure`（跳过证书验证）
4. SNI 填 `www.bing.com`

### Clash Meta / mihomo
```yaml
proxies:
  - name: "Hysteria2-Optimized"
    type: hysteria2
    server: 你的服务器IP
    port: 端口
    password: 密码
    sni: www.bing.com
    skip-cert-verify: true
```

## 与原有 3x-ui 节点的关系

- 原来的 VLESS+Reality 节点 **不受影响**，继续可用
- Hysteria2 作为独立服务运行，与 3x-ui 互不干扰
- 两个协议可以同时使用，建议日常用 Hysteria2，备用 VLESS

## 常见问题

**Q: BBR 开启失败？**
A: 你的内核版本太低（需要 4.9+）。执行 `uname -r` 查看，建议升级内核。

**Q: Hysteria2 连不上？**
A: 检查防火墙是否放行了 UDP 端口。云服务商的安全组也需要放行对应 UDP 端口。

**Q: 延迟还是高？**
A: BBR + Hysteria2 解决的是协议层效率问题。如果 VPS 到国内线路本身就差（比如美西普通线路 200ms+），协议优化也只能改善一部分。换 CN2 GIA 线路或日本/新加坡机房可以根本解决。

**Q: 自签证书安全吗？**
A: 对个人翻墙使用，安全风险可接受。不验证服务端身份意味着理论上可能被中间人攻击，但实际上你的 VPS IP 是固定的，风险极低。

## 卸载

```bash
systemctl stop hysteria-server
systemctl disable hysteria-server
bash <(curl -fsSL https://get.hy2.sh/) --remove
rm -rf /etc/hysteria
```

BBR 的卸载（不推荐，BBR 对所有网络连接都有益）：
```bash
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sysctl -p
```

## License

MIT

## 关注我

X(Twitter) 上分享 AI 工具和实用技术教程。
