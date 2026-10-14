# nginx reverse proxy + certbot for MikroTik Container (Home Assistant)

Build and configuration to run [nginx](https://nginx.org/) with
[certbot](https://certbot.eff.org/) inside a
[MikroTik Container](https://help.mikrotik.com/docs/display/ROS/Container) as a
TLS-terminating **reverse proxy** for [Home Assistant](https://www.home-assistant.io/).
It serves `ha.dids.atasha.net` on the router's public IP and proxies to HA at
`http://192.168.20.52:8123`.

Certificates come from Let's Encrypt via the **DNS-01** challenge
(`certbot-dns-route53`), so no inbound HTTP reachability is required to *issue*
a certificate. Renewal is automatic (see below).

Structured to match the sibling [`tor-mikrotik`](../tor-mikrotik) and
[`tailscale-mikrotik`](../tailscale-mikrotik) projects: same management-SSH
pattern, same env-driven container, same build model (buildx + skopeo). The
RouterOS-side plumbing (veth, container, port-forwards) lives in [`rsc/`](rsc).

## Requirements

RouterOS v7.6+ with the Container package, container `device-mode` enabled
(needs physical confirmation + reboot), and external storage (`usb2-part1`
here) for the image, root-dir and the persisted certificate mount.

## Build

`build.sh` builds for **arm64 only** and emits a single container-archive tar:

| Output tar | buildx platform | Runtime base | Devices |
| ---------- | --------------- | ------------ | ------- |
| `nginx-arm64.tar` | `linux/arm64` | `arm64v8/debian:bookworm-slim` | **RB5009** (Cortex-A72) and aarch64 |

arm32 is intentionally dropped — this project targets only the RB5009 router,
which is arm64. nginx and certbot are installed from the Debian archive, so
there is **no cross-compile step**; the build runs entirely in the arm64 base
image. The Mac build host is native arm64, so no QEMU is needed.

1. (Cross-arch host only) register QEMU once:

   ```
   docker run --privileged --rm tonistiigi/binfmt --install all
   ```

2. Build:

   ```
   ./build.sh          # -> nginx-arm64.tar
   ```

Upload `nginx-arm64.tar` to `usb2-part1` on the router (the `.rsc` scripts
reference `usb2-part1/nginx-arm64.tar`).

## Container environment variables

Set via `/container/envs` (see [`rsc/01-router-nginx.rsc`](rsc/01-router-nginx.rsc)
and [`rsc/secrets.local.rsc`](rsc/secrets.local.rsc)).

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `PASSWORD` | (unset) | root password for the management SSH server |
| `DOMAIN` | **required** | FQDN to serve, e.g. `ha.dids.atasha.net` |
| `UPSTREAM` | **required** | proxied backend, e.g. `http://192.168.20.52:8123` |
| `LE_EMAIL` | **required** | Let's Encrypt registration / expiry-notice email |
| `AWS_ACCESS_KEY_ID` | **required** | IAM key for `certbot-dns-route53` |
| `AWS_SECRET_ACCESS_KEY` | **required** | IAM secret (lives ONLY in `rsc/secrets.local.rsc`) |
| `AWS_DEFAULT_REGION` | **required** | AWS region, e.g. `us-east-1` |
| `STAGING` | `N` | `Y` uses the Let's Encrypt staging CA (avoids rate limits while testing) |
| `RENEW_INTERVAL_SECONDS` | `43200` | renewal-loop period (12h) |

A missing *required* variable is fatal — `nginx.sh` logs the reason and exits
non-zero so the failure is visible in the RouterOS container log.

## DNS-01 / Route53 certificate flow

certbot authenticates to Route53 with the `AWS_*` credentials and proves domain
control by writing a `_acme-challenge` TXT record — no inbound reachability is
needed to issue. The IAM user `certbot-ha-dids` is scoped to the `atasha.net`
hosted zone (id `Z013437429SD2LRMIJ38E`). `certbot-dns-route53`
**auto-discovers** the zone by walking the name, so **no zone id is passed** to
certbot — the id is recorded only for reference.

Reference IAM policy (zone id filled in; the secret key is NOT stored here):

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "VisualEditor0",
            "Effect": "Allow",
            "Action": [
                "route53:GetHostedZone",
                "route53:ChangeResourceRecordSets",
                "route53:ListResourceRecordSets"
            ],
            "Resource": "arn:aws:route53:::hostedzone/Z013437429SD2LRMIJ38E"
        },
        {
            "Sid": "VisualEditor1",
            "Effect": "Allow",
            "Action": [
                "route53:TestDNSAnswer",
                "route53:ListHostedZones",
                "route53:GetChange"
            ],
            "Resource": "*"
        }
    ]
}
```

> **Why `ListHostedZones` and `GetChange` are required (and on `*`).**
> `certbot-dns-route53` does not take a zone id — it **discovers** the zone by
> calling `route53:ListHostedZones` and matching the longest zone name against
> the domain, then **polls** `route53:GetChange` until the challenge TXT record
> reaches `INSYNC`. Both are account-level operations that AWS only accepts with
> `Resource: "*"` (they are not addressable per-hostedzone). Omitting either
> makes issuance fail with an `AccessDenied` on exactly that call — a policy
> that only grants the three zone-scoped actions above is **not sufficient** on
> its own. This was verified live during deployment: certbot failed first on
> `ListHostedZones`, then on `GetChange`, before succeeding once both were
> added.

## Renewal automation

`nginx.sh` runs a background loop that executes `certbot renew` every
`RENEW_INTERVAL_SECONDS` (12h by default). On a successful renewal the
`--deploy-hook "nginx -s reload"` reloads nginx so it picks up the new
certificate with **no downtime**. This loop — not system cron — is the active
renewal mechanism (`cron` is installed but unused). `/etc/letsencrypt` is
bind-mounted to `usb2-part1/nginx/letsencrypt`, so certificates persist across
restarts and re-deploys and are never needlessly re-issued.

## Manual prerequisite — Route53 A record

DNS-01 does **not** need an A record to *issue* the certificate, but external
clients need one to *reach* the proxy. Create an A record
`ha.dids.atasha.net -> <router public IP>` in the `atasha.net` zone. The WAN IP
is **dynamic** (DHCP on `ether1`); if it changes, update the A record.

## LAN access — split DNS

LAN clients cannot reach `ha.dids.atasha.net` via the public A record: a request
from inside the LAN to the public IP would need NAT loopback (hairpin), and the
`dstnat` forwards only match `in-interface=ether1`, so LAN-origin traffic hits
the router's own services instead. Fix it with **split DNS** — point the name at
the container directly for internal clients only:

```
/ip/dns/static/add name="ha.dids.atasha.net" type=A address=192.168.102.2 ttl=5m \
    comment="split-DNS: LAN clients reach the nginx HA proxy container directly"
/ip/dns/cache/flush
```

The router (`192.168.20.1`) is the LAN resolver with `allow-remote-requests=yes`,
so every LAN client now resolves the name to `192.168.102.2` and connects to the
container directly. The TLS cert still validates (SNI is `ha.dids.atasha.net`
regardless of the IP reached), so LAN access is trusted HTTPS with no hairpin
rule. External clients are unaffected — they resolve the public IP via Route53.
Verified live: a LAN `GET https://ha.dids.atasha.net/` returns `200` with
`ssl_verify_result=0` (trusted) and the Home Assistant frontend.

## RouterOS setup (`rsc/`)

Run on the router (`ssh admin@192.168.20.1`), in this order:

1. **[`rsc/secrets.local.rsc`](rsc/secrets.local.rsc)** — adds the real
   `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `LE_EMAIL` envs. This file
   is **git-ignored** and holds the secret; run it first.
2. **[`rsc/01-router-nginx.rsc`](rsc/01-router-nginx.rsc)** — the rest of the
   setup, in `STEP`/`VERIFY`/`TO REMOVE` form:
   - a static veth `192.168.102.2/24` (gateway `192.168.102.1`) added as a port
     on `bridge-containers`;
   - the non-secret container envs, the persisted `/etc/letsencrypt` mount, and
     the container itself (`hostname=nginx-router`, `start-on-boot`, **not**
     privileged — nginx needs no netfilter);
   - a forward-chain accept plus two `dstnat` port-forwards matching
     `in-interface=ether1` (the dynamic WAN) for `:80` and `:443` into the
     container. SNAT is not needed (documented in STEP 7).

To redeploy a new image, upload the new tar and run
[`rsc/upgrade.rsc`](rsc/upgrade.rsc) (stop → remove → re-add from the local tar
→ start; the cert mount survives).

## Management

The container runs an SSH server (root, `PASSWORD`) on its veth address, or use
the router CLI:

```
/container/shell [find where hostname="nginx-router"]
# nginx -t
# cat /etc/nginx/conf.d/default.conf
# certbot certificates
```
