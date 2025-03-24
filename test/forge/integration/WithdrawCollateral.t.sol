// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../BaseTest.t.sol";

import {MAD} from "src/MAD.sol";
import {OracleMock} from "src/mock/OracleMock.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

contract WithdrawCollateralIntegrationTest is BaseTest {

    using FixedPointMathLib for uint256;
    
    event Withdraw(uint256 indexed id, uint256 collateral);

    function testWithdrawCollateralRevertPositionDNE(uint256 positionId) public {
        vm.expectRevert(MAD.PositionDNE.selector);
        mad.withdrawCollateral(positionId, 1, RECEIVER);
    }

    function testWithdrawCollateralRevertUnauthorizedCaller(address caller) public {
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
        mad.withdrawCollateral(positionId, 1, RECEIVER);
    }

    function testWithdrawCollateralRevertInsufficientCollateral(uint256 collateral, uint256 borrow) public {
        collateral = bound(collateral, _minimumCollateral(ORACLE_MIN_PRICE), MAX_COLLATERAL_AMOUNT);
        borrow = bound(borrow, 1, _maximumBorrow(collateral, ORACLE_MIN_PRICE));

        vm.deal(USER, collateral);
        vm.prank(USER);
        weth.deposit{value: collateral}();

        uint256 positionId = mad.nextPositionId();

        vm.prank(USER);
        mad.mint(collateral, borrow, RECEIVER);

        vm.prank(USER);
        vm.expectRevert(MAD.InsufficientCollateral.selector);
        mad.withdrawCollateral(positionId, collateral + 1, RECEIVER);
    }

    function testWithdrawCollateralRevertLTVOutOfBounds(uint256 collateral, uint256 borrow) public {
        collateral = bound(collateral, _minimumCollateral(ORACLE_MIN_PRICE), MAX_COLLATERAL_AMOUNT);
        borrow = bound(borrow, 1, _maximumBorrow(collateral, ORACLE_MIN_PRICE));

        vm.deal(USER, collateral);
        vm.prank(USER);
        weth.deposit{value: collateral}();

        uint256 positionId = mad.nextPositionId();

        vm.prank(USER);
        mad.mint(collateral, borrow, RECEIVER);

        uint256 priceWad = (oracle.price() * 1 ether) / (10 ** oracle.scale());
        uint256 debt = borrow + borrow.mulWadUp(BASE_FEE_RATE_BPS);
        uint256 maxWithdraw = (collateral.mulWad(priceWad) - debt.divWad(0.9 ether)).divWad(priceWad);

        vm.prank(USER);
        vm.expectRevert(MAD.LTVOutOfBounds.selector);
        mad.withdrawCollateral(positionId, maxWithdraw + 1, RECEIVER);
    }
    
    function testWithdrawCollateralRevertTCROutOfBounds(uint256 crashedPrice) public {
        vm.deal(USER, MAX_COLLATERAL_AMOUNT);
        vm.prank(USER);
        weth.deposit{value: MAX_COLLATERAL_AMOUNT}();

        uint256 price = oracle.price();
        uint256 collateral = _minimumCollateral(price);
        uint256 borrow = _maximumBorrow(collateral, price) - 2;

        vm.prank(USER);
        mad.mint(collateral, borrow, RECEIVER);

        crashedPrice = bound(crashedPrice, 1, (ORACLE_MIN_PRICE * 9) / 10);

        uint256 collateral2 = _minimumCollateral(crashedPrice);
        uint256 borrow2 = _maximumBorrow(collateral, crashedPrice);

        vm.deal(SOMEONE, collateral2);
        vm.prank(SOMEONE);
        weth.deposit{value: collateral2}();

        uint256 positionIdSomeone = mad.nextPositionId();

        vm.prank(SOMEONE);
        mad.mint(collateral2, borrow2, RECEIVER);

        OracleMock(address(oracle)).setPrice(crashedPrice);

        uint256 priceWad = (oracle.price() * 1 ether) / (10 ** oracle.scale());
        uint256 debt = borrow2 + borrow2.mulWadUp(BASE_FEE_RATE_BPS);
        uint256 maxWithdraw = (collateral2.mulWad(priceWad) - debt.divWad(0.9 ether)).divWad(priceWad);

        vm.prank(SOMEONE);
        vm.expectRevert(MAD.TCROutOfBounds.selector);
        mad.withdrawCollateral(positionIdSomeone, (maxWithdraw * 9) / 10, RECEIVER);
    }

    function testWithdrawCollateralSuccessful(uint256 collateral, uint256 borrow, uint256 withdraw) public {
        collateral = bound(collateral, _minimumCollateral(ORACLE_MIN_PRICE), MAX_COLLATERAL_AMOUNT);
        borrow = bound(borrow, 1, _maximumBorrow(collateral, ORACLE_MIN_PRICE));

        vm.deal(USER, collateral);
        vm.prank(USER);
        weth.deposit{value: collateral}();

        uint256 positionId = mad.nextPositionId();

        vm.prank(USER);
        mad.mint(collateral, borrow, RECEIVER);

        (,,, uint256 collateralPointsBefore) = mad.positions(positionId);
        assertEq(collateralPointsBefore, collateral);
        assertEq(mad.totalSystemCollateralPoints(), collateral);
        assertEq(weth.balanceOf(address(mad)), collateral);
        assertEq(weth.balanceOf(RECEIVER), 0);

        uint256 priceWad = (oracle.price() * 1 ether) / (10 ** oracle.scale());
        uint256 debt = borrow + borrow.mulWadUp(BASE_FEE_RATE_BPS);
        uint256 maxWithdraw = (collateral.mulWad(priceWad) - debt.divWad(0.9 ether)).divWad(priceWad);

        withdraw = bound(withdraw, 1, (maxWithdraw * 9) / 10);

        vm.prank(USER);
        vm.expectEmit(true, false, false, true, address(mad));
        emit Withdraw(positionId, withdraw);
        mad.withdrawCollateral(positionId, withdraw, RECEIVER);

        (,,, uint256 collateralPointsAfter) = mad.positions(positionId);
        assertEq(collateralPointsAfter, collateral - withdraw);
        assertEq(mad.totalSystemCollateralPoints(), collateral - withdraw);
        assertEq(weth.balanceOf(address(mad)), collateral - withdraw);
        assertEq(weth.balanceOf(RECEIVER), withdraw);
    }
}