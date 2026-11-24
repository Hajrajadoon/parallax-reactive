# Submission kit

## 5-day plan (deadline Dec 5)

| Day | Do | Done when |
|---|---|---|
| 1 | Install Foundry, `./scripts/setup.sh`, fund the wallet on 3 chains | `forge test` is all green, balances show in `deploy-all.sh` |
| 2 | `./scripts/deploy-all.sh`, `make dashboard`, then 3–4 whale runs | Feed shows settled arbs with both legs ✓ |
| 3 | Push a public GitHub repo (including `deployments/` and `broadcast/`), fill in the tables below, check CI is green | Judges can click every hash |
| 4 | Record the demo video (script below), upload it unlisted to YouTube or Loom | Video is under 3:00 |
| 5 | Polish the README, submit on the buildathon page | Submitted ✔ |

## Filled in: see README "It's live" for addresses and both arb loops

Contract addresses and the tx hashes for ARB #1 and ARB #2 are in the README.

## (template below, kept for reference)

### Contracts
| Contract | Chain | Address |
|---|---|---|
| ParallaxReactive | Reactive Lasna | `deployments/REACTIVE.env → REACTIVE_ADDR` |
| ParallaxExecutor | Unichain Sepolia | `deployments/UNI.executor.env` |
| ParallaxExecutor | Base Sepolia | `deployments/BASE.executor.env` |
| ParallaxPair | Unichain Sepolia | `deployments/UNI.origin.env` |
| ParallaxPair | Base Sepolia | `deployments/BASE.origin.env` |

### One full loop (copy the hashes from the dashboard feed, where every box is a link)
| Step | Chain | Tx hash |
|---|---|---|
| ① Origin: whale swap emits `Sync` | Base Sepolia | |
| ② Reactive tx: `ArbOpened` + 2 callback requests | Reactive Lasna | |
| ③ Buy leg callback: `LegExecuted` | Base Sepolia | |
| ④ Sell leg callback: `LegExecuted` | Unichain Sepolia | |
| ⑤ Reactive tx: `ArbSettled` (PnL booked) | Reactive Lasna | |

Do it twice, once dumping on Base and once pumping on Unichain, so judges see both directions.

## Demo video script (≈ 2:45)

**0:00–0:20 · Hook.** Dashboard full screen, both prices in line.
> "Same token, two chains, two prices. Whoever closes the gap first gets paid. That's normally a bot farm.
> Parallax does it with one reactive contract and nothing else."

**0:20–0:45 · How.** Show the mermaid diagram in the README.
> "The brain on Reactive mirrors both pools from their Sync events. When the gap beats fees, it sizes the optimal
> trade on-chain and fires two callbacks in one transaction. It buys on the cheap chain and sells on the expensive one."

**0:45–1:40 · Live.** Whale panel → Base → dump 8 → *Unleash*. Keep the dashboard visible.
> "I'm dumping 8 pWETH on Base. The spread jumps to about 1,600 bps… and here's arb #N. The buy leg lands on Base,
> the sell leg on Unichain, and the spread is back inside the fee band. Origin to reactive took 1 second, both
> legs were done in about 4."
Click through: origin tx → Lasna tx → both leg txs on the explorers.

**1:40–2:15 · Why it's real work.** Open `ParallaxReactive.sol` and scroll through `_evaluate`, `optimalArbInput` and `_onLeg`.
> "Closed-form optimal sizing, a lock so it never double-fires on its own trades, a feedback loop from the
> executors, PnL accounting, and a circuit breaker after two partial fills. Executors enforce slippage, a timestamp
> deadline, a cooldown and replay protection. Timestamps, never block counts, because of Base's 200 ms blocks."

**2:15–2:40 · Craft.** Terminal: `forge test` passing. Then `./scripts/deploy-all.sh` deploys everything with one command.

**2:40–2:50 · Close.**
> "On 7-second blocks this was impossible. On Omni it closes in seconds. Parallax."

## Pre-submit checklist
- [ ] Repo is public, MIT licensed, CI is green
- [ ] `deployments/*.env` and `broadcast/` are committed
- [ ] The hash tables above are filled in and linked from the README
- [ ] Video is under 3:00, and the link is in the README and the form
- [ ] `./scripts/status.sh` shows `arbsFullyFilled ≥ 2` and a positive PnL
