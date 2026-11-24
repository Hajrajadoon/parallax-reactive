#!/usr/bin/env bash
# Prints the live state of both markets, both executors and the reactive brain.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; for f in deployments/*.env; do [[ -f "$f" ]] && source "$f"; done; set +a

price() { # pool rpc
  local r; r=$(cast call "$1" "getReserves()(uint112,uint112,uint32)" --rpc-url "$2")
  local r0 r1; r0=$(echo "$r" | sed -n 1p | awk '{print $1}'); r1=$(echo "$r" | sed -n 2p | awk '{print $1}')
  echo "reserves base=$(cast from-wei "$r0") quote=$(cast from-wei "$r1")  price=$(echo "scale=2; $r1 / $r0" | bc 2>/dev/null || echo '?')"
}

echo "── Markets"
echo "  Unichain  $(price "$UNI_POOL" "$UNICHAIN_SEPOLIA_RPC")"
echo "  Base      $(price "$BASE_POOL" "$BASE_SEPOLIA_RPC")"

echo "── Reactive brain  $REACTIVE_ADDR"
for fn in "currentSpreadBps()(uint256)" "activeArbId()(uint256)" "arbsOpened()(uint256)" "arbsSettled()(uint256)" \
          "arbsFullyFilled()(uint256)" "cumulativePnlQuote()(int256)" "paused()(bool)"; do
  printf '  %-28s %s\n' "${fn%%(*}" "$(cast call "$REACTIVE_ADDR" "$fn" --rpc-url "$REACTIVE_RPC" | awk '{print $1}')"
done
printf '  %-28s %s lREACT\n' "balance" "$(cast balance "$REACTIVE_ADDR" --rpc-url "$REACTIVE_RPC" --ether)"

echo "── Executors"
for SIDE in UNI BASE; do
  if [[ "$SIDE" == UNI ]]; then EX=$UNI_EXECUTOR; RPC=$UNICHAIN_SEPOLIA_RPC; PX=$UNI_CALLBACK_PROXY
  else EX=$BASE_EXECUTOR; RPC=$BASE_SEPOLIA_RPC; PX=$BASE_CALLBACK_PROXY; fi
  INV=$(cast call "$EX" "inventory()(uint256,uint256,uint256)" --rpc-url "$RPC")
  B=$(echo "$INV" | sed -n 1p | awk '{print $1}'); Q=$(echo "$INV" | sed -n 2p | awk '{print $1}'); N=$(echo "$INV" | sed -n 3p | awk '{print $1}')
  EXE=$(cast call "$EX" "legsExecuted()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
  SKP=$(cast call "$EX" "legsSkipped()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
  DEBT=$(cast call "$PX" "debt(address)(uint256)" "$EX" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}' || echo "?")
  printf '  %-5s pWETH=%s pUSD=%s gas=%s ETH  legs ok=%s skipped=%s  proxy-debt=%s\n' \
    "$SIDE" "$(cast from-wei "$B")" "$(cast from-wei "$Q")" "$(cast from-wei "$N")" "$EXE" "$SKP" "$DEBT"
done
