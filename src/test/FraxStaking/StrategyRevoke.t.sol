// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
import "forge-std/console.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";

contract StrategyRevokeTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testRevokeStrategyFromVault(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 1 ether && _amount < 10_000 ether);

        // Deposit to the vault and harvest
        vm_std_cheats.prank(user);
        want.approve(address(vault), _amount);
        vm_std_cheats.prank(user);
        vault.deposit(_amount);
        skip(1);
        strategy.harvest();
        console.log("Harvested once");
        skip(toSkip);
        strategy.harvest();
        console.log("Harvested twice");
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);

        // In order to pass these tests, you will need to implement prepareReturn.
        // TODO: uncomment the following lines.
        vault.revokeStrategy(address(strategy));
        console.log("Strategy Revoked");
        skip(toSkip);
        strategy.harvest();
        console.log("Harvested Thrice");
        assertGe(want.balanceOf(address(vault)), _amount);
    }

    function testRevokeStrategyFromStrategy(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 1 ether && _amount < 10_000 ether);

        vm_std_cheats.prank(user);
        want.approve(address(vault), _amount);
        vm_std_cheats.prank(user);
        vault.deposit(_amount);
        skip(1);
        strategy.harvest();
        console.log("Harvested once");
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);
        skip(toSkip);
        strategy.setEmergencyExit();
        skip(1);
        console.log("Emercengy Exit Set");
        strategy.harvest();

        assertGe(want.balanceOf(address(vault)), _amount); 
    }

    function testLiquidateAll(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 1 ether && _amount < 10_000 ether);

        vm_std_cheats.prank(user);
        want.approve(address(vault), _amount);
        vm_std_cheats.prank(user);
        vault.deposit(_amount);
        skip(1);
        uint256 balanceBefore = want.balanceOf(user);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);
        assertEq(strategy.estimatedTotalAssets(), strategy.stakedBalance());
        skip(1 days);
        console.log("Withdrawing half");    
        vm_std_cheats.prank(user);
        vault.withdraw(_amount /2);
        console.log("withdrawing all");
        vm_std_cheats.prank(user);
        vault.withdraw();
        assertRelApproxEq(want.balanceOf(address(user)), _amount + balanceBefore, ONE_BIP_REL_DELTA); 
    }
}
