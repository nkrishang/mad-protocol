// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../BaseTest.t.sol";

import {MAD} from "src/MAD.sol";
import {OracleMock} from "src/mock/OracleMock.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

contract SupplyCollateralIntegrationTest is BaseTest {
    using FixedPointMathLib for uint256;

    event Supply(uint256 indexed id, uint256 collateral);
    
    function testSupplyCollateralRevertPositionDNE(uint256 positionId) public {
        vm.expectRevert(MAD.PositionDNE.selector);
        mad.supplyCollateral(positionId, 100);
    }

    function testSupplyCollateralSuccessful(uint256 collateral, uint256 supply) public {
        collateral = bound(collateral, _minimumCollateral(ORACLE_MIN_PRICE), MAX_COLLATERAL_AMOUNT);
        supply = bound(collateral, _minimumCollateral(ORACLE_MIN_PRICE), MAX_COLLATERAL_AMOUNT);

        uint256 borrow = _maximumBorrow(collateral, ORACLE_MIN_PRICE);


        vm.deal(USER, collateral + supply);
        vm.prank(USER);
        weth.deposit{value: collateral + supply}();
        
        
        uint256 debt = borrow + borrow.mulWadUp(BASE_FEE_RATE_BPS);
        uint256 positionId = mad.nextPositionId();

        vm.prank(USER);
        mad.mint(collateral, borrow, RECEIVER);

        assertEq(mad.totalSupply(), borrow);
        assertEq(mad.debtPerDebtPoint(), 1);
        assertEq(mad.totalSystemDebtPoints(), debt);
        assertEq(mad.collateralPerCollateralPoint(), 1);
        assertEq(mad.totalSystemCollateralPoints(), collateral);

        (,,, uint256 collateralPointsPre) = mad.positions(positionId);
        assertEq(collateralPointsPre, collateral);

        assertEq(weth.balanceOf(address(mad)), collateral);
        assertEq(weth.balanceOf(USER), supply);

        vm.prank(USER);
        vm.expectEmit(true, false, false, true, address(mad));
        emit Supply(positionId, supply);
        mad.supplyCollateral(positionId, supply);

        assertEq(mad.totalSystemCollateralPoints(), collateral + supply);

        (,,, uint256 collateralPointsPost) = mad.positions(positionId);
        assertEq(collateralPointsPost, collateral + supply);

        assertEq(weth.balanceOf(address(mad)), collateral + supply);
        assertEq(weth.balanceOf(USER), 0);
    }
}