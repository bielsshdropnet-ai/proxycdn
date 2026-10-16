#!/usr/bin/env bash
# ==================================================================
#  CDN Proxy + Painel Web (DROPNET)
#  Proxy reverso nginx (portas 80/443/8443) + painel web HTTPS (8080).
#  Suporta Ubuntu 20.04+ e Debian 11+ (PHP 7.4 ou mais novo).
#  Convive com outros serviços (ex.: SSHPlus): portas já usadas são puladas
#  e o firewall NÃO é alterado, a menos que você peça.
#  Pode ser executado de novo para atualizar.
#
#  Variáveis opcionais (ambiente):
#    CDN_BASE_DOMAIN   domínio base dos domínios gerados (ex.: cdn.seudominio.com)
#    ADMIN_USER        usuário admin do painel (padrão: admin)
#    ADMIN_PASS        senha do admin (padrão: gerada aleatoriamente)
#    PANEL_ALLOW_IPS   IPs liberados no painel, separados por vírgula (padrão: todos)
#    CF_API_TOKEN      token Cloudflare p/ certificado wildcard (requer CDN_BASE_DOMAIN)
#    CDN_DNS=0         não instala o servidor DNS (nameservers próprios)
#    CDN_ENABLE_UFW=1  instala/ativa o ufw (só use em VPS limpa, sem outros serviços)
#    CDN_TZ            fuso do painel (padrão: America/Sao_Paulo)
# ==================================================================
set -Eeuo pipefail

VERSION="1.3.0"
export DEBIAN_FRONTEND=noninteractive

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'; else B=''; G=''; Y=''; R=''; C=''; N=''; fi
step() { echo; echo "${B}${C}[$1/$TOTAL]${N} ${B}$2${N}"; }
ok()   { echo "  ${G}✔${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
die()  { echo; echo "${R}✖ ERRO:${N} $*" >&2; exit 1; }
cleanup() { if [ -f /usr/sbin/policy-rc.d ] && grep -q 'cdn-panel-temp' /usr/sbin/policy-rc.d 2>/dev/null; then rm -f /usr/sbin/policy-rc.d; fi; }
trap cleanup EXIT
trap 'echo; echo "${R}✖ Falha na linha $LINENO (comando: $BASH_COMMAND). Corrija e rode o instalador de novo (é seguro repetir).${N}" >&2' ERR

TOTAL=9

echo "=================================================="
echo "   🚀 CDN PROXY + PAINEL WEB  v$VERSION"
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
CDN_DNS="${CDN_DNS:-1}"   # 1 = servidor DNS próprio (nameservers); 0 = desativa

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
step 3 "Instalando pacotes (pode levar alguns minutos)"
# Impede que o apt tente iniciar o nginx antes de configurarmos (evita falha se a porta 80 estiver ocupada).
printf '#!/bin/sh\n# cdn-panel-temp\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
APT_OPTS=(-o Acquire::ForceIPv4=true -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold)
if command -v fuser >/dev/null 2>&1 && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
  warn "Outro processo do apt está rodando (atualização automática?). Aguardando até 10 minutos..."
fi
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

# PHP-FPM econômico em RAM: só cria processos quando há requisição.
POOL="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
if [ -f "$POOL" ]; then
  sed -i -e 's/^pm = .*/pm = ondemand/' -e 's/^;\?pm.process_idle_timeout.*/pm.process_idle_timeout = 20s/' "$POOL"
fi
systemctl enable "$PHP_FPM" >/dev/null 2>&1
systemctl restart "$PHP_FPM"
for _ in $(seq 1 20); do [ -S "$PHP_SOCK" ] && break; sleep 0.5; done
[ -S "$PHP_SOCK" ] || die "Socket do PHP-FPM não encontrado em $PHP_SOCK."
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
  [ -n "$PUBLIC_IP" ] && warn "Não consegui consultar o IP público; usando o IP da interface ($PUBLIC_IP)."
fi
[ -n "$PUBLIC_IP" ] || die "Não foi possível detectar o IP do servidor."
IPV6=false
if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = 0 ] && ip -6 addr show scope global 2>/dev/null | grep -q inet6; then IPV6=true; fi
ok "IP público: $PUBLIC_IP  (IPv6: $IPV6)"

port_owner() { ss -ltnpH "sport = :$1" 2>/dev/null | head -1 | grep -o 'users:(("[^"]*"' | head -1 | sed 's/users:(("//; s/"//' || true; }
port_busy() { # 0 = ocupada por outro serviço (que não seja o nginx)
  local line; line="$(ss -ltnpH "sport = :$1" 2>/dev/null | head -1 || true)"
  [ -n "$line" ] && ! grep -q '"nginx"' <<<"$line"
}
json_list() { local o=""; for p in $1; do o+="${o:+, }$p"; done; echo "[$o]"; }

HTTP_PORTS=""; TLS_PORTS=""
if ! port_busy 80; then HTTP_PORTS="80"
elif ! port_busy 8880; then HTTP_PORTS="8880"; warn "Porta 80 ocupada por '$(port_owner 80)'. HTTP do proxy ficará na 8880."
else warn "Portas 80 e 8880 ocupadas: o proxy ficará sem HTTP."; fi
for p in 443 8443; do
  if ! port_busy "$p"; then TLS_PORTS+="$p "; else warn "Porta $p ocupada por '$(port_owner "$p")': não será usada pelo proxy."; fi
done
TLS_PORTS="${TLS_PORTS% }"
[ -n "$HTTP_PORTS$TLS_PORTS" ] || die "Nenhuma porta livre para o proxy (80, 8880, 443, 8443)."
PANEL_PORT=""
for p in $(seq 8080 8099); do
  if ! port_busy "$p" && [[ " $HTTP_PORTS $TLS_PORTS " != *" $p "* ]]; then PANEL_PORT="$p"; break; fi
done
[ -n "$PANEL_PORT" ] || die "Nenhuma porta livre entre 8080 e 8099 para o painel."
ok "Proxy HTTP: ${HTTP_PORTS:-nenhuma} | HTTPS: ${TLS_PORTS:-nenhuma} | Painel: $PANEL_PORT"
ALL_PORTS="$HTTP_PORTS $TLS_PORTS $PANEL_PORT"

# --- DNS (porta 53): ignora o stub do systemd-resolved (127.0.0.53) e o próprio named
dns_port_busy() { # 0 = ocupada por outro serviço
  local proto line
  for proto in -ltnpH -lunpH; do
    line="$(ss $proto 'sport = :53' 2>/dev/null | grep -v -E '127\.0\.0\.(53|54):53' | grep -v '"named"' | head -1 || true)"
    [ -n "$line" ] && return 0
  done
  return 1
}
DNS_ON=false
if [ "$CDN_DNS" = 1 ]; then
  if dns_port_busy; then warn "Porta 53 ocupada por outro serviço: o servidor DNS próprio (nameservers) NÃO será instalado."
  else DNS_ON=true; ok "Porta 53 livre: servidor DNS próprio será ativado"; fi
fi

# ---------------------------------------------------------------- 5
step 5 "Firewall"
UFW_ACTIVE=false
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then UFW_ACTIVE=true; fi

if [ "$CDN_ENABLE_UFW" = 1 ] && [ "$UFW_ACTIVE" = false ]; then
  SSH_PORTS="$( (sshd -T 2>/dev/null | awk '/^port /{print $2}') || true)"
  [ -n "$SSH_PORTS" ] || SSH_PORTS=22
  for p in $SSH_PORTS; do ufw allow "${p}/tcp" >/dev/null; ok "SSH liberado na porta $p"; done
  ufw --force enable >/dev/null
  UFW_ACTIVE=true
fi

if [ "$UFW_ACTIVE" = true ]; then
  for p in $HTTP_PORTS $TLS_PORTS; do ufw allow "${p}/tcp" >/dev/null; done
  if [ "$DNS_ON" = true ]; then ufw allow 53/tcp >/dev/null; ufw allow 53/udp >/dev/null; fi
  if [ -n "$PANEL_ALLOW_IPS" ]; then
    for a in "${ALLOW_ARR[@]}"; do ufw allow from "$a" to any port "$PANEL_PORT" proto tcp >/dev/null; done
    ok "Painel ($PANEL_PORT) liberado apenas para: $PANEL_ALLOW_IPS"
  else
    ufw allow "${PANEL_PORT}/tcp" >/dev/null
    warn "Painel ($PANEL_PORT) aberto para a internet. Use PANEL_ALLOW_IPS para restringir."
  fi
  ok "ufw: portas liberadas"
else
  ok "Firewall do servidor não foi alterado (ufw inativo)."
  warn "Se houver firewall (iptables/painel da hospedagem), libere TCP: $ALL_PORTS"
fi

# ---------------------------------------------------------------- 6
step 6 "Instalando painel e arquivos de configuração"
install_file() { # install_file <destino> <modo>
  mkdir -p "$(dirname "$1")"
  cat > "$1.new"
  chmod "$2" "$1.new"
  mv -f "$1.new" "$1"
}

mkdir -p /opt/cdn-panel/public /opt/cdn-panel/bin /etc/cdn-panel/certs /etc/nginx/cdn-sites /var/lib/cdn-panel /var/www/cdn-acme
install -d -m 700 /var/lib/cdn-panel-root
install -d /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/cdn-panel-reload.sh
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/cdn-panel-reload.sh
chown root:root /opt/cdn-panel /etc/cdn-panel
chmod 755 /opt/cdn-panel /etc/cdn-panel
install -d -m 750 -o www-data -g www-data /var/lib/cdn-panel

install_file '/opt/cdn-panel/lib.php' 644 <<'__CDN_FILE_EOF__'
<?php
declare(strict_types=1);

/*
 * CDN Proxy Panel - biblioteca compartilhada (painel web + helper root).
 * Tudo que vira configuração do nginx passa por validação estrita aqui.
 */

const P_DB       = '/var/lib/cdn-panel/db.json';
const P_SETTINGS = '/etc/cdn-panel/settings.json';
const P_SITES    = '/etc/nginx/cdn-sites';
const P_RUN      = '/run/cdn-panel';
const P_REQ      = '/var/lib/cdn-panel/apply.request';
const P_LE       = '/etc/letsencrypt/live';
const P_ACME_WEB = '/var/www/cdn-acme';
const P_ROOT_ST  = '/var/lib/cdn-panel-root';

class UserError extends RuntimeException {}

/** Vencimento por dias: expires = timestamp (0/ausente = sem vencimento). */
function is_expired(array $x): bool
{
    $e = (int)($x['expires'] ?? 0);
    return $e > 0 && $e <= time();
}

/** Dias restantes (arredonda para cima); null = sem vencimento; 0 = vencido. */
function days_left(array $x): ?int
{
    $e = (int)($x['expires'] ?? 0);
    if ($e <= 0) {
        return null;
    }
    return max(0, (int)ceil(($e - time()) / 86400));
}

function parse_days($v): int
{
    $v = trim((string)$v);
    if ($v === '') {
        return 0;
    }
    if (!preg_match('/^\d{1,4}$/', $v)) {
        throw new UserError('Dias inválidos (use um número de 0 a 3650).');
    }
    $n = (int)$v;
    if ($n > 3650) {
        throw new UserError('Máximo de 3650 dias.');
    }
    return $n;
}

function cdn_p(string $p): string
{
    return (getenv('CDN_PREFIX') ?: '') . $p;
}

/* ------------------------------------------------------------------ */
/* Armazenamento (JSON com lock + escrita atômica)                    */
/* ------------------------------------------------------------------ */

function db_default(): array
{
    return [
        'users'    => [],
        'domains'  => [],
        'zones'    => [],
        'settings' => ['base_domain' => ''],
        'fails'    => [],
        'log'      => [],
    ];
}

function db_read(): array
{
    $f = cdn_p(P_DB);
    if (!is_file($f) || is_link($f)) {
        return db_default();
    }
    $raw = @file_get_contents($f, false, null, 0, 8 * 1024 * 1024);
    $d = json_decode((string)$raw, true);
    if (!is_array($d)) {
        return db_default();
    }
    $d = array_replace(db_default(), $d);
    foreach (['users', 'domains', 'zones', 'fails', 'log'] as $k) {
        if (!is_array($d[$k])) {
            $d[$k] = [];
        }
    }
    if (!is_array($d['settings'])) {
        $d['settings'] = ['base_domain' => ''];
    }
    return $d;
}

/** Executa $fn(array &$db) sob lock exclusivo e grava o resultado. Exceção = nada é gravado. */
function db_mutate(callable $fn)
{
    $f = cdn_p(P_DB);
    $lock = @fopen($f . '.lock', 'c');
    if (!$lock) {
        throw new RuntimeException('Não foi possível abrir o lock do banco de dados.');
    }
    flock($lock, LOCK_EX);
    try {
        $db = db_read();
        $res = $fn($db);
        $db['log'] = array_slice($db['log'], -300);
        $tmp = $f . '.tmp';
        $json = json_encode($db, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        if (file_put_contents($tmp, $json) === false) {
            throw new RuntimeException('Falha ao gravar o banco de dados.');
        }
        @chmod($tmp, 0640);
        rename($tmp, $f);
        return $res;
    } finally {
        flock($lock, LOCK_UN);
        fclose($lock);
    }
}

function db_log(array &$db, string $user, string $msg): void
{
    $db['log'][] = ['t' => time(), 'u' => $user, 'm' => $msg];
}

function settings_read(): array
{
    $f = cdn_p(P_SETTINGS);
    $d = is_file($f) ? json_decode((string)@file_get_contents($f), true) : null;
    return is_array($d) ? $d : [];
}

/* ------------------------------------------------------------------ */
/* Validação                                                          */
/* ------------------------------------------------------------------ */

function valid_username(string $u): bool
{
    return (bool)preg_match('/^[a-z0-9_.-]{3,32}$/', $u);
}

function valid_ipv4(string $ip): bool
{
    return filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false;
}

function valid_hostname(string $h): bool
{
    return (bool)preg_match(
        '/^(?=.{4,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:[a-z]{2,63}|xn--[a-z0-9-]{1,59})$/',
        $h
    );
}

function valid_fqdn(string $h): bool
{
    return valid_hostname($h);
}

function ip_in_cidr(string $ip, string $cidr): bool
{
    [$net, $bits] = explode('/', $cidr);
    $bits = (int)$bits;
    $mask = $bits === 0 ? 0 : ((0xFFFFFFFF << (32 - $bits)) & 0xFFFFFFFF);
    return (ip2long($ip) & $mask) === (ip2long($net) & $mask);
}

function is_public_ipv4(string $ip): bool
{
    if (!valid_ipv4($ip)) {
        return false;
    }
    static $blocked = [
        '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
        '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.168.0.0/16', '198.18.0.0/15',
        '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/3',
    ];
    foreach ($blocked as $c) {
        if (ip_in_cidr($ip, $c)) {
            return false;
        }
    }
    return true;
}

function local_ips(): array
{
    $ips = [];
    $out = [];
    @exec('ip -4 -o addr show 2>/dev/null', $out);
    foreach ($out as $line) {
        if (preg_match('/inet (\d+\.\d+\.\d+\.\d+)/', $line, $m)) {
            $ips[] = $m[1];
        }
    }
    $s = settings_read();
    if (!empty($s['public_ip']) && is_string($s['public_ip'])) {
        $ips[] = $s['public_ip'];
    }
    return array_values(array_unique($ips));
}

/** Resolve um nome para IPv4s. (CDN_TEST_HOSTS_FILE existe só para testes automatizados.) */
function dns_lookup(string $host): array
{
    $tf = getenv('CDN_TEST_HOSTS_FILE');
    if ($tf !== false && $tf !== '') {
        $map = json_decode((string)@file_get_contents($tf), true);
        return (is_array($map) && isset($map[$host]) && is_array($map[$host])) ? array_values($map[$host]) : [];
    }
    $r = @gethostbynamel($host);
    return is_array($r) ? $r : [];
}

/** Resolve o host de origem para IPv4s públicos (ordenados, máx. 4). */
function resolve_origin(string $host): array
{
    if (valid_ipv4($host)) {
        $ips = [$host];
    } else {
        $ips = dns_lookup($host);
    }
    $ips = array_values(array_unique($ips));
    sort($ips, SORT_STRING);
    return array_slice($ips, 0, 4);
}

/**
 * Valida e normaliza a origem informada pelo cliente.
 * Retorna scheme, host, port, host_header e ips resolvidos.
 */
function validate_origin(array $in, bool $resolve = true): array
{
    $scheme = strtolower(trim((string)($in['scheme'] ?? 'http')));
    if (!in_array($scheme, ['http', 'https'], true)) {
        throw new UserError('Protocolo da origem deve ser http ou https.');
    }

    $host = strtolower(trim((string)($in['host'] ?? '')));
    if ($host === '') {
        throw new UserError('Informe o IP ou domínio de origem.');
    }
    if (!valid_ipv4($host) && !valid_hostname($host)) {
        throw new UserError('Origem inválida. Use um IPv4 (ex.: 203.0.113.10) ou um domínio (ex.: origem.exemplo.com).');
    }

    $portRaw = trim((string)($in['port'] ?? ''));
    $port = $portRaw === '' ? ($scheme === 'https' ? 443 : 80) : (ctype_digit($portRaw) ? (int)$portRaw : 0);
    if ($port < 1 || $port > 65535) {
        throw new UserError('Porta inválida (1 a 65535).');
    }
    if ($port === 25) {
        throw new UserError('A porta 25 não é permitida.');
    }

    $hh = strtolower(trim((string)($in['host_header'] ?? '')));
    if ($hh !== '' && !valid_hostname($hh) && !valid_ipv4($hh)) {
        throw new UserError('Host header inválido. Deixe vazio ou use um domínio válido.');
    }

    $ips = [];
    if ($resolve) {
        $ips = resolve_origin($host);
        if (!$ips) {
            throw new UserError('Não foi possível resolver o domínio de origem.');
        }
        $local = local_ips();
        foreach ($ips as $ip) {
            if (!is_public_ipv4($ip)) {
                throw new UserError('A origem aponta para um endereço privado/reservado (' . $ip . '), não permitido.');
            }
            if (in_array($ip, $local, true)) {
                throw new UserError('A origem não pode ser o próprio servidor da CDN.');
            }
        }
    }

    return ['scheme' => $scheme, 'host' => $host, 'port' => $port, 'host_header' => $hh, 'ips' => $ips];
}

/** Corta em N caracteres UTF-8 sem depender da extensão mbstring. */
function utf8_cut(string $s, int $n): string
{
    if (@preg_match('/^.{0,' . $n . '}/us', $s, $m) === 1) {
        return $m[0];
    }
    return substr($s, 0, $n);
}

/** Valida um domínio próprio do cliente (ex.: loja.cliente.com). */
function validate_custom_host(string $raw, array $db): string
{
    $h = rtrim(strtolower(trim($raw)), '.');
    if ($h === '') {
        throw new UserError('Informe o domínio que você quer usar.');
    }
    if (!valid_hostname($h)) {
        throw new UserError('Domínio inválido. Use algo como loja.seudominio.com ou seudominio.com (sem http:// e sem barras).');
    }
    $bases = array_filter([base_domain($db), strtolower(trim((string)($db['settings']['base_domain'] ?? '')))]);
    foreach ($bases as $b) {
        if ($h === $b || substr($h, -strlen($b) - 1) === '.' . $b) {
            throw new UserError('Esse domínio pertence à própria CDN. Use um domínio seu.');
        }
    }
    foreach (['.sslip.io', '.nip.io', '.local', '.localhost', '.internal', '.invalid', '.test', '.example'] as $bad) {
        if (substr($h, -strlen($bad)) === $bad) {
            throw new UserError('Esse tipo de domínio não pode ser usado.');
        }
    }
    foreach ($db['domains'] as $d) {
        if (strtolower((string)($d['fqdn'] ?? '')) === $h) {
            throw new UserError('Esse domínio já está cadastrado na CDN.');
        }
    }
    return $h;
}

function clean_label(string $s): string
{
    $s = trim(preg_replace('/[\x00-\x1F\x7F]+/u', ' ', $s) ?? '');
    return utf8_cut($s, 60);
}

function base_domain(array $db): string
{
    $b = strtolower(trim((string)($db['settings']['base_domain'] ?? '')));
    if ($b !== '' && valid_hostname($b)) {
        return $b;
    }
    $ip = (string)(settings_read()['public_ip'] ?? '');
    if (valid_ipv4($ip)) {
        return str_replace('.', '-', $ip) . '.sslip.io';
    }
    return '';
}

/* ------------------------------------------------------------------ */
/* Geração do nginx                                                   */
/* ------------------------------------------------------------------ */

function has_cert(string $host): bool
{
    $dir = cdn_p(P_LE) . '/' . $host;
    return valid_hostname($host) && is_file($dir . '/fullchain.pem') && is_file($dir . '/privkey.pem');
}

function cert_for(string $fqdn): array
{
    if (has_cert($fqdn)) {
        return [P_LE . '/' . $fqdn . '/fullchain.pem', P_LE . '/' . $fqdn . '/privkey.pem'];
    }
    $db = db_read();
    $base = strtolower(trim((string)($db['settings']['base_domain'] ?? '')));
    if ($base !== '' && valid_hostname($base) && substr($fqdn, -strlen($base) - 1) === '.' . $base) {
        $dir = cdn_p(P_LE) . '/' . $base;
        if (is_file($dir . '/fullchain.pem') && is_file($dir . '/privkey.pem')) {
            return [P_LE . '/' . $base . '/fullchain.pem', P_LE . '/' . $base . '/privkey.pem'];
        }
    }
    return ['/etc/cdn-panel/certs/default.crt', '/etc/cdn-panel/certs/default.key'];
}

/** Portas configuradas na instalação (o instalador pula portas já usadas por outros serviços). */
function ports_cfg(): array
{
    $s = settings_read();
    $clean = function ($v, array $def): array {
        if (!is_array($v)) {
            return $def;
        }
        $o = [];
        foreach ($v as $p) {
            if (is_int($p) && $p >= 1 && $p <= 65535) {
                $o[] = $p;
            }
        }
        return array_values(array_unique($o));
    };
    return [
        'http' => $clean($s['http_ports'] ?? null, [80]),
        'tls'  => $clean($s['tls_ports'] ?? null, [443, 8443]),
    ];
}

function listen_lines(bool $ipv6): string
{
    $c = ports_cfg();
    $l = '';
    foreach ($c['http'] as $p) {
        $l .= "    listen {$p};\n";
        if ($ipv6) {
            $l .= "    listen [::]:{$p};\n";
        }
    }
    foreach ($c['tls'] as $p) {
        $l .= "    listen {$p} ssl;\n";
        if ($ipv6) {
            $l .= "    listen [::]:{$p} ssl;\n";
        }
    }
    return $l;
}

/** URL para testar um domínio gerado, respeitando as portas realmente em uso. */
function site_url(string $fqdn): string
{
    $c = ports_cfg();
    if (in_array(80, $c['http'], true)) {
        return 'http://' . $fqdn;
    }
    if ($c['http']) {
        return 'http://' . $fqdn . ':' . $c['http'][0];
    }
    if (in_array(443, $c['tls'], true)) {
        return 'https://' . $fqdn;
    }
    return 'https://' . $fqdn . ':' . ($c['tls'][0] ?? 443);
}

function ssl_lines(string $crt, string $key): string
{
    return "    ssl_certificate {$crt};\n    ssl_certificate_key {$key};\n"
         . "    ssl_protocols TLSv1.2 TLSv1.3;\n"
         . "    ssl_session_cache shared:cdn_ssl:20m;\n"
         . "    ssl_session_timeout 1d;\n";
}

function render_site(string $id, array $d, array $o, bool $ipv6, bool $suspended): string
{
    $fqdn = $d['fqdn'];
    [$crt, $key] = cert_for($fqdn);
    $head = "# Gerado por cdn-panel - NÃO EDITE (id {$id})\n";

    if ($suspended) {
        return $head
            . "server {\n" . listen_lines($ipv6)
            . "    server_name {$fqdn};\n"
            . ssl_lines($crt, $key)
            . "    default_type text/plain;\n"
            . "    location / { return 403 \"Dominio suspenso.\\n\"; }\n}\n";
    }

    $servers = '';
    foreach ($o['ips'] as $ip) {
        $servers .= "    server {$ip}:{$o['port']} max_fails=3 fail_timeout=15s;\n";
    }
    $hostHeader = $o['host_header'] !== '' ? $o['host_header'] : '$host';
    $sni = $o['host_header'] !== '' ? $o['host_header'] : (valid_ipv4($o['host']) ? '$host' : $o['host']);

    $acme = '';
    if (($d['kind'] ?? 'generated') === 'custom') {
        $acme = "    location ^~ /.well-known/acme-challenge/ {\n"
              . "        root " . P_ACME_WEB . ";\n"
              . "        default_type text/plain;\n"
              . "    }\n\n";
    }

    $ssl = '';
    if ($o['scheme'] === 'https') {
        $ssl = "        proxy_ssl_server_name on;\n"
             . "        proxy_ssl_name {$sni};\n"
             . "        proxy_ssl_verify off;\n"
             . "        proxy_ssl_protocols TLSv1.2 TLSv1.3;\n";
    }

    return $head
        . "upstream cdn_{$id} {\n{$servers}    keepalive 16;\n}\n\n"
        . "server {\n" . listen_lines($ipv6)
        . "    server_name {$fqdn};\n"
        . ssl_lines($crt, $key) . "\n"
        . "    client_max_body_size 200m;\n"
        . "    limit_req zone=cdn_req burst=300 nodelay;\n"
        . "    limit_conn cdn_conn 150;\n\n"
        . $acme
        . "    location / {\n"
        . "        proxy_pass {$o['scheme']}://cdn_{$id};\n"
        . "        proxy_http_version 1.1;\n"
        . "        proxy_set_header Host {$hostHeader};\n"
        . "        proxy_set_header X-Real-IP \$remote_addr;\n"
        . "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n"
        . "        proxy_set_header X-Forwarded-Proto \$scheme;\n"
        . "        proxy_set_header Upgrade \$http_upgrade;\n"
        . "        proxy_set_header Connection \$cdn_connection_upgrade;\n"
        . $ssl
        . "        proxy_connect_timeout 10s;\n"
        . "        proxy_send_timeout 1d;\n"
        . "        proxy_read_timeout 1d;\n"
        . "        proxy_buffering off;\n"
        . "        proxy_request_buffering off;\n"
        . "        proxy_next_upstream error timeout http_502 http_503 http_504;\n"
        . "    }\n}\n";
}

/* ------------------------------------------------------------------ */
/* Aplicação (roda como root via systemd)                             */
/* ------------------------------------------------------------------ */

function run_cmd(string $cmd): array
{
    $out = [];
    $rc = 0;
    exec($cmd . ' 2>&1', $out, $rc);
    return [$rc, trim(implode("\n", $out))];
}

function write_run_json(string $name, array $data): void
{
    $dir = cdn_p(P_RUN);
    if (!is_dir($dir)) {
        @mkdir($dir, 0755, true);
    }
    $tmp = $dir . '/' . $name . '.tmp';
    file_put_contents($tmp, json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    chmod($tmp, 0644);
    rename($tmp, $dir . '/' . $name);
}

function read_run_json(string $name): array
{
    $f = cdn_p(P_RUN) . '/' . $name;
    $d = is_file($f) ? json_decode((string)@file_get_contents($f), true) : null;
    return is_array($d) ? $d : [];
}

function write_status(array $domains): void
{
    write_run_json('status.json', ['t' => time(), 'domains' => $domains, 'zones' => $GLOBALS['cdn_zone_status'] ?? []]);
}

function publish_result(array $r): void
{
    $prev = read_run_json('apply.result');
    $r['seq'] = (int)($prev['seq'] ?? 0) + 1;
    $r['t'] = time();
    unset($r['pending'], $r['status'], $r['hostId']);
    write_run_json('apply.result', $r);
}

function acme_available(): bool
{
    if (!in_array(80, ports_cfg()['http'], true)) {
        return false;
    }
    [$rc] = run_cmd('command -v ' . escapeshellarg(getenv('CDN_CERTBOT') ?: 'certbot'));
    return $rc === 0;
}

/** Emite certificados Let's Encrypt (HTTP-01) para domínios próprios. Retorna host => issued|retry|queued. */
function acme_run(array $hosts): array
{
    $res = [];
    $dir = cdn_p(P_ROOT_ST);
    @mkdir($dir, 0700, true);
    @mkdir(cdn_p(P_ACME_WEB), 0755, true);
    $stF = $dir . '/acme.json';
    $st = is_file($stF) ? json_decode((string)@file_get_contents($stF), true) : [];
    if (!is_array($st)) {
        $st = [];
    }
    $bin = getenv('CDN_CERTBOT') ?: 'certbot';
    $now = time();
    $n = 0;
    foreach ($hosts as $h) {
        if (!valid_hostname($h)) {
            continue;
        }
        $s = $st[$h] ?? ['fails' => 0, 'last' => 0];
        $wait = ((int)$s['fails']) > 0 ? min(3600 * (int)$s['fails'], 86400) : 0;
        if ($now - (int)$s['last'] < $wait) {
            $res[$h] = 'retry';
            continue;
        }
        if ($n >= 3) {
            $res[$h] = 'queued';
            continue;
        }
        $n++;
        [$rc, $out] = run_cmd(
            'timeout 150 ' . escapeshellarg($bin) . ' certonly --webroot -w ' . escapeshellarg(P_ACME_WEB)
            . ' -d ' . escapeshellarg($h) . ' --cert-name ' . escapeshellarg($h)
            . ' --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring'
        );
        if ($rc === 0 && has_cert($h)) {
            unset($st[$h]);
            $res[$h] = 'issued';
        } else {
            $st[$h] = ['fails' => (int)$s['fails'] + 1, 'last' => $now, 'err' => utf8_cut($out, 300)];
            $res[$h] = 'retry';
        }
    }
    file_put_contents($stF, json_encode($st));
    @chmod($stF, 0600);
    return $res;
}

/** Fluxo completo: aplica o nginx; se houver domínios próprios sem certificado, emite e aplica de novo. */
function cdn_apply(): array
{
    $GLOBALS['cdn_zone_status'] = [];
    $dns = cdn_apply_dns(db_read());
    $r = cdn_apply_pass();
    if ($dns['msg'] !== '') {
        $r['msg'] = $dns['msg'] . ' ' . $r['msg'];
    }
    if (!$dns['ok']) {
        $r['ok'] = false;
    }
    if (!$r['ok'] || !$r['pending']) {
        publish_result($r);
        return $r;
    }
    publish_result(array_merge($r, ['msg' => $r['msg'] . ' Emitindo certificados HTTPS em segundo plano...']));

    $res = acme_run($r['pending']);
    $issued = array_keys(array_filter($res, function ($s) {
        return $s === 'issued';
    }));

    $final = $r;
    $status = $r['status'];
    $hostId = $r['hostId'];
    if ($issued) {
        $final = cdn_apply_pass();
        $status = $final['status'];
        $hostId = $final['hostId'];
        if ($final['ok']) {
            $final['msg'] .= ' Certificados HTTPS emitidos: ' . implode(', ', $issued) . '.';
        }
    }
    foreach ($res as $h => $st) {
        $id = $hostId[$h] ?? null;
        if ($id !== null && isset($status[$id]) && $st !== 'issued') {
            $status[$id]['cert'] = ($st === 'queued') ? 'pending' : 'retry';
        }
    }
    write_status($status);
    if ($issued) {
        publish_result($final);
    }
    return $final;
}

function cdn_apply_pass(): array
{
    $settings = settings_read();
    $ipv6 = !empty($settings['ipv6']);
    $db = db_read();

    $files = [];
    $status = [];
    $pending = [];
    $hostId = [];
    $pubIp = (string)($settings['public_ip'] ?? '');
    $acmeOk = acme_available();

    foreach (all_domains($db) as $id => $d) {
        $id = (string)$id;
        try {
            if (!is_array($d) || !preg_match('/^[a-f0-9]{8}$/', $id)) {
                throw new UserError('registro inválido');
            }
            if (!isset($d['fqdn']) || !valid_site_name((string)$d['fqdn'])) {
                throw new UserError('domínio gerado inválido');
            }
            $owner = (string)($d['owner'] ?? '');
            $user = $db['users'][$owner] ?? null;
            $suspended = (($d['status'] ?? 'active') !== 'active') || !$user || !empty($user['disabled']) || is_expired($d);

            if ($suspended) {
                $files[$id . '.conf'] = render_site($id, $d, [], $ipv6, true);
                $status[$id] = ['state' => 'suspended', 'ips' => []];
                continue;
            }

            $custom = (($d['kind'] ?? 'generated') === 'custom');
            if ($custom) {
                $probe = (strncmp((string)$d['fqdn'], '*.', 2) === 0) ? 'cdn-probe.' . substr((string)$d['fqdn'], 2) : (string)$d['fqdn'];
                $seen = dns_lookup($probe);
                if ($pubIp === '' || !in_array($pubIp, $seen, true)) {
                    $status[$id] = ['state' => 'pending_dns', 'dns' => false, 'seen' => $seen, 'ips' => []];
                    continue;
                }
            }

            $o = validate_origin($d, true);
            $files[$id . '.conf'] = render_site($id, $d, $o, $ipv6, false);
            $status[$id] = ['state' => 'active', 'ips' => $o['ips']];
            if ($custom) {
                $status[$id]['dns'] = true;
                if (strncmp((string)$d['fqdn'], '*.', 2) === 0) {
                    $status[$id]['cert'] = 'unavailable';
                } elseif (has_cert((string)$d['fqdn'])) {
                    $status[$id]['cert'] = 'ok';
                } elseif ($acmeOk) {
                    $status[$id]['cert'] = 'pending';
                    $pending[] = (string)$d['fqdn'];
                    $hostId[(string)$d['fqdn']] = $id;
                } else {
                    $status[$id]['cert'] = 'unavailable';
                }
            }
        } catch (UserError $e) {
            $status[$id] = ['state' => 'error', 'msg' => $e->getMessage(), 'ips' => []];
        }
    }

    $dir = cdn_p(P_SITES);
    if (!is_dir($dir) && !@mkdir($dir, 0755, true)) {
        return ['ok' => false, 'changed' => false, 'msg' => 'Não foi possível criar ' . $dir, 'pending' => [], 'status' => $status, 'hostId' => []];
    }

    $old = [];
    foreach (glob($dir . '/*.conf') ?: [] as $f) {
        $old[basename($f)] = (string)file_get_contents($f);
    }

    ksort($old);
    ksort($files);
    if ($old === $files) {
        write_status($status);
        return ['ok' => true, 'changed' => false, 'msg' => 'Nenhuma alteração necessária.', 'pending' => $pending, 'status' => $status, 'hostId' => $hostId];
    }

    $restore = function () use ($dir, $old): void {
        foreach (glob($dir . '/*.conf') ?: [] as $f) {
            @unlink($f);
        }
        foreach ($old as $name => $content) {
            file_put_contents($dir . '/' . $name, $content);
        }
    };

    foreach (glob($dir . '/*.conf') ?: [] as $f) {
        if (!isset($files[basename($f)])) {
            @unlink($f);
        }
    }
    foreach ($files as $name => $content) {
        $tmp = $dir . '/.' . $name . '.tmp';
        file_put_contents($tmp, $content);
        chmod($tmp, 0644);
        rename($tmp, $dir . '/' . $name);
    }

    [$rc, $out] = run_cmd(getenv('CDN_NGINX_T') ?: 'nginx -t');
    if ($rc !== 0) {
        $restore();
        return ['ok' => false, 'changed' => false, 'msg' => 'nginx -t falhou, alterações desfeitas: ' . utf8_cut($out, 600), 'pending' => [], 'status' => $status, 'hostId' => []];
    }

    [$rc, $out] = run_cmd(getenv('CDN_NGINX_RELOAD') ?: 'systemctl reload-or-restart nginx');
    if ($rc !== 0) {
        $restore();
        run_cmd(getenv('CDN_NGINX_RELOAD') ?: 'systemctl reload-or-restart nginx');
        return ['ok' => false, 'changed' => false, 'msg' => 'Falha ao recarregar o nginx, alterações desfeitas: ' . utf8_cut($out, 600), 'pending' => [], 'status' => $status, 'hostId' => []];
    }

    write_status($status);
    return ['ok' => true, 'changed' => true, 'msg' => 'Configuração aplicada (' . count($files) . ' domínio(s) no ar).', 'pending' => $pending, 'status' => $status, 'hostId' => $hostId];
}

/* ------------------------------------------------------------------ */
/* Senhas                                                             */
/* ------------------------------------------------------------------ */

function random_password(int $len = 20): string
{
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    $out = '';
    for ($i = 0; $i < $len; $i++) {
        $out .= $chars[random_int(0, strlen($chars) - 1)];
    }
    return $out;
}

function check_password_policy(string $p): void
{
    if (strlen($p) < 10) {
        throw new UserError('A senha precisa ter pelo menos 10 caracteres.');
    }
    if (strlen($p) > 200) {
        throw new UserError('Senha muito longa.');
    }
}

require_once __DIR__ . '/lib_dns.php';
__CDN_FILE_EOF__
install_file '/opt/cdn-panel/lib_dns.php' 644 <<'__CDN_FILE_EOF__'
<?php
declare(strict_types=1);

/*
 * Servidor DNS próprio (BIND9, apenas autoritativo) - zonas dos clientes, estilo Cloudflare.
 * O cliente troca os nameservers no registro do domínio e gerencia os registros no painel.
 * Registros "proxied" respondem com o IP da CDN e viram sites no nginx (origem = valor do registro).
 */

const P_BIND_CONF  = '/etc/bind/cdn-zones.conf';
const P_BIND_ZONES = '/etc/bind/cdn-zones';
const DNS_TYPES    = ['A', 'AAAA', 'CNAME', 'MX', 'TXT'];
const DNS_MAX_RECS = 200;

function dns_enabled(): bool
{
    return !empty(settings_read()['dns']);
}

/** Nameservers que o cliente deve configurar. Padrão: ns1/ns2 sob o domínio base. */
function ns_names(array $db): array
{
    $s = is_array($db['settings'] ?? null) ? $db['settings'] : [];
    $base = base_domain($db);
    $n1 = strtolower(trim((string)($s['ns1'] ?? '')));
    $n2 = strtolower(trim((string)($s['ns2'] ?? '')));
    if (!valid_hostname($n1)) {
        $n1 = $base !== '' ? 'ns1.' . $base : '';
    }
    if (!valid_hostname($n2)) {
        $n2 = $base !== '' ? 'ns2.' . $base : '';
    }
    return ['ns1' => $n1, 'ns2' => $n2];
}

function zones_related(string $a, string $b): bool
{
    return $a === $b
        || substr($a, -strlen($b) - 1) === '.' . $b
        || substr($b, -strlen($a) - 1) === '.' . $a;
}

/** Valida o domínio (zona) que o cliente quer gerenciar. */
function validate_zone_name(string $raw, array $db, string $exceptId = ''): string
{
    $h = rtrim(strtolower(trim($raw)), '.');
    if ($h === '') {
        throw new UserError('Informe o domínio (ex.: seudominio.com).');
    }
    if (!valid_hostname($h)) {
        throw new UserError('Domínio inválido. Use só o domínio, como seudominio.com (sem http:// e sem barras).');
    }
    static $suffixes = ['com.br', 'net.br', 'org.br', 'gov.br', 'edu.br', 'co.uk', 'org.uk', 'com.au', 'co.nz',
        'co.za', 'com.ar', 'com.mx', 'co.in', 'com.pt', 'com.co', 'com.pe', 'com.ve', 'co.jp'];
    if (in_array($h, $suffixes, true)) {
        throw new UserError('Esse é um sufixo público, não um domínio. Use o domínio completo (ex.: meusite.com.br).');
    }
    $protect = array_filter([base_domain($db), strtolower(trim((string)($db['settings']['base_domain'] ?? '')))]);
    $nsn = ns_names($db);
    foreach ($nsn as $n) {
        if ($n !== '') {
            $protect[] = $n;
        }
    }
    foreach ($protect as $b) {
        if (zones_related($h, (string)$b) && $h !== '') {
            if ($h === $b || substr($h, -strlen($b) - 1) === '.' . $b || substr($b, -strlen($h) - 1) === '.' . $h) {
                throw new UserError('Esse domínio pertence à própria CDN. Use um domínio seu.');
            }
        }
    }
    foreach (['.sslip.io', '.nip.io', '.local', '.localhost', '.internal', '.invalid', '.test', '.example'] as $bad) {
        if (substr($h, -strlen($bad)) === $bad) {
            throw new UserError('Esse tipo de domínio não pode ser usado.');
        }
    }
    foreach ($db['zones'] as $zid => $z) {
        if ((string)$zid === $exceptId) {
            continue;
        }
        $zn = (string)($z['name'] ?? '');
        if ($zn === $h) {
            throw new UserError('Esse domínio já está cadastrado na CDN.');
        }
        if ($zn !== '' && zones_related($h, $zn)) {
            throw new UserError('Esse domínio entra em conflito com outro já cadastrado (' . $zn . ').');
        }
    }
    foreach ($db['domains'] as $d) {
        $f = strtolower((string)($d['fqdn'] ?? ''));
        if ($f === $h || substr($f, -strlen($h) - 1) === '.' . $h) {
            throw new UserError('Já existem domínios simples cadastrados dentro desse domínio. Remova-os antes.');
        }
    }
    return $h;
}

/** Valida/normaliza um registro DNS do cliente. */
function validate_record(array $in, string $zone, array $zoneRecords, string $exceptId = ''): array
{
    $type = strtoupper(trim((string)($in['type'] ?? '')));
    if (!in_array($type, DNS_TYPES, true)) {
        throw new UserError('Tipo de registro inválido.');
    }

    $name = rtrim(strtolower(trim((string)($in['name'] ?? ''))), '.');
    if ($name === '' || $name === $zone) {
        $name = '@';
    } elseif (substr($name, -strlen($zone) - 1) === '.' . $zone) {
        $name = substr($name, 0, -strlen($zone) - 1);
    }
    if ($name !== '@') {
        $lab = '[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?';
        if (!preg_match('/^(?:\*|' . $lab . ')(?:\.' . $lab . ')*$/', $name) || strlen($name) > 190) {
            throw new UserError('Nome inválido. Use @ (domínio raiz), www, api, *, etc.');
        }
    }

    $value = trim((string)($in['value'] ?? ''));
    $ttl = (int)($in['ttl'] ?? 300);
    if ($ttl < 60 || $ttl > 86400) {
        $ttl = 300;
    }
    $wantProxy = !empty($in['proxied']);
    if ($wantProxy && !in_array($type, ['A', 'CNAME'], true)) {
        throw new UserError('Só registros A e CNAME podem passar pelo proxy da CDN.');
    }

    $rec = ['type' => $type, 'name' => $name, 'ttl' => $ttl, 'proxied' => false];

    switch ($type) {
        case 'A':
            if (!valid_ipv4($value)) {
                throw new UserError('O valor de um registro A deve ser um IPv4 (ex.: 203.0.113.10).');
            }
            break;
        case 'AAAA':
            if (filter_var($value, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) === false) {
                throw new UserError('O valor de um registro AAAA deve ser um IPv6 válido.');
            }
            $value = strtolower($value);
            break;
        case 'CNAME':
            $value = rtrim(strtolower($value), '.');
            if (!valid_hostname($value)) {
                throw new UserError('O valor de um CNAME deve ser um domínio (ex.: destino.exemplo.com).');
            }
            if ($name === '@' && !$wantProxy) {
                throw new UserError('Não é possível usar CNAME na raiz do domínio (use um registro A, ou ative o proxy da CDN).');
            }
            break;
        case 'MX':
            $value = rtrim(strtolower($value), '.');
            if (!valid_hostname($value)) {
                throw new UserError('O valor de um MX deve ser o servidor de e-mail (ex.: mail.exemplo.com).');
            }
            $prio = (int)($in['prio'] ?? 10);
            if ($prio < 0 || $prio > 65535) {
                throw new UserError('Prioridade do MX inválida (0 a 65535).');
            }
            $rec['prio'] = $prio;
            break;
        case 'TXT':
            if ($value === '' || strlen($value) > 1000 || !preg_match('/^[\x20-\x7E]+$/', $value) || strpbrk($value, "\"\\") !== false) {
                throw new UserError('TXT inválido: use até 1000 caracteres simples (sem aspas e sem barra invertida).');
            }
            break;
    }
    $rec['value'] = $value;

    if ($wantProxy) {
        $o = validate_origin([
            'scheme'      => $in['scheme'] ?? 'http',
            'host'        => $value,
            'port'        => $in['port'] ?? '',
            'host_header' => $in['host_header'] ?? '',
        ], true);
        $rec['proxied'] = true;
        $rec['value'] = $o['host'];
        $rec['scheme'] = $o['scheme'];
        $rec['port'] = $o['port'];
        $rec['host_header'] = $o['host_header'];
    }

    foreach ($zoneRecords as $r) {
        if (($r['id'] ?? '') === $exceptId || ($r['name'] ?? '') !== $name) {
            continue;
        }
        $rt = (string)($r['type'] ?? '');
        if ($type === 'CNAME' || $rt === 'CNAME') {
            throw new UserError('Já existe um registro com esse nome. Um CNAME não pode coexistir com outros registros.');
        }
        if (!empty($r['proxied']) && in_array($type, ['A', 'AAAA'], true)) {
            throw new UserError('Esse nome já usa o proxy da CDN.');
        }
        if ($rec['proxied'] && in_array($rt, ['A', 'AAAA'], true)) {
            throw new UserError('Já existe um registro A/AAAA com esse nome. Remova-o antes de ativar o proxy.');
        }
        if ($rt === $type && strcasecmp((string)($r['value'] ?? ''), $rec['value']) === 0 && (($r['prio'] ?? null) === ($rec['prio'] ?? null))) {
            throw new UserError('Esse registro já existe.');
        }
    }
    if (count($zoneRecords) >= DNS_MAX_RECS && $exceptId === '') {
        throw new UserError('Limite de ' . DNS_MAX_RECS . ' registros por domínio atingido.');
    }
    return $rec;
}

function new_record_id(array $db): string
{
    do {
        $id = bin2hex(random_bytes(4));
        $used = isset($db['domains'][$id]);
        foreach ($db['zones'] as $zid => $z) {
            if ((string)$zid === $id) {
                $used = true;
            }
            foreach (($z['records'] ?? []) as $r) {
                if (($r['id'] ?? '') === $id) {
                    $used = true;
                }
            }
        }
    } while ($used);
    return $id;
}

/** Domínios (sites) gerados a partir dos registros "proxied" das zonas. */
function zone_domains(array $db): array
{
    $out = [];
    foreach ($db['zones'] as $zid => $z) {
        $zn = (string)($z['name'] ?? '');
        $susp = (($z['status'] ?? 'active') !== 'active') || is_expired($z);
        foreach (($z['records'] ?? []) as $r) {
            if (empty($r['proxied'])) {
                continue;
            }
            $rid = (string)($r['id'] ?? '');
            $nm = (string)($r['name'] ?? '@');
            $out[$rid] = [
                'id' => $rid, 'owner' => (string)($z['owner'] ?? ''), 'label' => '', 'kind' => 'custom', 'zone' => (string)$zid,
                'fqdn' => $nm === '@' ? $zn : $nm . '.' . $zn,
                'scheme' => (string)($r['scheme'] ?? 'http'), 'host' => (string)($r['value'] ?? ''),
                'port' => (int)($r['port'] ?? 80), 'host_header' => (string)($r['host_header'] ?? ''),
                'status' => $susp ? 'suspended' : 'active',
            ];
        }
    }
    return $out;
}

function all_domains(array $db): array
{
    return $db['domains'] + zone_domains($db);
}

function valid_site_name(string $fq): bool
{
    if (strncmp($fq, '*.', 2) === 0) {
        return valid_hostname(substr($fq, 2));
    }
    return valid_hostname($fq);
}

/* ------------------------------------------------------------------ */
/* Geração da zona                                                    */
/* ------------------------------------------------------------------ */

function dns_ns_lookup(string $zone): array
{
    $tf = getenv('CDN_TEST_HOSTS_FILE');
    if ($tf !== false && $tf !== '') {
        $map = json_decode((string)@file_get_contents($tf), true);
        return (is_array($map) && isset($map['ns:' . $zone]) && is_array($map['ns:' . $zone])) ? array_values($map['ns:' . $zone]) : [];
    }
    $out = [];
    foreach ((array)@dns_get_record($zone . '.', DNS_NS) as $x) {
        if (!empty($x['target'])) {
            $out[] = strtolower(rtrim((string)$x['target'], '.'));
        }
    }
    $out = array_values(array_unique($out));
    sort($out);
    return $out;
}

function txt_quote(string $v): string
{
    $parts = str_split($v, 255);
    return '"' . implode('" "', $parts) . '"';
}

/** Corpo da zona (com @@SERIAL@@ no lugar do serial). */
function render_zone_body(string $zone, array $records, array $ns, string $pubIp): string
{
    $parent = preg_replace('/^[^.]+\./', '', $ns['ns1']);
    $rname = 'hostmaster.' . (strpos((string)$parent, '.') !== false ? $parent : $ns['ns1']) . '.';
    $o = "\$TTL 300\n"
       . "@ IN SOA {$ns['ns1']}. {$rname} ( @@SERIAL@@ 3600 600 1209600 300 )\n"
       . "@ IN NS {$ns['ns1']}.\n"
       . "@ IN NS {$ns['ns2']}.\n";

    $have = [];
    foreach ($records as $r) {
        $have[$r['name']] = true;
    }
    foreach ($ns as $n) {
        if (substr($n, -strlen($zone) - 1) === '.' . $zone) {
            $lbl = substr($n, 0, -strlen($zone) - 1);
            if (empty($have[$lbl])) {
                $o .= "{$lbl} IN A {$pubIp}\n";
            }
        }
    }

    foreach ($records as $r) {
        $nm = $r['name'];
        $ttl = (int)$r['ttl'];
        if (!empty($r['proxied'])) {
            $o .= "{$nm} {$ttl} IN A {$pubIp}\n";
            continue;
        }
        switch ($r['type']) {
            case 'A':
            case 'AAAA':
                $o .= "{$nm} {$ttl} IN {$r['type']} {$r['value']}\n";
                break;
            case 'CNAME':
                $o .= "{$nm} {$ttl} IN CNAME {$r['value']}.\n";
                break;
            case 'MX':
                $o .= "{$nm} {$ttl} IN MX " . (int)($r['prio'] ?? 10) . " {$r['value']}.\n";
                break;
            case 'TXT':
                $o .= "{$nm} {$ttl} IN TXT " . txt_quote((string)$r['value']) . "\n";
                break;
        }
    }
    return $o;
}

/** Revalida (defesa em profundidade) os registros vindos do banco antes de gerar a zona. */
function sane_records(array $z, string $zone): array
{
    $out = [];
    foreach (($z['records'] ?? []) as $r) {
        if (!is_array($r)) {
            continue;
        }
        try {
            $clean = validate_record_stored($r, $zone);
            $clean['id'] = (string)($r['id'] ?? '');
            $out[] = $clean;
        } catch (UserError $e) {
            // registro inválido é ignorado
        }
    }
    return $out;
}

function validate_record_stored(array $r, string $zone): array
{
    $type = (string)($r['type'] ?? '');
    if (!in_array($type, DNS_TYPES, true)) {
        throw new UserError('tipo');
    }
    $name = (string)($r['name'] ?? '');
    $lab = '[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?';
    if ($name !== '@' && !preg_match('/^(?:\*|' . $lab . ')(?:\.' . $lab . ')*$/', $name)) {
        throw new UserError('nome');
    }
    $value = (string)($r['value'] ?? '');
    $ok = false;
    switch ($type) {
        case 'A':
            $ok = valid_ipv4($value);
            break;
        case 'AAAA':
            $ok = filter_var($value, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) !== false;
            break;
        case 'CNAME':
        case 'MX':
            $ok = valid_hostname($value);
            break;
        case 'TXT':
            $ok = $value !== '' && strlen($value) <= 1000 && preg_match('/^[\x20-\x7E]+$/', $value) && strpbrk($value, "\"\\") === false;
            break;
    }
    if (!$ok) {
        throw new UserError('valor');
    }
    $ttl = (int)($r['ttl'] ?? 300);
    $out = ['type' => $type, 'name' => $name, 'value' => $value, 'ttl' => ($ttl >= 60 && $ttl <= 86400) ? $ttl : 300,
            'proxied' => !empty($r['proxied'])];
    if ($type === 'MX') {
        $out['prio'] = max(0, min(65535, (int)($r['prio'] ?? 10)));
    }
    return $out;
}

/** Gera as zonas do BIND, valida e recarrega. Falha aqui não impede o nginx. */
function cdn_apply_dns(array $db): array
{
    $settings = settings_read();
    if (empty($settings['dns'])) {
        return ['ok' => true, 'changed' => false, 'msg' => '', 'zones' => []];
    }
    $ns = ns_names($db);
    $pub = (string)($settings['public_ip'] ?? '');
    $zdir = cdn_p(P_BIND_ZONES);
    $confF = cdn_p(P_BIND_CONF);
    @mkdir($zdir, 0755, true);
    @mkdir(cdn_p(P_ROOT_ST), 0700, true);
    $stF = cdn_p(P_ROOT_ST) . '/zones-state.json';
    $state = is_file($stF) ? json_decode((string)@file_get_contents($stF), true) : [];
    if (!is_array($state)) {
        $state = [];
    }

    $zstatus = [];
    $stanzas = '';
    $newFiles = [];
    $newState = [];
    $checkCmd = getenv('CDN_NAMED_CHECKZONE') ?: 'named-checkzone -q';

    foreach ($db['zones'] as $zid => $z) {
        $zid = (string)$zid;
        $name = (string)($z['name'] ?? '');
        try {
            if (!preg_match('/^[a-f0-9]{8}$/', $zid) || !valid_hostname($name)) {
                throw new UserError('registro inválido');
            }
            if ($ns['ns1'] === '' || $ns['ns2'] === '') {
                throw new UserError('Nameservers não configurados (defina em Sistema).');
            }
            if (!valid_ipv4($pub)) {
                throw new UserError('IP público da CDN desconhecido.');
            }
            $body = render_zone_body($name, sane_records($z, $name), $ns, $pub);
            $hash = sha1($body);
            $prev = $state[$name] ?? ['hash' => '', 'serial' => 0];
            $serial = ($prev['hash'] === $hash) ? (int)$prev['serial'] : max((int)$prev['serial'] + 1, time());
            $text = str_replace('@@SERIAL@@', (string)$serial, $body);

            $tmp = $zdir . '/.' . $name . '.zone.chk';
            file_put_contents($tmp, $text);
            [$rc, $out] = run_cmd($checkCmd . ' ' . escapeshellarg($name) . ' ' . escapeshellarg($tmp));
            @unlink($tmp);
            if ($rc !== 0) {
                throw new UserError('Zona inválida: ' . utf8_cut($out, 200));
            }
            $newFiles[$name . '.zone'] = $text;
            $newState[$name] = ['hash' => $hash, 'serial' => $serial];
            $stanzas .= "zone \"{$name}\" {\n    type master;\n    file \"" . P_BIND_ZONES . "/{$name}.zone\";\n"
                      . "    allow-transfer { none; };\n    allow-update { none; };\n    notify no;\n};\n\n";

            $seen = dns_ns_lookup($name);
            $mine = array_values(array_filter([$ns['ns1'], $ns['ns2']]));
            $okNs = $seen && !array_diff($seen, $mine);
            $zstatus[$zid] = ['ns' => $okNs ? 'ok' : 'pending', 'seen' => $seen];
        } catch (UserError $e) {
            $zstatus[$zid] = ['ns' => 'error', 'msg' => $e->getMessage(), 'seen' => []];
        }
    }

    $oldFiles = [];
    foreach (glob($zdir . '/*.zone') ?: [] as $f) {
        $oldFiles[basename($f)] = (string)file_get_contents($f);
    }
    $oldConf = is_file($confF) ? (string)file_get_contents($confF) : '';
    $conf = "# Gerado pelo cdn-panel. NÃO EDITE.\n" . $stanzas;

    ksort($oldFiles);
    ksort($newFiles);
    if ($oldFiles === $newFiles && $oldConf === $conf) {
        $GLOBALS['cdn_zone_status'] = $zstatus;
        return ['ok' => true, 'changed' => false, 'msg' => '', 'zones' => $zstatus];
    }

    $restore = function () use ($zdir, $confF, $oldFiles, $oldConf): void {
        foreach (glob($zdir . '/*.zone') ?: [] as $f) {
            @unlink($f);
        }
        foreach ($oldFiles as $n => $c) {
            file_put_contents($zdir . '/' . $n, $c);
        }
        file_put_contents($confF, $oldConf);
    };

    foreach (glob($zdir . '/*.zone') ?: [] as $f) {
        if (!isset($newFiles[basename($f)])) {
            @unlink($f);
        }
    }
    foreach ($newFiles as $n => $c) {
        $tmp = $zdir . '/.' . $n . '.tmp';
        file_put_contents($tmp, $c);
        chmod($tmp, 0644);
        rename($tmp, $zdir . '/' . $n);
    }
    file_put_contents($confF, $conf);
    chmod($confF, 0644);

    [$rc, $out] = run_cmd(getenv('CDN_NAMED_CHECKCONF') ?: 'named-checkconf');
    if ($rc !== 0) {
        $restore();
        return ['ok' => false, 'changed' => false, 'msg' => 'DNS: configuração inválida, alterações desfeitas: ' . utf8_cut($out, 300), 'zones' => $zstatus];
    }
    [$rc, $out] = run_cmd(getenv('CDN_DNS_RELOAD') ?: 'systemctl reload-or-restart bind9');
    if ($rc !== 0) {
        $restore();
        run_cmd(getenv('CDN_DNS_RELOAD') ?: 'systemctl reload-or-restart bind9');
        return ['ok' => false, 'changed' => false, 'msg' => 'DNS: falha ao recarregar o BIND, alterações desfeitas: ' . utf8_cut($out, 300), 'zones' => $zstatus];
    }

    file_put_contents($stF, json_encode($newState));
    @chmod($stF, 0600);
    $GLOBALS['cdn_zone_status'] = $zstatus;
    return ['ok' => true, 'changed' => true, 'msg' => 'DNS atualizado (' . count($newFiles) . ' zona(s)).', 'zones' => $zstatus];
}
__CDN_FILE_EOF__
install_file '/opt/cdn-panel/public/index.php' 644 <<'__CDN_FILE_EOF__'
<?php
declare(strict_types=1);

require __DIR__ . '/../lib.php';

date_default_timezone_set((string)(settings_read()['timezone'] ?? 'America/Sao_Paulo'));

$secure = !empty($_SERVER['HTTPS']);
$nonce = base64_encode(random_bytes(16));

header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header('Cache-Control: no-store');
header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-$nonce'; img-src 'self' data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'");

session_name('cdnsid');
session_set_cookie_params(['lifetime' => 0, 'path' => '/', 'secure' => $secure, 'httponly' => true, 'samesite' => 'Strict']);
session_start();

/* ---------------------------- helpers ---------------------------- */

function h($s): string
{
    return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function csrf(): string
{
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf'];
}

function csrf_field(string $action): string
{
    return '<input type="hidden" name="csrf" value="' . h(csrf()) . '"><input type="hidden" name="a" value="' . h($action) . '">';
}

function flash(string $type, string $msg): void
{
    $_SESSION['flash'][] = [$type, $msg];
}

function go(string $page = 'dash', array $q = []): void
{
    $q = ['p' => $page] + $q;
    header('Location: ?' . http_build_query($q));
    exit;
}

function client_ip(): string
{
    return (string)($_SERVER['REMOTE_ADDR'] ?? '0.0.0.0');
}

function me(): ?array
{
    static $cache = false;
    if ($cache !== false) {
        return $cache;
    }
    $name = $_SESSION['user'] ?? null;
    if (!$name) {
        return $cache = null;
    }
    $u = db_read()['users'][$name] ?? null;
    if (!$u || !empty($u['disabled'])) {
        $_SESSION = [];
        return $cache = null;
    }
    $u['name'] = $name;
    return $cache = $u;
}

function is_admin(): bool
{
    return (me()['role'] ?? '') === 'admin';
}

function require_admin(): void
{
    if (!is_admin()) {
        http_response_code(403);
        exit('Acesso negado.');
    }
}

function apply_proxy(): array
{
    $prev = (int)(read_run_json('apply.result')['seq'] ?? 0);
    @file_put_contents(cdn_p(P_REQ), (string)microtime(true));
    $deadline = microtime(true) + 25;
    while (microtime(true) < $deadline) {
        usleep(250000);
        $r = read_run_json('apply.result');
        if ((int)($r['seq'] ?? 0) > $prev) {
            return [(bool)($r['ok'] ?? false), (string)($r['msg'] ?? '')];
        }
    }
    return [false, 'A aplicação ainda está pendente. Atualize a página em alguns segundos.'];
}

function fmt_time(int $t): string
{
    return date('d/m/Y H:i', $t);
}

function owner_domains(array $db, string $owner): array
{
    return array_filter($db['domains'], fn($d) => ($d['owner'] ?? '') === $owner);
}

function owner_zones(array $db, string $owner): array
{
    return array_filter($db['zones'], fn($z) => ($z['owner'] ?? '') === $owner);
}

/** Retorna a zona se o usuário for dono (ou admin); senão null. */
function zone_for(array $db, string $zid, string $user): ?array
{
    $z = $db['zones'][$zid] ?? null;
    if (!is_array($z)) {
        return null;
    }
    if (($z['owner'] ?? '') !== $user && !is_admin()) {
        return null;
    }
    return $z;
}

function back_for(string $a): array
{
    if (in_array($a, ['user_create', 'user_update', 'user_reset', 'user_delete'], true)) {
        return ['users', []];
    }
    if ($a === 'pw_change') {
        return ['account', []];
    }
    if (in_array($a, ['settings_save', 'apply_now', 'ns_save'], true)) {
        return ['settings', []];
    }
    if ($a === 'domain_update') {
        return ['edit', ['id' => (string)($_POST['id'] ?? '')]];
    }
    if (in_array($a, ['rec_add', 'rec_delete', 'rec_proxy', 'zone_days'], true)) {
        return ['zone', ['id' => (string)($_POST['zone'] ?? '')]];
    }
    if (in_array($a, ['zone_create', 'zone_delete', 'zone_toggle'], true)) {
        return ['zones', []];
    }
    return ['dash', []];
}

/* ------------------------------ ações ------------------------------ */

function handle_post(): void
{
    $a = (string)($_POST['a'] ?? '');

    if ($a === 'login') {
        do_login();
        return;
    }
    if (!me()) {
        go('login');
    }
    if (!hash_equals(csrf(), (string)($_POST['csrf'] ?? ''))) {
        http_response_code(400);
        exit('Token CSRF inválido. Volte e tente novamente.');
    }

    $me = me();
    $user = $me['name'];

    try {
        switch ($a) {
            case 'logout':
                $_SESSION = [];
                session_destroy();
                header('Location: ?p=login');
                exit;

            case 'domain_create':
                $kind = (($_POST['kind'] ?? 'auto') === 'custom') ? 'custom' : 'generated';
                $o = validate_origin($_POST);
                $label = clean_label((string)($_POST['label'] ?? ''));
                $days = is_admin() ? parse_days($_POST['days'] ?? '') : 0;
                $customHost = '';
                if ($kind === 'custom') {
                    $customHost = validate_custom_host((string)($_POST['custom_host'] ?? ''), db_read());
                }
                $made = db_mutate(function (array &$db) use ($user, $o, $label, $kind, $customHost, $days) {
                    $max = (int)($db['users'][$user]['max_domains'] ?? 0);
                    if ($max > 0 && count(owner_domains($db, $user)) >= $max) {
                        throw new UserError("Você atingiu o limite de $max domínio(s).");
                    }
                    $base = base_domain($db);
                    do {
                        $id = bin2hex(random_bytes(4));
                    } while (isset($db['domains'][$id]));
                    if ($kind === 'custom') {
                        $fqdn = validate_custom_host($customHost, $db);
                        $target = $base !== '' ? $id . '.' . $base : '';
                    } else {
                        if ($base === '') {
                            throw new UserError('O domínio base ainda não foi configurado pelo administrador.');
                        }
                        $fqdn = $id . '.' . $base;
                        $target = '';
                    }
                    if (!valid_fqdn($fqdn)) {
                        throw new UserError('Não foi possível gerar um domínio válido.');
                    }
                    $db['domains'][$id] = [
                        'id' => $id, 'owner' => $user, 'label' => $label, 'fqdn' => $fqdn,
                        'kind' => $kind, 'target' => $target,
                        'scheme' => $o['scheme'], 'host' => $o['host'], 'port' => $o['port'],
                        'host_header' => $o['host_header'], 'status' => 'active', 'created' => time(),
                        'expires' => $days > 0 ? time() + $days * 86400 : 0,
                    ];
                    db_log($db, $user, "Criou $fqdn ($kind) -> {$o['scheme']}://{$o['host']}:{$o['port']}");
                    return ['id' => $id, 'fqdn' => $fqdn, 'target' => $target];
                });
                [$ok, $msg] = apply_proxy();
                if ($kind === 'custom') {
                    $pub = (string)(settings_read()['public_ip'] ?? 'IP da CDN');
                    flash($ok ? 'ok' : 'err', 'Domínio ' . $made['fqdn'] . ' adicionado. Agora aponte o DNS dele: registro A → ' . $pub
                        . ($made['target'] !== '' ? ' (ou CNAME → ' . $made['target'] . ')' : '')
                        . '. Quando o DNS propagar ele entra no ar sozinho e o HTTPS é emitido automaticamente.'
                        . ($ok ? '' : ' Aviso: ' . $msg));
                } elseif ($ok) {
                    flash('ok', 'Domínio criado e ativo.');
                } else {
                    flash('err', 'Domínio salvo, mas houve um problema ao aplicar: ' . $msg);
                }
                go('dash');

            case 'dns_check':
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $ok ? 'Verificação concluída. O estado dos domínios foi atualizado.' : $msg);
                go('dash');

            case 'domain_update':
                $id = (string)($_POST['id'] ?? '');
                $o = validate_origin($_POST);
                $label = clean_label((string)($_POST['label'] ?? ''));
                $setDays = (is_admin() && trim((string)($_POST['days'] ?? '')) !== '' && ($_POST['days'] ?? '') !== ($_POST['days_orig'] ?? ''))
                    ? parse_days($_POST['days']) : null;
                db_mutate(function (array &$db) use ($id, $o, $label, $user, $setDays) {
                    $d = $db['domains'][$id] ?? null;
                    if (!$d || (($d['owner'] ?? '') !== $user && !is_admin())) {
                        throw new UserError('Domínio não encontrado.');
                    }
                    $db['domains'][$id] = array_merge($d, [
                        'label' => $label, 'scheme' => $o['scheme'], 'host' => $o['host'],
                        'port' => $o['port'], 'host_header' => $o['host_header'],
                    ]);
                    if ($setDays !== null) {
                        $db['domains'][$id]['expires'] = $setDays > 0 ? time() + $setDays * 86400 : 0;
                        db_log($db, $user, "Prazo de {$d['fqdn']}: " . ($setDays > 0 ? "$setDays dia(s)" : 'sem vencimento'));
                    }
                    db_log($db, $user, "Alterou {$d['fqdn']} -> {$o['scheme']}://{$o['host']}:{$o['port']}");
                });
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $ok ? 'Domínio atualizado.' : 'Salvo, mas houve problema ao aplicar: ' . $msg);
                go('dash');

            case 'domain_delete':
                $id = (string)($_POST['id'] ?? '');
                db_mutate(function (array &$db) use ($id, $user) {
                    $d = $db['domains'][$id] ?? null;
                    if (!$d || (($d['owner'] ?? '') !== $user && !is_admin())) {
                        throw new UserError('Domínio não encontrado.');
                    }
                    unset($db['domains'][$id]);
                    db_log($db, $user, "Excluiu {$d['fqdn']}");
                });
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $ok ? 'Domínio excluído.' : 'Excluído, mas houve problema ao aplicar: ' . $msg);
                go('dash');

            case 'domain_toggle':
                require_admin();
                $id = (string)($_POST['id'] ?? '');
                $state = db_mutate(function (array &$db) use ($id, $user) {
                    $d = $db['domains'][$id] ?? null;
                    if (!$d) {
                        throw new UserError('Domínio não encontrado.');
                    }
                    $new = ($d['status'] ?? 'active') === 'active' ? 'suspended' : 'active';
                    $db['domains'][$id]['status'] = $new;
                    db_log($db, $user, ($new === 'active' ? 'Reativou ' : 'Suspendeu ') . $d['fqdn']);
                    return $new;
                });
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $ok ? ($state === 'active' ? 'Domínio reativado.' : 'Domínio suspenso.') : $msg);
                go('dash');

            case 'user_create':
                require_admin();
                $name = strtolower(trim((string)($_POST['username'] ?? '')));
                $pass = (string)($_POST['password'] ?? '');
                $max = max(0, min(10000, (int)($_POST['max_domains'] ?? 5)));
                if (!valid_username($name)) {
                    throw new UserError('Usuário inválido (3-32 caracteres: letras minúsculas, números, . _ -).');
                }
                if ($pass === '') {
                    $pass = random_password(16);
                }
                check_password_policy($pass);
                db_mutate(function (array &$db) use ($name, $pass, $max, $user) {
                    if (isset($db['users'][$name])) {
                        throw new UserError('Esse usuário já existe.');
                    }
                    $db['users'][$name] = [
                        'hash' => password_hash($pass, PASSWORD_DEFAULT), 'role' => 'client',
                        'max_domains' => $max, 'disabled' => false, 'created' => time(),
                    ];
                    db_log($db, $user, "Criou o cliente '$name'");
                });
                flash('ok', "Cliente '$name' criado. Senha: $pass (anote agora, ela não será exibida de novo).");
                go('users');

            case 'user_update':
                require_admin();
                $name = (string)($_POST['username'] ?? '');
                $max = max(0, min(10000, (int)($_POST['max_domains'] ?? 0)));
                $disabled = !empty($_POST['disabled']);
                db_mutate(function (array &$db) use ($name, $max, $disabled, $user) {
                    if (!isset($db['users'][$name])) {
                        throw new UserError('Usuário não encontrado.');
                    }
                    if ($name === $user && $disabled) {
                        throw new UserError('Você não pode desativar a si mesmo.');
                    }
                    $db['users'][$name]['max_domains'] = $max;
                    $db['users'][$name]['disabled'] = $disabled;
                    db_log($db, $user, "Atualizou '$name' (limite $max, " . ($disabled ? 'desativado' : 'ativo') . ')');
                });
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $ok ? 'Usuário atualizado.' : $msg);
                go('users');

            case 'user_reset':
                require_admin();
                $name = (string)($_POST['username'] ?? '');
                $pass = random_password(16);
                db_mutate(function (array &$db) use ($name, $pass, $user) {
                    if (!isset($db['users'][$name])) {
                        throw new UserError('Usuário não encontrado.');
                    }
                    $db['users'][$name]['hash'] = password_hash($pass, PASSWORD_DEFAULT);
                    db_log($db, $user, "Redefiniu a senha de '$name'");
                });
                flash('ok', "Nova senha de '$name': $pass (anote agora).");
                go('users');

            case 'user_delete':
                require_admin();
                $name = (string)($_POST['username'] ?? '');
                db_mutate(function (array &$db) use ($name, $user) {
                    if (!isset($db['users'][$name])) {
                        throw new UserError('Usuário não encontrado.');
                    }
                    if ($name === $user) {
                        throw new UserError('Você não pode excluir a si mesmo.');
                    }
                    foreach ($db['domains'] as $id => $d) {
                        if (($d['owner'] ?? '') === $name) {
                            unset($db['domains'][$id]);
                        }
                    }
                    foreach ($db['zones'] as $zid => $z) {
                        if (($z['owner'] ?? '') === $name) {
                            unset($db['zones'][$zid]);
                        }
                    }
                    unset($db['users'][$name]);
                    db_log($db, $user, "Excluiu o usuário '$name' e seus domínios");
                });
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $ok ? 'Usuário e domínios excluídos.' : $msg);
                go('users');

            case 'pw_change':
                $cur = (string)($_POST['current'] ?? '');
                $new = (string)($_POST['new'] ?? '');
                if ($new !== (string)($_POST['new2'] ?? '')) {
                    throw new UserError('A confirmação da nova senha não confere.');
                }
                check_password_policy($new);
                db_mutate(function (array &$db) use ($cur, $new, $user) {
                    if (!password_verify($cur, (string)($db['users'][$user]['hash'] ?? ''))) {
                        throw new UserError('Senha atual incorreta.');
                    }
                    $db['users'][$user]['hash'] = password_hash($new, PASSWORD_DEFAULT);
                    db_log($db, $user, 'Alterou a própria senha');
                });
                session_regenerate_id(true);
                flash('ok', 'Senha alterada.');
                go('account');

            case 'settings_save':
                require_admin();
                $base = strtolower(trim((string)($_POST['base_domain'] ?? '')));
                if ($base !== '' && !valid_hostname($base)) {
                    throw new UserError('Domínio base inválido.');
                }
                db_mutate(function (array &$db) use ($base, $user) {
                    $db['settings']['base_domain'] = $base;
                    db_log($db, $user, 'Domínio base: ' . ($base !== '' ? $base : '(padrão sslip.io)'));
                });
                flash('ok', 'Configurações salvas. Os domínios já criados continuam como estão.');
                go('settings');

            case 'apply_now':
                require_admin();
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $msg);
                go('settings');

            case 'zone_create':
                if (!dns_enabled()) {
                    throw new UserError('O servidor DNS não está ativo nesta CDN.');
                }
                $nsn = ns_names(db_read());
                if ($nsn['ns1'] === '' || $nsn['ns2'] === '') {
                    throw new UserError('Os nameservers ainda não foram configurados (admin: Sistema).');
                }
                $origin = null;
                if (trim((string)($_POST['host'] ?? '')) !== '') {
                    $origin = validate_origin($_POST, true);
                }
                $zname = (string)($_POST['zone_name'] ?? '');
                $days = is_admin() ? parse_days($_POST['days'] ?? '') : 0;
                $zid = db_mutate(function (array &$db) use ($user, $zname, $origin, $days) {
                    $max = (int)($db['users'][$user]['max_domains'] ?? 0);
                    if ($max > 0 && count(owner_domains($db, $user)) + count(owner_zones($db, $user)) >= $max) {
                        throw new UserError("Você atingiu o limite de $max domínio(s).");
                    }
                    $zn = validate_zone_name($zname, $db);
                    do {
                        $zid = bin2hex(random_bytes(4));
                    } while (isset($db['zones'][$zid]) || isset($db['domains'][$zid]));
                    $db['zones'][$zid] = ['id' => $zid, 'owner' => $user, 'name' => $zn, 'status' => 'active', 'created' => time(), 'records' => [], 'expires' => $days > 0 ? time() + $days * 86400 : 0];
                    if ($origin !== null) {
                        foreach (['@', 'www'] as $nm) {
                            $db['zones'][$zid]['records'][] = [
                                'id' => new_record_id($db), 'type' => valid_ipv4($origin['host']) ? 'A' : 'CNAME', 'name' => $nm,
                                'value' => $origin['host'], 'ttl' => 300, 'proxied' => true,
                                'scheme' => $origin['scheme'], 'port' => $origin['port'], 'host_header' => $origin['host_header'],
                            ];
                        }
                    }
                    db_log($db, $user, "Adicionou o domínio $zn com nameservers da CDN");
                    return $zid;
                });
                [$ok, $msg] = apply_proxy();
                $nsn = ns_names(db_read());
                flash($ok ? 'ok' : 'err', 'Domínio adicionado. Agora, onde você comprou o domínio, troque os nameservers para: '
                    . $nsn['ns1'] . ' e ' . $nsn['ns2'] . '.' . ($ok ? '' : ' Aviso: ' . $msg));
                go('zone', ['id' => $zid]);

            case 'zone_delete':
                $zid = (string)($_POST['zone'] ?? '');
                db_mutate(function (array &$db) use ($zid, $user) {
                    $z = $db['zones'][$zid] ?? null;
                    if (!$z || (($z['owner'] ?? '') !== $user && !is_admin())) {
                        throw new UserError('Domínio não encontrado.');
                    }
                    unset($db['zones'][$zid]);
                    db_log($db, $user, 'Excluiu a zona ' . ($z['name'] ?? ''));
                });
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $ok ? 'Domínio removido.' : 'Removido, mas houve problema ao aplicar: ' . $msg);
                go('zones');

            case 'zone_toggle':
                require_admin();
                $zid = (string)($_POST['zone'] ?? '');
                db_mutate(function (array &$db) use ($zid, $user) {
                    $z = $db['zones'][$zid] ?? null;
                    if (!$z) {
                        throw new UserError('Domínio não encontrado.');
                    }
                    $new = (($z['status'] ?? 'active') === 'active') ? 'suspended' : 'active';
                    $db['zones'][$zid]['status'] = $new;
                    db_log($db, $user, ($new === 'active' ? 'Reativou ' : 'Suspendeu ') . ($z['name'] ?? ''));
                });
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $ok ? 'Estado atualizado.' : $msg);
                go('zones');

            case 'rec_add':
                $zid = (string)($_POST['zone'] ?? '');
                db_mutate(function (array &$db) use ($zid, $user) {
                    $z = $db['zones'][$zid] ?? null;
                    if (!$z || (($z['owner'] ?? '') !== $user && !is_admin())) {
                        throw new UserError('Domínio não encontrado.');
                    }
                    $rec = validate_record($_POST, (string)$z['name'], $z['records'] ?? []);
                    $rec['id'] = new_record_id($db);
                    $db['zones'][$zid]['records'][] = $rec;
                    db_log($db, $user, "Registro {$rec['type']} {$rec['name']} em {$z['name']}");
                });
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $ok ? 'Registro adicionado.' : 'Salvo, mas houve problema ao aplicar: ' . $msg);
                go('zone', ['id' => $zid]);

            case 'rec_delete':
                $zid = (string)($_POST['zone'] ?? '');
                $rid = (string)($_POST['rec'] ?? '');
                db_mutate(function (array &$db) use ($zid, $rid, $user) {
                    $z = $db['zones'][$zid] ?? null;
                    if (!$z || (($z['owner'] ?? '') !== $user && !is_admin())) {
                        throw new UserError('Domínio não encontrado.');
                    }
                    $keep = [];
                    foreach (($z['records'] ?? []) as $r) {
                        if (($r['id'] ?? '') !== $rid) {
                            $keep[] = $r;
                        }
                    }
                    $db['zones'][$zid]['records'] = $keep;
                    db_log($db, $user, "Removeu um registro de {$z['name']}");
                });
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $ok ? 'Registro removido.' : 'Removido, mas houve problema ao aplicar: ' . $msg);
                go('zone', ['id' => $zid]);

            case 'rec_proxy':
                $zid = (string)($_POST['zone'] ?? '');
                $rid = (string)($_POST['rec'] ?? '');
                db_mutate(function (array &$db) use ($zid, $rid, $user) {
                    $z = $db['zones'][$zid] ?? null;
                    if (!$z || (($z['owner'] ?? '') !== $user && !is_admin())) {
                        throw new UserError('Domínio não encontrado.');
                    }
                    foreach (($z['records'] ?? []) as $i => $r) {
                        if (($r['id'] ?? '') !== $rid) {
                            continue;
                        }
                        $in = $r + ['scheme' => 'http', 'port' => '', 'host_header' => ''];
                        $in['proxied'] = empty($r['proxied']) ? 1 : 0;
                        if ($in['proxied']) {
                            $in['scheme'] = (string)($_POST['scheme'] ?? 'http');
                            $in['port'] = (string)($_POST['port'] ?? '');
                        }
                        $others = $z['records'];
                        $new = validate_record($in, (string)$z['name'], $others, $rid);
                        $new['id'] = $rid;
                        $db['zones'][$zid]['records'][$i] = $new;
                        db_log($db, $user, ($new['proxied'] ? 'Ativou' : 'Desativou') . " o proxy de {$new['name']} em {$z['name']}");
                        return;
                    }
                    throw new UserError('Registro não encontrado.');
                });
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $ok ? 'Registro atualizado.' : 'Salvo, mas houve problema ao aplicar: ' . $msg);
                go('zone', ['id' => $zid]);

            case 'zone_days':
                require_admin();
                $zid = (string)($_POST['zone'] ?? '');
                $days = parse_days($_POST['days'] ?? '');
                db_mutate(function (array &$db) use ($zid, $days, $user) {
                    if (!isset($db['zones'][$zid])) {
                        throw new UserError('Domínio não encontrado.');
                    }
                    $db['zones'][$zid]['expires'] = $days > 0 ? time() + $days * 86400 : 0;
                    db_log($db, $user, 'Prazo de ' . $db['zones'][$zid]['name'] . ': ' . ($days > 0 ? "$days dia(s)" : 'sem vencimento'));
                });
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $ok ? 'Prazo atualizado.' : $msg);
                go('zone', ['id' => $zid]);

            case 'ns_save':
                require_admin();
                $n1 = strtolower(trim((string)($_POST['ns1'] ?? '')));
                $n2 = strtolower(trim((string)($_POST['ns2'] ?? '')));
                foreach ([$n1, $n2] as $n) {
                    if ($n !== '' && !valid_hostname($n)) {
                        throw new UserError('Nameserver inválido: ' . $n);
                    }
                }
                db_mutate(function (array &$db) use ($n1, $n2, $user) {
                    $db['settings']['ns1'] = $n1;
                    $db['settings']['ns2'] = $n2;
                    db_log($db, $user, 'Nameservers: ' . ($n1 ?: '(padrão)') . ' / ' . ($n2 ?: '(padrão)'));
                });
                [$ok, $msg] = apply_proxy();
                flash($ok ? 'ok' : 'err', $ok ? 'Nameservers salvos.' : $msg);
                go('settings');

            default:
                throw new UserError('Ação desconhecida.');
        }
    } catch (UserError $e) {
        flash('err', $e->getMessage());
        [$pg, $qq] = back_for($a);
        go($pg, $qq);
    } catch (Throwable $e) {
        error_log('cdn-panel: ' . $e);
        flash('err', 'Erro interno. Tente novamente.');
        go('dash');
    }
}

function do_login(): void
{
    $ip = client_ip();
    $name = strtolower(trim((string)($_POST['username'] ?? '')));
    $pass = (string)($_POST['password'] ?? '');
    $now = time();
    $db = db_read();
    $f = $db['fails'][$ip] ?? ['n' => 0, 't' => 0];
    if ($f['n'] >= 5 && $now - (int)$f['t'] < 900) {
        flash('err', 'Muitas tentativas. Aguarde 15 minutos e tente novamente.');
        go('login');
    }

    $u = $db['users'][$name] ?? null;
    if ($u) {
        $ok = password_verify($pass, (string)($u['hash'] ?? '')) && empty($u['disabled']);
    } else {
        password_hash($pass, PASSWORD_DEFAULT); // custo equivalente, evita revelar se o usuário existe
        $ok = false;
    }

    if (!$ok) {
        db_mutate(function (array &$db) use ($ip, $now) {
            foreach ($db['fails'] as $k => $v) {
                if ($now - (int)($v['t'] ?? 0) > 3600) {
                    unset($db['fails'][$k]);
                }
            }
            $cur = $db['fails'][$ip] ?? ['n' => 0, 't' => 0];
            $n = ($now - (int)$cur['t'] > 900) ? 1 : (int)$cur['n'] + 1;
            $db['fails'][$ip] = ['n' => $n, 't' => $now];
        });
        usleep(400000);
        flash('err', 'Usuário ou senha incorretos.');
        go('login');
    }

    db_mutate(function (array &$db) use ($ip, $name) {
        unset($db['fails'][$ip]);
        db_log($db, $name, "Login ($ip)");
    });
    session_regenerate_id(true);
    $_SESSION['user'] = $name;
    go('dash');
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    handle_post();
    exit;
}

/* ------------------------------ views ------------------------------ */

function layout(string $title, string $body, bool $nav = true): void
{
    global $nonce;
    $me = me();
    $p = $_GET['p'] ?? 'dash';
    $flashes = $_SESSION['flash'] ?? [];
    unset($_SESSION['flash']);
    ?>
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title><?= h($title) ?> · CDN Proxy</title>
<style>
:root{--bg:#f4f6fb;--card:#fff;--ink:#1b2133;--mut:#6b7488;--line:#e3e7f0;--brand:#4f46e5;--brand2:#7c3aed;--ok:#0f9d58;--okbg:#e6f6ee;--err:#d93025;--errbg:#fdecea;--warn:#b26a00;--warnbg:#fff4e0;--code:#f0f2f8}
@media (prefers-color-scheme:dark){:root{--bg:#0f1320;--card:#171c2e;--ink:#e8ebf5;--mut:#97a0b8;--line:#262d45;--brand:#7c83ff;--brand2:#a78bfa;--ok:#4ade80;--okbg:#10301f;--err:#ff7b72;--errbg:#3a1614;--warn:#fbbf24;--warnbg:#33260a;--code:#1d2338}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
a{color:var(--brand);text-decoration:none}a:hover{text-decoration:underline}
header.top{background:var(--card);border-bottom:1px solid var(--line);position:sticky;top:0;z-index:5}
.wrap{max-width:1080px;margin:0 auto;padding:0 16px}
.bar{display:flex;align-items:center;gap:20px;min-height:58px;flex-wrap:wrap}
.logo{font-weight:800;letter-spacing:-.02em;font-size:18px;color:var(--ink)}
.logo b{background:linear-gradient(135deg,var(--brand),var(--brand2));-webkit-background-clip:text;background-clip:text;color:transparent}
nav{display:flex;gap:4px;flex:1;flex-wrap:wrap}
nav a{padding:8px 12px;border-radius:8px;color:var(--mut);font-weight:600}
nav a.on,nav a:hover{background:var(--code);color:var(--ink);text-decoration:none}
.who{color:var(--mut);font-size:13px;display:flex;align-items:center;gap:10px}
main{padding:24px 0 60px}
h1{font-size:24px;margin:0 0 4px;letter-spacing:-.02em}h2{font-size:17px;margin:0 0 14px}
.sub{color:var(--mut);margin:0 0 22px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:20px;margin-bottom:18px}
.grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));margin-bottom:18px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 16px}
.stat span{display:block;color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.06em}
.stat b{font-size:24px}
label{display:block;font-weight:600;font-size:13px;margin:0 0 5px}
input,select{width:100%;padding:10px 12px;border:1px solid var(--line);border-radius:9px;background:var(--bg);color:var(--ink);font:inherit}
input:focus,select:focus{outline:2px solid var(--brand);outline-offset:-1px;border-color:transparent}
.row{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));align-items:end}
.hint{color:var(--mut);font-size:12.5px;margin-top:4px}
button,.btn{display:inline-block;border:0;border-radius:9px;padding:10px 16px;font:inherit;font-weight:700;cursor:pointer;background:linear-gradient(135deg,var(--brand),var(--brand2));color:#fff}
button:hover,.btn:hover{filter:brightness(1.08);text-decoration:none}
button.ghost,.btn.ghost{background:var(--code);color:var(--ink)}
button.danger{background:var(--errbg);color:var(--err)}
button.sm,.btn.sm{padding:6px 10px;font-size:13px}
table{width:100%;border-collapse:collapse}
th{text-align:left;font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);padding:8px 10px;border-bottom:1px solid var(--line)}
td{padding:11px 10px;border-bottom:1px solid var(--line);vertical-align:middle}
tr:last-child td{border-bottom:0}
.tw{overflow-x:auto}
code,.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px}
code{background:var(--code);padding:2px 6px;border-radius:6px}
.badge{display:inline-block;padding:2px 9px;border-radius:99px;font-size:12px;font-weight:700}
.b-ok{background:var(--okbg);color:var(--ok)}.b-err{background:var(--errbg);color:var(--err)}.b-warn{background:var(--warnbg);color:var(--warn)}
.flash{padding:12px 14px;border-radius:10px;margin-bottom:14px;font-weight:600;word-break:break-word}
.f-ok{background:var(--okbg);color:var(--ok)}.f-err{background:var(--errbg);color:var(--err)}
.acts{display:flex;gap:6px;flex-wrap:wrap}.acts form{margin:0}
.login{max-width:380px;margin:9vh auto}
.login .card{padding:28px}
.muted{color:var(--mut)}
.empty{text-align:center;color:var(--mut);padding:28px 10px}
@media(max-width:640px){main{padding-top:16px}}
</style>
</head>
<body>
<?php if ($nav && $me): ?>
<header class="top"><div class="wrap bar">
  <a class="logo" href="?p=dash">CDN <b>Proxy</b></a>
  <nav>
    <a href="?p=dash" class="<?= $p === 'dash' || $p === 'edit' ? 'on' : '' ?>">Domínios</a>
    <?php if (dns_enabled()): ?><a href="?p=zones" class="<?= $p === 'zones' || $p === 'zone' ? 'on' : '' ?>">DNS</a><?php endif; ?>
    <?php if (is_admin()): ?>
    <a href="?p=users" class="<?= $p === 'users' ? 'on' : '' ?>">Clientes</a>
    <a href="?p=settings" class="<?= $p === 'settings' ? 'on' : '' ?>">Sistema</a>
    <?php endif; ?>
    <a href="?p=account" class="<?= $p === 'account' ? 'on' : '' ?>">Minha conta</a>
  </nav>
  <div class="who"><span><?= h($me['name']) ?><?= is_admin() ? ' · admin' : '' ?></span>
    <form method="post"><?= csrf_field('logout') ?><button class="ghost sm" type="submit">Sair</button></form></div>
</div></header>
<?php endif; ?>
<main><div class="wrap">
<?php foreach ($flashes as [$t, $m]): ?><div class="flash f-<?= $t === 'ok' ? 'ok' : 'err' ?>"><?= h($m) ?></div><?php endforeach; ?>
<?= $body ?>
</div></main>
<script nonce="<?= h($nonce) ?>">
document.addEventListener('click',function(e){
  var c=e.target.closest('[data-copy]');
  if(c){navigator.clipboard.writeText(c.getAttribute('data-copy')).then(function(){var t=c.textContent;c.textContent='Copiado!';setTimeout(function(){c.textContent=t},1200)});}
});
document.addEventListener('submit',function(e){
  var m=e.target.getAttribute('data-confirm');
  if(m&&!confirm(m)){e.preventDefault();}
});
(function(){var t=document.getElementById('r_type');if(!t)return;var pr=document.getElementById('r_prio_wrap'),px=document.getElementById('r_proxy_wrap');function f(){pr.style.display=t.value==='MX'?'':'none';px.style.display=(t.value==='A'||t.value==='CNAME')?'':'none';}t.addEventListener('change',f);f();})();
(function(){var k=document.getElementById('c_kind');if(!k)return;var w=document.getElementById('c_custom_wrap');function f(){w.style.display=k.value==='custom'?'':'none'}k.addEventListener('change',f);f();})();
</script>
</body>
</html>
    <?php
}

function badge_for(array $d, array $st): string
{
    $s = $st[$d['id']] ?? null;
    if (($d['status'] ?? 'active') !== 'active') {
        return '<span class="badge b-warn">Suspenso</span>';
    }
    if (!$s) {
        return '<span class="badge b-warn">Aplicando…</span>';
    }
    if ($s['state'] === 'error') {
        return '<span class="badge b-err" title="' . h($s['msg'] ?? '') . '">Erro</span>';
    }
    if ($s['state'] === 'suspended') {
        return '<span class="badge b-warn">Suspenso</span>';
    }
    if ($s['state'] === 'pending_dns') {
        return '<span class="badge b-warn">Aguardando DNS</span>';
    }
    $b = '<span class="badge b-ok">Ativo</span>';
    if (($d['kind'] ?? '') === 'custom') {
        $c = $s['cert'] ?? '';
        if ($c === 'ok') {
            $b .= ' <span class="badge b-ok">HTTPS</span>';
        } elseif ($c === 'pending') {
            $b .= ' <span class="badge b-warn">HTTPS em emissão</span>';
        } elseif ($c === 'retry') {
            $b .= ' <span class="badge b-err">HTTPS falhou, tentando de novo</span>';
        } else {
            $b .= ' <span class="badge b-warn">sem HTTPS válido</span>';
        }
    }
    return $b;
}

function page_login(): void
{
    ob_start(); ?>
<div class="login">
  <div class="card">
    <h1>CDN <span style="color:var(--brand)">Proxy</span></h1>
    <p class="sub">Entre para gerenciar seus domínios.</p>
    <form method="post" autocomplete="on">
      <input type="hidden" name="a" value="login">
      <label for="u">Usuário</label>
      <input id="u" name="username" autocomplete="username" required autofocus>
      <div style="height:12px"></div>
      <label for="pw">Senha</label>
      <input id="pw" name="password" type="password" autocomplete="current-password" required>
      <div style="height:18px"></div>
      <button type="submit" style="width:100%">Entrar</button>
    </form>
  </div>
</div>
    <?php
    layout('Entrar', (string)ob_get_clean(), false);
}

function page_dash(): void
{
    $db = db_read();
    $me = me();
    $admin = is_admin();
    $st = read_run_json('status.json')['domains'] ?? [];
    $list = $admin ? $db['domains'] : owner_domains($db, $me['name']);
    uasort($list, fn($a, $b) => ($b['created'] ?? 0) <=> ($a['created'] ?? 0));
    $max = (int)($me['max_domains'] ?? 0);
    $base = base_domain($db);
    $mine = count(owner_domains($db, $me['name']));
    $full = $max > 0 && $mine >= $max;
    $settings = settings_read();

    ob_start(); ?>
<h1>Domínios</h1>
<p class="sub">Informe a origem (seu servidor) e a CDN gera um domínio que passa pelo proxy.</p>

<div class="grid">
  <div class="stat"><span>Meus domínios</span><b><?= $mine ?><?= $max > 0 ? ' / ' . $max : '' ?></b></div>
  <?php if ($admin): ?>
  <div class="stat"><span>Total na CDN</span><b><?= count($db['domains']) ?></b></div>
  <div class="stat"><span>Clientes</span><b><?= count($db['users']) ?></b></div>
  <?php endif; ?>
  <div class="stat"><span>IP da CDN</span><b class="mono" style="font-size:16px"><?= h($settings['public_ip'] ?? '—') ?></b></div>
</div>

<div class="card">
  <h2>Novo domínio</h2>
  <?php if ($base === ''): ?>
    <p class="muted">O domínio base ainda não foi configurado. Peça ao administrador.</p>
  <?php elseif ($full): ?>
    <p class="muted">Você atingiu o limite de <?= $max ?> domínio(s).</p>
  <?php else: ?>
  <form method="post">
    <?= csrf_field('domain_create') ?>
    <div class="row" style="margin-bottom:12px">
      <div><label for="c_kind">Tipo de domínio</label>
        <select id="c_kind" name="kind"><option value="auto">Gerar um domínio para mim</option><option value="custom">Usar meu próprio domínio</option></select></div>
      <div style="grid-column:span 2" id="c_custom_wrap"><label for="c_custom">Seu domínio</label>
        <input id="c_custom" name="custom_host" placeholder="loja.seudominio.com" maxlength="253" autocomplete="off" inputmode="url">
        <div class="hint">Sem http:// e sem barras. Depois de criar, você aponta o DNS dele para a CDN.</div></div>
    </div>
    <div class="row">
      <div><label for="c_scheme">Protocolo da origem</label>
        <select id="c_scheme" name="scheme"><option value="http">http</option><option value="https">https</option></select></div>
      <div style="grid-column:span 2"><label for="c_host">IP ou domínio da origem</label>
        <input id="c_host" name="host" placeholder="203.0.113.10" required maxlength="253" inputmode="url" autocomplete="off"></div>
      <div><label for="c_port">Porta</label>
        <input id="c_port" name="port" placeholder="80 / 443" inputmode="numeric" maxlength="5"></div>
    </div>
    <div class="row" style="margin-top:12px">
      <div><label for="c_hh">Host header (opcional)</label>
        <input id="c_hh" name="host_header" placeholder="site.exemplo.com" maxlength="253" autocomplete="off">
        <div class="hint">Vazio = envia o domínio gerado. Preencha se a origem exige um nome específico.</div></div>
      <div><label for="c_label">Nome (opcional)</label>
        <input id="c_label" name="label" maxlength="60" autocomplete="off"></div>
      <?php if ($admin): ?><div><label for="c_days">Dias de acesso</label>
        <input id="c_days" name="days" type="number" min="0" max="3650" placeholder="30" inputmode="numeric">
        <div class="hint">Vazio/0 = sem vencimento. Ao acabar, desliga sozinho.</div></div><?php endif; ?>
      <div><button type="submit">Gerar domínio</button></div>
    </div>
  </form>
  <?php endif; ?>
</div>

<div class="card">
  <h2><?= $admin ? 'Todos os domínios' : 'Meus domínios' ?></h2>
  <?php if (!$list): ?>
    <div class="empty">Nenhum domínio ainda.</div>
  <?php else: ?>
  <div class="tw"><table>
    <thead><tr><th>Domínio</th><th>Origem</th><?php if ($admin): ?><th>Dono</th><?php endif; ?><th>Estado</th><th></th></tr></thead>
    <tbody>
    <?php foreach ($list as $d): ?>
      <tr>
        <td><a href="<?= h(site_url($d['fqdn'])) ?>" target="_blank" rel="noopener noreferrer"><code><?= h($d['fqdn']) ?></code></a>
          <?php if (!empty($d['label'])): ?><div class="hint"><?= h($d['label']) ?></div><?php endif; ?>
          <?php if (($d['kind'] ?? '') === 'custom'): $s_ = $st[$d['id']] ?? []; ?>
            <div class="hint"><span class="badge b-ok">Domínio próprio</span>
            <?php if (($s_['state'] ?? '') === 'pending_dns'): ?>
              · Aponte o DNS: <b>A → <?= h($settings['public_ip'] ?? '') ?></b><?php if (!empty($d['target'])): ?> (ou <b>CNAME → <?= h($d['target']) ?></b>)<?php endif; ?>
              <?php if (!empty($s_['seen'])): ?><br>Hoje ele aponta para: <?= h(implode(', ', $s_['seen'])) ?> (se usa Cloudflare, deixe a nuvem cinza)<?php endif; ?>
            <?php endif; ?></div>
          <?php endif; ?></td>
        <td class="mono"><?= h($d['scheme']) ?>://<?= h($d['host']) ?>:<?= h($d['port']) ?>
          <?php if (!empty($d['host_header'])): ?><div class="hint">Host: <?= h($d['host_header']) ?></div><?php endif; ?></td>
        <?php if ($admin): ?><td><?= h($d['owner']) ?></td><?php endif; ?>
        <td><?= badge_for($d, $st) ?><?= expiry_badge($d) ?>
          <?php if (($st[$d['id']]['state'] ?? '') === 'error'): ?><div class="hint"><?= h($st[$d['id']]['msg'] ?? '') ?></div><?php endif; ?></td>
        <td><div class="acts">
          <button class="ghost sm" type="button" data-copy="<?= h($d['fqdn']) ?>">Copiar</button>
          <?php if (($d['kind'] ?? '') === 'custom' && ($st[$d['id']]['state'] ?? '') === 'pending_dns'): ?>
          <form method="post"><?= csrf_field('dns_check') ?><button class="ghost sm" type="submit">Verificar DNS</button></form>
          <?php endif; ?>
          <a class="btn ghost sm" href="?p=edit&amp;id=<?= h($d['id']) ?>">Editar</a>
          <?php if ($admin): ?>
          <form method="post"><?= csrf_field('domain_toggle') ?><input type="hidden" name="id" value="<?= h($d['id']) ?>">
            <button class="ghost sm" type="submit"><?= ($d['status'] ?? 'active') === 'active' ? 'Suspender' : 'Reativar' ?></button></form>
          <?php endif; ?>
          <form method="post" data-confirm="Excluir <?= h($d['fqdn']) ?>? Essa ação não pode ser desfeita."><?= csrf_field('domain_delete') ?><input type="hidden" name="id" value="<?= h($d['id']) ?>">
            <button class="danger sm" type="submit">Excluir</button></form>
        </div></td>
      </tr>
    <?php endforeach; ?>
    </tbody>
  </table></div>
  <?php endif; ?>
</div>
    <?php
    layout('Domínios', (string)ob_get_clean());
}

function page_edit(): void
{
    $db = db_read();
    $id = (string)($_GET['id'] ?? '');
    $d = $db['domains'][$id] ?? null;
    if (!$d || (($d['owner'] ?? '') !== me()['name'] && !is_admin())) {
        if (empty($_SESSION['flash'])) {
            flash('err', 'Domínio não encontrado.');
        }
        go('dash');
    }
    ob_start(); ?>
<h1>Editar domínio</h1>
<p class="sub"><code><?= h($d['fqdn']) ?></code> · criado em <?= h(fmt_time((int)$d['created'])) ?></p>
<div class="card">
  <form method="post">
    <?= csrf_field('domain_update') ?><input type="hidden" name="id" value="<?= h($id) ?>">
    <div class="row">
      <div><label for="e_scheme">Protocolo da origem</label>
        <select id="e_scheme" name="scheme">
          <option value="http" <?= $d['scheme'] === 'http' ? 'selected' : '' ?>>http</option>
          <option value="https" <?= $d['scheme'] === 'https' ? 'selected' : '' ?>>https</option>
        </select></div>
      <div style="grid-column:span 2"><label for="e_host">IP ou domínio da origem</label>
        <input id="e_host" name="host" value="<?= h($d['host']) ?>" required maxlength="253" autocomplete="off"></div>
      <div><label for="e_port">Porta</label>
        <input id="e_port" name="port" value="<?= h($d['port']) ?>" inputmode="numeric" maxlength="5"></div>
    </div>
    <div class="row" style="margin-top:12px">
      <div><label for="e_hh">Host header (opcional)</label>
        <input id="e_hh" name="host_header" value="<?= h($d['host_header'] ?? '') ?>" maxlength="253" autocomplete="off"></div>
      <div><label for="e_label">Nome (opcional)</label>
        <input id="e_label" name="label" value="<?= h($d['label'] ?? '') ?>" maxlength="60" autocomplete="off"></div>
      <?php if (is_admin()): $dl = days_left($d); ?>
      <div><label for="e_days">Dias restantes</label>
        <input id="e_days" name="days" type="number" min="0" max="3650" value="<?= $dl === null ? '' : $dl ?>" placeholder="sem vencimento" inputmode="numeric">
        <input type="hidden" name="days_orig" value="<?= $dl === null ? '' : $dl ?>">
        <div class="hint">Mude para renovar (ex.: 30 = 30 dias a partir de agora). 0 = sem vencimento.</div></div>
      <?php endif; ?>
    </div>
    <div style="margin-top:18px;display:flex;gap:8px"><button type="submit">Salvar</button><a class="btn ghost" href="?p=dash">Cancelar</a></div>
  </form>
</div>
    <?php
    layout('Editar domínio', (string)ob_get_clean());
}

function page_users(): void
{
    require_admin();
    $db = db_read();
    ob_start(); ?>
<h1>Clientes</h1>
<p class="sub">Crie contas para seus clientes e defina quantos domínios cada um pode gerar.</p>

<div class="card">
  <h2>Novo cliente</h2>
  <form method="post" autocomplete="off">
    <?= csrf_field('user_create') ?>
    <div class="row">
      <div><label for="n_u">Usuário</label><input id="n_u" name="username" required maxlength="32" pattern="[a-z0-9_.\-]{3,32}"></div>
      <div><label for="n_p">Senha (vazio = gerar)</label><input id="n_p" name="password" type="text" autocomplete="off" maxlength="200"></div>
      <div><label for="n_m">Limite de domínios (0 = ilimitado)</label><input id="n_m" name="max_domains" type="number" min="0" max="10000" value="5"></div>
      <div><button type="submit">Criar cliente</button></div>
    </div>
  </form>
</div>

<div class="card">
  <h2>Contas</h2>
  <div class="tw"><table>
    <thead><tr><th>Usuário</th><th>Papel</th><th>Domínios</th><th>Limite</th><th>Ativo</th><th></th></tr></thead>
    <tbody>
    <?php foreach ($db['users'] as $name => $u): $n = count(owner_domains($db, (string)$name)); ?>
      <tr>
        <td><form id="uf-<?= h($name) ?>" method="post"><?= csrf_field('user_update') ?><input type="hidden" name="username" value="<?= h($name) ?>"></form>
          <b><?= h($name) ?></b><div class="hint">desde <?= h(fmt_time((int)($u['created'] ?? 0))) ?></div></td>
        <td><?= ($u['role'] ?? '') === 'admin' ? '<span class="badge b-ok">admin</span>' : 'cliente' ?></td>
        <td><?= $n ?></td>
        <td style="width:110px"><input form="uf-<?= h($name) ?>" name="max_domains" type="number" min="0" max="10000" value="<?= h((int)($u['max_domains'] ?? 0)) ?>"></td>
        <td><label style="margin:0;font-weight:500"><input form="uf-<?= h($name) ?>" type="checkbox" name="disabled" value="1" style="width:auto" <?= !empty($u['disabled']) ? 'checked' : '' ?>> desativado</label></td>
        <td><div class="acts"><button class="ghost sm" type="submit" form="uf-<?= h($name) ?>">Salvar</button>
          <form method="post" data-confirm="Gerar uma nova senha para <?= h($name) ?>?"><?= csrf_field('user_reset') ?><input type="hidden" name="username" value="<?= h($name) ?>"><button class="ghost sm" type="submit">Nova senha</button></form>
          <?php if ($name !== me()['name']): ?>
          <form method="post" data-confirm="Excluir <?= h($name) ?> e TODOS os domínios dele?"><?= csrf_field('user_delete') ?><input type="hidden" name="username" value="<?= h($name) ?>"><button class="danger sm" type="submit">Excluir</button></form>
          <?php endif; ?>
        </div></td>
      </tr>
    <?php endforeach; ?>
    </tbody>
  </table></div>
</div>
    <?php
    layout('Clientes', (string)ob_get_clean());
}

function page_settings(): void
{
    require_admin();
    $db = db_read();
    $s = settings_read();
    $res = read_run_json('apply.result');
    $base = base_domain($db);
    $custom = trim((string)($db['settings']['base_domain'] ?? ''));
    $ip = (string)($s['public_ip'] ?? '');
    $hasCert = $custom !== '' && is_file(cdn_p(P_LE) . '/' . $custom . '/fullchain.pem');
    $log = array_reverse(array_slice($db['log'], -60));

    ob_start(); ?>
<h1>Sistema</h1>
<p class="sub">Domínio base, estado da aplicação e registro de atividades.</p>

<div class="card">
  <h2>Domínio base</h2>
  <form method="post">
    <?= csrf_field('settings_save') ?>
    <div class="row">
      <div style="grid-column:span 2"><label for="bd">Domínio base dos domínios gerados</label>
        <input id="bd" name="base_domain" value="<?= h($custom) ?>" placeholder="cdn.seudominio.com" maxlength="253" autocomplete="off">
        <div class="hint">Vazio = usa <code><?= h($ip !== '' ? str_replace('.', '-', $ip) . '.sslip.io' : 'IP.sslip.io') ?></code> (funciona sem configurar DNS, só HTTP confiável).</div></div>
      <div><button type="submit">Salvar</button></div>
    </div>
  </form>
  <p class="hint" style="margin-top:14px">Portas do proxy: HTTP <b><?= h(implode(', ', ports_cfg()['http']) ?: '—') ?></b> · HTTPS <b><?= h(implode(', ', ports_cfg()['tls']) ?: '—') ?></b> · painel <b><?= h($s['panel_port'] ?? 8080) ?></b>.<br>
  Atualmente os domínios saem como <code>xxxxxxxx.<?= h($base ?: '—') ?></code>.<br>
  Com domínio próprio, crie no seu DNS o registro: <code>A  *.<?= h($custom ?: 'cdn.seudominio.com') ?>  →  <?= h($ip ?: 'IP da VPS') ?></code><br>
  HTTPS sem aviso no navegador exige certificado wildcard: no servidor rode <code>cdn-panel cert <?= h($custom ?: 'cdn.seudominio.com') ?> TOKEN_CLOUDFLARE</code>.
  Estado do certificado: <?= $hasCert ? '<span class="badge b-ok">wildcard instalado</span>' : '<span class="badge b-warn">autoassinado (HTTP funciona; HTTPS mostra aviso)</span>' ?></p>
</div>

<?php
  $nsn = ns_names($db);
  $bindState = trim((string)@shell_exec('systemctl is-active bind9 2>/dev/null'));
  $nsOk = [];
  foreach (['ns1', 'ns2'] as $k) {
      $nsOk[$k] = $nsn[$k] !== '' && in_array($ip, dns_lookup($nsn[$k]), true);
  }
?>
<div class="card">
  <h2>Servidor DNS (nameservers)</h2>
  <?php if (!dns_enabled()): ?>
    <p class="muted">O servidor DNS não está ativo (a porta 53 estava ocupada na instalação, ou ele foi desativado).</p>
  <?php else: ?>
  <p>Estado do BIND: <?= $bindState === 'active' ? '<span class="badge b-ok">ativo</span>' : '<span class="badge b-err">' . h($bindState ?: 'desconhecido') . '</span>' ?></p>
  <form method="post">
    <?= csrf_field('ns_save') ?>
    <div class="row">
      <div><label for="ns1">Nameserver 1</label><input id="ns1" name="ns1" value="<?= h($db['settings']['ns1'] ?? '') ?>" placeholder="<?= h($nsn['ns1']) ?>" maxlength="253" autocomplete="off"></div>
      <div><label for="ns2">Nameserver 2</label><input id="ns2" name="ns2" value="<?= h($db['settings']['ns2'] ?? '') ?>" placeholder="<?= h($nsn['ns2']) ?>" maxlength="253" autocomplete="off"></div>
      <div><button type="submit">Salvar</button></div>
    </div>
  </form>
  <p class="hint" style="margin-top:12px">Em uso: <code><?= h($nsn['ns1'] ?: '—') ?></code> <?= $nsOk['ns1'] ? '<span class="badge b-ok">resolve para a VPS</span>' : '<span class="badge b-warn">não resolve para a VPS</span>' ?>
    · <code><?= h($nsn['ns2'] ?: '—') ?></code> <?= $nsOk['ns2'] ? '<span class="badge b-ok">resolve para a VPS</span>' : '<span class="badge b-warn">não resolve para a VPS</span>' ?><br>
  Cada nameserver precisa resolver para <b><?= h($ip) ?></b> (crie um registro A para cada um no DNS do domínio deles; o registro curinga do domínio base já cobre os padrões). Libere também a porta <b>53</b> (TCP e UDP) no firewall da hospedagem.</p>
  <?php endif; ?>
</div>

<div class="card">
  <h2>Aplicação do nginx</h2>
  <p>Última execução: <?= !empty($res['t']) ? h(fmt_time((int)$res['t'])) : '—' ?> ·
    <?= isset($res['ok']) ? ($res['ok'] ? '<span class="badge b-ok">OK</span>' : '<span class="badge b-err">Falhou</span>') : '' ?></p>
  <p class="muted"><?= h($res['msg'] ?? 'Ainda não executado.') ?></p>
  <p class="hint">O sistema reaplica sozinho a cada 5 minutos (atualiza IPs de origens que usam domínio).</p>
  <form method="post"><?= csrf_field('apply_now') ?><button class="ghost" type="submit">Reaplicar agora</button></form>
</div>

<div class="card">
  <h2>Atividade recente</h2>
  <?php if (!$log): ?><div class="empty">Sem registros.</div><?php else: ?>
  <div class="tw"><table><thead><tr><th>Quando</th><th>Quem</th><th>O quê</th></tr></thead><tbody>
    <?php foreach ($log as $l): ?>
    <tr><td class="mono" style="white-space:nowrap"><?= h(fmt_time((int)$l['t'])) ?></td><td><?= h($l['u']) ?></td><td><?= h($l['m']) ?></td></tr>
    <?php endforeach; ?>
  </tbody></table></div>
  <?php endif; ?>
</div>
    <?php
    layout('Sistema', (string)ob_get_clean());
}

function page_account(): void
{
    ob_start(); ?>
<h1>Minha conta</h1>
<p class="sub">Usuário: <b><?= h(me()['name']) ?></b></p>
<div class="card" style="max-width:480px">
  <h2>Alterar senha</h2>
  <form method="post" autocomplete="off">
    <?= csrf_field('pw_change') ?>
    <label for="p0">Senha atual</label><input id="p0" name="current" type="password" autocomplete="current-password" required>
    <div style="height:12px"></div>
    <label for="p1">Nova senha (mín. 10 caracteres)</label><input id="p1" name="new" type="password" autocomplete="new-password" required minlength="10">
    <div style="height:12px"></div>
    <label for="p2">Repita a nova senha</label><input id="p2" name="new2" type="password" autocomplete="new-password" required minlength="10">
    <div style="height:18px"></div>
    <button type="submit">Salvar senha</button>
  </form>
</div>
    <?php
    layout('Minha conta', (string)ob_get_clean());
}

function expiry_badge(array $x): string
{
    $d = days_left($x);
    if ($d === null) {
        return '';
    }
    if ($d <= 0) {
        return ' <span class="badge b-err">Vencido</span>';
    }
    $cls = $d <= 5 ? 'b-warn' : 'b-ok';
    return ' <span class="badge ' . $cls . '">' . $d . ($d === 1 ? ' dia restante' : ' dias restantes') . '</span>';
}

function zone_badge(array $z, array $zst): string
{
    if (($z['status'] ?? 'active') !== 'active') {
        return '<span class="badge b-warn">Suspenso</span>';
    }
    if (is_expired($z)) {
        return '<span class="badge b-err">Vencido</span>';
    }
    $s = $zst[$z['id']] ?? null;
    if (!$s) {
        return '<span class="badge b-warn">Aplicando…</span>';
    }
    if (($s['ns'] ?? '') === 'ok') {
        return '<span class="badge b-ok">Ativo</span>';
    }
    if (($s['ns'] ?? '') === 'error') {
        return '<span class="badge b-err" title="' . h($s['msg'] ?? '') . '">Erro</span>';
    }
    return '<span class="badge b-warn">Aguardando nameservers</span>';
}

function page_zones(): void
{
    $db = db_read();
    $me = me();
    $admin = is_admin();
    $enabled = dns_enabled();
    $ns = ns_names($db);
    $zst = read_run_json('status.json')['zones'] ?? [];
    $list = array_filter($db['zones'], fn($z) => $admin || ($z['owner'] ?? '') === $me['name']);
    uasort($list, fn($a, $b) => ($b['created'] ?? 0) <=> ($a['created'] ?? 0));
    $max = (int)($me['max_domains'] ?? 0);
    $used = count(owner_domains($db, $me['name'])) + count(owner_zones($db, $me['name']));
    $full = $max > 0 && $used >= $max;

    ob_start(); ?>
<h1>DNS</h1>
<p class="sub">Cadastre um domínio e troque os nameservers dele: a CDN passa a cuidar do DNS e do HTTPS, como a Cloudflare.</p>

<?php if (!$enabled): ?>
<div class="card"><p class="muted">O servidor DNS próprio não está ativo nesta CDN (a porta 53 estava ocupada na instalação).</p></div>
<?php else: ?>
<div class="card">
  <h2>Adicionar domínio</h2>
  <?php if ($ns['ns1'] === '' || $ns['ns2'] === ''): ?>
    <p class="muted">Os nameservers ainda não foram configurados. Peça ao administrador (Sistema).</p>
  <?php elseif ($full): ?>
    <p class="muted">Você atingiu o limite de <?= $max ?> domínio(s).</p>
  <?php else: ?>
  <form method="post">
    <?= csrf_field('zone_create') ?>
    <div class="row">
      <div style="grid-column:span 2"><label for="z_name">Domínio (comprado em qualquer lugar)</label>
        <input id="z_name" name="zone_name" placeholder="seudominio.com" required maxlength="253" autocomplete="off" inputmode="url"></div>
    </div>
    <div class="row" style="margin-top:12px">
      <div><label for="z_scheme">Protocolo do site</label>
        <select id="z_scheme" name="scheme"><option value="http">http</option><option value="https">https</option></select></div>
      <div style="grid-column:span 2"><label for="z_host">IP ou domínio do seu site (opcional)</label>
        <input id="z_host" name="host" placeholder="203.0.113.10" maxlength="253" autocomplete="off">
        <div class="hint">Se informar, já criamos <b>@</b> e <b>www</b> passando pela CDN. Você pode ajustar depois.</div></div>
      <div><label for="z_port">Porta</label><input id="z_port" name="port" placeholder="80 / 443" inputmode="numeric" maxlength="5"></div>
      <?php if ($admin): ?><div><label for="z_days">Dias de acesso</label><input id="z_days" name="days" type="number" min="0" max="3650" placeholder="30" inputmode="numeric"></div><?php endif; ?>
      <div><button type="submit">Adicionar</button></div>
    </div>
  </form>
  <?php endif; ?>
</div>

<div class="card">
  <h2><?= $admin ? 'Todos os domínios' : 'Meus domínios' ?></h2>
  <?php if (!$list): ?><div class="empty">Nenhum domínio ainda.</div><?php else: ?>
  <div class="tw"><table>
    <thead><tr><th>Domínio</th><?php if ($admin): ?><th>Dono</th><?php endif; ?><th>Estado</th><th>Registros</th><th></th></tr></thead>
    <tbody>
    <?php foreach ($list as $z): ?>
      <tr>
        <td><a href="?p=zone&amp;id=<?= h($z['id']) ?>"><code><?= h($z['name']) ?></code></a></td>
        <?php if ($admin): ?><td><?= h($z['owner']) ?></td><?php endif; ?>
        <td><?= zone_badge($z, $zst) ?><?= expiry_badge($z) ?></td>
        <td><?= count($z['records'] ?? []) ?></td>
        <td><div class="acts">
          <a class="btn ghost sm" href="?p=zone&amp;id=<?= h($z['id']) ?>">Gerenciar</a>
          <?php if ($admin): ?>
          <form method="post"><?= csrf_field('zone_toggle') ?><input type="hidden" name="zone" value="<?= h($z['id']) ?>">
            <button class="ghost sm" type="submit"><?= ($z['status'] ?? 'active') === 'active' ? 'Suspender' : 'Reativar' ?></button></form>
          <?php endif; ?>
          <form method="post" data-confirm="Excluir <?= h($z['name']) ?> e todos os registros dele?"><?= csrf_field('zone_delete') ?><input type="hidden" name="zone" value="<?= h($z['id']) ?>">
            <button class="danger sm" type="submit">Excluir</button></form>
        </div></td>
      </tr>
    <?php endforeach; ?>
    </tbody>
  </table></div>
  <?php endif; ?>
</div>
<?php endif; ?>
    <?php
    layout('DNS', (string)ob_get_clean());
}

function page_zone(): void
{
    $db = db_read();
    $zid = (string)($_GET['id'] ?? '');
    $z = zone_for($db, $zid, me()['name']);
    if (!$z) {
        if (empty($_SESSION['flash'])) {
            flash('err', 'Domínio não encontrado.');
        }
        go('zones');
    }
    $ns = ns_names($db);
    $status = read_run_json('status.json');
    $zst = $status['zones'] ?? [];
    $dst = $status['domains'] ?? [];
    $zs = $zst[$zid] ?? [];
    $pub = (string)(settings_read()['public_ip'] ?? '');
    $sites = zone_domains($db);
    $recs = $z['records'] ?? [];

    ob_start(); ?>
<p class="muted" style="margin:0 0 6px"><a href="?p=zones">← Todos os domínios</a></p>
<h1><?= h($z['name']) ?> <?= zone_badge($z, $zst) ?></h1>
<p class="sub">Criado em <?= h(fmt_time((int)($z['created'] ?? 0))) ?><?= expiry_badge($z) ?></p>
<?php if (is_admin()): $zdl = days_left($z); ?>
<div class="card"><form method="post" class="row">
  <?= csrf_field('zone_days') ?><input type="hidden" name="zone" value="<?= h($zid) ?>">
  <div><label for="zd">Dias de acesso (a partir de agora)</label><input id="zd" name="days" type="number" min="0" max="3650" value="<?= $zdl === null ? '' : $zdl ?>" placeholder="sem vencimento"></div>
  <div><button type="submit">Salvar prazo</button></div>
</form></div>
<?php endif; ?>

<div class="card">
  <h2>Nameservers</h2>
  <?php if (($zs['ns'] ?? '') === 'ok'): ?>
    <p>✔ O domínio já usa os nameservers da CDN. O DNS e o HTTPS estão sendo gerenciados aqui.</p>
  <?php else: ?>
    <p>No site onde você <b>comprou o domínio</b>, abra as configurações de DNS/nameservers e troque os atuais por estes dois:</p>
  <?php endif; ?>
  <div class="acts" style="margin:10px 0">
    <code><?= h($ns['ns1']) ?></code><button class="ghost sm" type="button" data-copy="<?= h($ns['ns1']) ?>">Copiar</button>
    <code><?= h($ns['ns2']) ?></code><button class="ghost sm" type="button" data-copy="<?= h($ns['ns2']) ?>">Copiar</button>
  </div>
  <?php if (($zs['ns'] ?? '') !== 'ok'): ?>
    <p class="hint">Hoje o domínio usa: <?= !empty($zs['seen']) ? h(implode(', ', $zs['seen'])) : 'nenhum nameserver encontrado (ainda propagando ou domínio inexistente)' ?>.
    A troca pode levar de minutos a algumas horas.</p>
    <form method="post" style="margin-top:10px"><?= csrf_field('dns_check') ?><button class="ghost sm" type="submit">Verificar nameservers agora</button></form>
  <?php endif; ?>
</div>

<div class="card">
  <h2>Registros DNS</h2>
  <?php if (!$recs): ?><div class="empty">Nenhum registro ainda. Adicione abaixo.</div><?php else: ?>
  <div class="tw"><table>
    <thead><tr><th>Tipo</th><th>Nome</th><th>Valor</th><th>Proxy</th><th></th></tr></thead>
    <tbody>
    <?php foreach ($recs as $r): $site = $sites[$r['id']] ?? null; ?>
      <tr>
        <td><b><?= h($r['type']) ?></b></td>
        <td class="mono"><?= h($r['name']) ?></td>
        <td class="mono"><?= h(($r['type'] === 'MX' ? ($r['prio'] ?? 10) . ' ' : '') . $r['value']) ?>
          <?php if (!empty($r['proxied'])): ?><div class="hint">origem <?= h($r['scheme'] ?? 'http') ?>://<?= h($r['value']) ?>:<?= h($r['port'] ?? 80) ?></div><?php endif; ?></td>
        <td><?php if (!empty($r['proxied']) && $site): ?>
              <?= badge_for($site + ['id' => $r['id']], $dst) ?>
            <?php elseif (in_array($r['type'], ['A', 'CNAME'], true)): ?><span class="badge b-warn">só DNS</span>
            <?php else: ?><span class="muted">—</span><?php endif; ?></td>
        <td><div class="acts">
          <?php if (in_array($r['type'], ['A', 'CNAME'], true)): ?>
          <form method="post"><?= csrf_field('rec_proxy') ?><input type="hidden" name="zone" value="<?= h($zid) ?>"><input type="hidden" name="rec" value="<?= h($r['id']) ?>">
            <button class="ghost sm" type="submit"><?= !empty($r['proxied']) ? 'Desativar proxy' : 'Ativar proxy' ?></button></form>
          <?php endif; ?>
          <form method="post" data-confirm="Remover este registro?"><?= csrf_field('rec_delete') ?><input type="hidden" name="zone" value="<?= h($zid) ?>"><input type="hidden" name="rec" value="<?= h($r['id']) ?>">
            <button class="danger sm" type="submit">Remover</button></form>
        </div></td>
      </tr>
    <?php endforeach; ?>
    </tbody>
  </table></div>
  <p class="hint" style="margin-top:10px">Com o <b>proxy</b> ativo, o nome responde com o IP da CDN (<?= h($pub) ?>) e o tráfego é repassado para o valor do registro, com HTTPS automático. Sem proxy, é só DNS comum.</p>
  <?php endif; ?>
</div>

<div class="card">
  <h2>Adicionar registro</h2>
  <form method="post" autocomplete="off">
    <?= csrf_field('rec_add') ?><input type="hidden" name="zone" value="<?= h($zid) ?>">
    <div class="row">
      <div><label for="r_type">Tipo</label>
        <select id="r_type" name="type"><option>A</option><option>AAAA</option><option>CNAME</option><option>MX</option><option>TXT</option></select></div>
      <div><label for="r_name">Nome</label><input id="r_name" name="name" placeholder="@, www, api, *" maxlength="190"></div>
      <div style="grid-column:span 2"><label for="r_value">Valor</label><input id="r_value" name="value" required maxlength="1000" placeholder="203.0.113.10"></div>
      <div id="r_prio_wrap"><label for="r_prio">Prioridade (MX)</label><input id="r_prio" name="prio" type="number" min="0" max="65535" value="10"></div>
      <div><label for="r_ttl">TTL</label>
        <select id="r_ttl" name="ttl"><option value="300">Automático</option><option value="3600">1 hora</option><option value="86400">1 dia</option></select></div>
    </div>
    <div class="row" id="r_proxy_wrap" style="margin-top:12px">
      <div style="grid-column:span 2"><label style="font-weight:600"><input type="checkbox" name="proxied" value="1" style="width:auto"> Passar pelo proxy da CDN (o valor vira a origem do site)</label></div>
      <div><label for="r_scheme">Protocolo da origem</label><select id="r_scheme" name="scheme"><option value="http">http</option><option value="https">https</option></select></div>
      <div><label for="r_port">Porta da origem</label><input id="r_port" name="port" placeholder="80 / 443" inputmode="numeric" maxlength="5"></div>
    </div>
    <div style="margin-top:16px"><button type="submit">Adicionar registro</button></div>
  </form>
</div>
    <?php
    layout($z['name'], (string)ob_get_clean());
}

/* ------------------------------ roteador ------------------------------ */

$p = (string)($_GET['p'] ?? 'dash');

if ($p === 'login') {
    if (me()) {
        go('dash');
    }
    page_login();
    exit;
}

if (!me()) {
    go('login');
}

switch ($p) {
    case 'edit':     page_edit();     break;
    case 'users':    page_users();    break;
    case 'zones':    page_zones();    break;
    case 'zone':     page_zone();     break;
    case 'settings': page_settings(); break;
    case 'account':  page_account();  break;
    default:         page_dash();
}
__CDN_FILE_EOF__
install_file '/opt/cdn-panel/bin/cdn-apply' 755 <<'__CDN_FILE_EOF__'
#!/usr/bin/php
<?php
declare(strict_types=1);

/* Helper root: regenera os arquivos do nginx a partir do banco, valida (nginx -t) e recarrega. */

if (PHP_SAPI !== 'cli') {
    exit(1);
}
require __DIR__ . '/../lib.php';

// Remove o pedido primeiro: se chegar outro durante a aplicação, o systemd dispara de novo.
@unlink(cdn_p(P_REQ));

@mkdir(cdn_p(P_RUN), 0755, true);
$lock = fopen(cdn_p(P_RUN) . '/apply.lock', 'c');
if ($lock) {
    flock($lock, LOCK_EX);
}

try {
    $r = cdn_apply(); // publica o resultado (apply.result) ao longo do processo
} catch (Throwable $e) {
    $r = ['ok' => false, 'changed' => false, 'msg' => 'Erro interno: ' . $e->getMessage()];
    publish_result($r);
}

fwrite($r['ok'] ? STDOUT : STDERR, $r['msg'] . "\n");
exit($r['ok'] ? 0 : 1);
__CDN_FILE_EOF__
install_file '/opt/cdn-panel/bin/cdnctl.php' 644 <<'__CDN_FILE_EOF__'
<?php
declare(strict_types=1);

/* Utilitário de linha de comando (rodar como www-data via wrapper /usr/local/bin/cdn-panel). */

if (PHP_SAPI !== 'cli') {
    exit(1);
}
require __DIR__ . '/../lib.php';

$cmd = $argv[1] ?? 'help';
$a = array_slice($argv, 2);

function out(string $s): void
{
    fwrite(STDOUT, $s . "\n");
}

function fail(string $s): void
{
    fwrite(STDERR, "Erro: $s\n");
    exit(1);
}

try {
    switch ($cmd) {
        case 'init-admin':
            [$user, $pass] = [$a[0] ?? 'admin', $a[1] ?? ''];
            $base = strtolower(trim($a[2] ?? ''));
            if (!valid_username($user)) {
                fail('usuário inválido');
            }
            check_password_policy($pass);
            if ($base !== '' && !valid_hostname($base)) {
                fail('domínio base inválido');
            }
            $created = db_mutate(function (array &$db) use ($user, $pass, $base) {
                foreach ($db['users'] as $u) {
                    if (($u['role'] ?? '') === 'admin') {
                        if ($base !== '') {
                            $db['settings']['base_domain'] = $base;
                        }
                        return false;
                    }
                }
                $db['users'][$user] = [
                    'hash' => password_hash($pass, PASSWORD_DEFAULT),
                    'role' => 'admin', 'max_domains' => 0, 'disabled' => false, 'created' => time(),
                ];
                if ($base !== '') {
                    $db['settings']['base_domain'] = $base;
                }
                db_log($db, 'sistema', "Administrador '$user' criado");
                return true;
            });
            out($created ? 'admin-criado' : 'admin-ja-existe');
            break;

        case 'passwd':
            $user = $a[0] ?? '';
            $pass = $a[1] ?? random_password(16);
            check_password_policy($pass);
            db_mutate(function (array &$db) use ($user, $pass) {
                if (!isset($db['users'][$user])) {
                    throw new UserError('usuário não existe');
                }
                $db['users'][$user]['hash'] = password_hash($pass, PASSWORD_DEFAULT);
                $db['users'][$user]['disabled'] = false;
                $db['fails'] = [];
                db_log($db, 'sistema', "Senha de '$user' redefinida pela CLI");
            });
            out("Nova senha de $user: $pass");
            break;

        case 'list':
            $db = db_read();
            out(sprintf("%-20s %-8s %-8s %s", 'USUÁRIO', 'PAPEL', 'DOMÍNIOS', 'ESTADO'));
            foreach ($db['users'] as $name => $u) {
                $n = count(array_filter($db['domains'], fn($d) => ($d['owner'] ?? '') === $name));
                out(sprintf("%-20s %-8s %-8d %s", $name, $u['role'] ?? '-', $n, !empty($u['disabled']) ? 'desativado' : 'ativo'));
            }
            break;

        case 'domains':
            $db = db_read();
            foreach ($db['domains'] as $id => $d) {
                out(sprintf("%s  %-40s -> %s://%s:%s  [%s/%s] (%s)", $id, $d['fqdn'] ?? '?', $d['scheme'] ?? '', $d['host'] ?? '', $d['port'] ?? '', $d['kind'] ?? 'generated', $d['status'] ?? '', $d['owner'] ?? ''));
            }
            break;

        case 'setbase':
            $base = strtolower(trim($a[0] ?? ''));
            if ($base !== '' && !valid_hostname($base)) {
                fail('domínio base inválido');
            }
            db_mutate(function (array &$db) use ($base) {
                $db['settings']['base_domain'] = $base;
                db_log($db, 'sistema', 'Domínio base definido pela CLI: ' . ($base ?: '(padrão sslip.io)'));
            });
            out('ok');
            break;

        default:
            out("Uso: cdn-panel <comando>\n"
              . "  apply                      reaplica a configuração do nginx agora\n"
              . "  status                     mostra o estado dos serviços\n"
              . "  list                       lista usuários\n"
              . "  domains                    lista domínios\n"
              . "  passwd <usuario> [senha]   redefine a senha (gera uma aleatória se omitida)\n"
              . "  setbase <dominio>          define o domínio base dos domínios gerados\n"
              . "  cert <dominio> <cf-token>  emite certificado wildcard (Cloudflare DNS-01)");
    }
} catch (UserError $e) {
    fail($e->getMessage());
}
__CDN_FILE_EOF__
install_file '/usr/local/bin/cdn-panel' 755 <<'__CDN_FILE_EOF__'
#!/usr/bin/env bash
# CLI do CDN Proxy Panel
set -euo pipefail
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Rode como root: sudo cdn-panel $*" >&2; exit 1; }

case "${1:-help}" in
  apply)
    systemctl start cdn-apply.service || true
    cat /run/cdn-panel/apply.result 2>/dev/null; echo
    ;;
  status)
    for u in nginx cdn-apply.path cdn-apply.timer; do
      printf '%-18s %s\n' "$u" "$(systemctl is-active "$u" 2>&1 || true)"
    done
    for u in $(systemctl list-unit-files --no-legend 'php*-fpm.service' | awk '{print $1}'); do
      printf '%-18s %s\n' "$u" "$(systemctl is-active "$u" 2>&1 || true)"
    done
    nginx -t
    echo "Último apply: $(cat /run/cdn-panel/apply.result 2>/dev/null || echo nenhum)"
    ;;
  cert)
    DOM="${2:-}"; TOKEN="${3:-${CF_API_TOKEN:-}}"
    [ -n "$DOM" ] || { echo "Uso: cdn-panel cert <dominio-base> [token-cloudflare]"; exit 1; }
    if [ -z "$TOKEN" ]; then read -r -s -p "Token da API Cloudflare (Zone:DNS:Edit): " TOKEN; echo; fi
    [ -n "$TOKEN" ] || { echo "Token vazio."; exit 1; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-dns-cloudflare
    install -d -m 700 /etc/cdn-panel/secrets
    ( umask 077; printf 'dns_cloudflare_api_token = %s\n' "$TOKEN" > /etc/cdn-panel/secrets/cloudflare.ini )
    certbot certonly --dns-cloudflare --dns-cloudflare-credentials /etc/cdn-panel/secrets/cloudflare.ini \
      -d "$DOM" -d "*.$DOM" --cert-name "$DOM" --non-interactive --agree-tos --register-unsafely-without-email
    install -d /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/cdn-panel-reload.sh
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/cdn-panel-reload.sh
    runuser -u www-data -- php /opt/cdn-panel/bin/cdnctl.php setbase "$DOM"
    systemctl start cdn-apply.service || true
    echo "Certificado wildcard instalado para *.$DOM e aplicado."
    ;;
  *)
    exec runuser -u www-data -- php /opt/cdn-panel/bin/cdnctl.php "$@"
    ;;
esac
__CDN_FILE_EOF__
install_file '/etc/systemd/system/cdn-apply.service' 644 <<'__CDN_FILE_EOF__'
[Unit]
Description=CDN Proxy - aplica a configuracao do nginx
After=nginx.service

[Service]
Type=oneshot
ExecStart=/usr/bin/php /opt/cdn-panel/bin/cdn-apply
RuntimeDirectory=cdn-panel
RuntimeDirectoryPreserve=yes
__CDN_FILE_EOF__
install_file '/etc/systemd/system/cdn-apply.path' 644 <<'__CDN_FILE_EOF__'
[Unit]
Description=CDN Proxy - observa pedidos do painel

[Path]
PathExists=/var/lib/cdn-panel/apply.request
Unit=cdn-apply.service

[Install]
WantedBy=multi-user.target
__CDN_FILE_EOF__
install_file '/etc/systemd/system/cdn-apply.timer' 644 <<'__CDN_FILE_EOF__'
[Unit]
Description=CDN Proxy - reaplica a cada 5 minutos (atualiza IPs de origens por dominio)

[Timer]
OnBootSec=45s
OnUnitActiveSec=5min
AccuracySec=10s
Unit=cdn-apply.service

[Install]
WantedBy=timers.target
__CDN_FILE_EOF__

chown -R root:root /opt/cdn-panel
touch /var/lib/cdn-panel/db.json.lock
chown www-data:www-data /var/lib/cdn-panel/db.json.lock

printf '{\n  "public_ip": "%s",\n  "ipv6": %s,\n  "timezone": "%s",\n  "http_ports": %s,\n  "tls_ports": %s,\n  "panel_port": %s,\n  "dns": %s\n}\n' \
  "$PUBLIC_IP" "$IPV6" "$CDN_TZ" "$(json_list "$HTTP_PORTS")" "$(json_list "$TLS_PORTS")" "$PANEL_PORT" "$DNS_ON" > /etc/cdn-panel/settings.json
chmod 644 /etc/cdn-panel/settings.json

if [ ! -s /etc/cdn-panel/certs/default.crt ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=cdn-proxy" \
    -keyout /etc/cdn-panel/certs/default.key -out /etc/cdn-panel/certs/default.crt >/dev/null 2>&1
  chmod 600 /etc/cdn-panel/certs/default.key
  chmod 644 /etc/cdn-panel/certs/default.crt
  ok "Certificado autoassinado padrão criado"
fi

# --- nginx: listens gerados conforme as portas livres
mkdir -p /etc/cdn-panel/nginx
{
  for p in $HTTP_PORTS; do echo "    listen $p default_server;"; [ "$IPV6" = true ] && echo "    listen [::]:$p default_server;"; done
  for p in $TLS_PORTS;  do echo "    listen $p ssl default_server;"; [ "$IPV6" = true ] && echo "    listen [::]:$p ssl default_server;"; done
  true
} > /etc/cdn-panel/nginx/listen-default.inc
{
  echo "    listen $PANEL_PORT ssl;"
  [ "$IPV6" = true ] && echo "    listen [::]:$PANEL_PORT ssl;"
  true
} > /etc/cdn-panel/nginx/listen-panel.inc
: > /etc/cdn-panel/nginx/panel-acl.inc
if [ -n "$PANEL_ALLOW_IPS" ]; then
  { for a in "${ALLOW_ARR[@]}"; do printf '    allow %s;\n' "$a"; done; printf '    deny all;\n'; } > /etc/cdn-panel/nginx/panel-acl.inc
fi

install_file '/etc/nginx/conf.d/00-cdn-proxy.conf' 644 <<'__CDN_FILE_EOF__'
# Gerado pelo cdn-panel. Contexto http.
map $http_upgrade $cdn_connection_upgrade {
    default upgrade;
    ''      '';
}

limit_req_zone  $binary_remote_addr zone=cdn_req:20m rate=100r/s;
limit_conn_zone $binary_remote_addr zone=cdn_conn:20m;

log_format cdn '$remote_addr [$time_local] $host "$request" $status $body_bytes_sent '
               '$upstream_addr $request_time';
access_log /var/log/nginx/cdn-access.log cdn;

include /etc/nginx/cdn-sites/*.conf;
__CDN_FILE_EOF__
install_file '/etc/nginx/conf.d/01-cdn-default.conf' 644 <<'__CDN_FILE_EOF__'
# Gerado pelo cdn-panel. Qualquer host desconhecido é descartado.
server {
    include /etc/cdn-panel/nginx/listen-default.inc;
    server_name _;
    server_tokens off;

    ssl_certificate     /etc/cdn-panel/certs/default.crt;
    ssl_certificate_key /etc/cdn-panel/certs/default.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    access_log off;
    return 444;
}
__CDN_FILE_EOF__
install_file '/etc/nginx/conf.d/10-cdn-panel.conf' 644 <<'__CDN_FILE_EOF__'
# Gerado pelo cdn-panel. Painel web (HTTPS).
server {
    include /etc/cdn-panel/nginx/listen-panel.inc;
    server_name _;
    server_tokens off;

    ssl_certificate     /etc/cdn-panel/certs/default.crt;
    ssl_certificate_key /etc/cdn-panel/certs/default.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    # http://IP:porta -> https://IP:porta
    error_page 497 =301 https://$host:$server_port$request_uri;

    include /etc/cdn-panel/nginx/panel-acl.inc;

    root /opt/cdn-panel/public;
    index index.php;
    client_max_body_size 1m;
    access_log /var/log/nginx/cdn-panel-access.log;

    location / {
        rewrite ^ /index.php last;
    }

    location = /index.php {
        include snippets/fastcgi-php.conf;
        fastcgi_param HTTPS on;
        fastcgi_pass unix:@PHP_SOCK@;
        fastcgi_read_timeout 60s;
    }
}
__CDN_FILE_EOF__

sed -i "s|@PHP_SOCK@|${PHP_SOCK}|" /etc/nginx/conf.d/10-cdn-panel.conf
if grep -q '@PHP_SOCK@' /etc/nginx/conf.d/10-cdn-panel.conf; then die "Placeholder do PHP-FPM não substituído."; fi

# --- BIND9: servidor DNS autoritativo (somente zonas dos clientes; sem recursão)
if [ "$DNS_ON" = true ]; then
  mkdir -p /etc/bind/cdn-zones
  [ -f /etc/bind/named.conf.options.cdn-orig ] || cp -a /etc/bind/named.conf.options /etc/bind/named.conf.options.cdn-orig 2>/dev/null || true
  cat > /etc/bind/named.conf.options <<'__BIND_OPTS__'
// Gerado pelo cdn-panel: servidor autoritativo, sem recursão.
options {
    directory "/var/cache/bind";
    listen-on { any; };
    listen-on-v6 { none; };
    recursion no;
    allow-query { any; };
    allow-recursion { none; };
    allow-transfer { none; };
    allow-update { none; };
    version "none";
    hostname none;
    server-id none;
    minimal-responses yes;
    empty-zones-enable no;
    rate-limit { responses-per-second 20; window 5; };
};
__BIND_OPTS__
  [ -f /etc/bind/cdn-zones.conf ] || : > /etc/bind/cdn-zones.conf
  grep -q 'cdn-zones.conf' /etc/bind/named.conf.local 2>/dev/null || echo 'include "/etc/bind/cdn-zones.conf";' >> /etc/bind/named.conf.local
  chmod 755 /etc/bind/cdn-zones; chmod 644 /etc/bind/cdn-zones.conf
  if named-checkconf >/dev/null 2>&1; then ok "BIND9 configurado (autoritativo, sem recursão)"
  else named-checkconf || true; die "A configuração do BIND9 não passou no teste."; fi
fi

# remove o site padrão (conflita com o default_server da CDN)
rm -f /etc/nginx/sites-enabled/default
mkdir -p /var/log/nginx

nginx -t >/dev/null 2>&1 || { nginx -t; die "A configuração do nginx não passou no teste."; }
ok "Arquivos instalados e nginx validado"

# ---------------------------------------------------------------- 7
step 7 "Iniciando serviços"
systemctl daemon-reload
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx || { journalctl -u nginx -n 15 --no-pager || true; die "O nginx não iniciou (veja o log acima)."; }
if [ "$DNS_ON" = true ]; then
  systemctl enable bind9 >/dev/null 2>&1 || systemctl enable named >/dev/null 2>&1 || true
  systemctl restart bind9 2>/dev/null || systemctl restart named || { journalctl -u bind9 -u named -n 15 --no-pager || true; die "O BIND9 não iniciou (veja o log acima)."; }
  sleep 1
  if ss -lunH 'sport = :53' 2>/dev/null | grep -q .; then ok "Servidor DNS ouvindo na porta 53"; else warn "BIND9 iniciou, mas a porta 53/udp não aparece aberta."; fi
fi
systemctl enable --now cdn-apply.path cdn-apply.timer >/dev/null 2>&1
systemctl enable --now certbot.timer >/dev/null 2>&1 || true
ok "nginx, $PHP_FPM, cdn-apply.path e cdn-apply.timer ativos"

# ---------------------------------------------------------------- 8
step 8 "Criando administrador"
NEW_ADMIN=false
if [ -z "$ADMIN_PASS" ]; then ADMIN_PASS="$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 20 || true)"; fi
RES="$(runuser -u www-data -- php /opt/cdn-panel/bin/cdnctl.php init-admin "$ADMIN_USER" "$ADMIN_PASS" "$CDN_BASE_DOMAIN")"
if [ "$RES" = "admin-criado" ]; then
  NEW_ADMIN=true
  ( umask 077; printf 'Painel:  https://%s:%s\nUsuário: %s\nSenha:   %s\n' "$PUBLIC_IP" "$PANEL_PORT" "$ADMIN_USER" "$ADMIN_PASS" > /root/cdn-panel-credentials.txt )
  ok "Administrador '$ADMIN_USER' criado (credenciais em /root/cdn-panel-credentials.txt)"
else
  ok "Administrador já existia, mantido"
  if [ -n "$CDN_BASE_DOMAIN" ]; then ok "Domínio base atualizado para $CDN_BASE_DOMAIN"; fi
fi

if [ -n "$CF_API_TOKEN" ]; then
  [ -n "$CDN_BASE_DOMAIN" ] || die "CF_API_TOKEN exige CDN_BASE_DOMAIN."
  CF_API_TOKEN="$CF_API_TOKEN" /usr/local/bin/cdn-panel cert "$CDN_BASE_DOMAIN" || warn "Falha ao emitir o certificado wildcard (rode depois: cdn-panel cert $CDN_BASE_DOMAIN)."
fi

# ---------------------------------------------------------------- 9
step 9 "Testando a instalação"
systemctl start cdn-apply.service || true
APPLY_OK="$(php -r '$r=json_decode(@file_get_contents("/run/cdn-panel/apply.result"),true); echo !empty($r["ok"])?"1":"0";')"
if [ "$APPLY_OK" = 1 ]; then ok "Helper de aplicação do nginx funcionando"; else warn "Helper retornou erro: veja 'cat /run/cdn-panel/apply.result'"; fi

CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "https://127.0.0.1:${PANEL_PORT}/" || true)"
if [ "$CODE" = 302 ]; then ok "Painel respondendo em https://127.0.0.1:${PANEL_PORT} (redireciona para o login)"; else warn "Painel respondeu HTTP $CODE (esperado 302). Veja: journalctl -u nginx -u $PHP_FPM"; fi
for p in $HTTP_PORTS; do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${p}/" || true)"
  if [ "$CODE" = 000 ]; then ok "Proxy ativo na porta $p (host desconhecido é descartado)"; else warn "Porta $p respondeu HTTP $CODE (esperado conexão fechada)"; fi
done

if [ -z "$CDN_BASE_DOMAIN" ]; then BASE_SHOW="${PUBLIC_IP//./-}.sslip.io"; else BASE_SHOW="$CDN_BASE_DOMAIN"; fi

echo
echo "=================================================="
echo "  ${G}${B}✔ INSTALAÇÃO CONCLUÍDA${N}"
echo "=================================================="
echo "  Painel:   ${B}https://${PUBLIC_IP}:${PANEL_PORT}${N}   (certificado autoassinado: aceite o aviso do navegador)"
if [ "$NEW_ADMIN" = true ]; then
  echo "  Usuário:  ${B}${ADMIN_USER}${N}"
  echo "  Senha:    ${B}${ADMIN_PASS}${N}   (também em /root/cdn-panel-credentials.txt)"
fi
echo "  Domínios gerados: ${B}xxxxxxxx.${BASE_SHOW}${N}"
echo "  Domínio próprio:  o cliente cadastra o domínio no painel e aponta o DNS (A → ${PUBLIC_IP}); o HTTPS sai sozinho"
echo "  Portas do proxy:  HTTP ${HTTP_PORTS:-nenhuma} | HTTPS ${TLS_PORTS:-nenhuma}"
if [ -n "$CDN_BASE_DOMAIN" ]; then
  echo "  ${Y}DNS necessário:${N} registro  A  *.${CDN_BASE_DOMAIN}  →  ${PUBLIC_IP}"
fi
if [ "$DNS_ON" = true ]; then
  echo "  ${B}Nameservers próprios:${N} no painel, menu DNS → o cliente adiciona o domínio e troca os nameservers lá no registrador."
  echo "  ${Y}Para isso:${N} libere a porta 53 (TCP e UDP) na hospedagem e crie os registros A  ns1.${BASE_SHOW}  e  ns2.${BASE_SHOW}  →  ${PUBLIC_IP}"
  echo "            (ou deixe o curinga *.${BASE_SHOW} cobrir). Os nomes podem ser trocados no painel: Sistema → Servidor DNS."
fi
echo
echo "  Comandos úteis:  cdn-panel status | apply | list | domains | passwd <usuario> | cert <dominio>"
echo "  Libere TCP ${ALL_PORTS} no firewall da hospedagem (e no iptables, se usar)."
echo
