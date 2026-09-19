#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
if [ -d "$SCRIPT_DIR/codex-rs" ]; then
  REPO_ROOT="$SCRIPT_DIR"
elif [ -d "$SCRIPT_DIR/../codex-rs" ]; then
  REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
else
  printf 'Could not find codex-rs relative to %s\n' "$SCRIPT_DIR" >&2
  exit 1
fi
CODEX_RS_DIR="$REPO_ROOT/codex-rs"
TARGET_DIR="$CODEX_RS_DIR/target/release-thin"
PACKAGE_DIR="$TARGET_DIR/package"
BUILT_BINARY="$PACKAGE_DIR/bin/codex"
BUILT_CODE_MODE_HOST="$PACKAGE_DIR/bin/codex-code-mode-host"
INSTALL_DIR="${CODEX_INSTALL_DIR:-$HOME/bin}"
PACKAGE_ROOT="${CODEX_LOCAL_PACKAGE_ROOT:-${CODEX_HOME:-$HOME/.codex}/packages/local}"
INSTALLED_BINARY="$INSTALL_DIR/codex"
INSTALLED_CODE_MODE_HOST="$INSTALL_DIR/codex-code-mode-host"

step() {
  printf '==> %s\n' "$1"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s is required.\n' "$1" >&2
    exit 1
  fi
}

require_command nix
require_command python3
require_command rg
require_command zsh

RG_BINARY=$(command -v rg)
ZSH_BINARY=$(command -v zsh)

step "Building Codex release package"
(
  cd "$REPO_ROOT"
  # Positional arguments are expanded by the inner shell.
  # shellcheck disable=SC2016
  nix develop -c sh -c \
    'ulimit -n 8192 2>/dev/null || ulimit -n 4096 2>/dev/null || true
     export CARGO_TARGET_DIR="$1"
     export CODEX_REPO_ROOT="$5"
     exec python3 scripts/build_codex_package.py \
       --package-dir "$2" \
       --force \
       --cargo-profile release \
       --rg-bin "$3" \
       --zsh-bin "$4"' \
    sh "$TARGET_DIR" "$PACKAGE_DIR" "$RG_BINARY" "$ZSH_BINARY" "$REPO_ROOT"
)

for binary in "$BUILT_BINARY" "$BUILT_CODE_MODE_HOST"; do
  if [ ! -x "$binary" ]; then
    printf 'Expected built binary at %s\n' "$binary" >&2
    exit 1
  fi
done

step "Installing complete Codex package to $PACKAGE_ROOT"
mkdir -p "$INSTALL_DIR" "$PACKAGE_ROOT/releases"
INSTALLED_PACKAGE_DIR=$(mktemp -d "$PACKAGE_ROOT/releases/local.XXXXXXXX")
INSTALLED_PACKAGE_DIR=$(CDPATH='' cd -- "$INSTALLED_PACKAGE_DIR" && pwd)
trap 'rm -rf -- "$INSTALLED_PACKAGE_DIR"' EXIT
cp -R "$PACKAGE_DIR/." "$INSTALLED_PACKAGE_DIR/"

if [ "$(uname -s)" = "Darwin" ]; then
  require_command codesign
  step "Code-signing installed binaries"
  codesign \
    --force \
    --sign - \
    --identifier codex \
    --entitlements "$REPO_ROOT/.github/scripts/macos-signing/codex.entitlements.plist" \
    "$INSTALLED_PACKAGE_DIR/bin/codex"
  codesign \
    --force \
    --sign - \
    --identifier codex-code-mode-host \
    --entitlements "$REPO_ROOT/.github/scripts/macos-signing/codex-code-mode-host.entitlements.plist" \
    "$INSTALLED_PACKAGE_DIR/bin/codex-code-mode-host"
fi

"$INSTALLED_PACKAGE_DIR/bin/codex" --version

# Retain complete releases for running clients. Never copy through an existing
# launcher symlink: that would overwrite a previously installed package.
trap - EXIT
step "Linking Codex binaries into $INSTALL_DIR"
python3 - "$INSTALLED_PACKAGE_DIR" "$INSTALL_DIR" <<'PY'
import os
from pathlib import Path
import sys
import tempfile

package_dir = Path(sys.argv[1])
install_dir = Path(sys.argv[2])
with tempfile.TemporaryDirectory(prefix=".codex-install-", dir=install_dir) as staging:
    for name in ("codex", "codex-code-mode-host"):
        link = Path(staging) / name
        link.symlink_to(package_dir / "bin" / name)
        os.replace(link, install_dir / name)
PY

step "Done"
printf 'Package: %s\n' "$INSTALLED_PACKAGE_DIR"
printf '%s\n' "$INSTALLED_BINARY"
printf '%s\n' "$INSTALLED_CODE_MODE_HOST"
printf '\nTo switch an existing daemon to this build, run:\n  codex app-server daemon update --from-cli\n'
