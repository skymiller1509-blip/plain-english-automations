# Plain-English Automations — Reactive Omni Buildathon, Track 3 "Reactive Meets AI"

## The problem, in plain words

You have crypto, and you have a plan: "if ETH drops 10%, move to USDC."
Today, carrying that plan out means watching the price yourself, or trusting
a server, a bot, or an exchange to do it for you. If you are asleep, busy,
or offline when the price moves, the plan does not happen.

This project fixes that. You type the plan in plain English. A real AI reads
your words and turns them into exact settings. A Reactive contract watches
the live price and carries the plan out on its own — no server, no manual
click, no one watching the screen for you.

## How it works

There are three parts, and the AI is one of them — it runs live inside the
app, every time a user types a rule. That is what Track 3 requires: the AI
must be part of the running system, not just a tool used to build the
project. A fixed list of words, or a regex that looks for "10%", would NOT
count. This app really calls a neural network at runtime.

1. **You type a rule.** For example: "if ETH drops 10%, move to USDC".
2. **Gemini reads it, live.** The app sends only your sentence to Gemini
   through Firebase AI Logic and gets back strict JSON settings: which asset
   (ETH), which way the price moves (drop), how far (10%), what to do
   (move to USDC). You see the settings on screen and check them before
   anything is saved. If the AI misunderstood, you reword the sentence and
   ask again.
3. **The rule is saved on-chain.** The vault on Base Sepolia records the
   direction and the threshold, and reads the live Chainlink price itself
   at that exact moment as the baseline — so the rule is always measured
   from a real on-chain price, never a number typed by hand.
4. **The watcher watches the price.** The reactive contract on Reactive's
   Lasna testnet subscribes to the Chainlink feed's price updates. Every
   time the price moves, it checks: has the price moved by the threshold
   from the baseline, in the rule's direction? A clock tick re-checks the
   last observed price as a backstop, in case an update was missed or a
   callback failed.
5. **The rule carries itself out.** When the condition is met, the watcher
   asks the vault — through Reactive's official callback proxy — to move
   the deposit into USDC. The vault re-checks the live price itself before
   moving anything, so a mistaken or stale trigger can never move funds
   early. The watcher only considers the job done once it sees the vault's
   Executed event, so a failed callback is retried instead of forgotten.

## The price feed — a real one

The watcher listens to the **live Chainlink ETH/USD feed on Base Sepolia**:

- Proxy address: `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` (8 decimals)
- Verified live on 2026-11-11 with `cast`: `description()` returns
  "ETH / USD", `decimals()` returns 8, and `latestRoundData()` returned a
  fresh price of $2,078.35.
- The event watched is Chainlink's `AnswerUpdated(int256,uint256,uint256)`,
  topic0 `0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f`
  (also verified with `cast keccak`). The new price arrives as topic1,
  because Chainlink marks the price `indexed`.
- **The events are emitted by the aggregator, not the proxy.** The proxy
  is only a read path and never emits `AnswerUpdated` (proven 2026-11-11:
  the proxy emitted zero such events while the aggregator emitted every
  price move). The rule therefore subscribes to the aggregator
  `0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3`, read from the proxy's
  `aggregator()` at deploy time; `setAggregator()` re-subscribes if
  Chainlink ever rotates it. The vault keeps reading prices through the
  proxy, which is correct for reads.
- The feed updates when the price moves by 0.15% or on its heartbeat
  (about every 20 minutes on this testnet), so the watcher hears about
  real moves within minutes.

No mock price feed was needed: the real feed exists, is live, and is free
to read.

## The AI — live Gemini through Firebase AI Logic

The app uses Eddie's existing Firebase project **Privacy Firewall**
(`privacy-firewall-583a4`), with the Gemini Developer API already enabled
— the same setup as the Firebase hackathon entry. The pattern is copied
from that project's working code
(`~/workspace/hackathons/firebase/firewall/src/`):

- `getAI(app, { backend: new GoogleAIBackend() })`, then
  `getGenerativeModel(ai, { model: "gemini-2.0-flash",
  generationConfig: { responseMimeType: "application/json" } })`.
- The model is named explicitly (`gemini-2.0-flash`) and the reply is
  forced to strict JSON, so the app can read the settings without guessing.
- App Check runs first (reCAPTCHA Enterprise, same site key as the
  firewall), because Firebase AI Logic requires it.
- The config values in the frontend are the project's public web
  identifiers, already published in a public repo. No Gemini API key is in
  the code: with Firebase AI Logic the key stays server-side behind the
  Firebase proxy.
- Only the user's sentence is sent to Gemini. Nothing else about the user,
  the wallet, or the deposit leaves the page.

## The three contracts

| Contract | Chain | Job |
|---|---|---|
| `RuleVault` | Base Sepolia (84532) | Holds the deposited ETH; records the rule (direction, threshold, baseline from the live feed); `executeRule()` — only via the callback proxy — moves the deposit into MockUSDC at the live price |
| `PlainEnglishRule` | Lasna testnet (5318007) | Subscribes to the feed's AnswerUpdated events + a CRON tick; checks each new price against the rule; requests the execution callback when the condition is met |
| `MockSwap` + `MockUSDC` | Base Sepolia (84532) | The swap turns ETH into MockUSDC at the live Chainlink price; MockUSDC is a demo token with 6 decimals like real USDC |

**About MockUSDC — stated plainly:** it is a demo token with NO real
value. There is no real USDC swap on a testnet, so the demo shows the funds
visibly changing from ETH into a dollar token at the real Chainlink price.
The swap reads the same live feed as the rule, so the amount the owner
receives is priced exactly where the trigger fired. The token can only be
minted by the swap, and only the vault can ask the swap to mint.

**What the watcher can and cannot do:**

- It **cannot** move funds by itself. Only the vault can, and only through
  Reactive's official callback proxy, and only when the live price proves
  the rule's condition is really met.
- It **cannot** be triggered by a stranger: the vault accepts `executeRule`
  only from the callback proxy, and only when the proxy says the request
  came from this exact reactive contract.
- The owner can change the rule any time before it fires. After it fires,
  the vault is finished — it holds nothing and accepts nothing more.
- A second callback for the same rule is harmless: the vault refuses to
  execute twice, so a retry after a successful execution just reverts.

### A note on time

Everything price-based is measured in **timestamps** (wall-clock seconds),
never block numbers — the event's ground rule for Base Sepolia. This
project keeps no time-based state of its own; it only reacts to price
events and clock ticks.

## Values used — all from the official docs

- Lasna testnet: chain ID **5318007**, RPC `https://lasna-rpc.rnk.dev/`,
  explorer `https://lasna.reactscan.net/`, currency lREACT.
- Base Sepolia: chain ID **84532**, RPC `https://sepolia.base.org`,
  explorer `https://sepolia.basescan.org`.
- System contract (Lasna and mainnet): **0x8888888888888888888888888888888888888888**.
- Legacy system contract (emits the Cron events): **0x0000000000000000000000000000000000fffFfF**.
- Base Sepolia callback proxy: **0x476F44b11F5C942c58f4c8E3d0300E5710743585**.
- CRON topic used: Cron100 `0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70`
  (~every 100 blocks, ~2 minutes on Lasna).
- Chainlink ETH/USD feed (Base Sepolia): `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`.
- Library: `Reactive-Network/reactive-lib-omni` v0.1.0 — the current Omni
  library matching the docs (`AbstractReactive`, `AbstractCallback`,
  `requestCallbackV_1_0`). The older legacy `reactive-lib` v0.2.0 (RVM-style)
  was NOT used — it does not match the current docs.

Docs pages used: dev.reactive.network (Getting Started, Reactive Contracts,
Reactive Mainnet / Lasna Testnet, Callback Contracts, Origins &
Destinations, Demos, Cron Demo), docs.chain.link (Data Feeds API Reference,
Using Data Feeds on EVM Chains), and the Firebase AI Logic pattern from
the Privacy Firewall project.

## Money and fees — read this before deploying

- **Nothing here costs real money.** Both chains are testnets; only test ETH
  and test lREACT are involved.
- The **vault pays for the execution callback** in ETH (Reactive bills the
  recipient on the destination chain). Keep a small extra ETH reserve in
  the vault above the rule amount, or the vault will end up in debt after
  the execution. The vault is single-use, so that debt has no further
  effect, but the reserve is the clean way.
- The **reactive contract pays for its own subscriptions and ticks** in
  lREACT. Fund it with a small amount after deploy.
- **lREACT faucet (from the docs, CONFIRMED LIVE 2026-11-11 by the dead
  man's switch deploy):** send SepETH to Ethereum Sepolia
  `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` or Base Sepolia
  `0x2afaFD298b23b62760711756088F75B7409f5967`; **do NOT send more than 5
  ETH in one transaction (amounts above 5 ETH are lost)**. Live we received
  2.625 lREACT for 0.025 SepETH (105 per ETH).
- **Do not mix mainnet and testnet.** Testnet origin (Lasna) goes only to a
  testnet destination (Base Sepolia).

## Testnet funds — checked live 2026-11-11

The shared deployer wallet `0x791F80c3425beD85E86202571e276dF5B1339166`
(the fresh throwaway wallet made for the dead man's switch deploy) holds:

- Sepolia ETH: **0.00462**
- Base Sepolia ETH: **0.00899**
- Lasna lREACT: **1.52007**

Is that enough for this deploy? **Yes, but tight.** Deploying the three
Base Sepolia contracts costs well under 0.001 ETH in gas, and the default
demo deposit is 0.005 ETH (not 0.01 — the deploy script was set to 0.005
for exactly this reason), so the Base Sepolia side fits with a small
margin. The Lasna side fits too: the reactive deploy plus a 0.3–0.5 lREACT
funding leaves room. If a bigger demo deposit is wanted, or the lREACT
runs low, one more Google Cloud faucet claim (0.05 Sepolia ETH per day)
topped up and bridged covers it — no real money either way.

## Build and test (done — all green)

```bash
cd plain-english-automations
forge build   # Solc 0.8.29, via foundry.toml
forge test    # 24 tests, 24 passed
```

Tests prove, locally with a mock price feed standing in for Chainlink:

- Vault: the rule records the live baseline; no trigger before the
  threshold; trigger at exactly the threshold (drop) and beyond; a drop
  does not trigger a rise rule and a rise does not trigger a drop rule;
  execution reverts for anyone except the callback proxy; execution reverts
  before the threshold; execution moves the deposit into MockUSDC at the
  feed price (checked to the exact unit); execution works only once; the
  rule can be replaced before execution; the swap math is exact.
- Reactive: `react()` reverts for anyone except the system contract; a
  price event below the threshold requests nothing; a price event at the
  threshold requests exactly one callback to the vault calling
  `executeRule(address)`; a price event from any other contract is
  ignored; a rise rule fires on a rise and not on a drop; a CRON tick
  retries until the vault's Executed event confirms the job, then stops.

Two honest rounding notes from the tests: a rise of "exactly 10%" does not
quite clear a 10% bar in integer math, because `(baseline * 110) / 100`
rounds down a hair below the true 10% — the tests use 11% for the rise
case. The drop case clears exactly. This is a property of integer math,
not a bug in the rule.

## Deployed — live on testnet (2026-11-11)

Deployer (fresh throwaway wallet, key only in the dead-man's-switch
project's `.env`): `0x791F80c3425beD85E86202571e276dF5B1339166`.
All funds testnet only.

| Contract | Chain | Address |
|---|---|---|
| `PlainEnglishRule` (main) | Lasna testnet | `0x97fcd301f901f130c9e8aa77b92cc8c1be091949` |
| `RuleVault` (main) | Base Sepolia | `0x1f5fd7319e2204dd6f7a5b60e0108b60b992db50` |
| `MockUSDC` (main) | Base Sepolia | `0x5fa52de23aa1a37b14a1232cd32aecc801e4fac6` |
| `MockSwap` (main) | Base Sepolia | `0xa60a3921e1e49dc476da2480a4dccd7f63da0bb1` |
| `PlainEnglishRule` (demo) | Lasna testnet | `0xC4B7Ee9FF37906b519Ed2B7dcF3A1399806c6DD5` |
| `RuleVault` (demo) | Base Sepolia | `0xC4B7Ee9FF37906b519Ed2B7dcF3A1399806c6DD5` |

Main pair: drop rule, 10% threshold, baseline $2,081.33, vault holds
0.005 ETH, rule funded with 0.3 lREACT. Demo pair: drop rule, 0.1%
threshold, same $2,081.33 baseline, vault holds 0.001 ETH. The demo pair
is armed and waiting on a real 0.1% ETH price drop (trigger at or below
$2,079.25); a monitor polls the feed every 60 seconds. Full deploy state
and every transaction hash: `DEPLOY_STATUS.md`.

## Deploy order (run 2026-11-11)

1. Reactive contract on Lasna: `forge script script/DeployRule.s.sol
   --rpc-url lasna --broadcast` (env: `PRIVATE_KEY`, `DIRECTION`,
   `THRESHOLD_BPS`, `BASELINE_PRICE` — 0 is fine, set the rule later).
   Fund it with ~0.3–0.5 lREACT afterwards.
2. Vault + MockUSDC + MockSwap on Base Sepolia:
   `forge script script/DeployVault.s.sol --rpc-url base-sepolia
   --broadcast` (env: `PRIVATE_KEY`, `REACTIVE_ADDRESS`, `DIRECTION`,
   `THRESHOLD_BPS`, `DEPOSIT_ETH` — default 0.005). This also sets the
   rule on the vault, reading the live feed price as the baseline.
3. Link them: `forge script script/SetVault.s.sol --rpc-url lasna
   --broadcast` (env: `PRIVATE_KEY`, `RULE_ADDRESS`, `VAULT_ADDRESS`).
   It reads the rule from the vault itself over the Base Sepolia RPC, so
   the two contracts can never disagree about the baseline.
4. Live trigger test: use a **separate demo pair with a tiny threshold**
   (for example 10 basis points = 0.1%), so a real small price move fires
   the rule within minutes. The main pair keeps the real threshold (10%).
   Never re-point the main reactive contract at the demo vault: its
   executed flag is one-way, so a demo execution would permanently retire
   it — same lesson as the dead man's switch deploy.

## Frontend

`frontend/index.html` is a single page: connect wallet, type the rule in
plain English, ask Gemini live and check the settings it understood, save
the rule (vault on Base Sepolia, then the watcher on Lasna), deposit, and
a status readout (rule, baseline price, live price, move from baseline,
triggered or not, executed or not). The deployed main addresses are
already pasted into `VAULT_ADDRESS` / `RULE_ADDRESS`. The page uses the Firebase
CDN (v13.0.0) and ethers v6 from a CDN — no build step.

## Still to do

- [x] Deploy to Lasna + Base Sepolia (testnet only) — done 2026-11-11.
- [ ] Live trigger test with a demo pair at a 0.1% threshold — the demo
      pair is armed and a monitor is polling the feed every 60 seconds;
      fires on a real 0.1% price drop, with no manual call.
- [ ] Demo video (under 3 minutes) showing the typed sentence, the AI's
      parsed settings, and the rule firing on its own.
- [ ] Publish the repo on GitHub with an open-source licence (Apache-2.0
      LICENSE is already in this folder).
- [ ] Submit on DoraHacks with the repo, the demo video, and the on-chain
      transaction hashes.

## Note on `lib/`
`lib/forge-std` and `lib/reactive-lib-omni` are vendored here as plain files (not git submodules), so the repo publishes cleanly.
