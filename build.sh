#!/usr/bin/env sh
set -e

IMAGE=$1

docker buildx build --no-cache --pull -f Dockerfile.armhf -t "${IMAGE}:arm32v7-latest" .
docker buildx build --no-cache --pull -f Dockerfile.aarch64 -t "${IMAGE}:arm64v8-latest" .
docker buildx build --no-cache --pull -t "${IMAGE}:amd64-latest" .
