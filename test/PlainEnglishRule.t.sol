// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { PlainEnglishRule } from "../src/PlainEnglishRule.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Stand-in for Reactive's system contract at its real address
/// (0x8888888888888888888888888888888888888888). It records every callback
/// the rule contract requests as an EVENT, so the tests can prove the
/// trigger logic without a live network. Deployed with vm.etch in setUp().
/// @dev Why events, not state: vm.etch copies the mock's CODE to the system
/// address, but the code then writes to the SYSTEM address's storage, not
/// the mock's. Events land in the transaction receipt either way, so they
/// are the reliable observation channel.
contract MockSystem {
    event CallbackRequested(
        uint256 chainId,
        address recipient,
        uint64 gasLimit,
        bytes payload
    );

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(
        ISystemContract.CallbackConfiguration_V_1_0 memory config_
    ) external {
        emit CallbackRequested(
            config_.chainId,
            config_.recipient,
            config_.gasLimit,
            config_.payload
        );
    }
}

/// @notice Local proof of the reactive trigger logic. The rule contract is
/// tested against the mock system contract, with price events delivered
/// as LogRecords the way the system contract would deliver them.
contract PlainEnglishRuleTest is Test {
    address internal constant SYSTEM_ADDR =
        0x8888888888888888888888888888888888888888;

    bytes32 internal constant CALLBACK_REQUESTED_TOPIC =
        keccak256("CallbackRequested(uint256,address,uint64,bytes)");

    address internal vault = address(0xCAFE);
    /// @notice The Chainlink aggregator behind the FEED proxy — the real
    /// emitter of AnswerUpdated. The proxy itself never emits them.
    address internal constant AGGREGATOR =
        0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3;
    int256 internal constant BASELINE = 207835015914; // $2,078.35, 8 decimals
    uint256 internal constant THRESHOLD_BPS = 1000; // 10%

    MockSystem internal mock;
    PlainEnglishRule internal rule;

    function setUp() public {
        mock = new MockSystem();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        rule = new PlainEnglishRule(
            vault,
            AGGREGATOR,
            0, // DROP
            THRESHOLD_BPS,
            BASELINE,
            ruleCronTopic()
        );
    }

    function ruleCronTopic() internal pure returns (uint256) {
        return 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70; // Cron100
    }

    /// @dev Builds a LogRecord the way the system contract would deliver it.
    function _log(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_
    ) internal view returns (IReactive.LogRecord memory) {
        return
            IReactive.LogRecord({
                chainId: chainId_,
                contractAddress: contract_,
                topic0: topic0_,
                topic1: topic1_,
                topic2: 0,
                topic3: 0,
                data: "",
                blockNumber: block.number,
                opCode: 1,
                blockHash: 0,
                txHash: 0,
                logIndex: 0
            });
    }

    function _cronLog() internal view returns (IReactive.LogRecord memory) {
        return _log(block.chainid, address(0), rule.cronTopic(), 0);
    }

    /// @dev A Chainlink AnswerUpdated event: the new price is topic1
    /// (the indexed `current` value). Delivered from the AGGREGATOR —
    /// the proxy never emits this event (see the regression test below).
    function _priceLog(int256 price_) internal view returns (IReactive.LogRecord memory) {
        return
            _log(
                rule.BASE_SEPOLIA_CHAIN_ID(),
                rule.aggregator(),
                rule.ANSWER_UPDATED_TOPIC_0(),
                uint256(price_)
            );
    }

    function _vaultLog(uint256 topic0_) internal view returns (IReactive.LogRecord memory) {
        return _log(rule.BASE_SEPOLIA_CHAIN_ID(), vault, topic0_, 0);
    }

    function _react(IReactive.LogRecord memory log_) internal {
        vm.prank(SYSTEM_ADDR);
        rule.react(log_);
    }

    /// @dev Counts CallbackRequested events emitted since the LAST call to
    /// _callbackRequests(): vm.getRecordedLogs() drains the buffer, so
    /// each call here counts only NEW requests, not the running total.
    function _callbackRequests()
        internal
        view
        returns (Vm.Log[] memory requests)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == CALLBACK_REQUESTED_TOPIC) count++;
        }
        requests = new Vm.Log[](count);
        uint256 j;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == CALLBACK_REQUESTED_TOPIC) {
                requests[j++] = logs[i];
            }
        }
    }

    function testReactRevertsForNonSystem() public {
        IReactive.LogRecord memory log_ = _cronLog();
        vm.expectRevert();
        rule.react(log_);
    }

    function testPriceBelowThresholdRequestsNothing() public {
        vm.recordLogs();
        _react(_priceLog((BASELINE * 95) / 100)); // down 5%
        assertEq(_callbackRequests().length, 0);
        assertEq(rule.lastPrice(), (BASELINE * 95) / 100);
        assertFalse(rule.executed());
    }

    function testPriceAtExactlyThresholdRequestsCallback() public {
        vm.recordLogs();
        _react(_priceLog((BASELINE * 90) / 100)); // down exactly 10%
        Vm.Log[] memory requests = _callbackRequests();
        assertEq(requests.length, 1);
        (uint256 chainId, address recipient, , bytes memory payload) = abi.decode(
            requests[0].data,
            (uint256, address, uint64, bytes)
        );
        assertEq(chainId, 84532);
        assertEq(recipient, vault);
        // Payload must call executeRule(address) with the placeholder.
        bytes4 selector = bytes4(payload);
        assertEq(selector, bytes4(keccak256("executeRule(address)")));
        // Not confirmed yet: the vault's Executed event hasn't arrived.
        assertFalse(rule.executed());
    }

    function testRiseDoesNotTriggerDropRule() public {
        vm.recordLogs();
        _react(_priceLog((BASELINE * 120) / 100)); // up 20%
        assertEq(_callbackRequests().length, 0);
    }

    function testRiseRuleTriggersOnRise() public {
        PlainEnglishRule riseRule = new PlainEnglishRule(
            vault,
            AGGREGATOR,
            1, // RISE
            THRESHOLD_BPS,
            BASELINE,
            ruleCronTopic()
        );
        // Build the log BEFORE the prank: the getters below are external
        // calls, and vm.prank only applies to the next call — it would be
        // consumed by the first getter instead of react().
        // Up 11%: "exactly 10%" does not clear the bar, because
        // (baseline * 110) / 100 rounds down a hair below the true 10%.
        IReactive.LogRecord memory log_ = _log(
            riseRule.BASE_SEPOLIA_CHAIN_ID(),
            riseRule.aggregator(),
            riseRule.ANSWER_UPDATED_TOPIC_0(),
            uint256((BASELINE * 111) / 100)
        );
        vm.recordLogs();
        vm.prank(SYSTEM_ADDR);
        riseRule.react(log_);
        assertEq(_callbackRequests().length, 1);
    }

    function testPriceFromWrongContractIsIgnored() public {
        vm.recordLogs();
        // Same topic, but from some other contract, not the feed.
        _react(_log(rule.BASE_SEPOLIA_CHAIN_ID(), address(0xBEEF), rule.ANSWER_UPDATED_TOPIC_0(), uint256((BASELINE * 50) / 100)));
        assertEq(_callbackRequests().length, 0);
        assertEq(rule.lastPrice(), 0);
    }

    /// @notice REGRESSION: the first deployment subscribed to the FEED
    /// proxy, which never emits AnswerUpdated — so the rule never learned
    /// a price and never fired. A price event that claims to come from
    /// the proxy must be ignored, even for a 50% drop.
    function testPriceFromProxyIsIgnored() public {
        vm.recordLogs();
        _react(_log(rule.BASE_SEPOLIA_CHAIN_ID(), rule.FEED(), rule.ANSWER_UPDATED_TOPIC_0(), uint256((BASELINE * 50) / 100)));
        assertEq(_callbackRequests().length, 0);
        assertEq(rule.lastPrice(), 0);
    }

    function testSetAggregatorOnlyOwner() public {
        vm.expectRevert(PlainEnglishRule.NotOwner.selector);
        vm.prank(address(0x1234));
        rule.setAggregator(address(0xBEEF));
    }

    function testSetAggregatorChangesEmitter() public {
        address newAgg = address(0xA66A);
        rule.setAggregator(newAgg);
        assertEq(rule.aggregator(), newAgg);
        vm.recordLogs();
        // The old aggregator's events are now ignored.
        _react(_log(rule.BASE_SEPOLIA_CHAIN_ID(), AGGREGATOR, rule.ANSWER_UPDATED_TOPIC_0(), uint256((BASELINE * 50) / 100)));
        assertEq(_callbackRequests().length, 0);
        assertEq(rule.lastPrice(), 0);
        // The new aggregator's events are accepted and trigger.
        _react(_log(rule.BASE_SEPOLIA_CHAIN_ID(), newAgg, rule.ANSWER_UPDATED_TOPIC_0(), uint256((BASELINE * 90) / 100)));
        assertEq(_callbackRequests().length, 1);
        assertEq(rule.lastPrice(), (BASELINE * 90) / 100);
    }

    function testCronTickRetriesUntilExecutedEvent() public {
        vm.recordLogs();
        // Price event fires the rule once.
        _react(_priceLog((BASELINE * 90) / 100));
        assertEq(_callbackRequests().length, 1);
        // The callback has not been confirmed yet, so the backstop tick
        // asks again — the retry behaviour, by design.
        _react(_cronLog());
        assertEq(_callbackRequests().length, 1);
        // The vault's Executed event arrives: the job is done.
        _react(_vaultLog(uint256(rule.EXECUTED_TOPIC_0())));
        assertTrue(rule.executed());
        // Further ticks and price events ask for nothing more.
        _react(_cronLog());
        _react(_priceLog((BASELINE * 50) / 100));
        assertEq(_callbackRequests().length, 0);
    }

    function testSetRuleOnlyOwner() public {
        vm.expectRevert(PlainEnglishRule.NotOwner.selector);
        vm.prank(address(0x1234));
        rule.setRule(1, 500, BASELINE);
    }

    function testSetVaultOnlyOwner() public {
        vm.expectRevert(PlainEnglishRule.NotOwner.selector);
        vm.prank(address(0x1234));
        rule.setVault(address(0xBEEF));
    }
}
