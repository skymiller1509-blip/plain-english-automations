// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { AggregatorV3Interface } from "./AggregatorV3Interface.sol";
import { MockSwap } from "./MockSwap.sol";

/// @title Plain-English Rule Vault (destination chain: Base Sepolia)
/// @notice Holds the owner's deposited ETH and one rule, written in plain
/// English by the owner and turned into settings by a live AI call in the
/// app (see the frontend). The rule says: if the ETH price moves by X%
/// from the price when the rule was set, move the deposit into USDC.
/// The vault records the baseline price itself, straight from the live
/// Chainlink feed, at the moment the rule is set — so the baseline is
/// always the real on-chain price, never a number typed by hand.
/// When the Reactive contract on Lasna sees the move, it asks this vault
/// — through Reactive's official callback proxy — to carry the rule out.
/// Only the proxy, carrying the authorized reactive contract's address,
/// can trigger the execution. The vault itself re-checks the price
/// condition before moving anything, so a mistaken or stale trigger can
/// never move funds early.
/// @dev Follows the Callback Contracts pattern from dev.reactive.network:
/// inherit AbstractCallback, guard the callback with both
/// onlyServiceProvider (is the caller the proxy?) and onlyCallbackSender
/// (did the call really come from our reactive contract?). The first
/// payload argument is always the reactive contract's address, injected
/// by the proxy. Time logic uses timestamps, never block numbers (the
/// event's ground rule for Base Sepolia).
contract RuleVault is AbstractCallback {
    /// @notice Price fell by the threshold (or more) from the baseline.
    uint8 public constant DIRECTION_DROP = 0;
    /// @notice Price rose by the threshold (or more) from the baseline.
    uint8 public constant DIRECTION_RISE = 1;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public immutable owner;
    AggregatorV3Interface public feed;
    MockSwap public swap;

    /// @notice Direction of the rule (DROP or RISE). 0 until a rule is set.
    uint8 public direction;
    /// @notice Threshold in basis points: 1000 = 10%.
    uint256 public thresholdBps;
    /// @notice Live feed price (8 decimals) at the moment the rule was set.
    int256 public baselinePrice;
    /// @notice True once a rule has been set.
    bool public ruleSet;
    /// @notice True once the rule has been carried out. One shot only.
    bool public executed;

    event RuleSet(
        address indexed feed,
        uint8 direction,
        uint256 thresholdBps,
        int256 baselinePrice,
        uint256 setAt
    );
    event Deposited(address indexed from, uint256 amount);
    event Executed(
        address indexed owner,
        uint256 ethIn,
        uint256 usdcOut,
        int256 price,
        uint256 executedAt
    );

    error NotOwner();
    error NotRuleSet();
    error AlreadyExecuted();
    error NotTriggered(int256 price, int256 baselinePrice);
    error ZeroAddress();
    error BadDirection();
    error BadThreshold();
    error BadPrice();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param callbackProxy_ The Reactive callback proxy on this chain
    /// (Base Sepolia: 0x476F44b11F5C942c58f4c8E3d0300E5710743585).
    /// @param callbackSender_ The PlainEnglishRule reactive contract on Lasna.
    /// @param owner_ The person whose funds and rule these are.
    /// @param feed_ The Chainlink price feed (Base Sepolia ETH/USD).
    /// @param swap_ The MockSwap that turns ETH into MockUSDC.
    constructor(
        IPayable callbackProxy_,
        address callbackSender_,
        address owner_,
        address feed_,
        address swap_
    ) payable AbstractCallback(callbackProxy_, callbackSender_) {
        if (owner_ == address(0) || feed_ == address(0) || swap_ == address(0)) {
            revert ZeroAddress();
        }
        owner = owner_;
        feed = AggregatorV3Interface(feed_);
        swap = MockSwap(swap_);
    }

    /// @notice Plain ETH transfers are accepted as deposits.
    receive() external payable override {
        if (executed) revert AlreadyExecuted();
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Deposit ETH into the vault.
    function deposit() external payable {
        if (executed) revert AlreadyExecuted();
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice The live feed price right now (8 decimals).
    function currentPrice() public view returns (int256 price) {
        (, price, , , ) = feed.latestRoundData();
    }

    /// @notice Set (or replace) the rule. Reads the live feed price at
    /// this exact moment and records it as the baseline, so the rule is
    /// always measured from a real on-chain price. Only before execution.
    /// @param direction_ DIRECTION_DROP (0) or DIRECTION_RISE (1).
    /// @param thresholdBps_ Move size in basis points: 1000 = 10%.
    /// Must be between 1 and 9999 (0.01% to 99.99%).
    function setRule(uint8 direction_, uint256 thresholdBps_) external onlyOwner {
        if (executed) revert AlreadyExecuted();
        if (direction_ != DIRECTION_DROP && direction_ != DIRECTION_RISE) {
            revert BadDirection();
        }
        if (thresholdBps_ == 0 || thresholdBps_ >= BPS_DENOMINATOR) {
            revert BadThreshold();
        }
        int256 price = currentPrice();
        if (price <= 0) revert BadPrice();
        direction = direction_;
        thresholdBps = thresholdBps_;
        baselinePrice = price;
        ruleSet = true;
        emit RuleSet(address(feed), direction_, thresholdBps_, price, block.timestamp);
    }

    /// @notice True when the live price has moved by the threshold from
    /// the baseline, in the rule's direction. Pure check — moves nothing.
    function isTriggered() public view returns (bool) {
        if (!ruleSet || executed) return false;
        int256 price = currentPrice();
        if (price <= 0 || baselinePrice <= 0) return false;
        if (direction == DIRECTION_DROP) {
            // price * 10000 <= baseline * (10000 - threshold)
            return price * int256(BPS_DENOMINATOR) <=
                baselinePrice * int256(BPS_DENOMINATOR - thresholdBps);
        } else {
            // price * 10000 >= baseline * (10000 + threshold)
            return price * int256(BPS_DENOMINATOR) >=
                baselinePrice * int256(BPS_DENOMINATOR + thresholdBps);
        }
    }

    /// @notice How far the price has moved from the baseline, in basis
    /// points. Negative means the price fell. For the status readout.
    function moveBps() public view returns (int256) {
        if (!ruleSet || baselinePrice <= 0) return 0;
        int256 price = currentPrice();
        return ((price - baselinePrice) * int256(BPS_DENOMINATOR)) / baselinePrice;
    }

    /// @notice Carry the rule out: move the whole deposit into MockUSDC
    /// for the owner, at the live feed price. Callable ONLY through the
    /// Reactive callback proxy, and only when the price condition is
    /// really met right now. One shot: after this the vault is done.
    /// @param reactive_ Injected by the proxy: the reactive contract that
    /// requested this callback. Must be our authorized PlainEnglishRule.
    function executeRule(address reactive_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        if (!ruleSet) revert NotRuleSet();
        if (executed) revert AlreadyExecuted();
        int256 price = currentPrice();
        if (!isTriggered()) {
            revert NotTriggered(price, baselinePrice);
        }
        executed = true;
        uint256 amount = address(this).balance;
        uint256 usdcOut = swap.swapETHForUSDC{ value: amount }(owner);
        emit Executed(owner, amount, usdcOut, price, block.timestamp);
    }

    /// @notice Settles outstanding callback debt from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }
}
