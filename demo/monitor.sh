#!/bin/bash
# Polls the Chainlink feed price and the demo vault/rule executed flags.
# Stops as soon as the demo vault fires, or after 90 polls (~90 min).
RULE=0xC4B7Ee9FF37906b519Ed2B7dcF3A1399806c6DD5
FEED=0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1
CAST=/home/hatch/workspace/foundry/bin/cast
LOG=/home/hatch/workspace/hackathons/reactive/plain-english-automations/demo/monitor.log
: > "$LOG"
for i in $(seq 1 90); do
  PRICE=$($CAST call $FEED "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url https://sepolia.base.org 2>/dev/null | sed -n 2p | awk '{print $1}')
  VEXEC=$($CAST call $RULE "executed()(bool)" --rpc-url https://sepolia.base.org 2>/dev/null)
  REXEC=$($CAST call $RULE "executed()(bool)" --rpc-url https://lasna-rpc.rnk.dev/ 2>/dev/null)
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) price=${PRICE:-?} vault_executed=${VEXEC:-?} rule_executed=${REXEC:-?}" | tee -a "$LOG"
  if [ "$VEXEC" = "true" ]; then echo "FIRED at poll $i" | tee -a "$LOG"; break; fi
  sleep 60
done
echo "monitor done: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG"
