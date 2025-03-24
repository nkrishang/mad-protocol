// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../BaseTest.t.sol";

import {MAD} from "src/MAD.sol";
import {OracleMock} from "src/mock/OracleMock.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

contract CloseIntegrationTest is BaseTest {
    using FixedPointMathLib for uint256;

    event Close(uint256 indexed id, address indexed owner, uint256 debt, uint256 collateral);

    function testCloseRevertPoistionDNE(uint256 id) public {
        vm.expectRevert(MAD.PositionDNE.selector);
        mad.close(id, RECEIVER);
    }

    function testCloseRevertUnauthorizedCaller(address caller) public {
        vm.assume(caller != USER);

        uint256 collateral = _minimumCollateral(ORACLE_MIN_PRICE);
        uint256 borrow = _maximumBorrow(collateral, ORACLE_MIN_PRICE);

        vm.deal(USER, collateral);
        vm.prank(USER);
        weth.deposit{value: collateral}();

        uint256 positionId = mad.nextPositionId();

        vm.prank(USER);
        mad.mint(collateral, borrow, RECEIVER);

        vm.prank(caller);
        vm.expectRevert(MAD.UnauthorizedCaller.selector);
        mad.close(positionId, RECEIVER);
    }

    function testCloseRevertLTVOutOfBounds(uint256 collateral, uint256 crashedPrice) public {
        crashedPrice = bound(crashedPrice, 1, (ORACLE_MIN_PRICE * 9) / 10);
        collateral = bound(collateral, _minimumCollateral(ORACLE_MIN_PRICE), MAX_COLLATERAL_AMOUNT);
        
        uint256 borrow = _maximumBorrow(collateral, ORACLE_MIN_PRICE);

        vm.deal(USER, collateral);
        vm.prank(USER);
        weth.deposit{value: collateral}();

        assertTrue(oracle.price() > crashedPrice);

        uint256 positionId = mad.nextPositionId();

        vm.prank(USER);
        mad.mint(collateral, borrow, RECEIVER);

        OracleMock(address(oracle)).setPrice(crashedPrice);

        vm.expectRevert(MAD.LTVOutOfBounds.selector);
        vm.prank(USER);
        mad.close(positionId, RECEIVER);
    }

    function testCloseSuccessful(uint256 collateral, uint256 borrow) public {
        collateral = bound(collateral, _minimumCollateral(ORACLE_MIN_PRICE), MAX_COLLATERAL_AMOUNT);
        borrow = bound(borrow, 1, _maximumBorrow(collateral, ORACLE_MIN_PRICE));

        vm.deal(USER, collateral);
        vm.prank(USER);
        weth.deposit{value: collateral}();

        vm.deal(SOMEONE, collateral);
        vm.prank(SOMEONE);
        weth.deposit{value: collateral}();

        uint256 positionId = mad.nextPositionId();
        uint256 debt = borrow + borrow.mulWadUp(BASE_FEE_RATE_BPS);

        vm.prank(USER);
        mad.mint(collateral, borrow, USER);

        vm.prank(SOMEONE);
        mad.mint(collateral, borrow, SOMEONE);

        vm.prank(SOMEONE);
        mad.transfer(USER, debt - borrow);

        assertEq(mad.totalSupply(), 2 * borrow);
        assertEq(mad.debtPerDebtPoint(), 1);
        assertEq(mad.totalSystemDebtPoints(), 2 * debt);
        assertEq(mad.collateralPerCollateralPoint(), 1);
        assertEq(mad.totalSystemCollateralPoints(), 2 * collateral);

        assertEq(mad.balanceOf(USER), debt);
        assertEq(weth.balanceOf(address(mad)), 2 * collateral);
        assertEq(weth.balanceOf(USER), 0);

        (uint256 id, address owner, uint256 debtPoints, uint256 collateralPoints) = mad.positions(positionId);
        assertEq(id, positionId);
        assertEq(owner, USER);
        assertEq(debtPoints, debt);
        assertEq(collateralPoints, collateral);

        vm.prank(USER);
        vm.expectEmit(true, true, false, true, address(mad));
        emit Close(positionId, USER, debt, collateral);
        mad.close(positionId, USER);

        assertEq(mad.balanceOf(USER), 0);
        assertEq(weth.balanceOf(address(mad)), collateral);
        assertEq(weth.balanceOf(USER), collateral);

        assertEq(mad.totalSupply(), (2 * borrow) - debt);
        assertEq(mad.debtPerDebtPoint(), 1);
        assertEq(mad.totalSystemDebtPoints(), debt);
        assertEq(mad.collateralPerCollateralPoint(), 1);
        assertEq(mad.totalSystemCollateralPoints(), collateral);
    }
}