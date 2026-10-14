# nginx reverse-proxy + certbot container for MikroTik RouterOS containers.
#
# SINGLE-ARCH BUILD (arm64 ONLY):
#   arm64 (ARMv8) — RB5009UG+S+ (Cortex-A72). This project targets only that
#   router, so unlike the tor/tailscale images there is no arm32 variant.
#
# Single-stage: nginx and certbot come from the Debian archive, so there is no
# Go cross-compile stage like the tailscale image. The Mac build host is native
# arm64, so no QEMU is needed here (see build.sh for the binfmt note).
#
# Build arg (default is arm64 so a bare `docker build` works):
#   RUNTIME_BASE   arm64v8/debian:bookworm-slim

ARG RUNTIME_BASE=arm64v8/debian:bookworm-slim
FROM ${RUNTIME_BASE}

# nginx                        — the reverse proxy / TLS terminator.
# certbot                      — ACME client (Let's Encrypt).
# python3-certbot-dns-route53  — the DNS-01 plugin that writes TXT records in
#                                Route53 (no inbound reachability needed to issue).
# openssh-server               — management access, same pattern as the tor image.
# ca-certificates/curl/bash    — TLS trust store + debugging utilities.
# cron                         — installed per spec; the ACTIVE renewal mechanism
#                                is the shell loop in nginx.sh (documented there),
#                                not cron, so no cron job is enabled.
# openssl                      — cert inspection / debugging.
# gettext-base                 — provides `envsubst` used to render the vhost.
#
# NOTE: unlike the tor Dockerfile we deliberately DO NOT install iptables /
# iproute2 and do NOT run `update-alternatives --set iptables ...`. nginx is a
# userspace proxy and needs no netfilter — the one deliberate divergence from
# the tor image.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      nginx certbot python3-certbot-dns-route53 openssh-server \
      ca-certificates curl bash cron openssl gettext-base && \
    rm -rf /var/lib/apt/lists/*

# SSH host keys are generated at container startup (see nginx.sh), not build
# time — per-container keys are better practice.
RUN mkdir -p /var/run/sshd

COPY sshd_config /etc/ssh/
COPY nginx.conf.template default.conf.template /etc/nginx/templates/
COPY nginx.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/nginx.sh

# 22  management SSH    80  HTTP (302 -> HTTPS)    443  HTTPS (TLS + proxy)
EXPOSE 22 80 443
CMD ["/usr/local/bin/nginx.sh"]
