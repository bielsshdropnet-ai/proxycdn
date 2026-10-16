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
#    CDN_ENABLE_UFW=1  instala/ativa o ufw (só use em VPS limpa, sem outros serviços)
#    CDN_TZ            fuso do painel (padrão: America/Sao_Paulo)
# ==================================================================
set -Eeuo pipefail

VERSION="1.1.0"
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
apt-get update -y -qq
PKGS=(nginx php-fpm php-cli openssl curl ca-certificates iproute2)
if [ "$CDN_ENABLE_UFW" = 1 ]; then PKGS+=(ufw); fi
if [ -n "$CF_API_TOKEN" ]; then PKGS+=(certbot python3-certbot-dns-cloudflare); fi
apt-get install -y -qq -o Dpkg::Options::=--force-confold "${PKGS[@]}"
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

mkdir -p /opt/cdn-panel/public /opt/cdn-panel/bin /etc/cdn-panel/certs /etc/nginx/cdn-sites /var/lib/cdn-panel
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

class UserError extends RuntimeException {}

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
    foreach (['users', 'domains', 'fails', 'log'] as $k) {
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

/** Resolve o host de origem para IPv4s públicos (ordenados, máx. 4). */
function resolve_origin(string $host): array
{
    if (valid_ipv4($host)) {
        $ips = [$host];
    } else {
        $ips = @gethostbynamel($host) ?: [];
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

function cert_for(string $fqdn): array
{
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
        . "        proxy_send_timeout 120s;\n"
        . "        proxy_read_timeout 120s;\n"
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

function cdn_apply(): array
{
    $settings = settings_read();
    $ipv6 = !empty($settings['ipv6']);
    $db = db_read();

    $files = [];
    $status = [];

    foreach ($db['domains'] as $id => $d) {
        $id = (string)$id;
        try {
            if (!is_array($d) || !preg_match('/^[a-f0-9]{8}$/', $id)) {
                throw new UserError('registro inválido');
            }
            if (!isset($d['fqdn']) || !valid_fqdn((string)$d['fqdn'])) {
                throw new UserError('domínio gerado inválido');
            }
            $owner = (string)($d['owner'] ?? '');
            $user = $db['users'][$owner] ?? null;
            $suspended = (($d['status'] ?? 'active') !== 'active') || !$user || !empty($user['disabled']);

            if ($suspended) {
                $files[$id . '.conf'] = render_site($id, $d, [], $ipv6, true);
                $status[$id] = ['state' => 'suspended', 'ips' => []];
                continue;
            }

            $o = validate_origin($d, true);
            $files[$id . '.conf'] = render_site($id, $d, $o, $ipv6, false);
            $status[$id] = ['state' => 'active', 'ips' => $o['ips']];
        } catch (UserError $e) {
            $status[$id] = ['state' => 'error', 'msg' => $e->getMessage(), 'ips' => []];
        }
    }

    $dir = cdn_p(P_SITES);
    if (!is_dir($dir) && !@mkdir($dir, 0755, true)) {
        return ['ok' => false, 'changed' => false, 'msg' => 'Não foi possível criar ' . $dir];
    }

    $old = [];
    foreach (glob($dir . '/*.conf') ?: [] as $f) {
        $old[basename($f)] = (string)file_get_contents($f);
    }

    ksort($old);
    ksort($files);
    if ($old === $files) {
        write_run_json('status.json', ['t' => time(), 'domains' => $status]);
        return ['ok' => true, 'changed' => false, 'msg' => 'Nenhuma alteração necessária.'];
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
        return ['ok' => false, 'changed' => false, 'msg' => 'nginx -t falhou, alterações desfeitas: ' . utf8_cut($out, 600)];
    }

    [$rc, $out] = run_cmd(getenv('CDN_NGINX_RELOAD') ?: 'systemctl reload-or-restart nginx');
    if ($rc !== 0) {
        $restore();
        run_cmd(getenv('CDN_NGINX_RELOAD') ?: 'systemctl reload-or-restart nginx');
        return ['ok' => false, 'changed' => false, 'msg' => 'Falha ao recarregar o nginx, alterações desfeitas: ' . utf8_cut($out, 600)];
    }

    write_run_json('status.json', ['t' => time(), 'domains' => $status]);
    return ['ok' => true, 'changed' => true, 'msg' => 'Configuração aplicada (' . count($files) . ' domínio(s)).'];
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
                $o = validate_origin($_POST);
                $label = clean_label((string)($_POST['label'] ?? ''));
                $id = db_mutate(function (array &$db) use ($user, $o, $label) {
                    $max = (int)($db['users'][$user]['max_domains'] ?? 0);
                    if ($max > 0 && count(owner_domains($db, $user)) >= $max) {
                        throw new UserError("Você atingiu o limite de $max domínio(s).");
                    }
                    $base = base_domain($db);
                    if ($base === '') {
                        throw new UserError('O domínio base ainda não foi configurado pelo administrador.');
                    }
                    do {
                        $id = bin2hex(random_bytes(4));
                    } while (isset($db['domains'][$id]));
                    $fqdn = $id . '.' . $base;
                    if (!valid_fqdn($fqdn)) {
                        throw new UserError('Não foi possível gerar um domínio válido.');
                    }
                    $db['domains'][$id] = [
                        'id' => $id, 'owner' => $user, 'label' => $label, 'fqdn' => $fqdn,
                        'scheme' => $o['scheme'], 'host' => $o['host'], 'port' => $o['port'],
                        'host_header' => $o['host_header'], 'status' => 'active', 'created' => time(),
                    ];
                    db_log($db, $user, "Criou $fqdn -> {$o['scheme']}://{$o['host']}:{$o['port']}");
                    return $id;
                });
                [$ok, $msg] = apply_proxy();
                if ($ok) {
                    flash('ok', 'Domínio criado e ativo.');
                } else {
                    flash('err', 'Domínio salvo, mas houve um problema ao aplicar: ' . $msg);
                }
                go('dash');

            case 'domain_update':
                $id = (string)($_POST['id'] ?? '');
                $o = validate_origin($_POST);
                $label = clean_label((string)($_POST['label'] ?? ''));
                db_mutate(function (array &$db) use ($id, $o, $label, $user) {
                    $d = $db['domains'][$id] ?? null;
                    if (!$d || (($d['owner'] ?? '') !== $user && !is_admin())) {
                        throw new UserError('Domínio não encontrado.');
                    }
                    $db['domains'][$id] = array_merge($d, [
                        'label' => $label, 'scheme' => $o['scheme'], 'host' => $o['host'],
                        'port' => $o['port'], 'host_header' => $o['host_header'],
                    ]);
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

            default:
                throw new UserError('Ação desconhecida.');
        }
    } catch (UserError $e) {
        flash('err', $e->getMessage());
        $back = in_array($a, ['user_create', 'user_update', 'user_reset', 'user_delete'], true) ? 'users'
            : (in_array($a, ['pw_change'], true) ? 'account' : (in_array($a, ['settings_save', 'apply_now'], true) ? 'settings' : 'dash'));
        $q = ($a === 'domain_update') ? ['id' => (string)($_POST['id'] ?? '')] : [];
        go($a === 'domain_update' ? 'edit' : $back, $q);
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
    return '<span class="badge b-ok">Ativo</span>';
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
          <?php if (!empty($d['label'])): ?><div class="hint"><?= h($d['label']) ?></div><?php endif; ?></td>
        <td class="mono"><?= h($d['scheme']) ?>://<?= h($d['host']) ?>:<?= h($d['port']) ?>
          <?php if (!empty($d['host_header'])): ?><div class="hint">Host: <?= h($d['host_header']) ?></div><?php endif; ?></td>
        <?php if ($admin): ?><td><?= h($d['owner']) ?></td><?php endif; ?>
        <td><?= badge_for($d, $st) ?>
          <?php if (($st[$d['id']]['state'] ?? '') === 'error'): ?><div class="hint"><?= h($st[$d['id']]['msg'] ?? '') ?></div><?php endif; ?></td>
        <td><div class="acts">
          <button class="ghost sm" type="button" data-copy="<?= h($d['fqdn']) ?>">Copiar</button>
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

$prev = read_run_json('apply.result');
$seq = (int)($prev['seq'] ?? 0) + 1;

try {
    $r = cdn_apply();
} catch (Throwable $e) {
    $r = ['ok' => false, 'changed' => false, 'msg' => 'Erro interno: ' . $e->getMessage()];
}

$r['seq'] = $seq;
$r['t'] = time();
write_run_json('apply.result', $r);

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
                out(sprintf("%s  %-40s -> %s://%s:%s  [%s] (%s)", $id, $d['fqdn'] ?? '?', $d['scheme'] ?? '', $d['host'] ?? '', $d['port'] ?? '', $d['status'] ?? '', $d['owner'] ?? ''));
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

printf '{\n  "public_ip": "%s",\n  "ipv6": %s,\n  "timezone": "%s",\n  "http_ports": %s,\n  "tls_ports": %s,\n  "panel_port": %s\n}\n' \
  "$PUBLIC_IP" "$IPV6" "$CDN_TZ" "$(json_list "$HTTP_PORTS")" "$(json_list "$TLS_PORTS")" "$PANEL_PORT" > /etc/cdn-panel/settings.json
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
systemctl enable --now cdn-apply.path cdn-apply.timer >/dev/null 2>&1
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
echo "  Portas do proxy:  HTTP ${HTTP_PORTS:-nenhuma} | HTTPS ${TLS_PORTS:-nenhuma}"
if [ -n "$CDN_BASE_DOMAIN" ]; then
  echo "  ${Y}DNS necessário:${N} registro  A  *.${CDN_BASE_DOMAIN}  →  ${PUBLIC_IP}"
fi
echo
echo "  Comandos úteis:  cdn-panel status | apply | list | domains | passwd <usuario> | cert <dominio>"
echo "  Libere TCP ${ALL_PORTS} no firewall da hospedagem (e no iptables, se usar)."
echo
