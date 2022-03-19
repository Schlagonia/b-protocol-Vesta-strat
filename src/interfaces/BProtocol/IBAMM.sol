// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;

interface IBAMM {
    event ParamsSet(uint256 A, uint256 fee);
    event UserDeposit(
        address indexed user,
        uint256 lusdAmount,
        uint256 numShares
    );
    event UserWithdraw(
        address indexed user,
        uint256 lusdAmount,
        uint256 ethAmount,
        uint256 numShares
    );
    event RebalanceSwap(
        address indexed user,
        uint256 lusdAmount,
        uint256 ethAmount,
        uint256 timestamp
    );

    function fetchPrice() external view returns (uint256);

    function deposit(uint256 lusdAmount) external;

    function withdraw(uint256 numShares) external;

    function compensateForLusdDeviation(uint256 ethAmount)
        external
        view
        returns (uint256 newEthAmount);

    function getSwapEthAmount(uint256 lusdQty)
        external
        view
        returns (uint256 ethAmount, uint256 feeLusdAmount);

    function swap(
        uint256 lusdAmount,
        uint256 minEthReturn,
        address payable dest
    ) external returns (uint256);
}
