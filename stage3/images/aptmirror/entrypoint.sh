#!/bin/sh

service cron start
echo "Cron service has been started."

echo "Starting static file server..."
exec /app/static --port 5000 --path /data/ --mirror http://archive.ubuntu.com/ --cache-mirror
