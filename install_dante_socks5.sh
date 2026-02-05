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
  # 允许大小写字母+数字+下划线+短横线；长度 1-31；首字符必须是字母或下划线
  # 注意：部分发行版 useradd 可能默认不喜欢大写用户名，所以创建时使用 --force-badname
  local u="$1"
  [[ "$u" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,30}$ ]]
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

# 密码不回显，输入两次确认（允许大小写和数字，实际上脚本不限制字符集，只要非空且两次一致即可）
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

echo "[3/6] 创建/更新系统用户并设置密码 ..."
if id -u "$USERNAME" >/dev/null 2>&1; then
  echo "用户已存在：$USERNAME（将重置密码）"
else
  # 允许大写/“非标准”用户名
  useradd --force-badname -m -s /usr/sbin/nologin "$USERNAME"
  echo "已创建用户：$USERNAME"
fi
echo "${USERNAME}:${PASSWORD}" | chpasswd

echo "[4/6] 校验配置 ..."
danted -t -f /etc/danted.conf

echo "[5/6] 启动 danted（不使用 systemctl）..."
pkill danted >/dev/null 2>&1 || true
nohup danted -f /etc/danted.conf -D >/var/log/danted.log 2>&1 &

sleep 0.8

echo "[6/6] 检测监听 ..."
LISTEN_OK="no"
if ss -lntp 2>/dev/null | grep -q ":${PORT}\b"; then
  LISTEN_OK="yes"
fi

echo
echo "================= SOCKS5 搭建完成 ================="
echo "协议: SOCKS5 (Dante)"
echo "监听端口: ${PORT}"
echo "用户名: ${USERNAME}"
echo "密码: ${PASSWORD}"
echo "UDP: 已允许 (外部使用需映射/放行 UDP 端口)"
echo "监听状态: ${LISTEN_OK}"
echo
echo "容器内测试："
echo "  curl -v --socks5-hostname ${USERNAME}:${PASSWORD}@127.0.0.1:${PORT} https://ifconfig.me"
echo
echo "日志查看："
echo "  tail -n 200 /var/log/danted.log"
echo "停止："
echo "  pkill danted"
echo "===================================================="
