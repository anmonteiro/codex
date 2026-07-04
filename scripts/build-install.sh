#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ -d "$SCRIPT_DIR/codex-rs" ]; then
  REPO_ROOT="$SCRIPT_DIR"
elif [ -d "$SCRIPT_DIR/../codex-rs" ]; then
  REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
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
require_command rg
require_command zsh

RG_BINARY=$(command -v rg)
ZSH_BINARY=$(command -v zsh)

step "Building Codex release package"
(
  cd "$REPO_ROOT"
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

step "Installing Codex binaries to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp "$BUILT_BINARY" "$INSTALLED_BINARY"
cp "$BUILT_CODE_MODE_HOST" "$INSTALLED_CODE_MODE_HOST"

if [ "$(uname -s)" = "Darwin" ]; then
  require_command codesign
  step "Code-signing installed binaries"
  codesign \
    --force \
    --sign - \
    --identifier codex \
    --entitlements "$REPO_ROOT/.github/scripts/macos-signing/codex.entitlements.plist" \
    "$INSTALLED_BINARY"
  codesign \
    --force \
    --sign - \
    --identifier codex-code-mode-host \
    --entitlements "$REPO_ROOT/.github/scripts/macos-signing/codex-code-mode-host.entitlements.plist" \
    "$INSTALLED_CODE_MODE_HOST"
fi

step "Done"
printf '%s\n' "$INSTALLED_BINARY"
printf '%s\n' "$INSTALLED_CODE_MODE_HOST"
