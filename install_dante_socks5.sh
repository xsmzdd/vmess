#!/usr/bin/env bash
set -euo pipefail

# =========================
# Dante SOCKS5 installer (auto detect default NIC) - NO LOG
# =========================

SOCKS_PORT="${SOCKS_PORT:-1080}"
SOCKS_USER="${SOCKS_USER:-socksuser}"
ALLOW_CIDR="${ALLOW_CIDR:-0.0.0.0/0}"  # 建议改成你的固定IP/网段更安全

die() { echo "ERROR: $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请用 root 运行：sudo bash $0"
  fi
}

detect_default_iface() {
  local iface
  iface="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [[ -n "${iface}" ]] || die "无法检测默认网卡（default route）。请检查：ip -4 route"
  echo "${iface}"
}

detect_iface_ipv4() {
  local iface="$1"
  local ip4
  ip4="$(ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  [[ -n "${ip4}" ]] || die "无法获取网卡 ${iface} 的 IPv4 地址。请检查：ip -4 addr show dev ${iface}"
  echo "${ip4}"
}

install_pkgs() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y dante-server iproute2 curl
}

ensure_user() {
  local user="$1"
  if ! id -u "${user}" >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -m "${user}"
  fi
}

write_config() {
  local iface="$1"
  local ip4="$2"

  # 注意：本脚本“取消日志功能”，不会写 logoutput，也不会创建任何日志文件
  cat > /etc/danted.conf <<EOF
# Listen on all interfaces for incoming SOCKS connections
internal: 0.0.0.0 port = ${SOCKS_PORT}

# Outgoing interface (MUST NOT be 0.0.0.0)
external: ${iface}

# Authentication
socksmethod: username
clientmethod: none

# Detected IPv4 on ${iface}: ${ip4}

# Privileges
user.privileged: root
user.notprivileged: nobody

# DNS
resolveprotocol: udp

# Client rules (who can connect to the daemon)
client pass {
  from: ${ALLOW_CIDR} to: 0.0.0.0/0
}

client block {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}

# SOCKS rules (what connected clients may do)
socks pass {
  from: ${ALLOW_CIDR} to: 0.0.0.0/0
  command: connect bind udpassociate
}

socks block {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}
EOF
}

restart_service() {
  systemctl enable danted >/dev/null 2>&1 || true
  systemctl restart danted
  systemctl --no-pager --full status danted || true
}

quick_test() {
  local port="$1"
  echo
  echo "====== Quick test (curl via socks5) ======"
  echo "如果你已经创建了账号密码，可用："
  echo "  curl --socks5-hostname ${SOCKS_USER}:<PASSWORD>@127.0.0.1:${port} https://ifconfig.me"
  echo
  echo "当前监听端口检查："
  ss -lntp | grep -E ":${port}\b" || true
  echo "========================================="
}

main() {
  need_root

  echo "[1/6] 安装依赖与 dante-server..."
  install_pkgs

  echo "[2/6] 自动识别默认出口网卡..."
  local iface
  iface="$(detect_default_iface)"
  echo "默认网卡: ${iface}"

  echo "[3/6] 获取默认网卡 IPv4..."
  local ip4
  ip4="$(detect_iface_ipv4 "${iface}")"
  echo "网卡 ${iface} IPv4: ${ip4}"

  echo "[4/6] 创建服务账号（用于提示/示例；认证走 PAM）..."
  ensure_user "${SOCKS_USER}"

  echo "[5/6] 写入 /etc/danted.conf（external 使用默认网卡名；不配置日志）..."
  write_config "${iface}" "${ip4}"

  echo "[6/6] 启用并启动 danted..."
  restart_service

  echo
  echo "✅ 完成。配置摘要："
  echo "  - internal: 0.0.0.0:${SOCKS_PORT}"
  echo "  - external: ${iface}"
  echo "  - allow CIDR: ${ALLOW_CIDR}"
  echo "  - config: /etc/danted.conf"
  echo "  - log: (disabled)"
  echo
  echo "⚠️ 重要：你需要为系统用户设置密码（用于 SOCKS5 账号密码认证）："
  echo "  passwd ${SOCKS_USER}"
  echo
  quick_test "${SOCKS_PORT}"
}

main "$@"
