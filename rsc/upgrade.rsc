# =============================================================================
# Upgrade/redeploy the nginx reverse-proxy container — Main Router (192.168.20.1)
#
# Mirrors ../../tailscale-mikrotik/upgrade.rsc: capture the live container's
# settings, stop -> remove -> re-add from the LOCAL tar -> start. Unlike the
# tailscale version (which pulls remote-image=), this project ships a tar, so
# the re-add uses file=usb2-part1/nginx-arm64.tar + cmd=/usr/local/bin/nginx.sh
# (matching 01-router-nginx.rsc STEP 4).
#
# Upload the new nginx-arm64.tar to usb2-part1 BEFORE running this. The
# persisted cert mount (/usb2-part1/nginx/letsencrypt) survives the re-add, so
# no certificate is re-issued on upgrade.
# =============================================================================

# Container identifier
:local hostname "nginx-router";

/container
:local id [find where hostname=$hostname];
:local rootdir [get $id root-dir];
:local dns [get $id dns];
:local logging [get $id logging];
:local status [get $id status];
:local mounts [get $id mounts];
:local envlist [get $id envlist];
:local interface [get $id interface];
:local startonboot [get $id start-on-boot];
:global LogPrefix "Nginx";

:local logI do={
    :global LogPrefix;
    :put ($LogPrefix . ": " . $1);
    :log info ($LogPrefix . ": " . $1);
}

# Stop the container
$logI "Stopping the container...";
stop $id
:while ($status != "stopped") do={
    $logI "Waiting for the container to stop...";
    :delay 5;
    :set status [get $id status];
}
$logI "Stopped.";

# Remove the container
remove $id
$logI "Removing the container...";
:while ($status = "stopped") do={
    $logI "Waiting for the container to be removed...";
    :delay 5;
    :set status [get $id status];
}
$logI "Removed.";

# Add the container (from the LOCAL tar — this project ships a tar, not a
# registry image). cmd is required on RouterOS 7.22+.
:delay 5;
$logI "Adding the container...";
add file=usb2-part1/nginx-arm64.tar cmd=/usr/local/bin/nginx.sh \
    interface=$interface envlist=$envlist root-dir=$rootdir mounts=$mounts \
    start-on-boot=$startonboot hostname=$hostname dns=$dns logging=$logging \
    comment="nginx reverse proxy for Home Assistant (ha.dids.atasha.net)"
:do {
    :set status [get [find where hostname=$hostname] status];
    :if ($status != "stopped") do={
        $logI "Waiting for the container to be added...";
        :delay 5;
    }
} while ($status != "stopped")
$logI "Added."

# Start the container
$logI "Starting the container.";
:set id [find where hostname=$hostname];
start $id
