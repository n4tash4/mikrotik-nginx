# =============================================================================
# nginx reverse-proxy + certbot container — Main Router / hub (192.168.20.1)
# Device: MikroTik RB5009UG+S+ (arm64), RouterOS 7.24.4
# Bridge: existing "bridge-containers", subnet 192.168.102.0/24, gateway
#         192.168.102.1, DHCP pool "continers" 192.168.102.10-200. The nginx
#         container joins it on a NEW veth with a STATIC address OUTSIDE the pool.
# Storage: usb2-part1 (ext4) — image tar, root-dir and the cert mount live here.
#
# ROLE — terminate TLS for ha.dids.atasha.net on the router's PUBLIC IP and
#        reverse-proxy to Home Assistant at http://192.168.20.52:8123. The
#        certificate is issued/renewed by certbot inside the container using the
#        DNS-01 challenge via Route53, so NO inbound HTTP reachability is needed
#        to ISSUE a cert (external :80/:443 reachability is still needed to SERVE
#        the site — see the A-record note in VERIFY).
#
# Image: upload the arm64 tar built by ../build.sh -> nginx-arm64.tar.
# =============================================================================
# ADDRESSING:
#   bridge-containers gateway ....... 192.168.102.1  (router, already assigned)
#   DHCP pool "continers" ........... 192.168.102.10-200  (avoid — use static)
#   nginx container veth (veth-nginx) 192.168.102.2/24  (NEW — this script)
#
# Container ports (image, nginx.sh / Dockerfile):  22 SSH   80 HTTP   443 HTTPS
#
# WAN is ether1, public IP 87.192.98.212/21 but DYNAMIC (DHCP). All WAN-facing
# firewall/NAT below matches in-interface=ether1 — NEVER a hardcoded public IP.
#
# *** RUN rsc/secrets.local.rsc FIRST *** — it adds the real AWS access key +
# secret + LE_EMAIL to list=nginx. This script adds every OTHER env with
# placeholders and must not contain the secret.
# =============================================================================

# -----------------------------------------------------------------------------
# STEP 0: Prerequisites (verify — do NOT blindly re-run base router setup)
# -----------------------------------------------------------------------------
#   /system/resource/print          ; architecture-name: arm64 -> nginx-arm64.tar
#   /system/device-mode/print       ; container: yes (required to add containers)
#   /interface/bridge/print where name=bridge-containers   ; must exist
#   /disk/print                     ; confirm usb2-part1 is mounted (ext4)

# -----------------------------------------------------------------------------
# STEP 1: New veth for the nginx container on the EXISTING container bridge
# -----------------------------------------------------------------------------
# Static 192.168.102.2 (outside the DHCP pool .10-200). Gateway is the bridge
# address 192.168.102.1 (the router), which also gives the container its route
# to the LAN (so it can reach HA at 192.168.20.52 — see STEP 7).
/interface/veth/add \
    name=veth-nginx \
    address=192.168.102.2/24 \
    gateway=192.168.102.1 \
    comment="nginx container veth (reverse proxy for Home Assistant)"

/interface/bridge/port/add \
    bridge=bridge-containers \
    interface=veth-nginx

# -----------------------------------------------------------------------------
# STEP 2: nginx container environment (NON-secret envs only)
# -----------------------------------------------------------------------------
# The sensitive envs (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, LE_EMAIL) are
# added by rsc/secrets.local.rsc — RUN THAT FIRST. Do NOT put the secret here.
#
# PASSWORD is the management-SSH root password; set a real value or omit the
# line to disable password login (host keys are still generated at startup).
/container/envs/add list=nginx key="PASSWORD"           value="<ssh-password>"
/container/envs/add list=nginx key="DOMAIN"             value="ha.dids.atasha.net"
/container/envs/add list=nginx key="UPSTREAM"           value="http://192.168.20.52:8123"
/container/envs/add list=nginx key="AWS_DEFAULT_REGION" value="us-east-1"

# --- the following three are added by rsc/secrets.local.rsc (run it first) ---
#   AWS_ACCESS_KEY_ID       = AKIAQZFG5CUIMEFHGLDW   (ok to see; the SECRET is not)
#   AWS_SECRET_ACCESS_KEY   = <only in secrets.local.rsc>
#   LE_EMAIL                = <only in secrets.local.rsc>
#
# Optional envs (uncomment to use):
#   /container/envs/add list=nginx key="STAGING"                value="Y"       ; use LE staging CA while testing
#   /container/envs/add list=nginx key="RENEW_INTERVAL_SECONDS" value="43200"   ; renewal-loop period (default 12h)

# -----------------------------------------------------------------------------
# STEP 3: Mounts — PERSIST the certificates across container restarts
# -----------------------------------------------------------------------------
# /etc/letsencrypt MUST persist. Without this mount every restart re-issues a
# certificate and will quickly hit Let's Encrypt rate limits. Backed by
# usb2-part1 so it survives reboots and container re-adds (upgrade.rsc).
/container/mounts/add \
    list=nginx \
    src=/usb2-part1/nginx/letsencrypt \
    dst=/etc/letsencrypt \
    mode=rw

# Optional: persist nginx logs off the container's writable layer.
/container/mounts/add \
    list=nginx \
    src=/usb2-part1/nginx/log \
    dst=/var/log/nginx \
    mode=rw

# -----------------------------------------------------------------------------
# STEP 4: Add the container
# -----------------------------------------------------------------------------
# Use the arm64 tar from STEP 0. cmd is required on RouterOS 7.22+.
# NOT privileged: nginx is a userspace proxy and needs no NET_ADMIN/netfilter
# (unlike the Tor container, which needs privileged=yes for its in-container
# iptables REDIRECT). dns points at the bridge gateway first, then a public
# resolver as a backstop.
/container/add \
    file=usb2-part1/nginx-arm64.tar \
    interface=veth-nginx \
    envlists=nginx \
    mountlists=nginx \
    hostname=nginx-router \
    dns=192.168.102.1,8.8.8.8 \
    root-dir=usb2-part1/containers/nginx \
    cmd=/usr/local/bin/nginx.sh \
    start-on-boot=yes \
    logging=yes \
    comment="nginx reverse proxy for Home Assistant (ha.dids.atasha.net)"

# -----------------------------------------------------------------------------
# STEP 5: Firewall — allow forwarded WAN->container 80/443 flows to the veth
# -----------------------------------------------------------------------------
# dstnat (STEP 6) rewrites the destination to 192.168.102.2 BEFORE the forward
# chain, so this accept matches the translated dst-address. place-before=0 puts
# it ahead of any blanket forward drop.
/ip/firewall/filter/add \
    chain=forward \
    dst-address=192.168.102.2 \
    protocol=tcp \
    dst-port=80,443 \
    action=accept \
    comment="nginx: allow WAN->container 80/443" \
    place-before=0

# -----------------------------------------------------------------------------
# STEP 6: Port-forward — WAN :80 and :443 into the container (dstnat)
# -----------------------------------------------------------------------------
# Match the DYNAMIC WAN by interface (in-interface=ether1), NEVER by the public
# IP (it is DHCP-assigned and can change). Two rules: :80 and :443 straight to
# the container's veth, same ports.
#
# ORDERING: the only pre-existing dstnat rules on this router are the DYNAMIC
# natpmp/upnp rules. RouterOS evaluates/places dynamic rules separately from
# static ones, so a plain `add` (appended) is sufficient here and will not be
# shadowed by them. If a future conflict is ever observed, re-add with
# place-before=[find dynamic] to force these ahead of the dynamic rules.
/ip/firewall/nat/add \
    chain=dstnat \
    in-interface=ether1 \
    protocol=tcp \
    dst-port=80 \
    action=dst-nat \
    to-addresses=192.168.102.2 \
    to-ports=80 \
    comment="nginx: WAN :80 -> container :80 (302 to https)"
/ip/firewall/nat/add \
    chain=dstnat \
    in-interface=ether1 \
    protocol=tcp \
    dst-port=443 \
    action=dst-nat \
    to-addresses=192.168.102.2 \
    to-ports=443 \
    comment="nginx: WAN :443 -> container :443 (TLS + proxy to HA)"

# -----------------------------------------------------------------------------
# STEP 7: SNAT consideration (comment-only — NO rule added)
# -----------------------------------------------------------------------------
# No extra SNAT/hairpin rule is needed:
#   * WAN -> container: the inbound flow is dst-nat'd (STEP 6); its replies are
#     matched by conntrack and un-NAT'd automatically on the way back out, so
#     the external client gets a correct return path with no SNAT.
#   * container -> HA: the container's default route is the bridge gateway
#     192.168.102.1 (the router), which routes to the LAN (192.168.20.0/24)
#     normally. HA at 192.168.20.52 sees a source of 192.168.102.2 and replies
#     to it via the router — a normal routed path, no masquerade required.
# (Contrast the Tor distsw script, which DID need an SNAT because LAN transit
# traffic kept a LAN source with no return path into the container.)
# Add nothing here unless a captured flow proves otherwise.

# -----------------------------------------------------------------------------
# STEP 8: Start the container
# -----------------------------------------------------------------------------
/container/start [find where hostname="nginx-router"]

# =============================================================================
# VERIFY
# =============================================================================
#   /container/print                                   ; status running
#   /ip/firewall/nat/print where comment~"nginx:"      ; the two dstnat rules
#   /ip/firewall/filter/print where comment~"nginx:"   ; the forward accept
#
#   # inside the container:
#   /container/shell [find where hostname="nginx-router"]
#     nginx -t ; cat /etc/nginx/conf.d/default.conf
#     ls /etc/letsencrypt/live/ha.dids.atasha.net/      ; fullchain.pem + privkey.pem
#     certbot certificates
#
# *** MANUAL PREREQUISITE — Route53 A record (external access) ***
#   Create ha.dids.atasha.net -> the router's current PUBLIC IP (A record) in
#   the atasha.net zone. DNS-01 does NOT need this A record to ISSUE the cert
#   (certbot writes a TXT record), but external clients DO need it to reach the
#   site. The WAN IP is DYNAMIC (DHCP) — if it changes, update the A record.
#
#   From an external host (resolving ha.dids.atasha.net to the public IP):
#     curl -I  http://ha.dids.atasha.net     ; -> 302 to https://ha.dids.atasha.net
#     curl -I  https://ha.dids.atasha.net    ; -> 200/30x from Home Assistant
#     openssl s_client -connect ha.dids.atasha.net:443 -servername ha.dids.atasha.net
#
# TO REMOVE:
#   /container/stop   [find where hostname="nginx-router"]
#   /container/remove [find where hostname="nginx-router"]
#   /ip/firewall/nat/remove    [find comment~"nginx:"]
#   /ip/firewall/filter/remove [find comment~"nginx:"]
#   /interface/bridge/port/remove [find interface=veth-nginx]
#   /interface/veth/remove [find name=veth-nginx]
#   /container/envs/remove   [find where list=nginx]
#   /container/mounts/remove [find where list=nginx]
# =============================================================================
