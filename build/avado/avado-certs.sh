#!/bin/sh
# The *.my.ava.do certificate for this app's HTTPS address.
#
# Every AVADO box has the same *.my.ava.do certificate. The box's DAPPMANAGER
# serves the current copy (as AVADO-DNP-Nethermind uses it); iso.ava.do is the
# second source, and the copy taken when the image was built is the last
# resort. A downloaded copy is used only when it is for *.my.ava.do, is not
# about to expire and matches its key.

AVADO_CERT_DIR=/etc/avado/certs
AVADO_LIVE_CRT=$AVADO_CERT_DIR/live.crt
AVADO_LIVE_KEY=$AVADO_CERT_DIR/live.key
AVADO_CERT_SOURCES="http://dappmanager.my.ava.do http://iso.ava.do"

avado_fetch() { # url file
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 20 -o "$2" "$1" 2>/dev/null
  else
    wget -q -T 20 -O "$2" "$1" 2>/dev/null
  fi
}

avado_cert_ok() { # crt key
  [ -s "$1" ] && [ -s "$2" ] || return 1
  openssl x509 -in "$1" -noout -checkend 3600 >/dev/null 2>&1 || return 1
  openssl x509 -in "$1" -noout -subject 2>/dev/null | grep -q 'my\.ava\.do' || return 1
  _a=$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null)
  _b=$(openssl pkey -in "$2" -pubout 2>/dev/null | openssl sha256 2>/dev/null)
  [ -n "$_a" ] && [ "$_a" = "$_b" ]
}

avado_install_cert() { # crt key
  cp "$1" "$AVADO_LIVE_CRT.new" && cp "$2" "$AVADO_LIVE_KEY.new" &&
    chmod 600 "$AVADO_LIVE_KEY.new" &&
    mv -f "$AVADO_LIVE_CRT.new" "$AVADO_LIVE_CRT" && mv -f "$AVADO_LIVE_KEY.new" "$AVADO_LIVE_KEY"
}

# Returns 0 when the certificate in use changed (nginx must reload), 1 otherwise.
avado_certs_update() {
  mkdir -p "$AVADO_CERT_DIR"
  _t=$(mktemp -d)
  for _src in $AVADO_CERT_SOURCES; do
    if avado_fetch "$_src/my.ava.do.crt" "$_t/c" && avado_fetch "$_src/my.ava.do.key" "$_t/k" &&
      avado_cert_ok "$_t/c" "$_t/k"; then
      if cmp -s "$_t/c" "$AVADO_LIVE_CRT" && cmp -s "$_t/k" "$AVADO_LIVE_KEY"; then
        rm -rf "$_t"
        return 1
      fi
      avado_install_cert "$_t/c" "$_t/k"
      rm -rf "$_t"
      echo "[avado] HTTPS certificate updated from $_src"
      return 0
    fi
  done
  rm -rf "$_t"
  if ! avado_cert_ok "$AVADO_LIVE_CRT" "$AVADO_LIVE_KEY"; then
    avado_install_cert "$AVADO_CERT_DIR/build.crt" "$AVADO_CERT_DIR/build.key"
    echo "[avado] HTTPS certificate: using the copy from the image (no fresher copy reachable)"
    return 0
  fi
  return 1
}
