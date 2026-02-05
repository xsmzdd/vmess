#!/usr/bin/env bash
set -euo pipefail

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "请用 root 运行：sudo bash $0"
    exit 1
  fi
}

is_port_valid() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

rand_alpha12() {
  # 12 位随机大小写英文字母
  LC_ALL=C tr -dc 'A-Za-z' </dev/urandom | head -c 12
}

need_root

echo "=== Dante SOCKS5 安装脚本（随机用户名/密码，适用于容器/无 systemd）==="
read -rp "请输入 SOCKS5 端口 (1-65535) [44855]: " PORT
PORT="${PORT:-44855}"
if ! is_port_valid "$PORT"; then
  echo "端口不合法：$PORT"
  exit 1
fi

USERNAME="socks$(rand_alpha12 | tr 'A-Z' 'a-z' | head -c 8)"
PASSWORD="$(rand_alpha12)"

export DEBIAN_FRONTEND=noninteractive

echo "[1/6] 安装 dante-server / iproute2 / curl ..."
apt-get update -y
apt-get install -y dante-server iproute2 curl

echo "[2/6] 写入 /etc/danted.conf (TCP+UDP, username 认证) ..."
cat >/etc/danted.conf <<EOF
logoutput: stdout

internal: 0.0.0.0 port = ${PORT}
external: 0.0.0.0

method: username
user.privileged: root
user.notprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect disconnect error
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp udp
  log: connect disconnect error
}
EOF

echo "[3/6] 创建系统用户并设置随机密码 ..."
# 若意外重名则重新生成
for _ in {1..10}; do
  if id -u "$USERNAME" >/dev/null 2>&1; then
    USERNAME="socks$(rand_alpha12 | tr 'A-Z' 'a-z' | head -c 8)"
  else
    break
  fi
done
id -u "$USERNAME" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$USERNAME"
echo "${USERNAME}:${PASSWORD}" | chpasswd

echo "[4/6] 校验配置 ..."
danted -t -f /etc/danted.conf

echo "[5/6] 启动 danted（不使用 systemctl）..."
pkill danted >/dev/null 2>&1 || true
nohup danted -f /etc/danted.conf -D >/var/log/danted.log 2>&1 &

sleep 0.6

echo "[6/6] 检测监听 ..."
LISTEN_OK="no"
if ss -lntp 2>/dev/null | grep -q ":${PORT}\b"; then
  LISTEN_OK="yes"
fi

# 获取容器内 IP（可选显示）
IP_IN_CONTAINER="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP_IN_CONTAINER="${IP_IN_CONTAINER:-127.0.0.1}"

echo
echo "================= SOCKS5 搭建完成 ================="
echo "协议: SOCKS5 (Dante)"
echo "监听端口: ${PORT}"
echo "用户名: ${USERNAME}"
echo "密码: ${PASSWORD}"
echo "UDP: 已允许 (注意：外部使用需映射/放行 UDP 端口)"
echo "监听状态: ${LISTEN_OK}"
echo
echo "容器内测试："
echo "  curl -v --socks5-hostname ${USERNAME}:${PASSWORD}@127.0.0.1:${PORT} https://ifconfig.me"
echo
echo "日志查看："
echo "  tail -n 200 /var/log/danted.log"
echo "停止："
echo "  pkill danted"
echo
echo "外部机器测试（把 <服务器IP> 换成你的宿主机公网IP/域名，且确保已映射/放行端口）："
echo "  curl -v --socks5-hostname ${USERNAME}:${PASSWORD}@<服务器IP>:${PORT} https://ifconfig.me"
echo
echo "===================================================="
