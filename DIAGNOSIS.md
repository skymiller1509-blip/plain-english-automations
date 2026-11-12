# Diagnosis — why the plain-English automations demo rule never fired

Date: 2026-11-11 ~22:35 WAT (21:35 UTC). Read-only investigation only.
No transaction was sent, no contract state was changed, nothing was redeployed, nothing was spent.

## Verdict in one line

**The rule subscribed to price events from the Chainlink PROXY contract
(`0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`), but `AnswerUpdated` events
are emitted by the underlying AGGREGATOR contract
(`0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3`). The proxy never emits them.
The subscription can therefore never match, `react()` never receives a
price, `lastPrice` stays 0 forever, and the CRON backstop — which only
re-checks the last observed price — can never trigger either.**

Both price drops that should have fired the demo rule were emitted by the
aggregator (proven below). The vault side is healthy: its own
`isTriggered()` returns `true` right now. The rule just never learns the
price.

A second, separate anomaly was also found (see §5): the MAIN rule lost its
CRON-tick delivery the moment the demo rule was deployed, which strongly
suggests identical subscription triples collide in the subscription
service (only the latest subscriber keeps receiving). The fix must be
order-aware (see §7).

---

## 1. Stored state — what the contracts say right now

All values below were read live with `cast call` (Lasna
`https://lasna-rpc.rnk.dev`, Base Sepolia `https://sepolia.base.org`).

### Demo rule, Lasna `0xC4B7Ee9FF37906b519Ed2B7dcF3A1399806c6DD5`
| Field | Value | Verdict |
|---|---|---|
| `vault()` | `0xC4B7Ee9FF37906b519Ed2B7dcF3A1399806c6DD5` | correct |
| `direction()` | `0` (drop) | correct |
| `thresholdBps()` | `10` (0.1%) | correct |
| `baselinePrice()` | `208132812667` ($2,081.33) | correct |
| **`lastPrice()`** | **`0`** | **SMOKING GUN — no price event ever delivered** |
| `executed()` | `false` | not fired |
| `cronTopic()` | `0xb49937fb…1503c70` (Cron100) | correct |
| `owner()` | `0x791F80c3425beD85E86202571e276dF5B1339166` | correct |
| lREACT balance | `0.0545` (was ~0.288 at 22:00 WAT) | being spent on CRON-tick executions |

### Demo vault, Base Sepolia (same address)
| Field | Value | Verdict |
|---|---|---|
| `ruleSet()` | `true` | correct |
| `direction()` / `thresholdBps()` / `baselinePrice()` | `0` / `10` / `208132812667` | match the rule exactly |
| `executed()` | `false` | not fired |
| **`isTriggered()`** | **`true`** | **the condition IS met right now** |
| `moveBps()` | `-19` (price fell 0.19%, threshold is 0.1%) | past the line |
| `currentPrice()` | `207731918501` ($2,077.32) | live feed |
| ETH balance | `0.001` | intact, unmoved |

### Main rule, Lasna `0x97fcd301f901f130c9e8aa77b92cc8c1be091949`
Same story: `direction 0`, `thresholdBps 1000` (10%), `baselinePrice
208132812667`, **`lastPrice() = 0`**, `executed() = false`,
`cronTopic()` = Cron100, lREACT balance exactly `0.3` (unspent).
**The main pair has the same bug and would also never fire.**

## 2. The trigger math — the rule SHOULD have fired

Drop rule fires when `price * 10000 <= baseline * (10000 - threshold)`:
`208132812667 * 9990 / 10000 = 207924679854` ($2,079.25).
Live price `207731918501` ($2,077.32) is below that, and the vault's own
`isTriggered()` confirms `true`. Nothing is wrong with the numbers, the
threshold, or the direction.

## 3. Proof the price events exist — and who emits them

Chainlink ETH/USD feed on Base Sepolia, proxy
`0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` (8 decimals, "ETH / USD").
`proxy.aggregator()` = `0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3`
(`phaseAggregators(1)` returns the same address, `phaseId() = 1`).

Round history from the aggregator's `getRoundData`:
| Round | Answer | Updated at (UTC) |
|---|---|---|
| 292157 | `208132812667` ($2,081.33, the baseline) | 20:56:24 |
| 292158 | `207784350000` ($2,077.84) | 21:01:23 |
| 292159 | `207731918501` ($2,077.32) | 21:21:43 |

The two `AnswerUpdated` events (topic0
`0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f`):

| Block | Tx | Emitter | topic1 (price) |
|---|---|---|---|
| 57545073 | `0x5793e2b9d3734487b93201945a255b99d72c766669fe39af9b1d0914dda7f678` | **`0xa24A68DD…` (aggregator)** | `0x3060e99130` = 207784350000 |
| 57551174 | `0x235a919a6acbc9d3706529b81085538502ce15b5b7dbcd0d49cf0219629828a1` | **`0xa24A68DD…` (aggregator)** | `0x305dc986a5` = 207731918501 |

**The proxy (`0x4aDC67…`) emitted ZERO `AnswerUpdated` events** in every
window scanned (blocks 57553000–57554407 and the two drop windows). The
OCR transmitters call `transmit()` on the aggregator directly; the proxy
is only a read path (`latestRoundData` works through it — which is why the
vault's price reads are fine and why the scaffold's "verified live" check
passed while missing the emitter).

The rule's subscription is
`SYSTEM.subscribe(84532, FEED /* the proxy */, ANSWER_UPDATED_TOPIC_0, …)`
(`src/PlainEnglishRule.sol`, `_subscribeToFeed()`), and `react()` additionally
requires `log_.contractAddress == FEED` (the proxy). Both the subscription
and the in-contract check point at an address that never emits the event.

### How the scaffold missed it
The scaffold report says "Verified live with cast: the feed's latest
updates carry this topic." That verified the topic0 hash and that the feed
returns prices — but never checked **which address** emits the events. The
topic was right; the emitter was wrong.

## 4. Proof the rest of the delivery path works

Lasna event logs for the demo rule (`cast logs`, deploy block → latest):

| Event | Topic0 | Count | Meaning |
|---|---|---|---|
| `RuleChecked(int256,int256,bool)` | `0xdeeca078…` | **20** | CRON ticks ARE arriving; `react()` IS running — every one with `price = 0, triggered = false` |
| `PriceObserved(int256,uint256)` | `0x7737bc8b…` | **0** | no price event ever delivered |
| `ExecutionRequested(address,int256,uint256)` | `0xf536c290…` | **0** | no callback ever requested |

The 20 `RuleChecked` events land at blocks 8111901, 8112001, … 8113901 —
every 100 blocks, i.e. every Cron100 tick. The lREACT balance falling
0.288 → 0.0545 is the gas cost of those ~20 executions (~0.012 each).
So: subscriptions to the CRON clock work, `react()` runs, the backstop
runs — it just has no price to check (`lastPrice = 0` → `isTriggered(0)`
returns false by the `price_ <= 0` guard).

The vault's `executeRule` re-check logic is NOT the blocker either: it was
never called (no callback was ever requested), and its own `isTriggered()`
returns `true`, so it would accept a callback right now.

## 5. Second anomaly: the MAIN rule lost its CRON delivery (collision hypothesis)

| Contract | CRON triple | RuleChecked events |
|---|---|---|
| Demo rule | (Lasna, legacy system, Cron100) | 20, still ticking (latest 8113901) |
| Main rule | (Lasna, legacy system, Cron100) — **identical** | **1 ever**, at block 8111801, then silence |
| Main switch (dead man's switch) | (Lasna, legacy system, Cron1000) — different | still ticking (`CronChecked` at 8113001, 8114001) |

Timeline:
- Block 8111739: main rule deployed (subscribes Cron100 + feed-proxy).
- Block 8111792: main `setVault` + `setRule`.
- Block 8111801: main rule receives its first (and only) Cron100 tick.
- Block 8111803: main rule funded (0.3 lREACT — still exactly 0.3 now,
  i.e. `react()` has not run for it since).
- Block 8111844: demo rule deployed, subscribing to the **identical**
  Cron100 triple (and the identical feed triple).
- Block 8111901 onward: demo rule receives every Cron100 tick; main rule
  receives none.

Best-fit explanation: **identical subscription triples collide — only the
latest subscriber keeps receiving deliveries.** The CRON system itself is
healthy (the switch, on a different triple, keeps ticking). This is a
HYPOTHESIS, not directly observable: `ISubscriptionService` exposes only
`subscribe`/`unsubscribe` — there is no query function to read the registry
(`lib/reactive-lib-omni/src/interfaces/ISubscriptionService.sol`), and the
system contract (`0x8888…8888`) exposes no subscription-listing view in its
interface. But the timing (main ticked until the demo subscribed, then
never again) plus the control (switch on a different triple unaffected)
makes it the strongest explanation available.

**Why it matters for the fix:** if the hypothesis is right, redeploying
both rules with the same feed triple would leave only the LAST-deployed
rule receiving price events. The fix must be order-aware (see §7).

## 6. What is NOT broken (checks that passed)

- ✅ Contract code compiles; `forge test` 24/24 pass (local mock-feed tests).
- ✅ Deployments and linking are correct on both chains; rule/vault
  settings match exactly (direction, threshold, baseline).
- ✅ Vault price reads work (proxy `latestRoundData` is correct).
- ✅ CRON subscription + `react()` execution work (demo rule: 20 ticks).
- ✅ Funding is sufficient for the demo rule (0.0545 lREACT left, ~4 more
  ticks' worth at current burn — but ticks alone can never fire it).
- ✅ The vault would accept a callback right now (`isTriggered() = true`).
- ❌ Feed subscription points at the proxy, which never emits
  `AnswerUpdated`. (Root cause.)
- ❌ Main rule's CRON delivery stopped after the demo rule deployed.
  (Secondary anomaly, collision hypothesis.)

## 7. The fix

### 7.1 Code change (required, in `src/PlainEnglishRule.sol`)
1. Stop subscribing to the **proxy**. Subscribe to the **aggregator**
   address (`0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3`, read from the
   proxy's `aggregator()` / `phaseAggregators(phaseId())` at deploy time).
2. Change `react()`'s price-branch check from `log_.contractAddress == FEED`
   to `log_.contractAddress == aggregator`.
3. Make the aggregator a state variable with an owner-only
   `setAggregator(address)` (and re-subscribe on change), so a future
   Chainlink aggregator rotation doesn't silently break the rule again.
   Keep the proxy address for nothing event-related; the vault keeps
   reading prices through the proxy (that path is correct).
4. Differentiate the CRON triples so the two rules can't collide: e.g.
   main rule on Cron1000, demo rule on Cron100 (the CRON tick is only a
   backstop; the price events do the real work).
5. Optional hardening: on the first CRON tick after deploy, if
   `lastPrice == 0`, the rule cannot know the price — consider having the
   deploy script seed `lastPrice` via a setter, or accept that the first
   price event after deploy is what arms the backstop.

### 7.2 Redeploy (required — the existing contracts cannot be fixed in place)
- There is **no function to add or change the feed subscription** on a
  deployed rule (only `setVault` re-subscribes vault events). The
  subscription is made once, in the constructor.
- The vault's `_CALLBACK_SENDER` is `immutable`
  (`lib/reactive-lib-omni/src/base/AbstractCallback.sol:18`), set at
  construction to the rule's address. A new rule therefore needs a **new
  vault**; the old vaults can never execute.
- **Order matters (collision hypothesis): redeploy the DEMO pair first**,
  verify it fires, film the demo video, **then deploy the MAIN pair
  last** so the main rule is the latest subscriber to the shared feed
  triple. After the main deploy, verify the main rule receives the next
  price event (`lastPrice() > 0`, `PriceObserved` event) before calling
  the fix complete. If the main rule again receives nothing while the demo
  keeps ticking, the collision is confirmed and the demo rule's
  subscription is shadowing it — the demo pair should then be left as is
  (its firing is already recorded) and the main pair stands as the live
  subscriber.
- `MockSwap` / `MockUSDC` are standalone and can be **reused** (pass the
  existing addresses to the new vaults) to save gas; only rule + vault
  need redeploying.

### 7.3 Cost estimate (testnet funds only, nothing real)
Current deployer balances (checked live):
Sepolia `0.00462` ETH · Base Sepolia `0.002948` ETH · Lasna `0.5528` lREACT.
Stranded (unrecoverable — no withdraw function) in the old contracts:
old demo vault `0.001` ETH, old main vault `0.005` ETH, old rules
`0.3 + 0.0545` lREACT.

Per pair (from the first deploy's actuals: two vaults + two token/swap
deploys + 0.006 ETH deposits cost 0.00604 Base Sepolia ETH total, i.e.
deploy gas on Base Sepolia is ~0.00002 ETH per contract):
- Lasna: rule deploy + `setVault` + `setRule` + `0.3` lREACT funding.
  Two pairs ≈ `0.6` lREACT funding + deploy gas (paid from deployer
  balance; first deploy's Lasna gas was small vs. the funding).
  Have `0.5528` — **short ~0.05 lREACT** for full 0.3 + 0.3 funding.
  Top up by minting lREACT: send `0.001` SepETH to the faucet address
  `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` → ~0.1 lREACT
  (rate observed: 105 lREACT/ETH). Or fund each rule with `0.2` lREACT
  instead of 0.3 (plenty: the demo rule burned only ~0.24 lREACT over
  ~35 min of ticks; a rule that fires promptly needs far less).
- Base Sepolia: 2× vault deploy (~0.00002 ETH gas each, reusing
  MockSwap/MockUSDC) + deposits. At the original deposit sizes
  (main `0.005` + demo `0.001` = `0.006` ETH) the deployer needs
  ~`0.0061` ETH and has `0.002948` — **short ~0.0032 ETH**. Bridge
  `0.0035` SepETH → Base Sepolia (have `0.00462` SepETH, leaving
  `0.0011` for the lREACT mint above). **Or** reduce deposits for the
  re-test (main `0.002` + demo `0.001` = `0.003` ETH): then the
  `0.002948` on hand + a `0.001` SepETH bridge covers it with room to
  spare. Deposit size does not affect proving the loop.
- Cheapest comfortable path: bridge `0.0035` SepETH, mint `0.001` SepETH
  → lREACT, keep deposits at `0.005`/`0.001`. Total new spend ≈
  `0.0045` SepETH + ~`0.6` lREACT funding (recycled through the new
  rules) + negligible gas. If a fresh Google Cloud faucet claim
  (`0.05` SepETH/day) is available on 2026-11-12, that removes every
  constraint.

### 7.4 Verification checklist after the fix
- [ ] New demo rule: `lastPrice() > 0` after the next feed update.
- [ ] New demo rule: `PriceObserved` event appears on Lasna.
- [ ] New demo rule fires on a ≤0.1% move: `ExecutionRequested` on
  Lasna, callback tx on Base Sepolia, vault `executed() = true`,
  MockUSDC minted to the owner.
- [ ] New main rule (deployed last): `lastPrice() > 0` after the next
  feed update — proves it holds the shared feed subscription.
- [ ] Both rules still receiving CRON ticks (`RuleChecked` events
  keep appearing for each; if the main stops again, the collision is
  confirmed — see §5).

## 8. Evidence index (all read live, no transactions sent)
- Demo rule state: `lastPrice() = 0`, `baselinePrice() = 208132812667`,
  `thresholdBps() = 10`, `executed() = false`, balance `0.0545` lREACT.
- Demo vault state: `isTriggered() = true`, `moveBps() = -19`,
  `currentPrice() = 207731918501`, balance `0.001` ETH.
- Price update 1: Base Sepolia block 57545073, tx
  `0x5793e2b9d3734487b93201945a255b99d72c766669fe39af9b1d0914dda7f678`,
  emitter `0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3`, price
  `207784350000`, round 292158.
- Price update 2: Base Sepolia block 57551174, tx
  `0x235a919a6acbc9d3706529b81085538502ce15b5b7dbcd0d49cf0219629828a1`,
  emitter `0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3`, price
  `207731918501`, round 292159.
- Proxy `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`: zero
  `AnswerUpdated` events in all windows scanned.
- Lasna demo rule events: 20× `RuleChecked` (price 0), 0×
  `PriceObserved`, 0× `ExecutionRequested`.
- Lasna main rule events: 1× `RuleChecked` (block 8111801), 0×
  `PriceObserved`.
- Lasna main switch (control, Cron1000): `CronChecked` at 8113001, 8114001.
- `ISubscriptionService` has no subscription-query function, so the
  registry itself could not be read; all subscription conclusions are
  from emitted-event evidence.
