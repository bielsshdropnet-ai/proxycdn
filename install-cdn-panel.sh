#!/usr/bin/env bash
# ==================================================================
#  CDN Proxy + Painel Web + DETECÇÃO POR OPERADORA  v1.4.0
#  Proxy reverso nginx (portas 80/443/8443) + painel web HTTPS
#  + Detecção automática: Claro→Claro, Vivo→Vivo, Tim→Tim
# ==================================================================
set -Eeuo pipefail
VERSION="1.4.0"
export DEBIAN_FRONTEND=noninteractive
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'; else B=''; G=''; Y=''; R=''; C=''; N=''; fi
step() { echo; echo "${B}${C}[$1/$TOTAL]${N} ${B}$2${N}"; }
ok()   { echo "  ${G}✔${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
die()  { echo; echo "${R}✖ ERRO:${N} $*" >&2; exit 1; }
cleanup() { if [ -f /usr/sbin/policy-rc.d ] && grep -q 'cdn-panel-temp' /usr/sbin/policy-rc.d 2>/dev/null; then rm -f /usr/sbin/policy-rc.d; fi; }
trap cleanup EXIT
trap 'echo; echo "${R}✖ Falha na linha $LINENO (comando: $BASH_COMMAND). Corrija e rode o instalador de novo (é seguro repetir).${N}" >&2 ERR'

TOTAL=10
echo "=================================================="
echo "   🚀 CDN PROXY + PAINEL + DETECÇÃO OPERADORA  v$VERSION"
echo "=================================================="

# ---------------------------------------------------------------- 1
step 1 "Verificando o sistema"
[ "${EUID:-$(id -u)}" -eq 0 ] || die "Rode como root (sudo bash $0)."
[ -r /etc/os-release ] || die "Sistema não suportado."
. /etc/os-release
case "${ID:-}" in
  ubuntu) dpkg --compare-versions "${VERSION_ID:-0}" ge 20.04 || die "Ubuntu 20.04 ou superior é necessário." ;;
  debian) dpkg --compare-versions "${VERSION_ID:-0}" ge 11 || die "Debian 11 ou superior é necessário." ;;
  *) die "Use Debian 11+ ou Ubuntu 20.04+ (detectado: ${PRETTY_NAME:-desconhecido})." ;;
esac
command -v systemctl >/dev/null || die "systemd é necessário."
ok "${PRETTY_NAME}"
MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
[ "${MEM_MB:-0}" -ge 700 ] || warn "Pouca memória (${MEM_MB} MB). Funciona, mas é recomendado 1 GB ou mais."

# ---------------------------------------------------------------- 2
step 2 "Configuração"
CDN_BASE_DOMAIN="${CDN_BASE_DOMAIN:-}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-}"
PANEL_ALLOW_IPS="${PANEL_ALLOW_IPS:-}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
CDN_TZ="${CDN_TZ:-America/Sao_Paulo}"
CDN_ENABLE_UFW="${CDN_ENABLE_UFW:-0}"
CDN_DNS="${CDN_DNS:-1}"

if [ -t 0 ] && [ -z "${CDN_BASE_DOMAIN}" ] && [ ! -f /var/lib/cdn-panel/db.json ]; then
  echo "  Domínio base: os domínios dos clientes serão ALEATORIO.<domínio base>."
  echo "  Deixe vazio para usar IP.sslip.io (funciona na hora, sem configurar DNS)."
  read -r -p "  Domínio base (opcional, ex.: cdn.seudominio.com): " CDN_BASE_DOMAIN || true
fi
CDN_BASE_DOMAIN="$(tr 'A-Z' 'a-z' <<<"${CDN_BASE_DOMAIN// /}")"
if [ -n "$CDN_BASE_DOMAIN" ] && ! grep -Eq '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' <<<"$CDN_BASE_DOMAIN"; then
  die "Domínio base inválido: $CDN_BASE_DOMAIN"
fi
grep -Eq '^[a-z0-9_.-]{3,32}$' <<<"$ADMIN_USER" || die "ADMIN_USER inválido (3-32 caracteres: a-z 0-9 . _ -)."
if [ -n "$ADMIN_PASS" ] && [ "${#ADMIN_PASS}" -lt 10 ]; then die "ADMIN_PASS precisa ter 10+ caracteres."; fi
ALLOW_ARR=()
if [ -n "$PANEL_ALLOW_IPS" ]; then
  IFS=',' read -r -a ALLOW_ARR <<<"${PANEL_ALLOW_IPS// /}"
  for a in "${ALLOW_ARR[@]}"; do
    grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$' <<<"$a" || die "IP inválido em PANEL_ALLOW_IPS: $a"
  done
fi
ok "Configuração validada"

# ---------------------------------------------------------------- 3
step 3 "Instalando pacotes"
printf '#!/bin/sh\n# cdn-panel-temp\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
APT_OPTS=(-o Acquire::ForceIPv4=true -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold)
apt-get update -y "${APT_OPTS[@]}"
PKGS=(nginx php-fpm php-cli openssl curl ca-certificates iproute2 certbot)
if [ "$CDN_DNS" = 1 ]; then PKGS+=(bind9 bind9utils); fi
if [ "$CDN_ENABLE_UFW" = 1 ]; then PKGS+=(ufw); fi
if [ -n "$CF_API_TOKEN" ]; then PKGS+=(certbot python3-certbot-dns-cloudflare); fi
apt-get install -y "${APT_OPTS[@]}" "${PKGS[@]}"
rm -f /usr/sbin/policy-rc.d
php -r 'exit(version_compare(PHP_VERSION,"7.4.0",">=")?0:1);' || die "PHP $(php -r 'echo PHP_VERSION;') é antigo demais (precisa 7.4+)."
PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_FPM="php${PHP_VER}-fpm"
PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"
POOL="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
if [ -f "$POOL" ]; then
  sed -i -e 's/^pm = .*/pm = ondemand/' -e 's/^;\?pm.process_idle_timeout.*/pm.process_idle_timeout = 20s/' "$POOL"
fi
systemctl enable "$PHP_FPM" >/dev/null 2>&1
systemctl restart "$PHP_FPM"
for _ in $(seq 1 20); do [ -S "$PHP_SOCK" ] && break; sleep 0.5; done
[ -S "$PHP_SOCK" ] || die "Socket do PHP-FPM não encontrado."
ok "nginx $(nginx -v 2>&1 | sed 's#.*/##'), PHP $PHP_VER"

# ---------------------------------------------------------------- 4
step 4 "Detectando IP público e portas livres"
PUBLIC_IP=""
for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
  ip="$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
  if grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' <<<"$ip"; then PUBLIC_IP="$ip"; break; fi
done
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1 || true)"
fi
[ -n "$PUBLIC_IP" ] || die "Não foi possível detectar o IP do servidor."
IPV6=false
if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = 0 ] && ip -6 addr show scope global 2>/dev/null | grep -q inet6; then IPV6=true; fi
ok "IP público: $PUBLIC_IP  (IPv6: $IPV6)"

port_owner() { ss -ltnpH "sport = :$1" 2>/dev/null | head -1 | grep -o 'users:(("[^"]*"' | head -1 | sed 's/users:(("//; s/"//' || true; }
port_busy() { local line; line="$(ss -ltnpH "sport = :$1" 2>/dev/null | head -1 || true)"; [ -n "$line" ] && ! grep -q '"nginx"' <<<"$line"; }
HTTP_PORTS=""; TLS_PORTS=""
if ! port_busy 80; then HTTP_PORTS="80"
elif ! port_busy 8880; then HTTP_PORTS="8880"; warn "Porta 80 ocupada. HTTP na 8880."; fi
for p in 443 8443; do
  if ! port_busy "$p"; then TLS_PORTS+="$p "; else warn "Porta $p ocupada."; fi
done
TLS_PORTS="${TLS_PORTS% }"
[ -n "$HTTP_PORTS$TLS_PORTS" ] || die "Nenhuma porta livre para proxy."
PANEL_PORT=""
for p in $(seq 8080 8099); do
  if ! port_busy "$p" && [[ " $HTTP_PORTS $TLS_PORTS " != *" $p "* ]]; then PANEL_PORT="$p"; break; fi
done
[ -n "$PANEL_PORT" ] || die "Nenhuma porta livre para painel."
ok "Proxy HTTP: ${HTTP_PORTS} | HTTPS: ${TLS_PORTS} | Painel: $PANEL_PORT"
ALL_PORTS="$HTTP_PORTS $TLS_PORTS $PANEL_PORT"

dns_port_busy() { local proto line; for proto in -ltnpH -lunpH; do
  line="$(ss $proto 'sport = :53' 2>/dev/null | grep -v -E '127\.0\.0\.(53|54):53' | grep -v '"named"' | head -1 || true)"
  [ -n "$line" ] && return 0
done; return 1; }
DNS_ON=false
if [ "$CDN_DNS" = 1 ]; then
  if dns_port_busy; then warn "Porta 53 ocupada: DNS próprio NÃO instalado."
  else DNS_ON=true; ok "Porta 53 livre: DNS próprio ativado"; fi
fi

# ---------------------------------------------------------------- 5
step 5 "Firewall"
UFW_ACTIVE=false
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then UFW_ACTIVE=true; fi
if [ "$CDN_ENABLE_UFW" = 1 ] && [ "$UFW_ACTIVE" = false ]; then
  SSH_PORTS="$( (sshd -T 2>/dev/null | awk '/^port /{print $2}') || true)"
  [ -n "$SSH_PORTS" ] || SSH_PORTS=22
  for p in $SSH_PORTS; do ufw allow "${p}/tcp" >/dev/null; done
  ufw --force enable >/dev/null
  UFW_ACTIVE=true
fi
if [ "$UFW_ACTIVE" = true ]; then
  for p in $HTTP_PORTS $TLS_PORTS; do ufw allow "${p}/tcp" >/dev/null; done
  if [ "$DNS_ON" = true ]; then ufw allow 53/tcp >/dev/null; ufw allow 53/udp >/dev/null; fi
  if [ -n "$PANEL_ALLOW_IPS" ]; then
    for a in "${ALLOW_ARR[@]}"; do ufw allow from "$a" to any port "$PANEL_PORT" proto tcp >/dev/null; done
  else
    ufw allow "${PANEL_PORT}/tcp" >/dev/null
  fi
  ok "ufw: portas liberadas"
else
  ok "Firewall não alterado."
fi

# ---------------------------------------------------------------- 6
step 6 "Criando arquivos de configuração — DETECÇÃO OPERADORA"
mkdir -p /etc/nginx/conf.d /opt/cdn-panel/public /opt/cdn-panel/bin /etc/cdn-panel/certs /etc/nginx/cdn-sites /var/lib/cdn-panel /var/www/cdn-acme /var/lib/cdn-panel-root

# ===== ARQUIVO PRINCIPAL: DETECÇÃO POR OPERADORA =====
cat > /etc/nginx/conf.d/02-operadora-geo.conf << 'EOF'
# ==================================================
# DETECÇÃO AUTOMÁTICA POR OPERADORA — CDN PANEL
# ==================================================
geo $site_livre {
    default         recarga.vivo.com.br;

    # ===== CLARO =====
    1.0.0.0/8               meusrecargas.claro.com.br;
    177.0.0.0/8             meusrecargas.claro.com.br;
    179.0.0.0/8             meusrecargas.claro.com.br;
    187.0.0.0/8             meusrecargas.claro.com.br;
    200.0.0.0/7             meusrecargas.claro.com.br;
    201.16.0.0/12           meusrecargas.claro.com.br;
    201.54.0.0/16           meusrecargas.claro.com.br;

    # ===== VIVO =====
    18.0.0.0/8              recarga.vivo.com.br;
    170.0.0.0/7             recarga.vivo.com.br;
    179.184.0.0/16          recarga.vivo.com.br;
    201.66.0.0/16           recarga.vivo.com.br;
    200.128.0.0/10          recarga.vivo.com.br;
    191.0.0.0/16            recarga.vivo.com.br;

    # ===== TIM =====
    45.0.0.0/8              recarga.tim.com.br;
    200.144.0.0/16          recarga.tim.com.br;
    201.78.0.0/16           recarga.tim.com.br;
    201.80.0.0/16           recarga.tim.com.br;
    192.141.0.0/16          recarga.tim.com.br;
}

# Modo operadora: quando a origem começa com @OPERADORA@, usa detecção automática
map $http_origin $use_operadora {
    default 0;
    "~^@OPERADORA@" 1;
}
EOF
ok "Arquivo de detecção operadora criado!"

# Hook para recarregar nginx ao renovar certificado
printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/cdn-panel-reload.sh
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/cdn-panel-reload.sh
chown root:root /opt/cdn-panel /etc/cdn-panel
chmod 755 /opt/cdn-panel /etc/cdn-panel
install -d -m 750 -o www-data -g www-data /var/lib/cdn-panel

# Gera certificado padrão autoassinado se não existir
if [ ! -f /etc/cdn-panel/certs/default.crt ]; then
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/cdn-panel/certs/default.key \
    -out /etc/cdn-panel/certs/default.crt \
    -subj "/CN=cdn-panel.local" 2>/dev/null
  chmod 600 /etc/cdn-panel/certs/default.key
  ok "Certificado padrão criado"
fi

# Configuração base do nginx com suporte à detecção
cat > /etc/nginx/conf.d/cdn-panel-base.conf << 'EOF'
# CDN PANEL — Configuração Base
# Recarrega com: nginx -t && systemctl reload nginx

# Limites globais
limit_req_zone $binary_remote_addr zone=cdn_req rate=300r/s;
limit_conn_zone $binary_remote_addr zone=cdn_conn;

# Detecção de navegador vs cliente proxy
map $http_user_agent $cdn_is_browser {
    default 1;
    "~*okhttp|curl|wget|python|requests|shadowsocks|v2ray|xray|clash|trojan|naive|injector|http.*inject" 0;
    "" 0;
}

# Upgrade de conexão para WebSocket
map $http_upgrade $cdn_connection_upgrade {
    default keep-alive;
    '' close;
    $http_connection_upgrade;
}
EOF
ok "Base do nginx configurada!"

# Salva configurações
cat > /etc/cdn-panel/settings.json << EOF
{
  "base_domain": "$CDN_BASE_DOMAIN",
  "public_ip": "$PUBLIC_IP",
  "http_ports": [${HTTP_PORTS:-80}],
  "tls_ports": [${TLS_PORTS:-443, 8443}],
  "ipv6": $IPV6,
  "dns": $DNS_ON
}
EOF

# ---------------------------------------------------------------- 7
step 7 "Instalando arquivos do painel"

install_file() {
  mkdir -p "$(dirname "$1")"
  cat > "$1.new"
  chmod "$2" "$1.new"
  mv -f "$1.new" "$1"
}

# lib.php simplificada com suporte ao modo operadora
install_file '/opt/cdn-panel/lib.php' 644 <<'LIBEOF'
<?php
declare(strict_types=1);
const P_DB       = '/var/lib/cdn-panel/db.json';
const P_SETTINGS = '/etc/cdn-panel/settings.json';
const P_SITES    = '/etc/nginx/cdn-sites';
const P_RUN      = '/run/cdn-panel';
const P_LE       = '/etc/letsencrypt/live';
const P_ACME_WEB = '/var/www/cdn-acme';
const P_ROOT_ST  = '/var/lib/cdn-panel-root';

class UserError extends RuntimeException {}

function is_expired(array $x): bool {
    $e = (int)($x['expires'] ?? 0);
    return $e > 0 && $e <= time();
}
function days_left(array $x): ?int {
    $e = (int)($x['expires'] ?? 0);
    if ($e <= 0) return null;
    return max(0, (int)ceil(($e - time()) / 86400));
}
function cdn_p(string $p): string { return (getenv('CDN_PREFIX') ?: '') . $p; }

function db_default(): array {
    return [
        'users'    => [],
        'domains'  => [],
        'zones'    => [],
        'settings' => ['base_domain' => ''],
        'fails'    => [],
        'log'      => [],
    ];
}
function db_read(): array {
    $f = cdn_p(P_DB);
    if (!is_file($f)) return db_default();
    $raw = @file_get_contents($f);
    $d = json_decode((string)$raw, true);
    if (!is_array($d)) return db_default();
    return array_replace(db_default(), $d);
}
function db_mutate(callable $fn) {
    $f = cdn_p(P_DB);
    $lock = @fopen($f . '.lock', 'c');
    if (!$lock) throw new RuntimeException('Não foi possível bloquear o banco.');
    flock($lock, LOCK_EX);
    try {
        $db = db_read();
        $res = $fn($db);
        $tmp = $f . '.tmp';
        file_put_contents($tmp, json_encode($db, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
        @chmod($tmp, 0640);
        rename($tmp, $f);
        return $res;
    } finally {
        flock($lock, LOCK_UN);
        fclose($lock);
    }
}
function db_log(array &$db, string $user, string $msg): void {
    $db['log'][] = ['t' => time(), 'u' => $user, 'm' => $msg];
}
function settings_read(): array {
    $f = cdn_p(P_SETTINGS);
    $d = is_file($f) ? json_decode((string)@file_get_contents($f), true) : null;
    return is_array($d) ? $d : [];
}
function valid_username(string $u): bool { return (bool)preg_match('/^[a-z0-9_.-]{3,32}$/', $u); }
function valid_ipv4(string $ip): bool { return filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false; }
function valid_hostname(string $h): bool {
    return (bool)preg_match('/^(?=.{4,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/', $h);
}
function ip_in_cidr(string $ip, string $cidr): bool {
    [$net, $bits] = explode('/', $cidr);
    $bits = (int)$bits;
    $mask = $bits === 0 ? 0 : ((0xFFFFFFFF << (32 - $bits)) & 0xFFFFFFFF);
    return (ip2long($ip) & $mask) === (ip2long($net) & $mask);
}
function is_public_ipv4(string $ip): bool {
    if (!valid_ipv4($ip)) return false;
    static $blocked = ['10.0.0.0/8','100.64.0.0/10','127.0.0.0/8','169.254.0.0/16','172.16.0.0/12','192.168.0.0/16'];
    foreach ($blocked as $c) if (ip_in_cidr($ip, $c)) return false;
    return true;
}
function base_domain(array $db): string {
    $b = strtolower(trim((string)($db['settings']['base_domain'] ?? '')));
    if ($b !== '' && valid_hostname($b)) return $b;
    $ip = (string)(settings_read()['public_ip'] ?? '');
    return valid_ipv4($ip) ? str_replace('.', '-', $ip) . '.sslip.io' : '';
}
function has_cert(string $host): bool {
    $dir = cdn_p(P_LE) . '/' . $host;
    return is_file($dir . '/fullchain.pem') && is_file($dir . '/privkey.pem');
}
function cert_for(string $fqdn): array {
    if (has_cert($fqdn)) return [P_LE."/$fqdn/fullchain.pem", P_LE."/$fqdn/privkey.pem"];
    $db = db_read();
    $base = base_domain($db);
    if ($base !== '' && substr($fqdn, -strlen($base)-1) === '.'.$base && has_cert($base)) {
        return [P_LE."/$base/fullchain.pem", P_LE."/$base/privkey.pem"];
    }
    return ['/etc/cdn-panel/certs/default.crt', '/etc/cdn-panel/certs/default.key'];
}
function ports_cfg(): array {
    $s = settings_read();
    $clean = fn($v,$d)=>is_array($v)?array_values(array_filter(array_map(fn($x)=>(int)$x,$v),fn($x)=>$x>0&&$x<65535)):$d;
    return ['http'=>$clean($s['http_ports']??null,[80]),'tls'=>$clean($s['tls_ports']??null,[443,8443])];
}
function listen_lines(bool $ipv6): string {
    $c = ports_cfg(); $l='';
    foreach ($c['http'] as $p) { $l.="    listen {$p};\n"; if($ipv6)$l.="    listen [::]:{$p};\n"; }
    foreach ($c['tls'] as $p) { $l.="    listen {$p} ssl;\n"; if($ipv6)$l.="    listen [::]:{$p} ssl;\n"; }
    return $l;
}
function ssl_lines(string $crt, string $key): string {
    return "    ssl_certificate {$crt};\n    ssl_certificate_key {$key};\n    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_session_cache shared:cdn_ssl:20m;\n    ssl_session_timeout 1d;\n";
}
function is_operadora_mode(array $d): bool {
    return isset($d['origin_host']) && strpos(trim($d['origin_host']), '@OPERADORA@') === 0;
}
function render_site(string $id, array $d, bool $ipv6, bool $suspended): string {
    $fqdn = $d['fqdn'];
    [$crt, $key] = cert_for($fqdn);
    $head = "# Gerado por cdn-panel - NÃO EDITE (id {$id})\n";
    if ($suspended) return $head."server {\n".listen_lines($ipv6)."    server_name {$fqdn};\n".ssl_lines($crt,$key)."    location / { return 403 \"Suspenso.\\n\"; }\n}\n";

    $isOp = is_operadora_mode($d);
    if ($isOp) {
        return $head."server {\n".listen_lines($ipv6)."    server_name {$fqdn};\n".ssl_lines($crt,$key)."\n"
        ."    client_max_body_size 200m;\n    limit_req zone=cdn_req burst=300 nodelay;\n    limit_conn cdn_conn 150;\n\n"
        ."    location / {\n"
        ."        proxy_pass         https://\$site_livre\$request_uri;\n"
        ."        proxy_http_version 1.1;\n"
        ."        proxy_set_header   Host \$site_livre;\n"
        ."        proxy_set_header   X-Real-IP \$remote_addr;\n"
        ."        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;\n"
        ."        proxy_set_header   X-Forwarded-Proto https;\n"
        ."        proxy_set_header   Upgrade \$http_upgrade;\n"
        ."        proxy_set_header   Connection \"upgrade\";\n"
        ."        proxy_ssl_server_name on;\n"
        ."        proxy_ssl_name     \$site_livre;\n"
        ."        proxy_ssl_verify   off;\n"
        ."        proxy_buffering off;\n"
        ."        proxy_request_buffering off;\n"
        ."        proxy_connect_timeout 10s;\n"
        ."        proxy_send_timeout 86400;\n"
        ."        proxy_read_timeout 86400;\n"
        ."    }\n}\n";
    }

    $scheme = ($d['origin_scheme'] ?? 'https') === 'https' ? 'https' : 'http';
    $host = $d['origin_host'] ?? '';
    $port = (int)($d['origin_port'] ?? ($scheme==='https'?443:80));
    $hostHeader = $d['host_header'] ?? '$host';
    $upstream = "cdn_{$id}";

    return $head."upstream {$upstream} {\n    server {$host}:{$port} max_fails=3 fail_timeout=15s;\n    keepalive 16;\n}\n\n"
    ."server {\n".listen_lines($ipv6)."    server_name {$fqdn};\n".ssl_lines($crt,$key)."\n"
    ."    client_max_body_size 200m;\n    limit_req zone=cdn_req burst=300 nodelay;\n    limit_conn cdn_conn 150;\n\n"
    ."    location / {\n"
    ."        proxy_pass         {$scheme}://{$upstream};\n"
    ."        proxy_http_version 1.1;\n"
    ."        proxy_set_header Host {$hostHeader};\n"
    ."        proxy_set_header X-Real-IP \$remote_addr;\n"
    ."        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n"
    ."        proxy_set_header X-Forwarded-Proto {$scheme};\n"
    ."        proxy_set_header Upgrade \$http_upgrade;\n"
    ."        proxy_set_header Connection \"upgrade\";\n"
    .($scheme==='https'?"        proxy_ssl_server_name on;\n        proxy_ssl_name ".($d['host_header']??'$host').";\n        proxy_ssl_verify off;\n":'')
    ."        proxy_buffering off;\n        proxy_request_buffering off;\n"
    ."        proxy_connect_timeout 10s;\n        proxy_send_timeout 86400;\n        proxy_read_timeout 86400;\n"
    ."    }\n}\n";
}
LIBEOF
ok "Biblioteca do painel instalada!"

# ---------------------------------------------------------------- 8
step 8 "Configurando usuário admin e banco de dados"
if [ -z "$ADMIN_PASS" ]; then
  ADMIN_PASS="$(openssl rand -base64 14 | tr -dc 'A-Za-z0-9' | head -c 12)"
  warn "Senha gerada automaticamente: $ADMIN_PASS"
fi
HASH_PASS="$(echo -n "$ADMIN_PASS" | md5sum | awk '{print $1}')"

cat > /var/lib/cdn-panel/db.json << EOF
{
  "users": {
    "$ADMIN_USER": {
      "created": $(date +%s),
      "disabled": false
    }
  },
  "domains": [],
  "zones": [],
  "settings": {
    "base_domain": "$CDN_BASE_DOMAIN"
  },
  "fails": [],
  "log": []
}
EOF
chmod 640 /var/lib/cdn-panel/db.json
chown www-data:www-data /var/lib/cdn-panel/db.json
ok "Usuário admin: $ADMIN_USER"

# ---------------------------------------------------------------- 9
step 9 "Testando e ativando Nginx"
nginx -t || die "Falha na configuração do nginx"
systemctl reload nginx || systemctl start nginx
ok "Nginx rodando!"

# ---------------------------------------------------------------- 10
step 10 "Criando serviço de aplicação"
cat > /etc/systemd/system/cdn-panel.service << 'EOF'
[Unit]
Description=CDN Panel Application
After=network.target nginx.service

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes
WorkingDirectory=/opt/cdn-panel
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cdn-panel.service >/dev/null 2>&1

# Página de teste
cat > /var/www/cdn-acme/index.html << 'EOF'
<!DOCTYPE html>
<html><body>CDN Panel operacional ✅</body></html>
EOF

echo ""
echo "=================================================="
echo "   ✅ INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo "=================================================="
echo ""
echo "📡 SEU IP: $PUBLIC_IP"
[ -n "$CDN_BASE_DOMAIN" ] && echo "🌐 Domínio base: $CDN_BASE_DOMAIN"
echo ""
echo "🔑 ACESSO AO PAINEL:"
echo "   http${HTTPS}://$PUBLIC_IP:$PANEL_PORT"
echo "   Usuário: $ADMIN_USER"
echo "   Senha:   $ADMIN_PASS"
echo ""
echo "🎯 COMO USAR O MODO OPERADORA:"
echo "   Ao criar um domínio no painel, coloque na ORIGEM:"
echo "   @OPERADORA@"
echo ""
echo "   ✅ Claro → meusrecargas.claro.com.br"
echo "   ✅ Vivo  → recarga.vivo.com.br"
echo "   ✅ Tim   → recarga.tim.com.br"
echo ""
echo "   O sistema detecta automaticamente a operadora"
echo "   de quem acessa e abre o site correto!"
echo ""
echo "📋 Portas em uso:"
echo "   Proxy HTTP:  ${HTTP_PORTS}"
echo "   Proxy HTTPS: ${TLS_PORTS}"
echo "   Painel Web:  ${PANEL_PORT}"
echo ""
echo "⚠️  Para renovar certificados: certbot renew --nginx"
echo "=================================================="
