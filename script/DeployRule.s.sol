// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.29;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { PlainEnglishRule } from "../src/PlainEnglishRule.sol";

/// @notice Deploys the reactive contract on Lasna testnet (chain 5318007).
/// @dev Run: forge script script/DeployRule.s.sol --rpc-url lasna --broadcast
/// Env: VAULT_ADDRESS (optional, 0x0 to deploy first and set it later),
/// AGGREGATOR (the Chainlink aggregator behind the FEED proxy — read it
/// from the proxy's aggregator() with cast BEFORE deploying and confirm
/// it matches; default is the value verified live 2026-11-11),
/// DIRECTION (0 = drop, 1 = rise, default 0), THRESHOLD_BPS (default 1000
/// = 10%), BASELINE_PRICE (default 0 — set the rule afterwards with
/// SetRule, or pass the live feed price here).
/// After this, deploy the vault + swap on Base Sepolia (DeployVault.s.sol),
/// then point this contract at it with SetVault.s.sol.
/// Fund the rule contract with lREACT afterwards so it can pay for its
/// subscriptions and callbacks (Reactive bills reactive contracts).
contract DeployRule is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vault = vm.envOr("VAULT_ADDRESS", address(0));
        address aggregator = vm.envOr(
            "AGGREGATOR",
            address(0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3)
        );
        uint8 direction = uint8(vm.envOr("DIRECTION", uint256(0)));
        uint256 thresholdBps = vm.envOr("THRESHOLD_BPS", uint256(1000));
        int256 baselinePrice = int256(vm.envOr("BASELINE_PRICE", uint256(0)));

        vm.startBroadcast(deployerKey);
        PlainEnglishRule rule = new PlainEnglishRule(
            vault,
            aggregator,
            direction,
            thresholdBps,
            baselinePrice,
            // Cron100 topic from the docs (same value as the contract's
            // CRON100_TOPIC_0 constant).
            0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70
        );
        vm.stopBroadcast();

        console.log("PlainEnglishRule (Lasna):", address(rule));
        console.log("aggregator:", aggregator);
        console.log("direction:", direction);
        console.log("thresholdBps:", thresholdBps);
    }
}
