# Build & verification evidence

Captured on the arm64 Mac build host (native arm64, no QEMU/binfmt needed).

## Lint
- `bash -n nginx.sh` → exit 0 (no syntax errors)
- `sh -n build.sh` → exit 0 (no syntax errors)

## Image build
- `./build.sh` → **success**, produced `nginx-arm64.tar` (**261 MB**).
- Image tag: `nginx-mikrotik:0.1.0-arm64`, platform `linux/arm64`,
  base `arm64v8/debian:bookworm-slim`.

## Image tooling check
`docker run --rm nginx-mikrotik:0.1.0-arm64 sh -c "nginx -v; certbot --version; python3 -c 'import certbot_dns_route53'"`:
- `nginx version: nginx/1.22.1`
- `certbot 2.1.0`
- `certbot_dns_route53 import OK`
- `envsubst present` (gettext-base)

## nginx config validation
Rendered `default.conf.template` with `envsubst` (DOMAIN=ha.dids.atasha.net,
UPSTREAM=http://192.168.20.52:8123), copied the upgrade map, generated a dummy
self-signed cert so the `ssl_certificate` directives resolve, then ran
`nginx -t` inside the image → **syntax ok, test successful**.

Note: the first `nginx -t` failed on `http2 on;` (that standalone directive is
nginx 1.25+). Fixed to the 1.22-compatible `listen 443 ssl http2;` form,
rebuilt, and re-verified green.

## Secret handling
- The real `AWS_SECRET_ACCESS_KEY` and `LE_EMAIL` (`n@atasha.net`) values live
  ONLY in `rsc/secrets.local.rsc`, which is git-ignored and untracked. The SSH
  `PASSWORD` env is still a placeholder for the operator to fill before deploy.
- `rsc/secrets.local.rsc` and `*.tar` are git-ignored (confirmed via
  `git check-ignore`); the secret appears in no tracked file and in no git
  history (confirmed via `git log --all -p`).
- Access key id `AKIAQZFG5CUIMEFHGLDW` appears only in `rsc/secrets.local.rsc`
  and as a comment in `rsc/01-router-nginx.rsc` (per spec — the id is not secret).

## Not done (per instructions)
- Did NOT deploy to the router or run any `.rsc` script.
