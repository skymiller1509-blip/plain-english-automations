# Deploy status — 2026-11-11 ~22:00 WAT: DEPLOYED, waiting on a real price move

## Funding (shared deployer wallet from the dead man's switch deploy)
- Deployer (fresh throwaway, key ONLY in the dead-man's-switch project's
  `.env`, mode 600, gitignored):
  `0x791F80c3425beD85E86202571e276dF5B1339166`
- Balances BEFORE this deploy: Sepolia 0.00462 ETH | Base Sepolia 0.00899 ETH
  | Lasna 1.52007 lREACT.

## Main pair (Track 3 entry) — LIVE
- **Rule (Lasna): `0x97fcd301f901f130c9e8aa77b92cc8c1be091949`**
  Deploy tx: `0xca2b50a3fcd72c2184b6b309cb749ff8d4f1bf806d0df9c52c843745aeb12cd9`
  Direction drop (0), threshold 1000 bps (10%), baseline read from the vault.
  Funded with 0.3 lREACT.
  Fund tx: `0xe9f2ff704a8851f4f01405fe1b114311fe93d6309cecbc09968eb8a5f4e6010d`
- **Vault (Base Sepolia): `0x1f5fd7319e2204dd6f7a5b60e0108b60b992db50`**
  Deploy tx: `0xe0dd4321280c31f005bbd172e52bb6ea186bc6e14c7585f7bdfc407092ba1c12`
  Deposit 0.005 ETH, direction drop, threshold 1000 bps.
  Baseline recorded from the live feed at deploy: **208132812667
  ($2,081.33)**.
- **MockUSDC (Base Sepolia): `0x5fa52de23aa1a37b14a1232cd32aecc801e4fac6`**
  Deploy tx: `0xad53b9f59d1e25c2c83e5782eede04a67866138b7b54ba94b2c219def37f2b3f`
- **MockSwap (Base Sepolia): `0xa60a3921e1e49dc476da2480a4dccd7f63da0bb1`**
  Deploy tx: `0xdeb6277d3c9b3ed1a48d6f4fa2d85ddd565c1336efbbe30730d343e6a82a76e6`
- **Link txs (SetVault on Lasna):**
  setVault: `0xa385090ba49b0d1c3792ce958a36875a0be2f76db80ef4d3caea4502eb075120`
  setRule: `0x294ce1acfcb7d715e04debb800787fdee9e9f4aab92df28114bb047e9af93b35`
- Verified on-chain: rule vault/direction/threshold/baseline all match the
  vault exactly (baseline 208132812667 on both); vault ruleSet=true,
  executed=false, balance 0.005 ETH; rule balance 0.3 lREACT.

## Demo pair (separate rule + vault, 0.1% threshold) — ARMED, NOT FIRED YET
- **Demo rule (Lasna): `0xC4B7Ee9FF37906b519Ed2B7dcF3A1399806c6DD5`**
  Deploy tx: `0x4a62a071b235c381113dabd94ef80043ad4c69bb291ebf09f6d915cd9f33ff11`
  Direction drop (0), threshold **10 bps (0.1%)**, baseline 208132812667.
  Funded with 0.3 lREACT.
  Fund tx: `0x27f5f5092bdefb71d253de291e82dd2348a366e4ca0394a6bd98b2d7a0b58434`
- **Demo vault (Base Sepolia): `0xC4B7Ee9FF37906b519Ed2B7dcF3A1399806c6DD5`**
  (same address as the demo rule — same deployer nonce on both chains)
  Deploy tx: `0x66c08534fe627f55e43bd948c710e9669a61308f6c7f78f2fd7da8e44222382f`
  Deposit 0.001 ETH.
- **Demo MockUSDC (Base Sepolia): `0x659D783842fA76A901AcA87a13852D3EbBA2B0A5`**
  Deploy tx: `0x3f083e8faf636b9deabe285d79390dc5c965c86386f98dbb507b06da2878c306`
- **Demo MockSwap (Base Sepolia): `0xBd6Fdb04a4AE6493b376F114064FE70b45c9FCA8`**
  Deploy tx: `0x0b5149a222bf00839e05308d7e3e68f57286bde4ee4e5f228a1f8b7e871c06b1`
- **Demo link txs (SetVault on Lasna):**
  setVault: `0x131aeca11339c9403157121f5ae97d16971950f163ce85ad6492f39afde10163`
  setRule: `0x9d583448db25f7496874d23a7b3fea5a7e9b5a3272a63cce84d0c3f3600f1cc9`
- Verified on-chain: demo rule vault/threshold/baseline correct;
  demo vault executed=false, balance 0.001 ETH; demo rule balance
  ~0.288 lREACT.
- **Trigger price: at or below 207924679854 ($2,079.25)** — a 0.1% drop
  from the $2,081.33 baseline.
- **The wait:** the feed moves on a 0.15% deviation or a ~20-minute
  heartbeat. A monitor (`demo/monitor.sh`, log `demo/monitor.log`) polls
  the feed price and both executed flags every 60 seconds for up to
  90 minutes and stops the moment the demo vault fires. First poll
  2026-11-11T21:00:17Z: price 208132812667 (exactly the baseline),
  vault_executed=false, rule_executed=false.

## Final balances (2026-11-11 ~22:00 WAT, after both deploys)
- Deployer: Sepolia 0.00462 ETH (untouched) | Base Sepolia 0.002948 ETH
  | Lasna 0.5528 lREACT (checked live 2026-11-11 ~22:01 WAT)
- Main vault 0.005 ETH | main rule 0.3 lREACT
- Demo vault 0.001 ETH | demo rule ~0.288 lREACT

## REDEPLOY — demo pair only (2026-11-11 ~22:06–22:09 WAT), after the aggregator fix
Root cause (DIAGNOSIS.md): the rule subscribed to the Chainlink PROXY,
which never emits AnswerUpdated; the events come from the AGGREGATOR.
Fix in src/PlainEnglishRule.sol: the rule now subscribes to the
aggregator (read from the proxy's aggregator() at deploy time, verified
live: 0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3), react() checks the
aggregator address, and setAggregator(address) re-subscribes on change.
The vault is unchanged (it reads prices through the proxy, which is
correct for reads). Tests: 27/27 pass (was 24/24; 3 new tests incl. a
regression test proving proxy events are ignored).
- Funding (testnet only): bridge 0.0035 SepETH Sepolia -> Base Sepolia,
  tx 0x1b427901ba53ca00d87963131d68769b46616fe32deb1d414f1931b4cca20479
  (landed ~22:07:58Z, balance 0.002948 -> 0.006448 ETH); mint 0.001
  SepETH -> ~0.105 lREACT, tx
  0xf65ab5bb63679ce1fda7c602ce6df7853e5852d7074a70a4dde8e95942ebd373
  (Lasna 0.5528 -> 0.6578 lREACT). Sepolia left: ~0.000122 ETH.
- **New demo rule (Lasna): `0xa2e6f1d03e43193085f4d986f3c786e8029ad109`**
  Deploy tx: `0x05e753fbad05c9b6da6784c71e87d69b03ccf5f839eb25936d9fbc54dadbd946`
  (block 8115543). Direction drop (0), threshold **10 bps (0.1%)**,
  Cron100. aggregator() verified on-chain = the address above.
  Funded with 0.2 lREACT, tx
  `0x86143297535d10ef749d57f02d591d4b9bc86f09882826445fa2b0e3e07a0482`.
  NOTE: the deploy script inherited VAULT_ADDRESS from the shared
  deployer .env, so the rule was briefly pointed at the dead man's
  switch vault; setVault below re-pointed it correctly. No funds moved.
- **New demo vault (Base Sepolia): `0xa2e6f1d03e43193085f4d986f3c786e8029ad109`**
  (same address again — same deployer nonce on both chains)
  Deploy tx: `0x65bec93d18de186d8fbef7b6e1d66245c833218a401d8b70db4c8289f12df54f`
  Deposit 0.001 ETH. Reused demo MockUSDC
  0x659D783842fA76A901AcA87a13852D3EbBA2B0A5 and demo MockSwap
  0xBd6Fdb04a4AE6493b376F114064FE70b45c9FCA8 (swap re-pointed at the new
  vault, tx 0x4e7b33c278bc1c4fab658fc5125fb55e68875e9554396217abe499d9aae2b966;
  setRule tx 0x1172d127caa0830ff9ea6c54c6281c80621fd41a12cf79ad915a9b2bfcc25e2c).
  Baseline recorded from the live feed at deploy: **206853376574
  ($2,068.53)**.
- **Link txs (SetVault on Lasna):**
  setVault: `0xbd8d0d4f914d90fa49e310308e9fcca8f4428bc814c1e6c0bc84d81659ae51f1`
  setRule: `0x2416163ee2320729583f0034ad52ac596fdf10815e416dbba1b34794dcf8f467`
- Verified on-chain: rule aggregator/direction/threshold/baseline all
  correct; vault ruleSet=true, executed=false, balance 0.001 ETH;
  swap.vault() = the new vault; rule balance 0.2 lREACT.
- **Trigger price: at or below 206646523197 ($2,066.47)** — a 0.1% drop
  from the $2,068.53 baseline.
- **The wait (new monitor `demo/monitor2.sh`, log `demo/monitor2.log`,
  polls every 60s, still running at 22:37Z):** the old monitor died with
  its parent session (~21:58Z) and its log was archived as
  `demo/monitor_old.log`.
  VERDICT after ~31 min of waiting (deploy ~22:06Z, last check 22:37Z):
  **the new demo pair has NOT fired — not because the trigger failed,
  but because the rule has never received a price event.**
  The price DID cross the trigger line: $2,068.53 -> $2,077.18 (up) ->
  $2,070.31 -> $2,066.03 at 22:32:40Z (below the $2,066.47 trigger) ->
  $2,062.40 at 22:36:00Z. The vault's own isTriggered() returns TRUE
  right now (moveBps -29, currentPrice 206240000000) — the vault would
  accept a callback this second. But the rule's lastPrice is STILL 0,
  PriceObserved 0, ExecutionRequested 0, vault executed=false, balance
  still 0.001 ETH, owner MockUSDC 0. Six aggregator rounds have passed
  since the redeploy and none reached the rule. A setAggregator()
  re-subscribe (same address) was tried at 22:32:16Z, tx
  0x9aa858dca07c9562de9447612ea309ef164d04925909088a3ad9d5f01ff704e7 —
  no delivery in the 5 minutes after it either.
  What IS proven: the aggregator subscription IS registered (deploy
  receipt shows the Subscribe event, chain 84532, contract =
  aggregator), and the rule got exactly ONE Cron100 tick (block
  8115601) then silence. The old demo rule's ticks also stopped (it ran
  out of lREACT: 0.0545 left / ~0.012 per tick = ~4 ticks, last at
  8114301) and the main rule (0.3 lREACT, unspent) has had no tick since
  8111801 — so after the redeploy, NOBODY on the Cron100 triple is
  receiving ticks except the new rule's single one, while the dead
  man's switch on Cron1000 keeps ticking (event at 8116001). The
  delivery routing for shared subscription triples is still not
  understood from on-chain data (the registry is not readable), and
  price-event delivery to the new rule has not happened in 31 minutes.
  The monitor keeps running (until ~23:39Z) — if the rule fires later,
  monitor2.log will show FIRED with the evidence. Next steps to
  consider: ask on the Reactive Discord / docs whether cross-chain log
  delivery has a known delay or a one-subscriber-per-triple rule, and
  whether a fresh Lasna-only test (a rule with NO other subscriber on
  its triples) delivers — the main pair must NOT be redeployed until
  the demo pair is proven to receive events.

## Still to do
- [ ] Live trigger test — waiting on a real 0.1% ETH price drop (monitor
      running). When it fires, record the tick/callback tx hashes here.
- [ ] Demo video (under 3 minutes) showing the typed sentence, the AI's
      parsed settings, and the rule firing on its own.
- [ ] Publish the repo on GitHub with an open-source licence.
- [ ] Submit on DoraHacks with the repo, the demo video, and the tx hashes.
- [ ] Frontend: paste the deployed main addresses into `frontend/index.html`
      (`VAULT_ADDRESS` / `RULE_ADDRESS`).

## Notes
- One transient Lasna RPC failure (TLS EOF) on the first DeployRule
  attempt; the retry succeeded. Nothing was sent twice — no transaction
  exists from the failed attempt.
- The main rule was NEVER re-pointed at the demo vault; the demo pair is
  fully separate. The main pair is untouched and still armed (10% drop).
- Nothing on mainnet, nothing real spent. All funds are testnet only.

## Morning live check — 2026-11-12 ~08:18 WAT (Mabel, read-only)
- Lasna latest block 8,146,832 — chain advancing, NOT stalled.
- New demo rule 0xa2e6f1d03e43193085f4d986f3c786e8029ad109: lastPrice still 0, aggregator() correct (0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3), lREACT balance 0.2 (funded).
- New demo vault (same address, Base Sepolia): executed=false, isTriggered()=true — would accept a callback right now.
- Rule events since deploy (block 8115543): 0 RuleChecked, 0 PriceObserved. ~9 hours, ETH down ~1.5% (15x the 0.1% trigger), nothing arrived.
- Control — dead man's switch CronChecked: 24 ticks in 8116001–8140000, 7 in 8140001–8146001, last at 8146001 (08:01 WAT). Switch ticks every ~1000 blocks as expected. So CRON delivery works in general; the silence is specific to this rule's subscriptions.
- Conclusion unchanged: delivery problem, not rule logic. Do NOT redeploy the main pair until the demo pair proves it receives events. Next steps: ask Reactive (Discord/docs) about cross-chain log delivery / one-subscriber-per-triple; try a fresh Lasna-only test rule with no other subscriber on its triples.
