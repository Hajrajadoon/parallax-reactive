#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Parallax — one-shot deployment of the full loop across three chains
#    1. pool on Unichain Sepolia      4. executor on Unichain Sepolia
#    2. pool on Base Sepolia          5. executor on Base Sepolia
#    3. reactive brain on Lasna       6. wire executors into the brain
#  Every step writes its addresses to deployments/*.env, so a failed step can be
#  re-run on its own with:  ./scripts/deploy-all.sh <step-number>
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "✗ .env not found — run: cp .env.example .env  (then add PRIVATE_KEY)"; exit 1; }
set -a; source .env; set +a
: "${PRIVATE_KEY:?PRIVATE_KEY missing in .env}"
[[ "$PRIVATE_KEY" == 0x* ]] || { echo "✗ PRIVATE_KEY must start with 0x"; exit 1; }
command -v forge >/dev/null || { echo "✗ Foundry not installed — see https://getfoundry.sh"; exit 1; }
[[ -d lib/reactive-lib-omni ]] || { echo "✗ dependencies missing — run: ./scripts/setup.sh"; exit 1; }

RX_FLAGS="${REACTIVE_TX_FLAGS:-}"
ONLY="${1:-all}"
mkdir -p deployments

load()  { [[ -f "deployments/$1" ]] && { set -a; source "deployments/$1"; set +a; } || true; }
step()  { printf '\n\033[1;36m━━━ %s ━━━\033[0m\n' "$*"; }
want()  { [[ "$ONLY" == "all" || "$ONLY" == "$1" ]]; }

load UNI.origin.env; load BASE.origin.env; load REACTIVE.env
load UNI.executor.env; load BASE.executor.env

ME=$(cast wallet address --private-key "$PRIVATE_KEY")
step "Wallet $ME"
printf '  Unichain Sepolia : %s ETH\n'    "$(cast balance "$ME" --rpc-url "$UNICHAIN_SEPOLIA_RPC" --ether)"
printf '  Base Sepolia     : %s ETH\n'    "$(cast balance "$ME" --rpc-url "$BASE_SEPOLIA_RPC" --ether)"
printf '  Reactive Lasna   : %s lREACT\n' "$(cast balance "$ME" --rpc-url "$REACTIVE_RPC" --ether)"

if want 1; then
  step "1/6  Market on Unichain Sepolia"
  SIDE=UNI forge script script/DeployOrigin.s.sol:DeployOrigin --rpc-url "$UNICHAIN_SEPOLIA_RPC" --broadcast --slow
  load UNI.origin.env
fi

if want 2; then
  step "2/6  Market on Base Sepolia"
  SIDE=BASE forge script script/DeployOrigin.s.sol:DeployOrigin --rpc-url "$BASE_SEPOLIA_RPC" --broadcast --slow
  load BASE.origin.env
fi

if want 3; then
  step "3/6  Reactive brain on Reactive Lasna"
  : "${UNI_POOL:?run step 1 first}"; : "${BASE_POOL:?run step 2 first}"
  # shellcheck disable=SC2086
  OUT=$(forge create src/ParallaxReactive.sol:ParallaxReactive \
          --rpc-url "$REACTIVE_RPC" --private-key "$PRIVATE_KEY" --broadcast \
          --value "$REACTIVE_FUND" $RX_FLAGS \
          --constructor-args "$UNICHAIN_CHAIN_ID" "$UNI_POOL" true "$BASE_CHAIN_ID" "$BASE_POOL" true \
                             "$MIN_PROFIT_WEI" "$MAX_TRADE_WEI" "$SLIPPAGE_BPS" "$LEG_TTL" "$LOCK_TIMEOUT")
  echo "$OUT"
  REACTIVE_ADDR=$(echo "$OUT" | grep -i "Deployed to:" | awk '{print $3}' || true)
  REACTIVE_DEPLOY_TX=$(echo "$OUT" | grep -i "Transaction hash:" | awk '{print $3}' || true)
  [[ -n "$REACTIVE_ADDR" ]] || { echo "✗ could not read reactive address from forge output"; exit 1; }
  printf 'export REACTIVE_ADDR=%s\nexport REACTIVE_DEPLOY_TX=%s\n' "$REACTIVE_ADDR" "$REACTIVE_DEPLOY_TX" > deployments/REACTIVE.env
  load REACTIVE.env
fi

if want 4; then
  step "4/6  Executor on Unichain Sepolia"
  : "${REACTIVE_ADDR:?run step 3 first}"
  SIDE=UNI forge script script/DeployExecutor.s.sol:DeployExecutor --rpc-url "$UNICHAIN_SEPOLIA_RPC" --broadcast --slow
  load UNI.executor.env
fi

if want 5; then
  step "5/6  Executor on Base Sepolia"
  : "${REACTIVE_ADDR:?run step 3 first}"
  SIDE=BASE forge script script/DeployExecutor.s.sol:DeployExecutor --rpc-url "$BASE_SEPOLIA_RPC" --broadcast --slow
  load BASE.executor.env
fi

if want 6; then
  step "6/6  Wire executors into the reactive brain"
  : "${UNI_EXECUTOR:?run step 4 first}"; : "${BASE_EXECUTOR:?run step 5 first}"
  # shellcheck disable=SC2086
  cast send "$REACTIVE_ADDR" "configureExecutors(address,address)" "$UNI_EXECUTOR" "$BASE_EXECUTOR" \
       --rpc-url "$REACTIVE_RPC" --private-key "$PRIVATE_KEY" $RX_FLAGS
  echo
  echo "  Fund the brain so it can pay for react() (it pauses if it runs into debt):"
  echo "    cast send $REACTIVE_ADDR --value 0.4ether --rpc-url \$REACTIVE_RPC --private-key \$PRIVATE_KEY"
fi

./scripts/write-dashboard-config.sh

step "Parallax is live"
cat <<EOF
  Reactive (Lasna)      ${REACTIVE_ADDR:-}
  Unichain pool         ${UNI_POOL:-}
  Unichain executor     ${UNI_EXECUTOR:-}
  Base pool             ${BASE_POOL:-}
  Base executor         ${BASE_EXECUTOR:-}

  Next:
    make dashboard                 # open http://localhost:8090 (dashboard: /app.html)
    ./scripts/whale.sh base dump 8 # knock Base out of line and watch Parallax close the gap
EOF
