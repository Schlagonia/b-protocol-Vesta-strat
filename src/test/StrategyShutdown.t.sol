// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
import "forge-std/console.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";

import "../interfaces/Chainlink/AggregatorV3Interface.sol";

contract StrategyShutdownTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testVaultShutdownCanWithdraw(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 0.01 ether && _amount < 100_000_000 ether);

        // Deposit to the vault
        vm_std_cheats.prank(user);
        want.approve(address(vault), _amount);
        vm_std_cheats.prank(user);
        vault.deposit(_amount);
        assertEq(want.balanceOf(address(vault)), _amount);

        uint256 bal = want.balanceOf(user);
        if (bal > 0) {
            vm_std_cheats.prank(user);
            want.transfer(address(123), bal);
        }

        mockChainlink();

        // Harvest 1: Send funds through the strategy
        skip(3600 * 7);
        vm_std_cheats.roll(block.number + 1);
        
        

        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);

        // Set Emergency
        vault.setEmergencyShutdown(true);

        // Withdraw (does it work, do you get what you expect)
        console.log("User vault shares", vault.balanceOf(user));
        console.log("Vault PPS", vault.pricePerShare());
        console.log("Strategy assets b4 withdraw", strategy.estimatedTotalAssets());
        console.log("Want balance of vault b4 withdraw", want.balanceOf(address(vault)));
        vm_std_cheats.prank(user);
        vault.withdraw();

        assertRelApproxEq(want.balanceOf(user), _amount, ONE_BIP_REL_DELTA);
    }

    function testBasicShutdown(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 0.01 ether && _amount < 100_000_000 ether);

        // Deposit to the vault
        vm_std_cheats.prank(user);
        want.approve(address(vault), _amount);
        vm_std_cheats.prank(user);
        vault.deposit(_amount);
        assertEq(want.balanceOf(address(vault)), _amount);

        mockChainlink();

        // Harvest 1: Send funds through the strategy
        skip(1 days);
        vm_std_cheats.roll(block.number + 100);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);

        // Earn interest
        skip(1 days);
        vm_std_cheats.roll(block.number + 1);

        // Harvest 2: Realize profit
        strategy.harvest();
        skip(6 hours);
        vm_std_cheats.roll(block.number + 1);

        // Set emergency
        vm_std_cheats.prank(strategist);
        strategy.setEmergencyExit();

        strategy.harvest(); // Remove funds from strategy

        assertEq(want.balanceOf(address(strategy)), 0);
        assertGe(want.balanceOf(address(vault)), _amount); // The vault has all funds
        // NOTE: May want to tweak this based on potential loss during migration
    }
}
