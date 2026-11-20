#!/bin/zsh
# Build the relay for the server and put it, the site and the Caddy configuration in place.
#   Server/deploy/deploy.sh [relay] [site] [caddy]      (no argument: all three)
# The DeepSeek key is not handled here: it sits in /etc/fanwai/relay.env on the server only.
set -e
HOST=${FANWAI_HOST:-fanwai-hk}
cd "$(dirname "$0")/.."
what=("$@"); (( $# )) || what=(relay site caddy)
if (( ${what[(I)relay]} )); then
  (cd relay && go test -count=1 ./... && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /tmp/fanwai-relay .)
  scp -q /tmp/fanwai-relay deploy/fanwai-relay.service deploy/config.json $HOST:/tmp/
  ssh $HOST 'set -e
    id fanwai >/dev/null 2>&1 || sudo useradd --system --home /var/lib/fanwai --shell /usr/sbin/nologin fanwai
    sudo install -d -m 750 -o fanwai -g fanwai /var/lib/fanwai
    sudo install -d -m 755 /etc/fanwai
    [ -f /var/lib/fanwai/config.json ] || sudo install -m 640 -o fanwai -g fanwai /tmp/config.json /var/lib/fanwai/config.json
    sudo install -m 755 /tmp/fanwai-relay /usr/local/bin/fanwai-relay
    printf "#!/bin/sh\nexec sudo -u fanwai FANWAI_DATA=/var/lib/fanwai /usr/local/bin/fanwai-relay \"\$@\"\n" | sudo tee /usr/local/bin/fanwai >/dev/null; sudo chmod 755 /usr/local/bin/fanwai
    sudo install -m 644 /tmp/fanwai-relay.service /etc/systemd/system/fanwai-relay.service
    rm -f /tmp/fanwai-relay /tmp/fanwai-relay.service /tmp/config.json
    sudo systemctl daemon-reload
    if sudo test -s /etc/fanwai/relay.env; then sudo systemctl enable -q fanwai-relay; sudo systemctl restart fanwai-relay; sleep 1; systemctl is-active fanwai-relay; else echo "relay installed; /etc/fanwai/relay.env is missing, so it is not started"; fi'
fi
if (( ${what[(I)site]} )); then
  ssh $HOST 'sudo install -d -m 755 -o admin -g admin /srv/fanwai/site'
  rsync -az --delete site/ $HOST:/srv/fanwai/site/
fi
if (( ${what[(I)caddy]} )); then
  scp -q deploy/Caddyfile $HOST:/tmp/Caddyfile
  ssh $HOST 'sudo install -m 644 /tmp/Caddyfile /etc/caddy/Caddyfile && rm /tmp/Caddyfile && sudo caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && sudo systemctl reload caddy && echo "caddy reloaded"'
fi
