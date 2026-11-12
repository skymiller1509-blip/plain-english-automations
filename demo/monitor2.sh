#!/bin/bash
# Polls the Chainlink feed price and the NEW demo vault/rule executed flags.
# New demo pair (redeployed 2026-11-11 after the aggregator fix).
# Stops as soon as the new demo vault fires, or after 90 polls (~90 min).
RULE=0xa2e6f1d03e43193085f4d986f3c786e8029ad109
VAULT=0xa2e6f1d03e43193085f4d986f3c786e8029ad109
FEED=0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1
CAST=/home/hatch/workspace/foundry/bin/cast
LOG=/home/hatch/workspace/hackathons/reactive/plain-english-automations/demo/monitor2.log
: > "$LOG"
for i in $(seq 1 90); do
  PRICE=$($CAST call $FEED "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url https://sepolia.base.org 2>/dev/null | sed -n 2p | awk '{print $1}')
  VEXEC=$($CAST call $VAULT "executed()(bool)" --rpc-url https://sepolia.base.org 2>/dev/null)
  REXEC=$($CAST call $RULE "executed()(bool)" --rpc-url https://lasna-rpc.rnk.dev/ 2>/dev/null)
  LPRICE=$($CAST call $RULE "lastPrice()(int256)" --rpc-url https://lasna-rpc.rnk.dev/ 2>/dev/null)
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) price=${PRICE:-?} lastPrice=${LPRICE:-?} vault_executed=${VEXEC:-?} rule_executed=${REXEC:-?}" | tee -a "$LOG"
  if [ "$VEXEC" = "true" ]; then echo "FIRED at poll $i" | tee -a "$LOG"; break; fi
  sleep 60
done
echo "monitor done: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG"
