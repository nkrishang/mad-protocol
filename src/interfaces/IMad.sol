// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

struct Position {
    uint256 id;
    address owner;
    uint256 debtPoints;
    uint256 cancelledDebt;
    uint256 collateralPoints;
    uint256 cancelledCollateral;
}

interface IMad {}
