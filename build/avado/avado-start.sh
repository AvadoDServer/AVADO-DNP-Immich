#!/bin/sh
# AVADO start wrapper: the HTTPS front (nginx on ports 80 and 443 inside the
# container, in front of the app) and a lower CPU priority for the app, so
# the Ethereum node always comes first when the box is busy.
#
# AVADO's package format has no memory or CPU limits (the DAPPMANAGER does not
# pass them to docker-compose), so "nice" plus each app's own thread settings
# is what keeps an app from starving the node.
set -u
. /etc/avado/avado-certs.sh

# Start with the copy we have (no network wait); the check below fetches the
# box's current copy a few seconds later.
if ! avado_cert_ok "$AVADO_LIVE_CRT" "$AVADO_LIVE_KEY"; then
  avado_install_cert "$AVADO_CERT_DIR/build.crt" "$AVADO_CERT_DIR/build.key"
fi

NGINX_USER=nobody
for _u in nginx www-data; do
  if id -u "$_u" >/dev/null 2>&1; then NGINX_USER=$_u; break; fi
done
mkdir -p /tmp/avado-nginx
chown "$NGINX_USER" /tmp/avado-nginx
sed "s/__NGINX_USER__/$NGINX_USER/" /etc/avado/nginx.conf.in > /etc/avado/nginx.conf

# The web front: restarted if it ever stops.
(
  while :; do
    nginx -c /etc/avado/nginx.conf -g 'daemon off;'
    echo "[avado] web front stopped; starting it again in 5 s" >&2
    sleep 5
  done
) &

# Certificate check: shortly after start, then daily.
(
  sleep 15
  while :; do
    if avado_certs_update; then nginx -c /etc/avado/nginx.conf -s reload; fi
    sleep 86400
  done
) &

# App-specific preparation (first-run settings, helper services, settings
# taken from the box). Sourced, so it can export settings for the app.
if [ -f /etc/avado/app-prestart.sh ]; then
  . /etc/avado/app-prestart.sh
fi

exec nice -n "${AVADO_APP_NICE:-10}" "$@"
