#!/bin/bash
# nginx reverse-proxy container entrypoint for MikroTik RouterOS containers.
#
# Terminates TLS for a single FQDN and reverse-proxies to Home Assistant.
# Certificates are issued and renewed with certbot using the DNS-01 challenge
# via Route53 (certbot-dns-route53), so NO inbound HTTP-01 reachability is
# required to issue a cert. The RouterOS-side plumbing (veth, container,
# port-forwards) lives in the rsc/ scripts beside this file.
#
# Mirrors the structure of the tor-mikrotik container: an SSH server for
# management, host keys generated at first boot, and env-driven config.

set -m

# ---------------------------------------------------------------------------
# Env contract. Defaults suit the HA reverse-proxy use case.
# ---------------------------------------------------------------------------
#   PASSWORD                root password for the management SSH server [optional]
#   DOMAIN                  FQDN to serve, e.g. ha.dids.atasha.net      [REQUIRED]
#   UPSTREAM                proxied backend, e.g. http://192.168.20.52:8123 [REQUIRED]
#   LE_EMAIL                Let's Encrypt registration/expiry email     [REQUIRED]
#   AWS_ACCESS_KEY_ID       IAM key for certbot-dns-route53             [REQUIRED]
#   AWS_SECRET_ACCESS_KEY   IAM secret for certbot-dns-route53          [REQUIRED]
#   AWS_DEFAULT_REGION      AWS region, e.g. us-east-1                  [REQUIRED]
#   STAGING                 "Y" -> use the LE staging CA (--staging)    [optional]
#   RENEW_INTERVAL_SECONDS  renewal-loop period (default 43200 = 12h)   [optional]
#
# NOTE on Route53: the hosted zone is atasha.net (id Z013437429SD2LRMIJ38E);
# ha.dids.atasha.net is a record within it. certbot-dns-route53 auto-discovers
# the zone by walking the name, so no zone id is passed here.
# ---------------------------------------------------------------------------

RENEW_INTERVAL_SECONDS="${RENEW_INTERVAL_SECONDS:-43200}"

# ---------------------------------------------------------------------------
# Validate required env. A missing REQUIRED var is fatal — log clearly and exit
# non-zero so the container's failure is obvious in the RouterOS container log.
# ---------------------------------------------------------------------------
fatal() { echo "nginx.sh FATAL: $1" >&2; exit 1; }

[ -n "${DOMAIN:-}" ]                || fatal "DOMAIN is required (FQDN to serve)."
[ -n "${UPSTREAM:-}" ]              || fatal "UPSTREAM is required (e.g. http://192.168.20.52:8123)."
[ -n "${LE_EMAIL:-}" ]              || fatal "LE_EMAIL is required (Let's Encrypt contact email)."
[ -n "${AWS_ACCESS_KEY_ID:-}" ]     || fatal "AWS_ACCESS_KEY_ID is required for certbot-dns-route53."
[ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || fatal "AWS_SECRET_ACCESS_KEY is required for certbot-dns-route53."
[ -n "${AWS_DEFAULT_REGION:-}" ]    || fatal "AWS_DEFAULT_REGION is required for certbot-dns-route53."

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

# ---------------------------------------------------------------------------
# (1) SSH management server prep.
# ---------------------------------------------------------------------------
if [ ! -d "/var/run/sshd" ]; then
  mkdir -p /var/run/sshd
fi

# Generate SSH host keys on first start if missing (runtime, not build time —
# per-container keys are better practice; same rationale as the tor container).
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -A
fi

# Set root password if provided.
if [ -n "${PASSWORD:-}" ]; then
  echo "root:${PASSWORD}" | chpasswd
fi

# ---------------------------------------------------------------------------
# (2) Render the nginx config from the baked-in templates.
#   - Remove Debian's default site so it cannot shadow our vhost.
#   - 00-upgrade-map.conf carries the WebSocket $connection_upgrade map (http
#     context) and MUST load before the vhost — copied verbatim.
#   - default.conf is rendered from the template, substituting ONLY ${DOMAIN}
#     and ${UPSTREAM} so nginx's own $-variables survive.
# ---------------------------------------------------------------------------
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default 2>/dev/null || true
mkdir -p /etc/nginx/conf.d

cp /etc/nginx/templates/nginx.conf.template /etc/nginx/conf.d/00-upgrade-map.conf

export DOMAIN UPSTREAM
envsubst '${DOMAIN} ${UPSTREAM}' \
  < /etc/nginx/templates/default.conf.template \
  > /etc/nginx/conf.d/default.conf

echo "Rendered /etc/nginx/conf.d/default.conf for DOMAIN=${DOMAIN} UPSTREAM=${UPSTREAM}"

# A :80-only fallback vhost used if NO cert can be obtained (see below). It
# serves a plain redirect so the container stays up and diagnosable instead of
# crash-looping on a missing certificate.
write_http_only_vhost() {
  cat > /etc/nginx/conf.d/default.conf <<EOF
# FALLBACK: no certificate available — serving :80 only so the container stays
# up. Fix certbot/Route53 and reload (or restart) to get the full :443 vhost.
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 302 https://\$host\$request_uri;
}
EOF
  echo "nginx.sh: wrote :80-only fallback vhost (no certificate present)."
}

# ---------------------------------------------------------------------------
# (3) Obtain the certificate if absent (DNS-01 via Route53).
#   --keep-until-expiring makes a repeat run a no-op if a valid cert exists.
#   STAGING=Y uses the LE staging CA to avoid burning rate limits while testing.
# Behaviour on failure:
#   - a cert already exists  -> log and continue (a transient issuance/DNS error
#     must never take the proxy down).
#   - no cert exists         -> log FATAL-level warning and fall back to a
#     :80-only vhost so the container stays up (chosen over exit 1).
# ---------------------------------------------------------------------------
CERT_LIVE="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"

certbot_args=(certonly --dns-route53 -d "${DOMAIN}"
              --non-interactive --agree-tos -m "${LE_EMAIL}"
              --keep-until-expiring)
if [ "${STAGING:-N}" = "Y" ]; then
  certbot_args+=(--staging)
  echo "nginx.sh: STAGING=Y -> using Let's Encrypt STAGING CA."
fi

if [ ! -f "${CERT_LIVE}" ]; then
  echo "nginx.sh: no certificate for ${DOMAIN} yet — requesting one via DNS-01/Route53..."
  if certbot "${certbot_args[@]}"; then
    echo "nginx.sh: certificate obtained for ${DOMAIN}."
  else
    echo "nginx.sh FATAL: certbot failed and no existing certificate — falling back to :80-only." >&2
    write_http_only_vhost
  fi
else
  echo "nginx.sh: existing certificate found for ${DOMAIN}; (re)validating with certbot (non-fatal)..."
  certbot "${certbot_args[@]}" || \
    echo "nginx.sh: certbot run failed but an existing certificate is present — continuing." >&2
fi

# ---------------------------------------------------------------------------
# (4) Start the management SSH server in the background.
# ---------------------------------------------------------------------------
/usr/sbin/sshd

# ---------------------------------------------------------------------------
# (5) Background renewal loop. Every RENEW_INTERVAL_SECONDS run certbot renew;
# on a successful renewal the --deploy-hook reloads nginx so it picks up the new
# certificate with no downtime. This loop (not system cron) is the active
# renewal mechanism for this container — self-contained and env-driven, matching
# the tor container's style.
# ---------------------------------------------------------------------------
(
  while sleep "${RENEW_INTERVAL_SECONDS}"; do
    certbot renew --dns-route53 --quiet --deploy-hook "nginx -s reload"
  done
) &

# ---------------------------------------------------------------------------
# (6) Start nginx in the foreground as PID 1's child (daemon off).
# ---------------------------------------------------------------------------
exec nginx -g 'daemon off;'
