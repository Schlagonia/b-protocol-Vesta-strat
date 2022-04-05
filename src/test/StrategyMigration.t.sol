// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import {StrategyFixture} from "./utils/StrategyFixture.sol";

// NOTE: if the name of the strat or file changes this needs to be updated
import {Strategy} from "../Strategy.sol";

contract StrategyMigrationTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testMigration(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 0.01 ether && _amount < 100_000_000 ether);

        // Deposit to the vault and harvest
        vm_std_cheats.prank(user);
        want.approve(address(vault), _amount);
        vm_std_cheats.prank(user);
        vault.deposit(_amount);
        skip(1);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);

        // Migrate to a new strategy
        vm_std_cheats.prank(strategist);
        address newStrategyAddr = deployStrategy(address(vault));
        vault.migrateStrategy(address(strategy), newStrategyAddr);
        assertRelApproxEq(
            Strategy(payable(newStrategyAddr)).estimatedTotalAssets(),
            _amount,
            ONE_BIP_REL_DELTA
        );
    }

    // Test that migrate sends ETH to new strategy
    function testMigrationWithETH(uint256 _amount) public { 
    }
}
