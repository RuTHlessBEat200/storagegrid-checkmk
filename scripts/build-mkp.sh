#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Build the netapp_storagegrid Checkmk extension package (.mkp).
#
# This spins up the official Checkmk container, copies the plugin family
# into a fresh site, and uses Checkmk's own "mkp" tool (via `mkp template`
# followed by `mkp package`) to create the .mkp file. Using the real tool
# guarantees the result is in the exact format Checkmk expects, without
# having to hand-maintain a list of packaged files.
#
# Usage:
#   scripts/build-mkp.sh [version]
#
# "version" defaults to (in order of preference):
#   1. The first script argument, if given.
#   2. The current Git tag, if HEAD is tagged (a leading "v" is stripped).
#   3. A development version derived from the commit count and short hash.
#
# Environment variables:
#   CHECKMK_IMAGE   Checkmk Docker image to build with (default: see below)
#   SITE            Checkmk site name used inside the container (default: cmk)
#   CONTAINER       Name of the Docker container to create (default: checkmk-mkp-build)
###############################################################################

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FAMILY="netapp_storagegrid"
SITE="${SITE:-cmk}"
CONTAINER="${CONTAINER:-checkmk-mkp-build}"
IMAGE="${CHECKMK_IMAGE:-checkmk/check-mk-community:2.5.0-latest}"

AUTHOR="Bedag Informatik AG"
TITLE="NetApp StorageGRID"
DESCRIPTION="Checkmk special agent and check plugins for monitoring NetApp StorageGRID via its Grid Management REST API."
DOWNLOAD_URL="https://github.com/bedag/storagegrid-checkmk"
VERSION_MIN_REQUIRED="2.5.0"

###############################################################################
# Determine version
###############################################################################

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  if git describe --tags --exact-match >/dev/null 2>&1; then
    VERSION="$(git describe --tags --exact-match)"
  else
    VERSION="0.0.0-dev$(git rev-list --count HEAD).g$(git rev-parse --short HEAD)"
  fi
fi
VERSION="${VERSION#v}"

echo "==> Building ${FAMILY} version ${VERSION} using ${IMAGE}"

mkdir -p dist

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

###############################################################################
# Start Checkmk
###############################################################################

echo "==> Starting Checkmk container"
docker run -d --name "$CONTAINER" -e CMK_PASSWORD=build-mkp "$IMAGE" >/dev/null

echo "==> Waiting for the site to finish starting"
timeout=300
elapsed=0
until docker logs "$CONTAINER" 2>&1 | grep -q "### CONTAINER STARTED"; do
  if (( elapsed >= timeout )); then
    echo "ERROR: timed out waiting for the Checkmk container to start" >&2
    docker logs "$CONTAINER" >&2
    exit 1
  fi
  sleep 5
  elapsed=$((elapsed + 5))
  echo "   ...waiting (${elapsed}s)"
done

###############################################################################
# Copy plugin files into the site
###############################################################################

PLUGIN_DIR="/omd/sites/${SITE}/local/lib/python3/cmk_addons/plugins/${FAMILY}"

echo "==> Copying plugin files into the site"
docker exec "$CONTAINER" mkdir -p "$PLUGIN_DIR"
docker cp "cmk_addons/plugins/${FAMILY}/." "${CONTAINER}:${PLUGIN_DIR}/"
docker exec "$CONTAINER" chmod +x "${PLUGIN_DIR}/libexec/agent_netapp_storagegrid"
docker exec "$CONTAINER" chown -R "${SITE}:${SITE}" "/omd/sites/${SITE}/local"

###############################################################################
# Generate and patch the manifest
###############################################################################

echo "==> Generating manifest template"
docker exec "$CONTAINER" bash -c "su - '${SITE}' -c 'mkp template ${FAMILY}'" > "dist/${FAMILY}.manifest"

echo "==> Filling in package metadata"
python3 "${REPO_ROOT}/scripts/patch_manifest.py" "dist/${FAMILY}.manifest" \
  --title "$TITLE" \
  --description "$DESCRIPTION" \
  --author "$AUTHOR" \
  --download-url "$DOWNLOAD_URL" \
  --version "$VERSION" \
  --version-min-required "$VERSION_MIN_REQUIRED"

###############################################################################
# Build the MKP
###############################################################################

echo "==> Packaging MKP"
docker cp "dist/${FAMILY}.manifest" "${CONTAINER}:/omd/sites/${SITE}/tmp/${FAMILY}.manifest"
docker exec "$CONTAINER" chown "${SITE}:${SITE}" "/omd/sites/${SITE}/tmp/${FAMILY}.manifest"
docker exec "$CONTAINER" bash -c "su - '${SITE}' -c 'mkp package /omd/sites/${SITE}/tmp/${FAMILY}.manifest'"

###############################################################################
# Collect the result
###############################################################################

echo "==> Collecting MKP"
MKP_PATH="$(docker exec "$CONTAINER" find "/omd/sites/${SITE}/var/check_mk/packages_local" -name '*.mkp' | head -n1)"
if [[ -z "$MKP_PATH" ]]; then
  echo "ERROR: no .mkp file was produced" >&2
  exit 1
fi
docker cp "${CONTAINER}:${MKP_PATH}" "dist/"

echo "==> Done:"
ls -lh dist/*.mkp
