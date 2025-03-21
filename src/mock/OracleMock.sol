// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracle} from "../interfaces/IOracle.sol";

contract OracleMock is IOracle {
    function scale() external pure returns (uint8) {
        return 8;
    }

    function price() external view returns (uint256) {
        if (block.timestamp == 0) {
            return 3 * 1e7; // 0.3
        }

        if (block.timestamp % 5 == 0) {
            return 25 * 1e6; // 0.25
        } else if (block.timestamp % 3 == 0) {
            return 35 * 1e6; // 0.35
        } else {
            return 3 * 1e7; // 0.3
        }
    }
}
