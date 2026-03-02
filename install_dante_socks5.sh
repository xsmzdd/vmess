#!/usr/bin/env bash
# 一键安装 SOCKS5 (Dante) - 支持 Debian/Ubuntu & Alpine
# 功能:
#   - 让你输入端口
#   - 自动生成随机用户名和12位大小写密码
#   - 启用 UDP
#   - 配置并启动 danted 服务

set -e

# 必须用 root
if [ "$EUID" -ne 0 ]; then
  echo "请用 root 权限运行此脚本！例如：sudo bash $0"
  exit 1
fi

if [ ! -f /etc/os-release ]; then
  echo "无法识别系统类型（缺少 /etc/os-release）"
  exit 1
fi

. /etc/os-release

echo "检测到系统: $ID"

# 读端口
read -p "请输入 SOCKS5 端口(1-65535): " PORT
if ! echo "$PORT" | grep -Eq '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "端口不合法：$PORT"
  exit 1
fi

# 随机用户名和密码
USERNAME="socks$(tr -dc 'a-z' </dev/urandom | head -c 4)"
PASSWORD="$(tr -dc 'A-Za-z' </dev/urandom | head -c 12)"

echo "即将创建的 SOCKS5 账号：$USERNAME"
echo "随机生成的密码为 12 位大小写字母。"

# 安装 Dante
SERVICE_NAME="danted"

case "$ID" in
  debian|ubuntu)
    echo "使用 APT 安装 dante-server..."
    apt update
    apt install -y dante-server
    ;;

  alpine)
    echo "使用 APK 安装 dante-server..."
    apk update
    apk add dante-server
    ;;

  *)
    echo "暂不支持此系统: $ID"
    exit 1
    ;;
esac

# 找到 nologin 路径
if command -v nologin >/dev/null 2>&1; then
  NOLOGIN_BIN="$(command -v nologin)"
elif [ -x /usr/sbin/nologin ]; then
  NOLOGIN_BIN="/usr/sbin/nologin"
elif [ -x /sbin/nologin ]; then
  NOLOGIN_BIN="/sbin/nologin"
else
  NOLOGIN_BIN="/bin/false"
fi

# 创建系统用户(无家目录无登录)
if id -u "$USERNAME" >/dev/null 2>&1; then
  echo "系统用户 $USERNAME 已存在，跳过创建。"
else
  if command -v useradd >/dev/null 2>&1; then
    useradd -M -s "$NOLOGIN_BIN" "$USERNAME"
  elif command -v adduser >/dev/null 2>&1; then
    # Alpine 的 adduser
    adduser -D -H -s "$NOLOGIN_BIN" "$USERNAME"
  else
    echo "系统中没有 useradd/adduser，无法创建用户。"
    exit 1
  fi
fi

echo "$USERNAME:$PASSWORD" | chpasswd

# 生成 danted 配置
cat >/etc/danted.conf <<EOF
logoutput: syslog

internal: 0.0.0.0 port = $PORT
internal: ::0 port = $PORT
external: 0.0.0.0

method: username
user.privileged: root
user.notprivileged: nobody
user.libwrap: nobody

# 允许所有客户端连接到本机的 SOCKS 端口
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

# 允许 TCP + UDP 转发
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect udp_associate
    log: connect disconnect error
}
EOF

echo "已写入配置文件 /etc/danted.conf"

# 启动并设置开机自启
if [ "$ID" = "alpine" ]; then
  echo "使用 OpenRC 管理服务..."
  rc-update add "$SERVICE_NAME" default || true
  rc-service "$SERVICE_NAME" restart
else
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
  else
    # 兼容老系统
    if command -v service >/dev/null 2>&1; then
      service "$SERVICE_NAME" restart
    elif [ -x "/etc/init.d/$SERVICE_NAME" ]; then
      "/etc/init.d/$SERVICE_NAME" restart
    else
      echo "找不到服务管理命令，请手工重启 $SERVICE_NAME 服务。"
    fi
  fi
fi

echo
echo "================ 安装完成 ================"
echo "SOCKS5 服务器已配置完成（支持 UDP）。"
echo "服务器 IP: 你的服务器公网IP"
echo "端口    : $PORT"
echo "用户名  : $USERNAME"
echo "密码    : $PASSWORD"
echo
echo "在客户端中选择 SOCKS5 + 用户名密码认证，并填写以上信息即可。"
echo "如有防火墙（iptables/ufw/security-group），记得放行端口 $PORT。"
echo "========================================="
