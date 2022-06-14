// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
import "forge-std/console.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";

// NOTE: if the name of the strat or file changes this needs to be updated
import {Str8Vesta} from "../../Str8Vesta.sol";

contract StrategyMigrationTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testMigration(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 1 ether && _amount < 10_000 ether);

        // Deposit to the vault and harvest
        vm_std_cheats.prank(user);
        want.approve(address(vault), _amount);
        vm_std_cheats.prank(user);
        vault.deposit(_amount);
        skip(1);
        strategy.harvest();
        assertEq(want.balanceOf(address(strategy)), 0);
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);
        skip(1 days);
        // Migrate to a new strategy
        vm_std_cheats.prank(strategist);
        address newStrategyAddr = deployStrategy(address(vault));
        vault.migrateStrategy(address(strategy), newStrategyAddr);
        assertRelApproxEq(
            Str8Vesta(payable(newStrategyAddr)).estimatedTotalAssets(),
            _amount,
            ONE_BIP_REL_DELTA
        );
    }

    // Test that migrate does not complete if called withen 1 day of the latest deposit due to tokens being locked
    function testFailMigration(uint256 _amount) public { 
        vm_std_cheats.assume(_amount > 1 ether && _amount < 10_000 ether);

        // Deposit to the vault and harvest
        vm_std_cheats.prank(user);
        want.approve(address(vault), _amount);
        vm_std_cheats.prank(user);
        vault.deposit(_amount);
        strategy.harvest();
        
        assertEq(want.balanceOf(address(strategy)), 0);
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);
        // Migrate to a new strategy
        vm_std_cheats.prank(strategist);
        address newStrategyAddr = deployStrategy(address(vault));
        
        vault.migrateStrategy(address(strategy), newStrategyAddr);

        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);
    }
}
