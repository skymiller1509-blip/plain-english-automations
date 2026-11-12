// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.29;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { PlainEnglishRule } from "../src/PlainEnglishRule.sol";
import { RuleVault } from "../src/RuleVault.sol";

/// @notice Points the Lasna reactive contract at the Base Sepolia vault
/// and mirrors the vault's rule onto it (direction, threshold, baseline).
/// @dev Run: forge script script/SetVault.s.sol --rpc-url lasna --broadcast
/// Env: PRIVATE_KEY, RULE_ADDRESS (the Lasna PlainEnglishRule),
/// VAULT_ADDRESS (the Base Sepolia RuleVault). The baseline price is read
/// from the vault itself over the Base Sepolia RPC, so the two contracts
/// can never disagree about it. Get the direction/threshold from the
/// vault too — this script copies all three values, it never asks you to
/// type them by hand.
/// @dev Forge scripts can read another chain with a fork: createFork +
/// selectFork, read, then switch back to the broadcast fork.
contract SetVault is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address ruleAddr = vm.envAddress("RULE_ADDRESS");
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        uint256 baseFork = vm.createFork(vm.rpcUrl("base-sepolia"));
        vm.selectFork(baseFork);
        RuleVault vault = RuleVault(payable(vaultAddr));
        uint8 direction = vault.direction();
        uint256 thresholdBps = vault.thresholdBps();
        int256 baselinePrice = vault.baselinePrice();
        require(vault.ruleSet(), "vault has no rule yet");

        uint256 lasnaFork = vm.createFork(vm.rpcUrl("lasna"));
        vm.selectFork(lasnaFork);
        vm.startBroadcast(deployerKey);
        PlainEnglishRule rule = PlainEnglishRule(payable(ruleAddr));
        rule.setVault(vaultAddr);
        rule.setRule(direction, thresholdBps, baselinePrice);
        vm.stopBroadcast();

        console.log("Rule now points at vault:", vaultAddr);
        console.log("direction:", direction);
        console.log("thresholdBps:", thresholdBps);
        console.log("baselinePrice:", uint256(baselinePrice));
    }
}
