#!/usr/bin/env bash
# Package the resize Lambda with a LINUX ARM64 build of sharp (lb-28).
#
# WHY DOCKER. sharp ships prebuilt native binaries per platform. `npm install`
# on a Mac installs the darwin-arm64 build, which the Lambda runtime cannot
# load - the function then fails at import with "Could not load the sharp
# module using the linux-arm64 runtime", on every invocation, with the
# distribution already live. Building inside the AWS base image is the only way
# to be sure the binary matches the runtime.
#
# ARM64 because the function runs on Graviton (cheaper per ms, and the same
# architecture the Fargate tasks already use).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../build"
ZIP="$OUT/resize.zip"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "Building sharp for linux/arm64 inside the Lambda base image..."
docker run --rm --platform linux/arm64 \
  -v "$HERE":/src:ro -v "$OUT":/out \
  --entrypoint /bin/sh public.ecr.aws/lambda/nodejs:22 -c '
    set -e
    mkdir -p /build && cd /build
    cp /src/package.json /src/index.js /src/resize.js .
    # --omit=dev so the test tooling never reaches the bundle.
    npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1
    # The AWS SDK is provided by the runtime; bundling it would add ~10MB for
    # nothing and risk a version skew with the platform.
    rm -rf node_modules/@aws-sdk
    # Copy the tree out and zip on the HOST: the Lambda base image has no zip
    # binary, and installing one here would make the build depend on a package
    # repo being reachable.
    cp -r index.js resize.js package.json node_modules /out/
  '

( cd "$OUT" && zip -qr resize.zip index.js resize.js package.json node_modules && rm -rf index.js resize.js package.json node_modules )

echo
ls -lh "$ZIP" | awk '{printf "  %s  %s\n", $9, $5}'

# Fail loudly if the native binary is for the wrong platform - the whole point
# of building in Docker. A darwin binary here imports fine on a laptop and
# fails on EVERY Lambda invocation, with the distribution already live.
#
# NOTE `grep -c`, not `grep -q`. Under `set -o pipefail` a `-q` exits on the
# first match, `unzip` then dies of SIGPIPE, and the pipeline reports failure
# even though the match SUCCEEDED - this check reported "the Docker build did
# not take" against a bundle that contained the binary all along.
if [ "$(unzip -l "$ZIP" | grep -c "@img/sharp-linux-arm64" || true)" -eq 0 ]; then
  echo "ERROR: no @img/sharp-linux-arm64 in the bundle - the Docker build did not take" >&2
  exit 1
fi
echo "  verified: @img/sharp-linux-arm64 present"
