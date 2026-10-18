#!/bin/sh
set -e

mkdir -p /config /etc/zot /data

# Preserve existing configuration and initialize new volumes from the image default.
VOL_SETTINGS="/config/config.json"
if [ ! -f "$VOL_SETTINGS" ]; then
    cp /etc/zot/default-config.json "$VOL_SETTINGS"
fi
ln -sf "$VOL_SETTINGS" /etc/zot/config.json

# Legacy persisted configurations use the relative filename "stdout".
ln -sf /dev/stdout stdout

exec /usr/local/bin/zot serve /etc/zot/config.json
