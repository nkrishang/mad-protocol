// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOracle {
    /// @notice Returns the scale/decimals of USD price of native token.
    function scale() external view returns (uint8);

    /// @notice Returns the price of 1 native token in USD.
    function price() external view returns (uint256);
}
