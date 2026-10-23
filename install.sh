#!/usr/bin/env bash
# Installs claude-account into ~/.local/bin (override: PREFIX=/usr/local).
# Run from a clone: ./install.sh
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
  Linux) ;;
  *) echo "claude-account works on Linux only: on macOS, Claude Code keeps its login in the Keychain, not in a file." >&2; exit 1 ;;
esac
for dep in python3 curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; exit 1; }
done

mkdir -p "$PREFIX/bin" "$PREFIX/share/claude-account"
install -m 755 "$SRC/bin/claude-account" "$PREFIX/bin/claude-account"
install -m 644 "$SRC/bin/claude-account.completion.sh" "$PREFIX/share/claude-account/completion.sh"

echo "installed $PREFIX/bin/claude-account"
case ":$PATH:" in *":$PREFIX/bin:"*) ;; *) echo "add $PREFIX/bin to your PATH" ;; esac
echo "tab completion: add this line to ~/.bashrc or ~/.zshrc"
echo "  source $PREFIX/share/claude-account/completion.sh"
