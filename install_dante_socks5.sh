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

is_username_valid() {
  # 允许：大小写字母/数字/_/-；首字符必须是字母或下划线；长度 1-31
  local u="$1"
  [[ "$u" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,30}$ ]]
}

detect_default_iface() {
  # 从默认路由中拿 dev
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

detect_iface_ipv4() {
  local iface="$1"
  ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1
}

need_root

echo "=== Dante SOCKS5 安装脚本（手动输入账号密码，适用于容器/无 systemd）==="

read -rp "请输入 SOCKS5 端口 (1-65535) [44855]: " PORT
PORT="${PORT:-44855}"
if ! is_port_valid "$PORT"; then
  echo "端口不合法：$PORT"
  exit 1
fi

read -rp "请输入 SOCKS5 用户名（支持大小写和数字，如 User01）[socksuser]: " USERNAME
USERNAME="${USERNAME:-socksuser}"
if ! is_username_valid "$USERNAME"; then
  echo "用户名不合法：$USERNAME"
  echo "允许：大小写字母/数字/_/-；首字符必须是字母或下划线；长度<=31"
  exit 1
fi

read -rsp "请输入 SOCKS5 密码（不回显，支持大小写和数字）: " PASSWORD
echo
if [[ -z "${PASSWORD}" ]]; then
  echo "密码不能为空"
  exit 1
fi
read -rsp "请再次输入密码确认: " PASSWORD2
echo
if [[ "${PASSWORD}" != "${PASSWORD2}" ]]; then
  echo "两次输入的密码不一致"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[1/7] 安装 dante-server / iproute2 / curl ..."
apt-get update -y
apt-get install -y dante-server iproute2 curl

echo "[2/7] 自动检测默认出口网卡与 IPv4（用于 external 绑定）..."
IFACE="$(detect_default_iface || true)"
if [[ -z "${IFACE}" ]]; then
  echo "未能检测到默认路由网卡，请检查：ip -4 route show default"
  exit 1
fi

IP="$(detect_iface_ipv4 "${IFACE}" || true)"
if [[ -z "${IP}" ]]; then
  echo "未能检测到网卡 ${IFACE} 的 IPv4 地址，请检查：ip -4 addr show dev ${IFACE}"
  exit 1
fi

echo "默认网卡: ${IFACE}"
echo "IPv4: ${IP}"

echo "[3/7] 写入 /etc/danted.conf (TCP+UDP, username 认证；取消日志) ..."
cat >/etc/danted.conf <<EOF
# 对外监听端口（容器内通常用 0.0.0.0）
internal: 0.0.0.0 port = ${PORT}
# 出口绑定必须是具体地址/接口，这里使用默认路由网卡的 IPv4
external: ${IP}

method: username
user.privileged: root
user.notprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp udp
}
EOF

echo "[4/7] 创建/更新系统用户并设置密码 ..."
if id -u "$USERNAME" >/dev/null 2>&1; then
  echo "用户已存在：$USERNAME（将重置密码）"
else
  # 你的环境 useradd 支持 --badnames（不支持 --force-badname）
  if useradd --help 2>&1 | grep -q -- '--badnames'; then
    useradd --badnames -m -s /usr/sbin/nologin "$USERNAME"
  else
    useradd -m -s /usr/sbin/nologin "$USERNAME"
  fi
  echo "已创建用户：$USERNAME"
fi
echo "${USERNAME}:${PASSWORD}" | chpasswd

echo "[5/7] 校验配置 ..."
# 你这版 danted 用 -V 校验（不支持 -t）
danted -V -f /etc/danted.conf

echo "[6/7] 启动 danted（不使用 systemctl；取消日志输出重定向）..."
pkill danted >/dev/null 2>&1 || true

# -D 后台运行；不再 nohup 重定向到 /var/log
danted -f /etc/danted.conf -D

sleep 0.8

echo "[7/7] 检测监听 ..."
LISTEN_OK="no"
if ss -lntp 2>/dev/null | grep -q ":${PORT}\b"; then
  LISTEN_OK="yes"
fi

echo
echo "================= SOCKS5 搭建完成 ================="
echo "协议: SOCKS5 (Dante)"
echo "监听端口: ${PORT}"
echo "external 出口IP: ${IP}"
echo "默认网卡: ${IFACE}"
echo "用户名: ${USERNAME}"
echo "密码: ${PASSWORD}"
echo "UDP: 已允许 (外部使用需映射/放行 UDP 端口)"
echo "监听状态: ${LISTEN_OK}"
echo
echo "容器内测试："
echo "  curl -v --socks5-hostname ${USERNAME}:${PASSWORD}@127.0.0.1:${PORT} https://ifconfig.me"
echo
echo "停止："
echo "  pkill danted"
echo "===================================================="
