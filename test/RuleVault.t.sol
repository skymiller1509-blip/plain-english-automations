// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { RuleVault } from "../src/RuleVault.sol";
import { MockUSDC } from "../src/MockUSDC.sol";
import { MockSwap } from "../src/MockSwap.sol";

/// @notice Stand-in for the Chainlink feed: the price is set by hand so
/// the tests can prove the threshold math exactly.
contract MockFeed {
    int256 public price = 207835015914; // $2,078.35, 8 decimals

    function setPrice(int256 price_) external {
        price = price_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "ETH / USD";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Local proof of the vault's rule logic. This test contract plays
/// the callback proxy AND the authorized reactive sender: the vault is
/// deployed with both roles set to this contract's address, so calling
/// executeRule() directly from here passes the proxy checks exactly the
/// way the real proxy call would.
contract RuleVaultTest is Test {
    MockFeed internal feed;
    MockUSDC internal usdc;
    MockSwap internal swap;
    RuleVault internal vault;

    address internal owner = address(this);
    address internal constant STRANGER = address(0x1234);

    int256 internal constant BASELINE = 207835015914; // $2,078.35

    function setUp() public {
        feed = new MockFeed();
        // Deploy the token first with a placeholder minter, then the swap,
        // then point the token at the swap as its minter.
        usdc = new MockUSDC(address(this));
        swap = new MockSwap(address(feed), address(usdc), address(this));
        usdc.setMinter(address(swap));
        vault = new RuleVault{ value: 0.01 ether }(
            IPayable(payable(address(this))),
            address(this),
            owner,
            address(feed),
            address(swap)
        );
        // The swap only takes orders from the vault.
        swap.setVault(address(vault));
    }

    // IPayable: the vault treats this contract as the callback proxy.
    receive() external payable {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function testSetRuleRecordsLiveBaseline() public {
        vault.setRule(0, 1000);
        assertEq(vault.baselinePrice(), BASELINE);
        assertEq(vault.thresholdBps(), 1000);
        assertEq(vault.direction(), 0);
        assertTrue(vault.ruleSet());
    }

    function testSetRuleRevertsForBadDirection() public {
        vm.expectRevert(RuleVault.BadDirection.selector);
        vault.setRule(2, 1000);
    }

    function testSetRuleRevertsForZeroThreshold() public {
        vm.expectRevert(RuleVault.BadThreshold.selector);
        vault.setRule(0, 0);
    }

    function testSetRuleOnlyOwner() public {
        vm.expectRevert(RuleVault.NotOwner.selector);
        vm.prank(STRANGER);
        vault.setRule(0, 1000);
    }

    function testNoTriggerBeforeThreshold() public {
        vault.setRule(0, 1000); // drop 10%
        feed.setPrice((BASELINE * 95) / 100); // down 5%
        assertFalse(vault.isTriggered());
        assertEq(vault.moveBps(), -500);
    }

    function testTriggerAtExactlyThreshold() public {
        vault.setRule(0, 1000);
        feed.setPrice((BASELINE * 90) / 100); // down exactly 10%
        assertTrue(vault.isTriggered());
    }

    function testTriggerBeyondThreshold() public {
        vault.setRule(0, 1000);
        feed.setPrice((BASELINE * 80) / 100); // down 20%
        assertTrue(vault.isTriggered());
    }

    function testDropDoesNotTriggerRiseRule() public {
        vault.setRule(1, 1000); // rise 10%
        feed.setPrice((BASELINE * 80) / 100); // down 20%
        assertFalse(vault.isTriggered());
    }

    function testRiseTriggersRiseRule() public {
        vault.setRule(1, 1000);
        // Up 11%: "exactly 10%" does not clear the bar, because
        // (baseline * 110) / 100 rounds down a hair below the true 10%.
        feed.setPrice((BASELINE * 111) / 100);
        assertTrue(vault.isTriggered());
        // 1099, not 1100: integer division rounds the 11% rise down by a hair.
        assertEq(vault.moveBps(), 1099);
    }

    function testExecuteRevertsForStranger() public {
        vault.setRule(0, 1000);
        feed.setPrice((BASELINE * 90) / 100);
        vm.expectRevert();
        vm.prank(STRANGER);
        vault.executeRule(address(this));
    }

    function testExecuteRevertsBeforeThreshold() public {
        vault.setRule(0, 1000);
        feed.setPrice((BASELINE * 95) / 100);
        vm.expectRevert(
            abi.encodeWithSelector(
                RuleVault.NotTriggered.selector,
                (BASELINE * 95) / 100,
                BASELINE
            )
        );
        vault.executeRule(address(this));
    }

    function testExecuteMovesFundsToMockUSDC() public {
        vault.setRule(0, 1000);
        feed.setPrice((BASELINE * 90) / 100);
        uint256 ownerUsdcBefore = usdc.balanceOf(owner);
        vault.executeRule(address(this));
        assertTrue(vault.executed());
        assertEq(address(vault).balance, 0);
        // 0.01 ETH at $1,870.515 (90% of $2,078.35) = $18.705151 in mUSDC.
        uint256 expected = (0.01 ether * uint256((BASELINE * 90) / 100)) / 1e20;
        assertEq(usdc.balanceOf(owner) - ownerUsdcBefore, expected);
        assertEq(expected, 18_705_151); // $18.705151, 6 decimals
    }

    function testExecuteOnlyOnce() public {
        vault.setRule(0, 1000);
        feed.setPrice((BASELINE * 90) / 100);
        vault.executeRule(address(this));
        vm.expectRevert(RuleVault.AlreadyExecuted.selector);
        vault.executeRule(address(this));
    }

    function testSetRuleCanBeReplacedBeforeExecution() public {
        vault.setRule(0, 1000);
        feed.setPrice((BASELINE * 95) / 100);
        vault.setRule(1, 500); // change mind: rise 5%, new baseline
        assertEq(vault.baselinePrice(), (BASELINE * 95) / 100);
        assertEq(vault.thresholdBps(), 500);
        assertEq(vault.direction(), 1);
    }

    function testSwapMathDirectly() public {
        // 0.01 ETH at $2,078.35 -> 20,783,501 mUSDC units ($20.783501).
        // Called as the vault (only the vault may swap).
        vm.prank(address(vault));
        uint256 out = swap.swapETHForUSDC{ value: 0.01 ether }(owner);
        assertEq(out, 20_783_501);
    }
}
