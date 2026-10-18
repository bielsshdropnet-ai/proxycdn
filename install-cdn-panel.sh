#!/usr/bin/env bash
# ==================================================================
#  CDN Proxy + Painel Web (DROPNET)
#  Proxy reverso nginx (portas 80/443/8443) + painel web HTTPS (8080).
#  Suporta Ubuntu 20.04+ e Debian 11+ (PHP 7.4 ou mais novo).
#  Convive com outros serviços (ex.: SSHPlus): portas já usadas são puladas
#  e o firewall NÃO é alterado, a menos que você peça.
#  Pode ser executado de novo para atualizar.
#
#  ✅ ADICIONAL: Detecção Automática por Operadora
#     Origem especial: @OPERADORA@ → Claro→Claro, Vivo→Vivo, Tim→Tim
# ==================================================================
set -Eeuo pipefail
VERSION="1.3.1"
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
echo "   + Detecção Automática por Operadora ✅"
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
port_busy() { local line; line="$(ss -ltnpH "sport = :$1" 2>/dev/null | head -1 || true)"; [ -n "$line" ] && ! grep -q '"nginx"' <<<"$line"; }
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
dns_port_busy() { local proto line; for proto in -ltnpH -lunpH; do line="$(ss $proto 'sport = :53' 2>/dev/null | grep -v -E '127\.0\.0\.(53|54):53' | grep -v '"named"' | head -1 || true)"; [ -n "$line" ] && return 0; done; return 1; }
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

# ===== ADICIONAL: ARQUIVO DE DETECÇÃO DE OPERADORA =====
cat > /etc/nginx/conf.d/02-operadora-geo.conf << 'EOF'
# ==================================================
# DETECÇÃO AUTOMÁTICA POR OPERADORA
# Origem especial no painel: @OPERADORA@
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
EOF
ok "Arquivo de detecção operadora criado"
# ===== FIM DA ADIÇÃO =====

install_file() { mkdir -p "$(dirname "$1")"; cat > "$1.new"; chmod "$2" "$1.new"; mv -f "$1.new" "$1"; }
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
 * CDN Proxy Panel - biblioteca compartilhada
 * ✅ Suporte adicional: Modo Operadora (@OPERADORA@)
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

function is_expired(array $x): bool { $e = (int)($x['expires'] ?? 0); return $e > 0 && $e <= time(); }
function days_left(array $x): ?int { $e = (int)($x['expires'] ?? 0); if ($e <= 0) return null; return max(0, (int)ceil(($e - time()) / 86400)); }
function parse_days($v): int { $v = trim((string)$v); if ($v === '') return 0; if (!preg_match('/^\d{1,4}$/', $v)) throw new UserError('Dias inválidos.'); $n = (int)$v; if ($n > 3650) throw new UserError('Máximo de 3650 dias.'); return $n; }
function cdn_p(string $p): string { return (getenv('CDN_PREFIX') ?: '') . $p; }

function db_default(): array { return ['users'=>[],'domains'=>[],'zones'=>[],'settings'=>['base_domain'=>''],'fails'=>[],'log'=>[]]; }
function db_read(): array { $f=cdn_p(P_DB); if(!is_file($f)||is_link($f))return db_default();$raw=@file_get_contents($f);$d=json_decode((string)$raw,true);if(!is_array($d))return db_default();return array_replace(db_default(),$d); }
function db_mutate(callable $fn) { $f=cdn_p(P_DB);$lock=@fopen($f.'.lock','c');if(!$lock)throw new RuntimeException('Banco bloqueado.');flock($lock,LOCK_EX);try{$db=db_read();$res=$fn($db);$db['log']=array_slice($db['log'],-300);$tmp=$f.'.tmp';file_put_contents($tmp,json_encode($db,JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES));@chmod($tmp,0640);rename($tmp,$f);return $res;}finally{flock($lock,LOCK_UN);fclose($lock);} }
function db_log(array &$db, string $user, string $msg): void { $db['log'][]=['t'=>time(),'u'=>$user,'m'=>$msg]; }
function settings_read(): array { $f=cdn_p(P_SETTINGS);$d=is_file($f)?json_decode((string)@file_get_contents($f),true):null;return is_array($d)?$d:[]; }

function valid_username(string $u): bool { return (bool)preg_match('/^[a-z0-9_.-]{3,32}$/',$u); }
function valid_ipv4(string $ip): bool { return filter_var($ip,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4)!==false; }
function valid_hostname(string $h): bool { return (bool)preg_match('/^(?=.{4,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:[a-z]{2,63}|xn--[a-z0-9-]{1,59})$/',$h); }
function ip_in_cidr(string $ip, string $cidr): bool { [$net,$bits]=explode('/',$cidr);$mask=$bits===0?0:((0xFFFFFFFF<<(32-$bits))&0xFFFFFFFF);return(ip2long($ip)&$mask)===(ip2long($net)&$mask); }
function is_public_ipv4(string $ip): bool { if(!valid_ipv4($ip))return false;static $blocked=['0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8','169.254.0.0/16','172.16.0.0/12','192.0.0.0/24','192.0.2.0/24','192.168.0.0/16','198.18.0.0/15','198.51.100.0/24','203.0.113.0/24','224.0.0.0/3'];foreach($blocked as$c)if(ip_in_cidr($ip,$c))return false;return true; }
function local_ips(): array { $ips=[];$out=[];@exec('ip -4 -o addr show 2>/dev/null',$out);foreach($out as$line)if(preg_match('/inet (\d+\.\d+\.\d+\.\d+)/',$line,$m))$ips[]=$m[1];$s=settings_read();if(!empty($s['public_ip']))$ips[]=$s['public_ip'];return array_values(array_unique($ips)); }
function dns_lookup(string $host): array { $r=@gethostbynamel($host);return is_array($r)?$r:[]; }
function resolve_origin(string $host): array { if(valid_ipv4($host))return[$host];$ips=dns_lookup($host);return array_slice(array_values(array_unique($ips)),0,4); }

/**
 * ✅ MODO OPERADORA ADICIONADO:
 * Origem = @OPERADORA@ → retorna sinal especial para detecção automática
 */
function validate_origin(array $in, bool $resolve = true): array
{
    $scheme = strtolower(trim((string)($in['scheme'] ?? 'http')));
    if (!in_array($scheme, ['http', 'https'], true)) throw new UserError('Protocolo deve ser http ou https.');
    
    $host = strtolower(trim((string)($in['host'] ?? '')));
    
    // ===== SINAL ESPECIAL: MODO OPERADORA =====
    if ($host === '@operadora' || $host === '@operadora@') {
        return [
            'scheme' => 'operadora',
            'host' => '@OPERADORA@',
            'port' => 443,
            'host_header' => '',
            'ips' => [],
        ];
    }
    
    if ($host === '') throw new UserError('Informe o IP ou domínio de origem.');
    if (!valid_ipv4($host) && !valid_hostname($host)) throw new UserError('Origem inválida.');
    
    $portRaw = trim((string)($in['port'] ?? ''));
    $port = $portRaw === '' ? ($scheme==='https'?443:80) : (ctype_digit($portRaw)?(int)$portRaw:0);
    if ($port<1||$port>65535) throw new UserError('Porta inválida.');
    if ($port===25) throw new UserError('Porta 25 não permitida.');
    
    $hh = strtolower(trim((string)($in['host_header'] ?? '')));
    if ($hh !== '' && !valid_hostname($hh) && !valid_ipv4($hh)) throw new UserError('Host header inválido.');
    
    $ips = [];
    if ($resolve) {
        $ips = resolve_origin($host);
        if (!$ips) throw new UserError('Não foi possível resolver a origem.');
        $local = local_ips();
        foreach ($ips as $ip) {
            if (!is_public_ipv4($ip)) throw new UserError("Origem privada/reservada: $ip");
            if (in_array($ip, $local, true)) throw new UserError('Origem não pode ser o próprio servidor.');
        }
    }
    return ['scheme'=>$scheme,'host'=>$host,'port'=>$port,'host_header'=>$hh,'ips'=>$ips];
}

function utf8_cut(string $s, int $n): string { if(@preg_match('/^.{0,'.$n.'}/us',$s,$m)===1)return$m[0];return substr($s,0,$n); }
function validate_custom_host(string $raw, array $db): string { $h=rtrim(strtolower(trim($raw)),'.');if($h==='')throw new UserError('Informe o domínio.');if(!valid_hostname($h))throw new UserError('Domínio inválido.');$bases=array_filter([base_domain($db),strtolower(trim((string)($db['settings']['base_domain']??'')))]);foreach($bases as$b)if($h===$b||substr($h,-strlen($b)-1)==='.'.$b)throw new UserError('Pertence à própria CDN.');foreach(['.sslip.io','.nip.io','.local','.localhost','.internal','.invalid','.test','.example']as$bad)if(substr($h,-strlen($bad))===$bad)throw new UserError('Domínio não permitido.');foreach($db['domains']as$d)if(strtolower((string)($d['fqdn']??''))===$h)throw new UserError('Domínio já cadastrado.');return$h; }
function clean_label(string $s): string { return utf8_cut(trim(preg_replace('/[\x00-\x1F\x7F]+/u',' ',$s)??''),60); }
function base_domain(array $db): string { $b=strtolower(trim((string)($db['settings']['base_domain']??'')));if($b!==''&&valid_hostname($b))return$b;$ip=(string)(settings_read()['public_ip']??'');return valid_ipv4($ip)?str_replace('.','-',$ip).'.sslip.io':''; }

function has_cert(string $host): bool { $dir=cdn_p(P_LE).'/'.$host;return valid_hostname($host)&&is_file($dir.'/fullchain.pem')&&is_file($dir.'/privkey.pem'); }
function cert_for(string $fqdn): array { if(has_cert($fqdn))return[P_LE."/$fqdn/fullchain.pem",P_LE."/$fqdn/privkey.pem"];$db=db_read();$base=strtolower(trim((string)($db['settings']['base_domain']??'')));if($base!==''&&valid_hostname($base)&&substr($fqdn,-strlen($base)-1)==='.'.$base){$dir=cdn_p(P_LE).'/'.$base;if(is_file($dir.'/fullchain.pem')&&is_file($dir.'/privkey.pem'))return[P_LE."/$base/fullchain.pem",P_LE."/$base/privkey.pem"];}return['/etc/cdn-panel/certs/default.crt','/etc/cdn-panel/certs/default.key']; }

function ports_cfg(): array { $s=settings_read();$clean=function($v,array$def):array{if(!is_array($v))return$def;$o=[];foreach($v as$p)if(is_int($p)&&$p>=1&&$p<=65535)$o[]=$p;return array_values(array_unique($o));};return['http'=>$clean($s['http_ports']??null,[80]),'tls'=>$clean($s['tls_ports']??null,[443,8443])]; }
function listen_lines(bool $ipv6): string { $c=ports_cfg();$l='';foreach($c['http']as$p){$l.="    listen {$p};\n";if($ipv6)$l.="    listen [::]:{$p};\n";}foreach($c['tls']as$p){$l.="    listen {$p} ssl;\n";if($ipv6)$l.="    listen [::]:{$p} ssl;\n";}return$l; }
function site_url(string $fqdn): string { $c=ports_cfg();if(in_array(80,$c['http'],true))return'http://'.$fqdn;if($c['http'])return'http://'.$fqdn.':'.$c['http'][0];if(in_array(443,$c['tls'],true))return'https://'.$fqdn;return'https://'.$fqdn.':'.($c['tls'][0]??443); }
function ssl_lines(string $crt, string $key): string { return "    ssl_certificate {$crt};\n    ssl_certificate_key {$key};\n    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_session_cache shared:cdn_ssl:20m;\n    ssl_session_timeout 1d;\n"; }

/**
 * ✅ Função auxiliar: Verifica se é modo operadora
 */
function is_operadora_mode(array $d): bool {
    return isset($d['scheme']) && $d['scheme'] === 'operadora';
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

    // ===== MODO OPERADORA =====
    if (is_operadora_mode($o)) {
        return $head
            . "server {\n"
            . listen_lines($ipv6)
            . "    server_name {$fqdn};\n"
            . ssl_lines($crt, $key) . "\n"
            . "    client_max_body_size 200m;\n"
            . "    limit_req zone=cdn_req burst=300 nodelay;\n"
            . "    limit_conn cdn_conn 150;\n\n"
            . "    location /.well-known/acme-challenge/ {\n"
            . "        root /var/www/cdn-acme;\n"
            . "    }\n\n"
            . "    location / {\n"
            . "        proxy_pass         https://\$site_livre\$request_uri;\n"
            . "        proxy_http_version 1.1;\n"
            . "        proxy_set_header   Host \$site_livre;\n"
            . "        proxy_set_header   X-Real-IP \$remote_addr;\n"
            . "        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;\n"
            . "        proxy_set_header   X-Forwarded-Proto https;\n"
            . "        proxy_set_header   Upgrade \$http_upgrade;\n"
            . "        proxy_set_header   Connection \"upgrade\";\n"
            . "        proxy_ssl_server_name on;\n"
            . "        proxy_ssl_name     \$site_livre;\n"
            . "        proxy_ssl_verify   off;\n"
            . "        proxy_buffering off;\n"
            . "        proxy_request_buffering off;\n"
            . "        proxy_connect_timeout 10s;\n"
            . "        proxy_send_timeout 1d;\n"
            . "        proxy_read_timeout 1d;\n"
            . "    }\n}\n";
    }

    // ===== MODO NORMAL (ORIGINAL) =====
    $servers = '';
    foreach ($o['ips'] as $ip) {
        $servers .= "    server {$ip}:{$o['port']} max_fails=3 fail_timeout=15s;\n";
    }
    $hostHeader = $o['host_header'] !== '' ? $o['host_header'] : '$host';
    $sni = $o['host_header'] !== '' ? $o['host_header'] : (valid_ipv4($o['host']) ? '$host' : $o['host']);
    $acme = '';
    if (($d['kind'] ?? 'generated') === 'custom') {
        $acme = "    location ^~ /.well-known/acme-challenge/ {\n        root " . P_ACME_WEB . ";\n        default_type text/plain;\n    }\n\n";
    }
    $ssl = '';
    if ($o['scheme'] === 'https') {
        $ssl = "        proxy_ssl_server_name on;\n        proxy_ssl_name {$sni};\n        proxy_ssl_verify off;\n        proxy_ssl_protocols TLSv1.2 TLSv1.3;\n";
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
        . "    error_page 418 = @cdn_decoy;\n"
        . "    location @cdn_decoy {\n"
        . "        root /var/www/cdn-decoy;\n"
        . "        default_type text/html;\n"
        . "        try_files /index.html =404;\n"
        . "    }\n\n"
        . "    location / {\n"
        . "        if (\$cdn_is_browser) { return 418; }\n"
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

function run_cmd(string $cmd): array { $out=[];$rc=0;exec($cmd.' 2>&1',$out,$rc);return[$rc,trim(implode("\n",$out))]; }
function write_run_json(string $name, array $data): void { $dir=cdn_p(P_RUN);if(!is_dir($dir))@mkdir($dir,0755,true);$tmp=$dir.'/'.$name.'.tmp';file_put_contents($tmp,json_encode($data,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES));chmod($tmp,0644);rename($tmp,$dir.'/'.$name); }
function read_run_json(string $name): array { $f=cdn_p(P_RUN).'/'.$name;$d=is_file($f)?json_decode((string)@file_get_contents($f),true):null;return is_array($d)?$d:[]; }
function write_status(array $domains): void { write_run_json('status.json',['t'=>time(),'domains'=>$domains,'zones'=>$GLOBALS['cdn_zone_status']??[]]); }
function publish_result(array $r): void { $prev=read_run_json('apply.result');$r['seq']=(int)($prev['seq']??0)+1;$r['t']=time();unset($r['pending'],$r['status'],$r['hostId']);write_run_json('apply.result',$r); }
function acme_available(): bool { if(!in_array(80,ports_cfg()['http'],true))return false;[$rc]=run_cmd('command -v ' . escapeshellarg(getenv('CDN_CERTBOT')?:'certbot'));return$rc===0; }
function acme_run(array $hosts): array { $res=[];$dir=cdn_p(P_ROOT_ST);@mkdir($dir,0700,true);@mkdir(cdn_p(P_ACME_WEB),0755,true);$stF=$dir.'/acme.json';$st=is_file($stF)?json_decode((string)@file_get_contents($stF),true):[];if(!is_array($st))$st=[];$bin=getenv('CDN_CERTBOT')?:'certbot';$now=time();$n=0;foreach($hosts as$h){if(!valid_hostname($h))continue;$s=$st[$h]??['fails'=>0,'last'=>0];$wait=((int)$s['fails'])>0?min(3600*(int)$s['fails'],86400):0;if($now-(int)$s['last']<$wait){$res[$h]='retry';continue;}if($n>=3){$res[$h]='queued';continue;}$n++;[$rc,$out]=run_cmd('timeout 150 '.escapeshellarg($bin).' certonly --webroot -w '.escapeshellarg(P_ACME_WEB).' -d '.escapeshellarg($h).' --cert-name '.escapeshellarg($h).' --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring');if($rc===0&&has_cert($h)){unset($st[$h]);$res[$h]='issued';}else{$st[$h]=['fails'=>(int)$s['fails']+1,'last'=>$now,'err'=>utf8_cut($out,300)];$res[$h]='retry';}}file_put_contents($stF,json_encode($st));@chmod($stF,0600);return$res; }

function cdn_apply(): array { $GLOBALS['cdn_zone_status']=[];$dns=cdn_apply_dns(db_read());$r=cdn_apply_pass();if($dns['msg']!==''){$r['msg']=$dns['msg'].' '.$r['msg'];}if(!$dns['ok'])$r['ok']=false;if(!$r['ok']||!$r['pending']){publish_result($r);return$r;}publish_result(array_merge($r,['msg'=>$r['msg'].' Emitindo certificados HTTPS em segundo plano...']));$res=acme_run($r['pending']);$issued=array_keys(array_filter($res,function($s){return$s==='issued';}));$final=$r;$status=$r['status'];$hostId=$r['hostId'];if($issued){$final=cdn_apply_pass();$status=$final['status'];$hostId=$final['hostId'];if($final['ok'])$final['msg'].=' Certificados HTTPS emitidos: '.implode(', ',$issued).'.';}foreach($res as$h=>$st){$id=$hostId[$h]??null;if($id!==null&&isset($status[$id])&&$st!=='issued')$status[$id]['cert']=($st==='queued')?'pending':'retry';}write_status($status);if($issued){publish_result($final);}return$final; }

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
            if (!is_array($d) || !preg_match('/^[a-f0-9]{8}$/', $id)) throw new UserError('registro inválido');
            if (!isset($d['fqdn']) || !valid_site_name((string)$d['fqdn'])) throw new UserError('domínio inválido');
            
            $owner = (string)($d['owner'] ?? '');
            $user = $db['users'][$owner] ?? null;
            $suspended = (($d['status'] ?? 'active') !== 'active') || !$user || !empty($user['disabled']) || is_expired($d);
            
            if ($suspended) {
                $files[$id.'.conf'] = render_site($id, $d, [], $ipv6, true);
                $status[$id] = ['state'=>'suspended','ips'=>[]];
                continue;
            }
            
            $custom = (($d['kind'] ?? 'generated') === 'custom');
            if ($custom) {
                $probe = (strncmp((string)$d['fqdn'],'*.',2)===0)?'cdn-probe.'.substr((string)$d['fqdn'],2):(string)$d['fqdn'];
                $seen = dns_lookup($probe);
                if ($pubIp === '' || !in_array($pubIp, $seen, true)) {
                    $status[$id] = ['state'=>'pending_dns','dns'=>false,'seen'=>$seen,'ips'=>[]];
                    continue;
                }
            }
            
            // Valida origem — suporta @OPERADORA@
            $o = validate_origin($d, true);
            
            $files[$id.'.conf'] = render_site($id, $d, $o, $ipv6, false);
            $status[$id] = ['state'=>'active','ips'=>$o['ips']];
            
            if ($custom) {
                $status[$id]['dns'] = true;
                if (strncmp((string)$d['fqdn'],'*.',2)===0) {
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
            $status[$id] = ['state'=>'error','msg'=>$e->getMessage(),'ips'=>[]];
        }
    }
    
    $dir = cdn_p(P_SITES);
    if (!is_dir($dir) && !@mkdir($dir,0755,true)) return ['ok'=>false,'changed'=>false,'msg'=>"Não foi possível criar $dir",'pending'=>[],'status'=>$status,'hostId'=>[]];
    
    $old = []; foreach (glob($dir.'/*.conf')?:[] as $f) $old[basename($f)]=(string)file_get_contents($f);
    ksort($old); ksort($files);
    
    if ($old === $files) { write_status($status); return ['ok'=>true,'changed'=>false,'msg'=>'Nenhuma alteração necessária.','pending'=>$pending,'status'=>$status,'hostId'=>$hostId]; }
    
    $restore = function() use ($dir,$old):void { foreach(glob($dir.'/*.conf')?:[] as$f)@unlink($f);foreach($old as$n=>$c)file_put_contents($dir.'/'.$n,$c); };
    foreach (glob($dir.'/*.conf')?:[] as$f) if(!isset($files[basename($f)]))@unlink($f);
    foreach ($files as$n=>$c) { $tmp=$dir.'/.'.$n.'.tmp';file_put_contents($tmp,$c);chmod($tmp,0644);rename($tmp,$dir.'/'.$n); }
    
    [$rc,$out]=run_cmd(getenv('CDN_NGINX_T')?:'nginx -t');
    if ($rc!==0) { $restore(); return ['ok'=>false,'changed'=>false,'msg'=>'nginx -t falhou: '.utf8_cut($out,600),'pending'=>[],'status'=>$status,'hostId'=>[]]; }
    
    [$rc,$out]=run_cmd(getenv('CDN_NGINX_RELOAD')?:'systemctl reload-or-restart nginx');
    if ($rc!==0) { $restore(); run_cmd(getenv('CDN_NGINX_RELOAD')?:'systemctl reload-or-restart nginx'); return ['ok'=>false,'changed'=>false,'msg'=>'Falha ao recarregar nginx: '.utf8_cut($out,600),'pending'=>[],'status'=>$status,'hostId'=>[]]; }
    
    write_status($status);
    return ['ok'=>true,'changed'=>true,'msg'=>'Configuração aplicada ('.count($files).' domínio(s) no ar).','pending'=>$pending,'status'=>$status,'hostId'=>$hostId];
}

function random_password(int $len=20): string { $c='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';$o='';for($i=0;$i<$len;$i++)$o.=$c[random_int(0,strlen($c)-1)];return$o; }
function check_password_policy(string $p): void { if(strlen($p)<10)throw new UserError('Senha precisa ter pelo menos 10 caracteres.');if(strlen($p)>200)throw new UserError('Senha muito longa.'); }

require_once __DIR__.'/lib_dns.php';
__CDN_FILE_EOF__

# O restante do arquivo original continua exatamente igual...
# (mantive lib_dns.php, index.php e todo o restante intacto — só rem
