#!/usr/bin/env bash

if [[ -z $1 ]]; then
    echo "Update Nakamochi with locally built nd and ngui."
    echo "Usage: $(basename "$0") nakamochi-ip [binaries-path]"
    echo "Where:"
    echo "  nakamochi-ip      IP address of the Nakamochi device"
    echo "  binaries-path     (Optional) Path to the directory containing 'nd' and 'ngui' binaries. Defaults to ./zig-out/bin."
    exit 1
fi

NAKAMOCHI_IP=$1
BINARIES_PATH=${2:-./zig-out/bin}

if [[ ! -f "$BINARIES_PATH/nd" || ! -f "$BINARIES_PATH/ngui" ]]; then
    echo "Could not find nd/ngui binaries in the specified path: $BINARIES_PATH"
    exit 1
fi

ssh_cmd="ssh root@$NAKAMOCHI_IP"

nakamochi_nd_path="$($ssh_cmd 'grep -o "/home/uiuser/v[0-9]\.[0-9]\.[0-9]" /etc/sv/nd/run | head -n 1')"
if [[ -z $nakamochi_nd_path ]]; then
    echo "Could not determine Nakamochi nd installation path."
    exit 1
fi

$ssh_cmd "sha256sum $nakamochi_nd_path/*; sv stop nd" || {
    echo "Failed to stop nd service"
    exit 1
}
scp "$BINARIES_PATH/nd" "root@$NAKAMOCHI_IP:$nakamochi_nd_path/nd" || {
    echo "Failed to copy nd binary"
    exit 1
}
scp "$BINARIES_PATH/ngui" "root@$NAKAMOCHI_IP:$nakamochi_nd_path/ngui" || {
    echo "Failed to copy ngui binary"
    exit 1
}
$ssh_cmd "sha256sum $nakamochi_nd_path/*; sv start nd; grep ndg /var/log/socklog/daemon/current | tail" || {
    echo "Failed to start nd service"
    exit 1
}

echo "Nakamochi NDG update completed."
