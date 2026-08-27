#!/bin/sh
set -eu

ROOT=/usr/local/lib/zero1-tool/www
PORT=9511

if [ ! -f "$ROOT/index.html" ] || [ ! -x "$ROOT/cgi-bin/zero1.cgi" ]; then
    echo "Zero1tool web files are missing under $ROOT" >&2
    exit 1
fi

if [ -x /bin/busybox ]; then
    exec /bin/busybox httpd -f -p "0.0.0.0:${PORT}" -h "$ROOT"
elif [ -x /usr/bin/busybox ]; then
    exec /usr/bin/busybox httpd -f -p "0.0.0.0:${PORT}" -h "$ROOT"
elif command -v busybox >/dev/null 2>&1; then
    exec "$(command -v busybox)" httpd -f -p "0.0.0.0:${PORT}" -h "$ROOT"
elif command -v httpd >/dev/null 2>&1; then
    exec "$(command -v httpd)" -f -p "0.0.0.0:${PORT}" -h "$ROOT"
else
    echo "Neither busybox httpd nor standalone httpd was found" >&2
    exit 1
fi
