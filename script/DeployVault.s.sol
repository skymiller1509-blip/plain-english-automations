// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.29;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { RuleVault } from "../src/RuleVault.sol";
import { MockUSDC } from "../src/MockUSDC.sol";
import { MockSwap } from "../src/MockSwap.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

/// @notice Deploys the vault, the mock USDC token and the mock swap on
/// Base Sepolia (chain 84532), sets the rule, and deposits the rule amount
/// in the same run.
/// @dev Run: forge script script/DeployVault.s.sol --rpc-url base-sepolia --broadcast
/// Env: PRIVATE_KEY, REACTIVE_ADDRESS (the Lasna PlainEnglishRule),
/// DIRECTION (0 = drop, 1 = rise, default 0), THRESHOLD_BPS (default 1000
/// = 10%), DEPOSIT_ETH (default 0.005), EXISTING_USDC / EXISTING_SWAP
/// (optional: reuse already-deployed MockUSDC/MockSwap instead of
/// deploying fresh ones — pass both or neither; the swap is re-pointed
/// at the new vault with setVault).
/// The deployer becomes the vault owner. Keep a little extra ETH in the vault:
/// the execution callback is billed to the vault in ETH. The default deposit
/// is 0.005, not 0.01: the shared deployer wallet holds ~0.009 Base Sepolia
/// ETH after the dead man's switch deploy (checked live 2026-11-11), so 0.01
/// plus gas would not fit — top up from the faucet first if you want a bigger demo.
/// The mock token and swap are demo-only: MockUSDC has no real value and
/// the swap prices at the live Chainlink feed.
/// Deploy order (the swap and the vault point at each other): token with
/// the deployer as minter -> swap with the deployer as vault placeholder
/// -> vault -> swap.setVault(vault) -> token.setMinter(swap).
/// When reusing, the swap is re-pointed at the new vault and the token's
/// minter (already the swap) is left alone.
contract DeployVault is Script {
    // Chainlink ETH/USD feed on Base Sepolia, proxy, 8 decimals.
    // Verified live 2026-11-11: description() = "ETH / USD".
    address internal constant FEED = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;

    // Base Sepolia callback proxy, from dev.reactive.network.
    IPayable internal constant PROXY =
        IPayable(payable(0x476F44b11F5C942c58f4c8E3d0300E5710743585));

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address reactive = vm.envAddress("REACTIVE_ADDRESS");
        uint8 direction = uint8(vm.envOr("DIRECTION", uint256(0)));
        uint256 thresholdBps = vm.envOr("THRESHOLD_BPS", uint256(1000));
        uint256 deposit = vm.envOr("DEPOSIT_ETH", uint256(0.005 ether));
        address deployer = vm.addr(deployerKey);
        address existingUsdc = vm.envOr("EXISTING_USDC", address(0));
        address existingSwap = vm.envOr("EXISTING_SWAP", address(0));
        require(
            (existingUsdc == address(0)) == (existingSwap == address(0)),
            "pass both EXISTING_USDC and EXISTING_SWAP, or neither"
        );

        vm.startBroadcast(deployerKey);
        MockUSDC usdc;
        MockSwap swap;
        if (existingUsdc != address(0)) {
            usdc = MockUSDC(existingUsdc);
            swap = MockSwap(existingSwap);
        } else {
            usdc = new MockUSDC(deployer);
            swap = new MockSwap(FEED, address(usdc), deployer);
        }
        RuleVault vault = new RuleVault{ value: deposit }(
            PROXY,
            reactive,
            deployer,
            FEED,
            address(swap)
        );
        swap.setVault(address(vault));
        if (existingUsdc == address(0)) {
            usdc.setMinter(address(swap));
        }
        // Reads the live feed price and records it as the baseline.
        vault.setRule(direction, thresholdBps);
        vm.stopBroadcast();

        console.log("MockUSDC (Base Sepolia):", address(usdc));
        console.log("MockSwap (Base Sepolia):", address(swap));
        console.log("RuleVault (Base Sepolia):", address(vault));
        console.log("direction:", direction);
        console.log("thresholdBps:", thresholdBps);
        console.log("baselinePrice:", vault.baselinePrice());
        console.log("depositWei:", deposit);
    }
}
