#!/usr/bin/env bash
# Knock one pool out of line so Parallax has a gap to close.
#   ./scripts/whale.sh <uni|base> <dump|pump> <amount>
#   dump: sell <amount> pWETH  (price falls)      e.g. ./scripts/whale.sh base dump 8
#   pump: spend <amount> pUSD on pWETH (rises)    e.g. ./scripts/whale.sh uni pump 25000
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; for f in deployments/*.env; do [[ -f "$f" ]] && source "$f"; done; set +a

SIDE_IN="${1:-base}"; DIRECTION="${2:-dump}"; AMOUNT_HUMAN="${3:-8}"
case "$SIDE_IN" in
  uni|UNI|unichain)  SIDE=UNI;  RPC="$UNICHAIN_SEPOLIA_RPC" ;;
  base|BASE)         SIDE=BASE; RPC="$BASE_SEPOLIA_RPC" ;;
  *) echo "usage: $0 <uni|base> <dump|pump> <amount>"; exit 1 ;;
esac
[[ "$DIRECTION" == "dump" || "$DIRECTION" == "pump" ]] || { echo "direction must be dump or pump"; exit 1; }

AMOUNT=$(cast to-wei "$AMOUNT_HUMAN")
echo "🐋  $DIRECTION $AMOUNT_HUMAN on $SIDE  —  $(date '+%H:%M:%S')"
SIDE=$SIDE DIRECTION=$DIRECTION AMOUNT=$AMOUNT \
  forge script script/Whale.s.sol:Whale --rpc-url "$RPC" --broadcast --slow
echo "Origin tx hashes: broadcast/Whale.s.sol/$(cast chain-id --rpc-url "$RPC")/run-latest.json"
