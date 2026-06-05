#!/usr/bin/env bash
# Userland setup, run as the 'dev' user inside the builder VM after cloud-init.
# Idempotent enough to re-run while iterating. Expects config/mise-global.toml
# to already be pushed to ~/.config/mise/config.toml.
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

# --- mise -------------------------------------------------------------------
if ! command -v mise >/dev/null 2>&1; then
  curl -fsSL https://mise.run | sh
fi
if ! grep -q 'mise activate bash' "$HOME/.bashrc" 2>/dev/null; then
  {
    echo 'export PATH="$HOME/.local/bin:$PATH"'
    echo 'eval "$(mise activate bash)"'
  } >> "$HOME/.bashrc"
fi
eval "$("$HOME/.local/bin/mise" activate bash)"

# Install everything from the mirrored global config (node, java, tmux, ...).
mise install -y
mise reshim
hash -r

# --- coding agents ----------------------------------------------------------
# Claude Code — native installer, no Node dependency.
curl -fsSL https://claude.ai/install.sh | bash

# Cursor CLI — installs `cursor-agent` into ~/.local/bin.
curl -fsS https://cursor.com/install | bash

# GitHub Copilot CLI — needs Node >=22, provided by mise.
mise exec -- npm install -g @github/copilot
mise reshim

echo "setup-tools: done."
echo "  claude:       $(command -v claude || echo MISSING)"
echo "  cursor-agent: $(command -v cursor-agent || echo MISSING)"
echo "  copilot:      $(mise which copilot 2>/dev/null || command -v copilot || echo MISSING)"
