// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
import "forge-std/console.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";

import "../interfaces/Chainlink/AggregatorV3Interface.sol";

contract StrategyOperationsTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testStrategyOperation(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 0.01 ether && _amount < 100_000_000 ether);

        uint256 balanceBefore = want.balanceOf(address(user));
        depositToVault(user, vault, _amount);

        skip(3 * ONE_MINUTE);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA); 

        skip(3 * ONE_MINUTE);
        strategy.tend();
        
        skip(3 * ONE_MINUTE);
        vm_std_cheats.prank(user);
        vault.withdraw();

        assertRelApproxEq(want.balanceOf(user), balanceBefore, ONE_BIP_REL_DELTA);
    }

    function testEmergencyExit(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 0.01 ether && _amount < 100_000_000 ether);

        depositToVault(user, vault, _amount);

        skip(1);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);

        strategy.setEmergencyExit();
        skip(1);
        strategy.harvest();

        assertRelApproxEq(strategy.estimatedTotalAssets(), 0, ONE_BIP_REL_DELTA);
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, ONE_BIP_REL_DELTA);
    }

    function testProfitableHarvest(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 0.01 ether && _amount < 100_000_000 ether);

        uint256 balanceBefore = want.balanceOf(address(user));
        depositToVault(user, vault, _amount);

        // Harvest 1: Send funds through the strategy
        skip(1);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);

        uint256 beforePps = vault.pricePerShare();

        tip(address(LQTY), address(strategy), _amount / 1000); // 1 LQTY airdrop for every 1000 LUSD in strat

        // Harvest 2: Realize profit
        skip(1);
        strategy.harvest();

        skip(3600 * 6);

        mockChainlink();

        uint256 profit = want.balanceOf(address(vault));
        assertGt(strategy.estimatedTotalAssets() + profit, _amount);
        assertGt(vault.pricePerShare(), beforePps);

        vm_std_cheats.prank(user);
        vault.withdraw();
        assertGt(want.balanceOf(user), balanceBefore);
    }

    function testChangeDebt(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 0.01 ether && _amount < 100_000_000 ether);

        depositToVault(user, vault, _amount);
        vault.updateStrategyDebtRatio(address(strategy), 5_000);
        skip(1);
        strategy.harvest();
        uint256 half = uint256(_amount / 2);
        assertRelApproxEq(strategy.estimatedTotalAssets(), half, ONE_BIP_REL_DELTA);

        vault.updateStrategyDebtRatio(address(strategy), 10_000);
        skip(1);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);

        vault.updateStrategyDebtRatio(address(strategy), 5_000);
        skip(1);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), half, ONE_BIP_REL_DELTA);
    }

    function testSweep(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 0.01 ether && _amount < 100_000_000 ether);

        vm_std_cheats.prank(user);
        // solhint-disable-next-line
        (bool sent, ) = address(weth).call{value: WETH_AMT}("");
        require(sent, "failed to send ether");

        // Strategy want token doesn't work
        vm_std_cheats.prank(user);
        want.transfer(address(strategy), _amount);
        assertEq(address(want), address(strategy.want()));
        assertGt(want.balanceOf(address(strategy)), 0);

        vm_std_cheats.expectRevert("!want");
        strategy.sweep(address(want));

        // Vault share token doesn't work
        vm_std_cheats.expectRevert("!shares");
        strategy.sweep(address(vault));

        // Protected token doesn't work
        vm_std_cheats.expectRevert("!protected");
        strategy.sweep(0x00FF66AB8699AAfa050EE5EF5041D1503aa0849a); // B.Protocol tokens

        uint256 beforeBalance = weth.balanceOf(address(this));
        vm_std_cheats.prank(user);
        weth.transfer(address(strategy), WETH_AMT);
        assertNeq(address(weth), address(strategy.want()));
        assertEq(weth.balanceOf(address(user)), 0);
        strategy.sweep(address(weth));
        assertEq(weth.balanceOf(address(this)), WETH_AMT + beforeBalance);
    }

    function testTriggers(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 0.01 ether && _amount < 100_000_000 ether);

        // Deposit to the vault and harvest
        vm_std_cheats.prank(user);
        want.approve(address(vault), _amount);
        vm_std_cheats.prank(user);
        vault.deposit(_amount);
        vault.updateStrategyDebtRatio(address(strategy), 5_000);
        skip(1);
        strategy.harvest();

        strategy.harvestTrigger(0);
        strategy.tendTrigger(0);
    }
}
