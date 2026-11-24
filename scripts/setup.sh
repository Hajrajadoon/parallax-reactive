#!/usr/bin/env bash
# Installs Solidity dependencies (forge-std + Reactive Omni library) and runs the test suite.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v forge >/dev/null || {
  echo "Foundry not found. Install it with:"
  echo "  curl -L https://foundry.paradigm.xyz | bash && foundryup"
  exit 1
}

[[ -d .git ]] || git init -q

install() { # repo dir
  if [[ -d "lib/$2" && -n "$(ls -A "lib/$2" 2>/dev/null)" ]]; then echo "✓ lib/$2 present"; return; fi
  forge install "$1" || forge install "$1" --no-commit
}
install foundry-rs/forge-std forge-std
install Reactive-Network/reactive-lib-omni reactive-lib-omni

[[ -f .env ]] || { cp .env.example .env; echo "✓ created .env — add your PRIVATE_KEY"; }
chmod +x scripts/*.sh

forge build
forge test
echo
echo "✓ Setup complete. Next: fund your wallet (see README) and run ./scripts/deploy-all.sh"
