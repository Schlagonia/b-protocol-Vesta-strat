// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "./interfaces/<protocol>/<Interface>.sol";
import "./interfaces/BProtocol/IBAMM.sol";
import "./interfaces/Liquity/IStabilityPool.sol";
import "./interfaces/Curve/StableSwapExchange.sol";
import "./interfaces/Uniswap/ISwapRouter.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    IBAMM public constant bProtocolPool =
        IBAMM(0x00FF66AB8699AAfa050EE5EF5041D1503aa0849a);
    IStabilityPool public constant liquityStabilityPool =
        IStabilityPool(0x66017D22b0f8556afDd19FC67041899Eb65a21bb);

    // DAI - Used for swaps routing
    IERC20 internal constant DAI =
        IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 internal constant LQTY =
        IERC20(0x6DEA81C8171D0bA574754EF6F8b412F2Ed88c54D);
    IERC20 internal constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // LUSD3CRV Curve Metapool
    IStableSwapExchange internal constant curvePool =
        IStableSwapExchange(0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA);

    // Uniswap v3 router
    ISwapRouter internal constant router =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    
    // 100%
    uint256 internal constant MAX_BPS = 10000;

    // Minimum expected output when swapping
    // This should be relative to MAX_BPS representing 100%
    uint256 public minExpectedSwapPercentage;

    uint24 public ethToDaiFee;
    uint24 public lqtyToEthFee;

    // solhint-disable-next-line no-empty-blocks
    constructor(address _vault) BaseStrategy(_vault) {
        ethToDaiFee = 3000;
        lqtyToEthFee = 3000;

        // Allow 1% slippage by default
        minExpectedSwapPercentage = 9900;

        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return "StrategyBProtocolLiquityLUSD";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant() + valueOfPoolTokens();
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    // solhint-disable-next-line no-empty-blocks
    {
        // First, claim & sell any LQTY.

        _sellAvailableRewards();

        // Second, run initial profit + loss calculations.

        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;

        if (_totalAssets >= _totalDebt) {
            // Implicitly, _profit & _loss are 0 before we change them.
            _profit = _totalAssets - _totalDebt;
        } else {
            _loss = _totalDebt - _totalAssets;
        }

        // Third, free up _debtOutstanding + our profit, and make any necessary adjustments to the accounting.

        (uint256 _amountFreed, uint256 _liquidationLoss) = liquidatePosition(
            _debtOutstanding + _profit
        );

        _loss = _loss + _liquidationLoss;

        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            _loss = _loss - _profit;
            _profit = 0;
        } else {
            _profit = _profit - _loss;
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _liquidWant = balanceOfWant();

        if (_liquidWant > _debtOutstanding) {
            uint256 _amountToDeposit = _liquidWant - _debtOutstanding;

            _checkAllowance(
                address(bProtocolPool),
                address(want),
                _amountToDeposit
            );

            bProtocolPool.deposit(_amountToDeposit);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // Maintains invariant `want.balanceOf(this) >= _liquidatedAmount`
        // Maintains invariant `_liquidatedAmount + _loss <= _amountNeeded`
        _amountNeeded = Math.min(_amountNeeded, estimatedTotalAssets()); // This makes it safe to request to liquidate more than we have

        uint256 _liquidWant = balanceOfWant();

        if (_liquidWant >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        uint256 _wantToWithdraw = _amountNeeded - _liquidWant;

        uint256 _sharesToWithdraw = (_wantToWithdraw * 1e18) /
            wantValuePerPoolToken();

        bProtocolPool.withdraw(_sharesToWithdraw);
        _sellAvailableETH(); // Withdrawing will sometimes give us some ETH if B.Protocol hasn't already rebalanced it away

        _liquidWant = balanceOfWant();

        if (_liquidWant >= _amountNeeded) {
            _liquidatedAmount = _amountNeeded;
        } else {
            _liquidatedAmount = _liquidWant;
            _loss = _amountNeeded - _liquidWant;
        }
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidatePosition(estimatedTotalAssets());
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary
    // solhint-disable-next-line no-empty-blocks
    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    // solhint-disable-next-line no-empty-blocks
    {

    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return (_amtInWei * ethPrice()) / 1e18;
    }

    // ---------- HELPER & UTILITY FUNCTIONS ------------

    function _sellAvailableRewards() internal {
        bProtocolPool.withdraw(0); // Should trigger the contract to send us our LQTY rewards

        // Convert LQTY rewards to DAI
        if (LQTY.balanceOf(address(this)) > 0) {
            _sellLQTYforDAI();
        }

        _sellAvailableETH(); // This will handle converting that DAI back into want
    }

    function _sellAvailableETH() internal {
        if (address(this).balance > 0) {
            _sellETHforDAI();
        }

        if (DAI.balanceOf(address(this)) > 0) {
            _sellDAIforLUSD();
        }
    }

    function _sellLQTYforDAI() internal {
        _checkAllowance(address(router), address(LQTY), LQTY.balanceOf(address(this)));

        bytes memory path = abi.encodePacked(
            address(LQTY), // LQTY-ETH
            lqtyToEthFee,
            address(WETH), // ETH-DAI
            ethToDaiFee,
            address(DAI)
        );

        // Proceeds from LQTY are not subject to minExpectedSwapPercentage
        // so they could get sandwiched if we end up in an uncle block
        router.exactInput(
            ISwapRouter.ExactInputParams(
                path,
                address(this),
                block.timestamp,
                LQTY.balanceOf(address(this)),
                0
            )
        );
    }

    function _sellETHforDAI() internal {
        uint256 _ethUSD = bProtocolPool.fetchPrice();
        uint256 _ethBalance = address(this).balance;

        // Balance * Price * Swap Percentage (adjusted to 18 decimals)
        uint256 _minExpected = (_ethBalance
            * _ethUSD
            * minExpectedSwapPercentage) / (MAX_BPS * 1e18);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams(
                address(WETH), // tokenIn
                address(DAI), // tokenOut
                ethToDaiFee, // ETH-DAI fee
                address(this), // recipient
                block.timestamp, // deadline
                _ethBalance, // amountIn
                _minExpected, // amountOut
                0 // sqrtPriceLimitX96
            );

        router.exactInputSingle{value: address(this).balance}(params);
        router.refundETH();
    }

    function _sellDAIforLUSD() internal {
        uint256 _daiBalance = DAI.balanceOf(address(this));

        _checkAllowance(address(curvePool), address(DAI), _daiBalance);

        curvePool.exchange_underlying(
            1, // from DAI index
            0, // to LUSD index
            _daiBalance, // amount
            (_daiBalance * minExpectedSwapPercentage) / MAX_BPS // minDy
        );
    }

    // _checkAllowance adapted from https://github.com/therealmonoloco/liquity-stability-pool-strategy/blob/1fb0b00d24e0f5621f1e57def98c26900d551089/contracts/Strategy.sol#L316

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, _amount);
        }
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfPoolTokens() public view returns (uint256) {
        return IERC20(address(bProtocolPool)).balanceOf(address(this)); // Pool is not fully ERC-20 compatible (there's no transfer function), but balanceOf should be fine.
    }

    function valueOfPoolTokens() public view returns (uint256) {
        uint256 _poolTokenBalance = balanceOfPoolTokens();

        uint256 _valuePerPoolToken = wantValuePerPoolToken();

        return (_poolTokenBalance * _valuePerPoolToken) / 1e18;
    }

    function wantValuePerPoolToken() public view returns (uint256) {
        return
            (totalValueInBProtocolPool() * 1e18) /
            IERC20(address(bProtocolPool)).totalSupply();
    }

    function ethPrice() public view returns (uint256 _ethPrice) {
        uint256 _ethPrice = bProtocolPool.fetchPrice();
        require(_ethPrice > 0, "!oracle_working");
    }

    // Returns the total amount of value, in want (LUSD), in the B.Protocol pool
    function totalValueInBProtocolPool() public view returns (uint256) {
        uint256 _wantOwnedByBProtocolPool = liquityStabilityPool
            .getCompoundedLUSDDeposit(address(bProtocolPool));
        uint256 _ethOwnedByBProtocolPool = liquityStabilityPool
            .getDepositorETHGain(address(bProtocolPool)) +
            address(bProtocolPool).balance;

        return
            _wantOwnedByBProtocolPool +
            ((_ethOwnedByBProtocolPool * ethPrice()) / 1e18);
    }

    // ------------ MANAGEMENT FUNCTIONS -------------

    // Ideally we would receive fair market value by performing every swap
    // through Flashbots. However, since we may be swapping capital and not
    // only profits, it is important to do our best to avoid bad swaps or
    // sandwiches in case we end up in an uncle block.
    function setMinExpectedSwapPercentage(uint256 _minExpectedSwapPercentage)
        external
        onlyEmergencyAuthorized
    {
        minExpectedSwapPercentage = _minExpectedSwapPercentage;
    }

}
