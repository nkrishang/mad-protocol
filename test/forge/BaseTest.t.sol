// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../lib/forge-std/src/Test.sol";

import {MAD} from "src/MAD.sol";
import {OracleMock} from "src/mock/OracleMock.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import {WETH} from "lib/solady/src/tokens/WETH.sol";

contract BaseTest is Test {
    // Test Constants
    uint256 internal constant BLOCK_TIME = 1;

    // Contract Constants
    uint256 internal constant MIN_COLLATERAL_VALUE_UNSCALED = 2000;
    int256 internal constant DECAY_RATE_SCALED = 0.89 ether;
    uint256 internal constant BASE_FEE_RATE_BPS = 0.01 ether;
    uint256 internal constant MAX_VARIABLE_FEE_RATE_BPS = 0.04 ether;

    // Stakeholders
    address internal USER;
    address internal RECEIVER;
    address internal LIQUIDATOR;
    address internal INSURANCE_RESERVE;

    // Contracts
    MAD internal mad;
    WETH internal weth;
    IOracle internal oracle;

    function setUp() public virtual {
        USER = makeAddr("User");
        RECEIVER = makeAddr("Receiver");
        LIQUIDATOR = makeAddr("Liquidator");
        INSURANCE_RESERVE = makeAddr("Reserve");

        weth = new WETH();
        vm.label(address(weth), "WETH");

        oracle = new OracleMock();
        vm.label(address(oracle), "Oracle");

        mad = new MAD(IOracle(oracle), weth);
        vm.label(address(mad), "MAD");

        vm.prank(USER);
        weth.approve(address(mad), type(uint256).max);

        vm.prank(RECEIVER);
        weth.approve(address(mad), type(uint256).max);

        vm.prank(LIQUIDATOR);
        weth.approve(address(mad), type(uint256).max);

        vm.prank(INSURANCE_RESERVE);
        weth.approve(address(mad), type(uint256).max);
    }

    /// @dev Rolls & warps the given number of blocks forward the blockchain.
    function _forward(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_TIME); // Block speed should depend on test network.
    }

    /// @dev Bounds the fuzzing input to a realistic number of blocks.
    function _boundBlocks(uint256 blocks) internal pure returns (uint256) {
        return bound(blocks, 1, type(uint32).max);
    }
}
