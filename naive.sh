#!/usr/bin/env bash
set -Eeuo pipefail

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

trap 'die "Ошибка на строке $LINENO. Смотри вывод выше."' ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root."
}

check_os() {
  [[ -r /etc/os-release ]] || die "Не удалось определить ОС."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *)
      warn "Скрипт рассчитан на Debian/Ubuntu. Сейчас: ${ID:-unknown} ${VERSION_ID:-unknown}"
      ;;
  esac
}

check_arch() {
  case "$(uname -m)" in
    x86_64) GO_ARCH="amd64" ;;
    aarch64|arm64) GO_ARCH="arm64" ;;
    *)
      die "Неподдерживаемая архитектура: $(uname -m)"
      ;;
  esac
}

check_ports_free() {
  for port in 80 443; do
    if ss -tln "( sport = :$port )" 2>/dev/null | tail -n +2 | grep -q .; then
      die "Порт $port уже занят. Освободи его и запусти скрипт снова."
    fi
  done
}

prompt_inputs() {
  while true; do
    read -r -p "Введите домен или поддомен (например, proxy.example.com): " DOMAIN
    [[ "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] && break
    warn "Домен выглядит некорректно."
  done

  while true; do
    read -r -p "Введите email для TLS (например, admin@example.com): " EMAIL
    [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
    warn "Email выглядит некорректно."
  done

  while true; do
    read -r -p "Сколько пользователей создать? " USERS
    [[ "$USERS" =~ ^[1-9][0-9]*$ ]] && break
    warn "Нужно целое число от 1."
  done
}

gen_token() {
  local len="$1"
  local token=""

  while [[ ${#token} -lt "$len" ]]; do
    token+="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | tr -d '\n')"
  done

  printf '%s' "${token:0:$len}"
}

backup_if_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    local backup="${path}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$path" "$backup"
    log "Сделана резервная копия: $backup"
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget openssl ca-certificates ufw iproute2 tar
}

enable_bbr() {
  local sysctl_file="/etc/sysctl.d/99-naiveproxy-bbr.conf"
  cat > "$sysctl_file" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null || true
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    log "BBR включён."
  else
    warn "BBR не подтвердился. На некоторых ядрах он может быть недоступен."
  fi
}

configure_firewall() {
  ufw allow 22/tcp >/dev/null || true
  ufw allow 80/tcp >/dev/null || true
  ufw allow 443/tcp >/dev/null || true
  ufw --force enable >/dev/null || true
  log "UFW настроен."
}

install_go() {
  log "Установка Go..."
  local go_version
  go_version="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"
  [[ "$go_version" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Не удалось получить версию Go."

  local go_tar="/tmp/${go_version}.linux-${GO_ARCH}.tar.gz"
  wget -q "https://go.dev/dl/${go_version}.linux-${GO_ARCH}.tar.gz" -O "$go_tar"

  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$go_tar"

  export PATH="$PATH:/usr/local/go/bin:/root/go/bin"
  go version
}

build_caddy() {
  export PATH="$PATH:/usr/local/go/bin:/root/go/bin"
  export TMPDIR=/root/tmp
  mkdir -p /root/tmp

  go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

  cd /root
  rm -f /root/caddy

  local caddy_ver="${CADDY_VERSION:-v2.11.2}"
  local fp_ver="${FORWARDPROXY_VERSION:-v2.11.2-naive}"

  /root/go/bin/xcaddy build "$caddy_ver" \
    --with "github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@${fp_ver}"

  install -m 0755 /root/caddy /usr/bin/caddy
  /usr/bin/caddy version
}

create_web_root() {
  mkdir -p /var/www/html /etc/caddy

  cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CDN Storage - Protected Node</title>
    <style>
        :root {
            --bg-color: #0b0f19;
            --card-bg: #151d2a;
            --card-border: #232d3f;
            --text-main: #f1f5f9;
            --text-muted: #64748b;
            --accent: #3b82f6;
            --accent-hover: #2563eb;
            --error-bg: rgba(239, 68, 68, 0.08);
            --error-border: rgba(239, 68, 68, 0.25);
            --error-text: #fca5a5;
        }

        * {
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: var(--bg-color);
            background-image: radial-gradient(circle at 50% 0%, rgba(59, 130, 246, 0.08) 0%, transparent 60%);
            color: var(--text-main);
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            margin: 0;
            padding: 1rem;
        }

        .container {
            text-align: center;
            background: var(--card-bg);
            padding: 2.25rem 2rem;
            border-radius: 16px;
            box-shadow: 0 20px 40px -15px rgba(0, 0, 0, 0.5), 0 0 0 1px rgba(255, 255, 255, 0.05);
            max-width: 410px;
            width: 100%;
            border: 1px solid var(--card-border);
            backdrop-filter: blur(8px);
        }

        .logo {
            font-weight: 700;
            font-size: 1.4rem;
            letter-spacing: -0.03em;
            margin-bottom: 1.5rem;
            color: var(--text-main);
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 0.6rem;
        }

        .logo-icon {
            width: 32px;
            height: 32px;
            background: rgba(59, 130, 246, 0.12);
            border: 1px solid rgba(59, 130, 246, 0.25);
            border-radius: 8px;
            display: flex;
            align-items: center;
            justify-content: center;
            color: var(--accent);
        }

        .logo span {
            color: var(--accent);
        }

        .error-box {
            background-color: var(--error-bg);
            border: 1px solid var(--error-border);
            color: var(--error-text);
            padding: 1rem;
            border-radius: 10px;
            font-size: 1rem;
            margin-bottom: 1.5rem;
            text-align: center;
            line-height: 1.5;
        }

        .btn {
            display: block;
            width: 100%;
            padding: 0.8rem 1rem;
            background-color: var(--accent);
            color: white;
            border: none;
            border-radius: 8px;
            font-weight: 600;
            font-size: 0.92rem;
            cursor: pointer;
            transition: all 0.2s ease;
            box-shadow: 0 4px 12px rgba(59, 130, 246, 0.25);
        }

        .btn:hover {
            background-color: var(--accent-hover);
            transform: translateY(-1px);
            box-shadow: 0 6px 16px rgba(59, 130, 246, 0.35);
        }

        .btn:active {
            transform: translateY(0);
        }

        .footer {
            margin-top: 2rem;
            padding-top: 1.25rem;
            border-top: 1px solid rgba(255, 255, 255, 0.06);
            font-size: 0.8rem;
            color: var(--text-muted);
        }

        .footer-title {
            text-transform: uppercase;
            font-size: 0.8rem;
            letter-spacing: 0.08em;
            font-weight: 600;
            margin-bottom: 0.75rem;
            color: #475569;
        }

        .node-id {
            margin-top: 1rem;
            font-family: monospace;
            font-size: 0.8rem;
            color: #475569;
        }
    </style>
</head>
<body>

<div class="container">
    <div class="logo">
        <div class="logo-icon">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"></path><polyline points="3.27 6.96 12 12.01 20.73 6.96"></polyline><line x1="12" y1="22.08" x2="12" y2="12"></line></svg>
        </div>
        <span>SkyLine</span>CDN
    </div>

    <div class="error-box">
        <center>Please login to continue.</center>
    </div>

    <button class="btn" onclick="showNginxError()">Login to the system</button>

    <div class="footer">
        <div class="footer-title">Ping to other CDN</div>
        <div id="cdnlist"></div>
        <div class="node-id">Node ID: dev-skyline-cdn</div>
    </div>
</div>

<script>
function showNginxError() {
    setTimeout(() => {
        document.open();
        document.write(`<!DOCTYPE html>
<html>
<head>
<title>403 Forbidden</title>
<style>
    body {
        background-color: white;
        color: black;
        font-family: "Times New Roman", Times, serif;
        margin: 0;
        padding: 0;
    }
    .center {
        text-align: center;
        margin-top: 0.7%;
    }
    h1 {
        font-size: 2.5em;
        font-weight: normal;
        margin: 0 0 15px 0;
    }
    hr {
        border: 0;
        border-top: 1px solid #ccc;
        width: 100%;
        margin: 0 0 15px 0;
    }
    p {
        font-size: 1em;
        margin: 0;
    }
    .subtext {
        margin-top: 10px;
        font-size: 1em;
    }
</style>
</head>
<body>
<div class="center">
<h1><strong>403 Forbidden</strong></h1>
<br>
<hr>
<p>nginx/1.30.6</p>
<p class="subtext">IP is outside the permitted access range</p>
</div>
</body>
</html>`);
        document.close();
    }, 2000);
}

const nodes = [
    {name: 'dev-skyline-cdn-fra03', base: 39},
    {name: 'dev-skyline-cdn-ams02', base: 45},
    {name: 'dev-skyline-cdn-hel01', base: 17},
    {name: 'dev-skyline-cdn-par05', base: 56},
    {name: 'dev-skyline-cdn-vie04', base: 119}
];

function rnd(b) {
    return b + Math.floor(Math.random() * 5) - 2;
}

function color(p) {
    return p < 30 ? '#22c55e' : p < 80 ? '#eab308' : '#ef4444';
}

function upd() {
    document.getElementById('cdnlist').innerHTML = nodes.map(n => {
        const p = rnd(n.base);
        return `<div style="display:flex;justify-content:space-between;font-family:monospace;margin-bottom:0.25rem;"><span>${n.name}</span><span style="color:${color(p)}">${p} ms</span></div>`;
    }).join('');
}

upd();
setInterval(upd, 1200);
</script>

</body>
</html>
EOF
}

generate_users() {
  USERS_FILE="/root/naiveproxy-users.txt"
  : > "$USERS_FILE"
  chmod 600 "$USERS_FILE"

  BASIC_AUTH_LINES=""

  for ((i=1; i<=USERS; i++)); do
    login="u${i}_$(gen_token 6)"
    password="$(gen_token 24)"

    BASIC_AUTH_LINES+=$'    basic_auth '"$login"' '"$password"$'\n'

    link="naive+https://${login}:${password}@${DOMAIN}:443"
    printf 'User %d\n  login: %s\n  password: %s\n  link: %s\n\n' \
      "$i" "$login" "$password" "$link" | tee -a "$USERS_FILE" >/dev/null
  done
}

create_caddyfile() {
  backup_if_exists /etc/caddy/Caddyfile

  cat > /etc/caddy/Caddyfile <<EOF
{
  order forward_proxy before file_server
}

:443, ${DOMAIN} {
  tls ${EMAIL}

  forward_proxy {
${BASIC_AUTH_LINES}    hide_ip
    hide_via
    probe_resistance
  }

  file_server {
    root /var/www/html
  }
}
EOF

  chmod 644 /etc/caddy/Caddyfile
  log "Caddyfile создан."
}

create_systemd_unit() {
  backup_if_exists /etc/systemd/system/caddy.service

  cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy with NaiveProxy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

start_service() {
  /usr/bin/caddy validate --config /etc/caddy/Caddyfile
  systemctl enable caddy
  systemctl restart caddy
  systemctl --no-pager --full status caddy || true
}

main() {
  require_root
  check_os
  check_arch
  check_ports_free
  prompt_inputs
  install_packages
  enable_bbr
  configure_firewall
  install_go
  build_caddy
  create_web_root
  generate_users
  create_caddyfile
  create_systemd_unit
  start_service

  log "Готово."
  echo
  echo "Файл с учётными данными: /root/naiveproxy-users.txt"
  echo "Готовая ссылка формата:"
  echo "  naive+https://LOGIN:PASSWORD@${DOMAIN}:443"
  echo
  echo "Проверка логов:"
  echo "  journalctl -u caddy -f"
}

main "$@"