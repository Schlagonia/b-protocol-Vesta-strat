// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Extended} from "./interfaces/IERC20Extended.sol";

import "./interfaces/Vesta/IStabilityPool.sol";
import "./interfaces/Chainlink/AggregatorV3Interface.sol";
import "./interfaces/Balancer/IBalancerVault.sol";
import "./interfaces/Balancer/IBalancerPool.sol";
import "./interfaces/Balancer/IAsset.sol";
import "./interfaces/WETH/IWETH9.sol";

contract Str8Vesta is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    IStabilityPool public constant stabilityPool =
        IStabilityPool(0x64cA46508ad4559E1fD94B3cf48f3164B4a77E42); 

    IERC20 internal constant VSTA =
        IERC20(0xa684cd057951541187f288294a1e1C2646aA2d24);
    IWETH9 internal constant WETH =
        IWETH9(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    // USDC used for swaps routing
    address internal constant usdc =
        address(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);

    IBalancerVault internal constant balancerVault =
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    AggregatorV3Interface internal constant priceFeed = AggregatorV3Interface(0x190b8C66E8e1694Ae9Ff16170122Feb2D287820f);
    
    address public constant vstaPool = address(0xC61ff48f94D801c1ceFaCE0289085197B5ec44F0);
    bytes32 public immutable vstaPoolId;
    address public constant wethUsdcPool = address(0x64541216bAFFFEec8ea535BB71Fbc927831d0595);
    bytes32 public immutable wethUsdcPoolId;
    address public constant usdcVstPool = address(0x5A5884FC31948D59DF2aEcCCa143dE900d49e1a3);
    bytes32 public immutable usdcVstPoolId;

    // 100%
    uint256 internal constant MAX_BPS = 10000;

    // Minimum expected output when swapping
    // This should be relative to MAX_BPS representing 100%
    uint256 public minExpectedSwapPercentageBips;

    uint256 private immutable wantDecimals;
    uint256 private immutable minWant;
    uint256 public immutable maxSingleInvest;

    constructor(address _vault) BaseStrategy(_vault) {
        // Allow .5% slippage by default
        minExpectedSwapPercentageBips = 9950;

        want.safeApprove(address(stabilityPool), type(uint256).max); // All want will be in pool, so this doesn't add sec risk

        vstaPoolId = IBalancerPool(vstaPool).getPoolId();
        wethUsdcPoolId = IBalancerPool(wethUsdcPool).getPoolId();
        usdcVstPoolId = IBalancerPool(usdcVstPool).getPoolId();

        wantDecimals = IERC20Extended(address(want)).decimals();

        minWant = 10 ** (wantDecimals - 3);
        maxSingleInvest = 10 ** (wantDecimals + 6);
    }

    function name() external pure override returns (string memory) {
        return "Str8VestaVST";
    }

    // B.Protocol needs to send ETH to strat
    receive() external payable {}    

    function estimatedTotalAssets() public view override returns (uint256) {
        unchecked {
            return balanceOfWant() + vstStaked() + availableEthTowant();
        }
    }

    //predicts our profit at next report
    function expectedReturn() public view returns (uint256) {
        uint256 estimateAssets = estimatedTotalAssets();

        uint256 debt = vault.strategies(address(this)).totalDebt;
        if (debt > estimateAssets) {
            return 0;
        } else {
            unchecked {
                return estimateAssets - debt;
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        //we are spending all our cash unless we have debt outstanding
        uint256 _wantBal = want.balanceOf(address(this));
        if (_wantBal < _debtOutstanding) {
            withdrawSome(_debtOutstanding - _wantBal);
            return;
        }

        // send all of our want tokens to be deposited
        uint256 toInvest = _wantBal - _debtOutstanding;

        uint256 _wantToInvest = Math.min(toInvest, maxSingleInvest);
        // deposit and stake
        depositSome(_wantToInvest);
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        _profit = 0;
        _loss = 0; 
        _debtPayment = 0;

        // Liquidate position so that everything is in want
        //Rewards are payed out based on amount withdrawn so this is the best way to get all rewards to the strat
        harvester();

        //get base want balance
        uint256 wantBalance = want.balanceOf(address(this));

        uint256 balance = wantBalance + vstStaked();

        //get amount given to strat by vault
        uint256 debt = vault.strategies(address(this)).totalDebt;

        //Check to see if there is nothing invested
        if (balance == 0 && debt == 0) {
            return (_profit, _loss, _debtPayment);
        }

        //Balance - Total Debt is profit
        if (balance >= debt) {
            _profit = balance - debt;

            uint256 needed = _profit + _debtOutstanding;
            if (needed > wantBalance) {
                withdrawSome(needed - wantBalance);

                wantBalance = want.balanceOf(address(this));

                if (wantBalance < needed) {
                    if (_profit >= wantBalance) {
                        _profit = wantBalance;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min((wantBalance - _profit), _debtOutstanding);
                    }
                } else {
                    _debtPayment = _debtOutstanding;
                }
            } else {
                _debtPayment = _debtOutstanding;
            }
        } else {
            _loss = debt - balance;
            if (_debtOutstanding > wantBalance) {
                withdrawSome(_debtOutstanding - wantBalance);
                wantBalance = want.balanceOf(address(this));
            }

            _debtPayment = Math.min(wantBalance, _debtOutstanding);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // Maintains invariant `want.balanceOf(this) >= _liquidatedAmount`
        // Maintains invariant `_liquidatedAmount + _loss <= _amountNeeded`

        uint256 _liquidWant = balanceOfWant();

        if (_liquidWant >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        withdrawSome(_amountNeeded - _liquidWant);

        _liquidWant = balanceOfWant();

        unchecked {

            if (_liquidWant >= _amountNeeded) {
                _liquidatedAmount = _amountNeeded;
            } else {
                _liquidatedAmount = _liquidWant;
                _loss = _amountNeeded - _liquidWant;
            }
        }
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        if(vstStaked() > 0){ 
            stabilityPool.withdrawFromSP(type(uint256).max);
        }

        // Claim & sell any VSTA & ETH.
        _sellAvailableRewards();

        return balanceOfWant();
    }
    
    function prepareMigration(address /*_newStrategy*/) internal override {
        liquidateAllPositions();
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {
        return (_amtInWei * getWethPrice()) / 1e18; // Assumes that 1 VST = 1 USD
    }

    // ---------- HELPER & UTILITY FUNCTIONS ------------

    function vstStaked() public view returns(uint256) {
        return stabilityPool.getCompoundedVSTDeposit(address(this));
    }
    
    function depositSome(uint256 _amount) internal {
        if (_amount < minWant) {
            return;
        }

        stabilityPool.provideToSP(_amount);
    }

    function withdrawSome(uint256 _amount) internal {
        if(_amount == 0) {
            return;
        }

        //If we dont have enough staked we may be able to sell seized token or rewards to account for it
        if(_amount > vstStaked()) {
            liquidateAllPositions();
            return;
        }

        stabilityPool.withdrawFromSP(_amount);
    }

    function harvester() internal {
        if(vstStaked() == 0) {
            return;
        }

        stabilityPool.withdrawFromSP(0);
        _sellAvailableRewards();
    }

    //Only gets called after all positions have been withdrawn previously
    function _sellAvailableRewards() internal {

        // Convert VSTA rewards to WETH
        if (balanceOfVSTA() > 0) {
            _sellVSTAforWeth();
        }

        _sellAvailableETH(); //Converts all ETH -> WETH -> USDC -> VST
    }

    function sellAvailableETH() external onlyVaultManagers {
        _sellAvailableETH();
    }

    function _sellVSTAforWeth() internal {
        uint256 _amountToSell = balanceOfVSTA();

        _checkAllowance(
            address(balancerVault),
            address(VSTA),
            _amountToSell
        );

        //single swap balancer from vsta to weth
        IBalancerVault.SingleSwap memory singleSwap =
            IBalancerVault.SingleSwap(
                vstaPoolId,
                IBalancerVault.SwapKind.GIVEN_IN,
                IAsset(address(VSTA)),
                IAsset(address(WETH)),
                _amountToSell,
                abi.encode(0)
                );  

        IBalancerVault.FundManagement memory fundManagement =
            IBalancerVault.FundManagement(
                address(this),
                false,
                payable(address(this)),
                false
            );


        balancerVault.swap(
            singleSwap,
            fundManagement,
            0,
            block.timestamp
        );
        
    }

    function _sellAvailableETH() internal {
        if (address(this).balance > 0) {
            _wrapEth();
        }

        _sellWethForVST();
    }

    function _sellWethForVST() internal {
        uint256 wethBalance = WETH.balanceOf(address(this));

        if(wethBalance == 0) {
            return;
        }
        _checkAllowance(address(balancerVault), address(WETH), wethBalance);

        //Batch swap from WETH -> USDC -> VST
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](2);

        swaps[0] = IBalancerVault.BatchSwapStep(
                wethUsdcPoolId,
                0,
                1,
                wethBalance,
                abi.encode(0)
            );

        swaps[1] = IBalancerVault.BatchSwapStep(
                usdcVstPoolId,
                1,
                2,
                0,
                abi.encode(0)
            );

        IAsset[] memory assets = new IAsset[](3);
        assets[0] = IAsset(address(WETH));
        assets[1] = IAsset(usdc);
        assets[2] = IAsset(address(want));

        IBalancerVault.FundManagement memory fundManagement =
            IBalancerVault.FundManagement(
                address(this),
                false,
                payable(address(this)),
                false
            );
        
        int[] memory limits = new int[](3);
        limits[0] = int(wethBalance);
            
        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN, 
            swaps, 
            assets, 
            fundManagement, 
            limits, 
            block.timestamp
            );
    }

    function _wrapEth() internal {
        WETH.deposit{ value: address(this).balance}();
    }

    // _checkAllowance adapted from https://github.com/therealmonoloco/liquity-stability-pool-strategy/blob/1fb0b00d24e0f5621f1e57def98c26900d551089/contracts/Strategy.sol#L316

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        uint256 _currentAllowance = IERC20(_token).allowance(
            address(this),
            _contract
        );
        if (_currentAllowance < _amount) {
            IERC20(_token).safeIncreaseAllowance(
                _contract,
                _amount - _currentAllowance
            );
        }
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfVSTA() public view returns (uint256) {
        return VSTA.balanceOf(address(this));
    }

    function availableEthTowant() public view returns (uint256) {
        uint256 availableEth = address(this).balance + stabilityPool.getDepositorAssetGain(address(this));

        return ethToWant(availableEth);
    }
 
    //return price of eth based on oracle call
    function getWethPrice() internal view returns(uint256) {
        (
            /*uint80 roundID*/,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = priceFeed.latestRoundData();

        return uint256(price) * 1 ether / (10 ** priceFeed.decimals());
    }

    // ------------ MANAGEMENT FUNCTIONS -------------

    // Ideally we would receive fair market value by performing every swap
    // through Flashbots. However, since we may be swapping capital and not
    // only profits, it is important to do our best to avoid bad swaps or
    // sandwiches in case we end up in an uncle block.
    function setMinExpectedSwapPercentage(uint256 _minExpectedSwapPercentageBips)
        external
        onlyEmergencyAuthorized
    {
        require(_minExpectedSwapPercentageBips <= MAX_BPS, "Thats to many bip's bruh");
        minExpectedSwapPercentageBips = _minExpectedSwapPercentageBips;
    }
}
