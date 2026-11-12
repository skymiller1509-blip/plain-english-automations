// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.29;

import { AggregatorV3Interface } from "./AggregatorV3Interface.sol";
import { MockUSDC } from "./MockUSDC.sol";

/// @title Mock Swap (demo only)
/// @notice Swaps ETH for MockUSDC at the LIVE Chainlink price. It is a
/// demo stand-in for a real exchange: there is no liquidity pool and no
/// real USDC here. The price comes from the same Chainlink feed the vault
/// and the reactive contract watch, so the amount of mock USDC the owner
/// receives is priced exactly where the trigger fired.
/// @dev Only the RuleVault may call swapETHForUSDC: the vault is the only
/// contract that should be able to turn deposited ETH into mock USDC.
/// Math: ETH has 18 decimals, the feed has 8, MockUSDC has 6, so
/// usdc = ethWei * price / 1e20. Example: 0.01 ETH at $2,078.35 gives
/// 1e16 * 207835015914 / 1e20 = 20,783,501 (6 decimals) = $20.78.
contract MockSwap {
    AggregatorV3Interface public immutable feed;
    MockUSDC public immutable usdc;
    address public vault;
    address public owner;

    event Swapped(address indexed to, uint256 ethIn, uint256 usdcOut, int256 price);
    event VaultSet(address indexed vault);

    error NotOwner();
    error NotVault();
    error ZeroAddress();
    error BadPrice();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(address feed_, address usdc_, address vault_) {
        if (feed_ == address(0) || usdc_ == address(0) || vault_ == address(0)) {
            revert ZeroAddress();
        }
        feed = AggregatorV3Interface(feed_);
        usdc = MockUSDC(usdc_);
        vault = vault_;
        owner = msg.sender;
    }

    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultSet(vault_);
    }

    /// @notice The live feed price, for the frontend status readout.
    function currentPrice() public view returns (int256 price) {
        (, price, , , ) = feed.latestRoundData();
    }

    /// @notice Turn the sent ETH into MockUSDC for `to_`, at the live
    /// feed price. Callable only by the RuleVault, during executeRule().
    function swapETHForUSDC(address to_) external payable onlyVault returns (uint256 usdcOut) {
        int256 price = currentPrice();
        if (price <= 0) revert BadPrice();
        usdcOut = (msg.value * uint256(price)) / 1e20;
        usdc.mint(to_, usdcOut);
        emit Swapped(to_, msg.value, usdcOut, price);
    }
}
