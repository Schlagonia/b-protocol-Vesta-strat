// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
import "forge-std/console.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IStaker } from "../../interfaces/Frax/IStaker.sol";

import {StrategyParams, IVault} from "../../interfaces/Vault.sol";

contract StrategyOperationsTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testStrategyOperation(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 1 ether && _amount < 10_000 ether);

        uint256 balanceBefore = want.balanceOf(address(user));
        depositToVault(user, vault, _amount);

        skip(3 * ONE_MINUTE);
        strategy.harvest();
        //console.log("Strate Want after harvest ", want.balanceOf(address(strategy)));
        //console.log("VST Staked ", strategy.vstStaked());
        assertEq(want.balanceOf(address(strategy)), 0);
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA); 

        skip(3 * ONE_MINUTE);
        strategy.tend();
        
        skip(toSkip);
        vm_std_cheats.prank(user);
        vault.withdraw();

        assertGe(want.balanceOf(user), balanceBefore);
    }

    function testEmergencyExit(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 1 ether && _amount < 10_000 ether);

        depositToVault(user, vault, _amount);

        skip(1);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);

        strategy.setEmergencyExit();
        skip(toSkip);
        strategy.harvest();

        assertRelApproxEq(strategy.estimatedTotalAssets(), 0, ONE_BIP_REL_DELTA);
        assertGe(want.balanceOf(address(vault)), _amount);
    }

    function testProfitableHarvest(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 1 ether && _amount < 10_000 ether);

        uint256 balanceBefore = want.balanceOf(address(user));
        depositToVault(user, vault, _amount);

        // Harvest 1: Send funds through the strategy
        skip(1);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);

        uint256 beforePps = vault.pricePerShare();

        // Harvest 2: Realize profit
        skip(1);
        strategy.harvest();

        skip(3600 * 6);

        uint256 profit = want.balanceOf(address(vault));
        assertGt(strategy.estimatedTotalAssets() + profit, _amount);
        assertGt(vault.pricePerShare(), beforePps);
        skip(toSkip);
        vm_std_cheats.prank(user);
        vault.withdraw();
        assertGt(want.balanceOf(user), balanceBefore);
    }
    
    // Simulate B.AMM not able to sell the ETH and the price moves against us
    function testIncurLosses(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 100 ether && _amount < 10_000 ether);

        uint256 balanceBefore = want.balanceOf(address(user));
        depositToVault(user, vault, _amount);

        skip(3 * ONE_MINUTE);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA); 
        skip(toSkip);
        IStaker.LockedStake[] memory stakes = staker.lockedStakesOf(address(strategy));
        vm_std_cheats.startPrank(address(strategy));
        staker.withdrawLocked(stakes[0].kek_id);
        want.transfer(address(777), want.balanceOf(address(strategy)) / 10); // Throw away 10% of value to sim losses
        vm_std_cheats.stopPrank();

        strategy.setDoHealthCheck(false);

        skip(3 * ONE_MINUTE);
        strategy.harvest();

        StrategyParams memory params = vault.strategies(address(strategy));
        uint256 loss = params.totalLoss;
        assertGt(loss, 0);
    }

    // Simulate above, but LQTY rewards save us and give us profit
    function testIncurEthLossesButStrategyProfit(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 100 ether && _amount < 10_000 ether);

        uint256 balanceBefore = want.balanceOf(address(user));
        depositToVault(user, vault, _amount);

        skip(3 * ONE_MINUTE);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA); 
        assertEq(address(strategy).balance, 0);
        skip(toSkip);
        IStaker.LockedStake[] memory stakes = staker.lockedStakesOf(address(strategy));
        vm_std_cheats.startPrank(address(strategy));
        staker.withdrawLocked(stakes[0].kek_id);
        want.transfer(address(777), want.balanceOf(address(strategy))/ 1000); // Throw away 0.1% of value to sim losses
        vm_std_cheats.stopPrank();

        tip(address(VSTA), address(strategy), 100 ether);

        skip(3 * ONE_MINUTE);
        strategy.harvest();

        uint256 profit = want.balanceOf(address(vault));
        assertGt(profit, 0);
    }

    function testChangeDebt(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 1 ether && _amount < 10_000 ether);

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
        skip(toSkip);
        vault.updateStrategyDebtRatio(address(strategy), 5_000);
        skip(1);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), half, ONE_BIP_REL_DELTA);
    }

    function testSweep(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 1 ether && _amount < 10_000 ether);

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

        uint256 beforeBalance = weth.balanceOf(address(this));
        vm_std_cheats.prank(user);
        weth.transfer(address(strategy), WETH_AMT);
        assertNeq(address(weth), address(strategy.want()));
        assertEq(weth.balanceOf(address(user)), 0);
        strategy.sweep(address(weth));
        assertEq(weth.balanceOf(address(this)), WETH_AMT + beforeBalance);
    }

    function testTriggers(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 1 ether && _amount < 10_000 ether);

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

    function testHarvestAllRewards(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 100 ether && _amount < 10_000 ether);

        uint256 balanceBefore = want.balanceOf(address(user));
        depositToVault(user, vault, _amount);

        skip(3 * ONE_MINUTE);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA); 
        assertEq(FXS.balanceOf(address(strategy)), 0);
        assertEq(VSTA.balanceOf(address(strategy)), 0);

        skip(2 * toSkip);
        uint256 _amountToWithdraw = vault.balanceOf(user) / 2;
        vm_std_cheats.prank(user);
        vault.withdraw(_amountToWithdraw); // This should call liquidatePosition, which will get some ETH into the strat

        assertGt(FXS.balanceOf(address(strategy)), 0);
        assertGt(VSTA.balanceOf(address(strategy)), 0);

        skip(3 * ONE_MINUTE);
        strategy.harvest();
        assertEq(FXS.balanceOf(address(strategy)), 0);
        assertLe(VSTA.balanceOf(address(strategy)), strategy.minVsta());
  
        uint256 profit = want.balanceOf(address(vault));
        assertGt(profit, 0);

        skip(toSkip);

        vm_std_cheats.prank(user);
        vault.withdraw();
        
        assertGt(want.balanceOf(address(user)), balanceBefore);
    }

    function testLargeDeposit() public {
        uint256 _amount = 100_000 ether;

        uint256 balanceBefore = want.balanceOf(address(user));
        depositToVault(user, vault, _amount);

        // Harvest 1: Send funds through the strategy
        skip(1);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);

        uint256 beforePps = vault.pricePerShare();

        tip(address(VSTA), address(strategy), 1e17); // 1 LQTY airdrop for every 1000 LUSD in strat
        tip(address(FXS), address(strategy), 1e14);
        // Harvest 2: Realize profit
        skip(1);
        strategy.harvest();

        skip(3600 * 6);

        uint256 profit = want.balanceOf(address(vault));
        assertGt(strategy.estimatedTotalAssets() + profit, _amount);
        assertGt(vault.pricePerShare(), beforePps);
        assertEq(VSTA.balanceOf(address(strategy)), 0);
        assertEq(FXS.balanceOf(address(strategy)), 0);
        skip(toSkip);
        vm_std_cheats.prank(user);
        vault.withdraw();
        assertGt(want.balanceOf(user), balanceBefore);
    }

    //Assure we are still earning rewards after the lock period is up
    function testStakingReturns(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 100 ether && _amount < 10_000 ether);

        uint256 balanceBefore = want.balanceOf(address(user));
        depositToVault(user, vault, _amount);

        // Harvest 1: Send funds through the strategy
        skip(1);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);
        skip(toSkip);

        (uint256 fxsEarned, uint256 vstaEarned) = staker.earned(address(strategy));
        assertGt(fxsEarned, 0);
        assertGt(vstaEarned, 0);

        skip(toSkip);

        (uint256 fxsEarned2, uint256 vstaEarned2) = staker.earned(address(strategy));

        assertGt(fxsEarned2, fxsEarned);
        assertGt(vstaEarned2, vstaEarned);

    }

    function testLockPeriods(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 100 ether && _amount < 5_000 ether);

        depositToVault(user, vault, _amount);

        // Harvest 1: Send funds through the strategy
        skip(1);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);
        skip(toSkip);

        depositToVault(user, vault, _amount);
        assertRelApproxEq(strategy.stakedBalance(), _amount, ONE_BIP_REL_DELTA);
        strategy.harvest();
        uint256 balanceBefore = want.balanceOf(address(user));
        vm_std_cheats.prank(user);
        vault.withdraw(_amount);

        assertRelApproxEq(want.balanceOf(address(user)), balanceBefore + _amount, ONE_BIP_REL_DELTA);
    }
}