#!/usr/bin/env bash
# Builds the image locally, ships it over SSH, and (re)starts it.
#   Usage: server/deploy/deploy.sh root@host [/opt/snap-salat]
set -euo pipefail
HOST="${1:?usage: deploy.sh user@host [remote_dir]}"
DIR="${2:-/opt/snap-salat}"
TAG="snap-salat:$(date +%Y%m%d-%H%M%S)"
ENGINE="$(command -v docker || command -v podman)"

cd "$(dirname "$0")/.."
echo "→ building $TAG"
"$ENGINE" build --platform linux/amd64 -t "$TAG" -t snap-salat:latest .

echo "→ uploading image"
# podman names local images localhost/…; re-tag on arrival so the name
# matches IMAGE= whichever tool built it.
"$ENGINE" save "$TAG" | gzip | ssh "$HOST" "gunzip | docker load | sed -n 's/^Loaded image: //p' | xargs -I{} docker tag {} $TAG"

echo "→ starting"
ssh "$HOST" "mkdir -p $DIR"
scp deploy/docker-compose.yml deploy/Caddyfile.standalone "$HOST:$DIR/"
ssh "$HOST" "cd $DIR && touch .env && sed -i '/^IMAGE=/d' .env && echo IMAGE=$TAG >> .env && docker compose up -d --remove-orphans && docker image prune -f >/dev/null"
echo "✓ deployed $TAG"
