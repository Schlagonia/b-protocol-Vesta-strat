// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
import "forge-std/console.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../interfaces/Chainlink/AggregatorV3Interface.sol";

import "../../interfaces/Vesta/IStabilityPool.sol";
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
        
        skip(3 * ONE_MINUTE);
        vm_std_cheats.prank(user);
        vault.withdraw();

        assertRelApproxEq(want.balanceOf(user), balanceBefore, ONE_BIP_REL_DELTA);
    }

    function testEmergencyExit(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 1 ether && _amount < 10_000 ether);

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
        vm_std_cheats.assume(_amount > 1 ether && _amount < 10_000 ether);

        uint256 balanceBefore = want.balanceOf(address(user));
        depositToVault(user, vault, _amount);

        // Harvest 1: Send funds through the strategy
        skip(1);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);

        uint256 beforePps = vault.pricePerShare();

        tip(address(VSTA), address(strategy), _amount / 1000); // 1 LQTY airdrop for every 1000 LUSD in strat

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

    // Simulate some B.AMM ETH coming back into strat
    function testOperationsWithETH(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 100 ether && _amount < 10_000 ether);

        uint256 balanceBefore = want.balanceOf(address(user));
        depositToVault(user, vault, _amount);

        skip(3 * ONE_MINUTE);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA); 
        assertEq(address(strategy).balance, 0);

        vm_std_cheats.deal(address(strategy), 1 ether);

        skip(3 * ONE_MINUTE);
        uint256 _amountToWithdraw = vault.balanceOf(user) / 2;
        vm_std_cheats.prank(user);
        vault.withdraw(_amountToWithdraw); // This should call liquidatePosition, which will get some ETH into the strat

        assertGt(address(strategy).balance, 2);

        skip(3 * ONE_MINUTE);
        strategy.harvest();
        assertEq(address(strategy).balance, 0);

        uint256 profit = want.balanceOf(address(vault));
        assertGt(profit, 1);
    }

    // Run it back but this time instead of harvest use sellAvailableETH to dispose of ETH
    function testOperationsWithETHManualSell(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 100 ether && _amount < 10_000 ether);

        depositToVault(user, vault, _amount);

        skip(3 * ONE_MINUTE);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA); 
        assertEq(address(strategy).balance, 0);

        uint256 _strategyAssetsBeforeETH = strategy.estimatedTotalAssets();

        vm_std_cheats.deal(address(strategy), .1 ether);

        skip(30 * ONE_MINUTE);
        uint256 _amountToWithdraw = vault.balanceOf(user) / 2;
        vm_std_cheats.prank(user);
        vault.withdraw(_amountToWithdraw); // This should call liquidatePosition, which will get some ETH into the strat

        assertGt(address(strategy).balance, 0);

        strategy.sellAvailableETH();
        assertEq(address(strategy).balance, 0);
        assertGt(strategy.estimatedTotalAssets(), _strategyAssetsBeforeETH / 2);
        
        skip(3 * ONE_MINUTE);
        strategy.harvest();

        uint256 profit = want.balanceOf(address(vault));
        assertGt(profit, 0);
    }
    
    // Simulate B.AMM not able to sell the ETH and the price moves against us
    function testIncurLosses(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 100 ether && _amount < 10_000 ether);

        uint256 balanceBefore = want.balanceOf(address(user));
        depositToVault(user, vault, _amount);

        skip(3 * ONE_MINUTE);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA); 
        assertEq(address(strategy).balance, 0);

        vm_std_cheats.deal(stabilityPool, 0.1 ether);

        uint256 _strategyShares = IStabilityPool(stabilityPool).getCompoundedVSTDeposit(address(strategy));

        vm_std_cheats.startPrank(address(strategy));
        IStabilityPool(stabilityPool).withdrawFromSP(_strategyShares / 10); 
        want.transfer(address(777), want.balanceOf(address(strategy))); // Throw away 10% of value to sim losses
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

        uint256 _strategyShares = IStabilityPool(stabilityPool).getCompoundedVSTDeposit(address(strategy));
        vm_std_cheats.startPrank(address(strategy));
        IStabilityPool(stabilityPool).withdrawFromSP(_strategyShares / 1000); 
        want.transfer(address(777), want.balanceOf(address(strategy))); // Throw away 0.1% of value to sim losses
        vm_std_cheats.stopPrank();

        vm_std_cheats.deal(stabilityPool, 40 ether);
        vm_std_cheats.deal(address(strategy), .1 ether);

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
        assertEq(address(strategy).balance, 0);
        assertEq(VSTA.balanceOf(address(strategy)), 0);

        vm_std_cheats.deal(stabilityPool, 1 ether);
        vm_std_cheats.deal(address(strategy), 1 ether);
        //vm_std_cheats.prank(0xC9032419AA502fAFA107775DCa8b7d07575d9DB5); //Vest Multisig
        //VSTA.transfer(bProtocolPool, 10 ether);

        skip(30 * ONE_MINUTE);
        uint256 _amountToWithdraw = vault.balanceOf(user) / 2;
        vm_std_cheats.prank(user);
        vault.withdraw(_amountToWithdraw); // This should call liquidatePosition, which will get some ETH into the strat

        assertGt(address(strategy).balance, 0);
        assertGt(VSTA.balanceOf(address(strategy)), 0);

        skip(3 * ONE_MINUTE);
        strategy.harvest();
        assertEq(address(strategy).balance, 0);
        assertEq(VSTA.balanceOf(address(strategy)), 0);
  
        uint256 profit = want.balanceOf(address(vault));
        assertGt(profit, 0);

        skip(3600 * 6);

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

        tip(address(VSTA), address(strategy), _amount / 1000); // 1 LQTY airdrop for every 1000 LUSD in strat

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
}