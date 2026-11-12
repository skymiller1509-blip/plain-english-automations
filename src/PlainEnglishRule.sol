// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title Plain-English Rule (reactive contract, Lasna testnet)
/// @notice Watches one RuleVault on Base Sepolia and the live Chainlink
/// ETH/USD price feed on the same chain. Three subscriptions feed the
/// same react():
///  - AnswerUpdated events from the Chainlink AGGREGATOR: every time the
///    price moves, the new price arrives here and is checked against the
///    rule. The events are emitted by the aggregator contract, NOT by the
///    feed proxy (the proxy is only a read path and never emits
///    AnswerUpdated) — subscribing to the proxy was the bug that kept
///    the first deployment from ever firing. The aggregator address is
///    read from the proxy's aggregator() at deploy time and stored here;
///    setAggregator() re-subscribes if Chainlink ever rotates it.
///  - a CRON tick from Reactive's own clock (the backstop): if a price
///    event was missed or a callback failed, the next tick re-checks the
///    last observed price instead of forgetting the rule.
///  - every event from the vault (its Executed event confirms the rule
///    was carried out, so the switch stops asking).
/// The rule itself (direction, threshold, baseline price) is stored here
/// and set by the owner to match the vault's rule. The check is plain
/// integer math in basis points: a drop rule fires when
/// price * 10000 <= baseline * (10000 - threshold), a rise rule when
/// price * 10000 >= baseline * (10000 + threshold). The vault re-checks
/// the live price itself before moving anything, so a mistaken or stale
/// trigger is harmless.
/// @dev Follows the Reactive Contracts + CRON patterns from
/// dev.reactive.network (Omni): inherit AbstractReactive, guard react()
/// with onlySystem, subscribe through SYSTEM, request callbacks with
/// SYSTEM.requestCallbackV_1_0. The callback payload's first argument is
/// always an address placeholder (address(0)); the proxy overwrites it
/// with this contract's address so the vault can authenticate the sender.
/// Time logic uses timestamps, never block numbers (the event's ground
/// rule for Base Sepolia) — this contract keeps no time-based state of
/// its own; it only reacts to price events and clock ticks.
contract PlainEnglishRule is AbstractReactive {
    /// @notice The legacy system contract that emits the Cron events.
    /// (dev.reactive.network/reactive-contracts, "Subscribing To CRON Events")
    address internal constant LEGACY_SYSTEM_ADDR =
        0x0000000000000000000000000000000000fffFfF;

    /// @notice CRON event topic0 values from the official docs.
    /// Cron100 ticks about every 100 blocks (~2 minutes on Lasna).
    uint256 public constant CRON100_TOPIC_0 =
        0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    /// @notice Topic0 of Chainlink's AnswerUpdated(int256,uint256,uint256)
    /// event. Verified live with cast: the feed's latest updates carry
    /// this topic. The new price is topic1 (current is indexed).
    uint256 public constant ANSWER_UPDATED_TOPIC_0 =
        0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f;

    /// @notice Topic0 of the vault's Executed(address,uint256,uint256,int256,uint256) event.
    bytes32 public constant EXECUTED_TOPIC_0 =
        keccak256("Executed(address,uint256,uint256,int256,uint256)");

    /// @notice Base Sepolia chain ID (dev.reactive.network/origins-and-destinations).
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;

    /// @notice The live Chainlink ETH/USD feed on Base Sepolia, proxy,
    /// 8 decimals. Verified live 2026-11-11: description() returns
    /// "ETH / USD", decimals() returns 8. The proxy is a READ path only:
    /// it never emits AnswerUpdated, so the rule never subscribes to it.
    /// It is kept here as a reference; the vault reads prices through it.
    address public constant FEED =
        0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;

    /// @notice The Chainlink aggregator behind the proxy. THIS is the
    /// contract that emits AnswerUpdated events (the OCR transmitters
    /// call transmit() on the aggregator directly). Set at deploy from
    /// the proxy's aggregator(); changeable with setAggregator().
    address public aggregator;

    uint64 private constant CALLBACK_GAS_LIMIT = 1_000_000;

    address public owner;
    address public vault;
    uint256 public cronTopic;
    /// @notice Direction of the rule: 0 = price dropped by the threshold,
    /// 1 = price rose by the threshold. Mirrors the vault's rule.
    uint8 public direction;
    /// @notice Threshold in basis points: 1000 = 10%.
    uint256 public thresholdBps;
    /// @notice Feed price (8 decimals) at the moment the rule was set.
    /// Mirrors the vault's baseline.
    int256 public baselinePrice;
    /// @notice Last feed price observed (from AnswerUpdated topic1).
    int256 public lastPrice;
    /// @notice True once the vault's Executed event has been observed.
    bool public executed;

    event PriceObserved(int256 indexed price, uint256 at);
    event RuleChecked(int256 price, int256 baselinePrice, bool triggered);
    event ExecutionRequested(address indexed vault, int256 price, uint256 at);
    event ExecutionConfirmed(address indexed vault, uint256 at);
    event VaultSet(address indexed vault);
    event AggregatorSet(address indexed aggregator);
    event RuleSet(uint8 direction, uint256 thresholdBps, int256 baselinePrice);

    error NotOwner();
    error VaultNotSet();
    error ZeroAddress();
    error BadDirection();
    error BadThreshold();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param vault_ The RuleVault on Base Sepolia (address(0) is allowed
    /// here so the reactive contract can be deployed first; set the vault
    /// afterwards with setVault()).
    /// @param aggregator_ The Chainlink aggregator behind the FEED proxy
    /// (read it from the proxy's aggregator() at deploy time — never
    /// guess it). Must not be address(0): the feed subscription is made
    /// in the constructor.
    /// @param direction_ 0 = drop, 1 = rise.
    /// @param thresholdBps_ Move size in basis points (1000 = 10%).
    /// @param baselinePrice_ Feed price when the rule was set (8 decimals).
    /// 0 is allowed at deploy; set the rule afterwards with setRule().
    /// @param cronTopic_ Which CRON tick to listen to (see constants above).
    constructor(
        address vault_,
        address aggregator_,
        uint8 direction_,
        uint256 thresholdBps_,
        int256 baselinePrice_,
        uint256 cronTopic_
    ) payable {
        if (aggregator_ == address(0)) revert ZeroAddress();
        if (direction_ > 1) revert BadDirection();
        if (thresholdBps_ >= 10_000) revert BadThreshold();
        owner = msg.sender;
        vault = vault_;
        aggregator = aggregator_;
        direction = direction_;
        thresholdBps = thresholdBps_;
        baselinePrice = baselinePrice_;
        cronTopic = cronTopic_;
        _subscribeToCron();
        _subscribeToFeed();
        if (vault_ != address(0)) {
            _subscribeToVault();
        }
    }

    function _subscribeToCron() internal {
        SYSTEM.subscribe(
            block.chainid,
            LEGACY_SYSTEM_ADDR,
            cronTopic,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function _subscribeToFeed() internal {
        // Only AnswerUpdated events from the Chainlink AGGREGATOR.
        // The proxy never emits them (see the contract notice above).
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID,
            aggregator,
            ANSWER_UPDATED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function _subscribeToVault() internal {
        // Every event from this one contract (topic0 left open), so the
        // Executed confirmation is always seen.
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID,
            vault,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Point the switch at the vault (deploy order: reactive first,
    /// then vault, then setVault). Unsubscribes from the old vault first.
    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        if (vault != address(0)) {
            SYSTEM.unsubscribe(
                BASE_SEPOLIA_CHAIN_ID,
                vault,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        vault = vault_;
        _subscribeToVault();
        emit VaultSet(vault_);
    }

    /// @notice Point the rule at a new Chainlink aggregator (e.g. after a
    /// Chainlink rotation). Unsubscribes from the old aggregator first so
    /// stale price events can never be delivered again.
    function setAggregator(address aggregator_) external onlyOwner {
        if (aggregator_ == address(0)) revert ZeroAddress();
        if (aggregator != address(0)) {
            SYSTEM.unsubscribe(
                BASE_SEPOLIA_CHAIN_ID,
                aggregator,
                ANSWER_UPDATED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        aggregator = aggregator_;
        _subscribeToFeed();
        emit AggregatorSet(aggregator_);
    }

    /// @notice Set (or replace) the rule, mirroring the vault's rule.
    /// The baseline must be the live feed price at the moment the rule
    /// is set — read it from the feed, never typed by hand.
    function setRule(uint8 direction_, uint256 thresholdBps_, int256 baselinePrice_)
        external
        onlyOwner
    {
        if (direction_ > 1) revert BadDirection();
        if (thresholdBps_ == 0 || thresholdBps_ >= 10_000) revert BadThreshold();
        direction = direction_;
        thresholdBps = thresholdBps_;
        baselinePrice = baselinePrice_;
        emit RuleSet(direction_, thresholdBps_, baselinePrice_);
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external override onlySystem {
        if (log_.chainId == block.chainid && log_.topic0 == cronTopic) {
            // Backstop tick: re-check the last observed price. This
            // covers a missed price event or a failed callback; it cannot
            // see a price newer than the last AnswerUpdated.
            _checkTrigger(lastPrice);
        } else if (
            log_.chainId == BASE_SEPOLIA_CHAIN_ID &&
            log_.contractAddress == aggregator &&
            log_.topic0 == ANSWER_UPDATED_TOPIC_0
        ) {
            // The new price is topic1: AnswerUpdated's `current` is indexed.
            int256 price = int256(log_.topic1);
            lastPrice = price;
            emit PriceObserved(price, block.timestamp);
            _checkTrigger(price);
        } else if (
            log_.chainId == BASE_SEPOLIA_CHAIN_ID &&
            log_.contractAddress == vault &&
            log_.topic0 == uint256(EXECUTED_TOPIC_0)
        ) {
            executed = true;
            emit ExecutionConfirmed(vault, block.timestamp);
        }
        // Anything else falls through silently. Reverting as a filter
        // would still cost gas, per the docs.
    }

    /// @notice True when the given price has moved by the threshold from
    /// the baseline, in the rule's direction.
    function isTriggered(int256 price_) public view returns (bool) {
        if (executed || vault == address(0)) return false;
        if (price_ <= 0 || baselinePrice <= 0 || thresholdBps == 0) return false;
        if (direction == 0) {
            return price_ * int256(10_000) <=
                baselinePrice * int256(10_000 - thresholdBps);
        } else {
            return price_ * int256(10_000) >=
                baselinePrice * int256(10_000 + thresholdBps);
        }
    }

    function _checkTrigger(int256 price_) internal {
        bool trigger = isTriggered(price_);
        emit RuleChecked(price_, baselinePrice, trigger);
        if (!trigger) {
            return;
        }
        bytes memory payload = abi.encodeWithSignature(
            "executeRule(address)",
            address(0) // placeholder: the proxy injects this contract's address
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: BASE_SEPOLIA_CHAIN_ID,
                recipient: vault,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
        emit ExecutionRequested(vault, price_, block.timestamp);
    }

    /// @notice Settles outstanding debt from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }
}
