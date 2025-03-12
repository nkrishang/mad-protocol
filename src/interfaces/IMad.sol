// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

struct Position {
    uint256 id;
    address owner;
    uint256 debt;
    uint256 collateral;
}

interface IMad {}
