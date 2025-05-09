// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../lib/forge-std/src/Test.sol";

import {MAD} from "src/MAD.sol";
import {OracleMock} from "src/mock/OracleMock.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import {WETH} from "lib/solady/src/tokens/WETH.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

contract BaseTest is Test {
    using FixedPointMathLib for int256;
    using FixedPointMathLib for uint256;

    // Test Constants
    uint256 internal constant BLOCK_TIME = 1;
    uint256 internal constant ORACLE_PRICE_SCALE = 8;
    uint256 internal constant ORACLE_MIN_PRICE = 25000000;
    uint256 internal constant ORACLE_AVG_PRICE = 30000000;
    uint256 internal constant ORACLE_MAX_PRICE = 35000000;
    uint256 internal constant MAX_COLLATERAL_AMOUNT = 1e40;
    uint256 internal constant MAX_BORROW_AMOUNT = 9e39;
    uint256 internal constant MAX_LTV = 0.9 ether;

    // Contract Constants
    uint256 internal constant MIN_COLLATERAL_VALUE_UNSCALED = 2000;

    uint256 internal constant DECAY_RATE_SCALED = 0.89 ether;
    uint256 internal constant BASE_FEE_RATE_BPS = 0.01 ether;
    uint256 internal constant MAX_VARIABLE_FEE_RATE_BPS = 0.04 ether;

    // Stakeholders
    address internal USER;
    address internal SOMEONE;
    address internal RECEIVER;
    address internal LIQUIDATOR;
    address internal INSURANCE_RESERVE;

    // Contracts
    MAD internal mad;
    WETH internal weth;
    IOracle internal oracle;

    function setUp() public virtual {
        USER = makeAddr("User");
        SOMEONE = makeAddr("Someone");
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

        vm.prank(SOMEONE);
        weth.approve(address(mad), type(uint256).max);

        vm.prank(RECEIVER);
        weth.approve(address(mad), type(uint256).max);

        vm.prank(LIQUIDATOR);
        weth.approve(address(mad), type(uint256).max);

        vm.prank(INSURANCE_RESERVE);
        weth.approve(address(mad), type(uint256).max);

        if (block.timestamp == 0) {
            _forward(50);
        }
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

    /// @dev Calculates the minimum collateral amount at an oracle price.
    function _minimumCollateral(uint256 oraclePrice) internal pure returns (uint256) {
        return (MIN_COLLATERAL_VALUE_UNSCALED * 1 ether).divWadUp((oraclePrice * 1 ether) / (10 ** ORACLE_PRICE_SCALE));
    }

    /// @dev Calculates the maximum debt amount at a collateral amount and oracle price.
    function _maximumBorrow(uint256 collateral, uint256 oraclePrice) internal view returns (uint256) {
        // Get maximum collateral value.
        uint256 collateralValue = collateral.mulWad((oraclePrice * 1 ether) / (10 ** ORACLE_PRICE_SCALE));

        // Get max debt against collateral
        uint256 maxDebt = collateralValue.mulWad(0.9 ether);

        // Get variable fee rate calculated as `r(n) = r(n-1) * (decay ^ hoursElapsed)`.
        uint256 currentVariableRate = mad.variableFeeRate().mulWadUp(
            uint256(
                int256(DECAY_RATE_SCALED).powWad(int256((block.timestamp - mad.lastFeeUpdateTimestamp()) / 1 hours))
            )
        );
        uint256 rate = BASE_FEE_RATE_BPS + currentVariableRate;

        // Get max borrow amount
        uint256 borrow = maxDebt.divWadUp(1 ether + rate);

        return borrow;
    }
}
