#!/usr/bin/env bash
# Install or reconfigure agent-clip. Safe to re-run any time.
#
#   curl -fsSL https://raw.githubusercontent.com/Pratham-commits-code/agent-clip/main/install.sh | bash
#
# Skip the questions (for scripts or agents) by setting:
#   CLIP_REMOTE=host|local   where pasted content should go
#   CLIP_SKILLS=yes|no       install the agent skill for Claude Code / Codex
#   CLIP_BIN_DIR=path        install location (default ~/.local/bin)
set -euo pipefail

REPO="Pratham-commits-code/agent-clip"
BIN_DIR="${CLIP_BIN_DIR:-$HOME/.local/bin}"
CONFIG="$HOME/.config/agent-clip/config"

fail() { echo "error: $*" >&2; exit 1; }
ask() { local reply; read -r -p "$1" reply </dev/tty || true; echo "$reply"; }

[ "$(uname)" = Darwin ] || fail "agent-clip only works on macOS."
command -v swiftc >/dev/null || fail "Swift is missing. Run 'xcode-select --install', then re-run this script."

# Use the checkout this script lives in, or download the source when piped from curl.
src="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
if [ ! -f "$src/clip.swift" ]; then
  src="$(mktemp -d)"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$src" --strip-components 1
fi

echo "Building clip (Apple silicon + Intel)..."
build="$(mktemp -d)"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13" "$src/clip.swift" -o "$build/clip-$arch" 2>/dev/null \
    || fail "build failed. Run: swiftc $src/clip.swift"
done
lipo -create "$build/clip-arm64" "$build/clip-x86_64" -output "$build/clip"
mkdir -p "$BIN_DIR"
install -m 755 "$build/clip" "$BIN_DIR/clip"
echo "Installed $BIN_DIR/clip"

# Where the clipboard lives. Agents often run on one Mac while you paste on another.
current="$(sed -n 's/^remote=//p' "$CONFIG" 2>/dev/null || true)"
remote="${CLIP_REMOTE-}"
if [ -z "${CLIP_REMOTE+set}" ]; then
  echo
  echo "Which Mac do you paste on?"
  echo "  - Press Enter or type 'local' if it's this one."
  echo "  - Type an SSH host (like my-laptop or user@laptop.local) if agents run here but you paste on another Mac."
  remote="$(ask "Paste on [${current:-local}]: ")"
  remote="${remote:-${current:-local}}"
fi
[ "$remote" = local ] && remote=""

if [ -n "$remote" ]; then
  echo "Setting up clip on $remote..."
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote" 'test "$(uname)" = Darwin && mkdir -p ~/.local/bin' \
    || fail "can't reach $remote as a Mac over SSH without a password prompt. Set up SSH keys (ssh-copy-id $remote), then re-run."
  scp -q "$BIN_DIR/clip" "$remote:.local/bin/clip"
  ssh -o BatchMode=yes "$remote" '~/.local/bin/clip --local --types >/dev/null' \
    || fail "clip installed on $remote but can't read its clipboard. Make sure you're logged in there."
  echo "clip on $remote is ready."
fi
mkdir -p "$(dirname "$CONFIG")"
echo "remote=$remote" >"$CONFIG"

# Teach coding agents about clip.
for agent in claude codex; do
  [ -d "$HOME/.$agent" ] || continue
  answer="${CLIP_SKILLS-}"
  [ -n "$answer" ] || answer="$(ask "Install the clip skill for $agent? [Y/n] ")"
  case "$answer" in [nN]*) continue ;; esac
  mkdir -p "$HOME/.$agent/skills/clip"
  rm -f "$HOME/.$agent/skills/clip/SKILL.md" # may be a symlink into an old checkout
  cp "$src/SKILL.md" "$HOME/.$agent/skills/clip/SKILL.md"
  echo "Installed skill in ~/.$agent/skills/clip"
done

echo
echo "Done. Clipboard target: ${remote:-this Mac} (saved in $CONFIG; re-run this script to change it)."
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Add $BIN_DIR to your PATH: echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc" ;;
esac
echo "Try it: echo '**hello** from *clip*' | clip --md -"
