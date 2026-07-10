#!/usr/bin/env bash
# build-plugin.sh — package hq-pack-agent for release.
#
# Produces a versioned tarball of the package tree (excluding dev-only bits) that
# can be attached to the GitHub Release. Cutting a Release with tag v<VERSION> is
# what makes agents self-update; this helper just builds the artifact + validates
# that VERSION, package.yaml, and plugin.json agree.
#
# Modeled on core/packages/hq-pack-cowork/scripts/build-plugin.sh.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PACK_ROOT/VERSION")"
OUT="${1:-$HOME/Downloads/hq-pack-agent-$VERSION.tgz}"

# --- Version parity guard ---
PKG_YAML_VER="$(sed -nE 's/^version:[[:space:]]*//p' "$PACK_ROOT/package.yaml" | head -1 | tr -d '[:space:]')"
PLUGIN_VER="$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$PACK_ROOT/.claude-plugin/plugin.json" | head -1)"
if [ "$VERSION" != "$PKG_YAML_VER" ] || [ "$VERSION" != "$PLUGIN_VER" ]; then
  echo "version mismatch: VERSION=$VERSION package.yaml=$PKG_YAML_VER plugin.json=$PLUGIN_VER" >&2
  exit 1
fi

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hq-pack-agent-build.XXXXXX")"
STAGE="$BUILD_ROOT/hq-pack-agent"
trap 'rm -rf "$BUILD_ROOT"' EXIT
mkdir -p "$STAGE"

rsync -a \
  --exclude '.git' \
  --exclude '.DS_Store' \
  --exclude 'tests/tmp' \
  "$PACK_ROOT/" "$STAGE/"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
tar -C "$BUILD_ROOT" -czf "$OUT" hq-pack-agent

echo "built $OUT (v$VERSION)"
echo "next: git tag v$VERSION && gh release create v$VERSION -R indigoai-us/hq-pack-agent"
