// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../BaseTest.t.sol";

import {MAD} from "src/MAD.sol";
import {OracleMock} from "src/mock/OracleMock.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

contract MintIntegrationTest is BaseTest {
    using FixedPointMathLib for uint256;

    event Transfer(address indexed from, address indexed to, uint256 amount);

    function testMintInsufficientCollateral(uint256 collateral, uint256 borrow) public {
        collateral = bound(collateral, 1, _minimumCollateral(ORACLE_MAX_PRICE));

        vm.expectRevert(MAD.InsufficientCollateral.selector);
        mad.mint(collateral, borrow, RECEIVER);
    }

    function testMintLTVOutOfBounds(uint256 collateral, uint256 borrow) public {
        collateral = bound(collateral, _minimumCollateral(ORACLE_MIN_PRICE), MAX_COLLATERAL_AMOUNT);
        borrow = bound(borrow, _maximumBorrow(collateral, ORACLE_MAX_PRICE), MAX_BORROW_AMOUNT);

        vm.expectRevert(MAD.LTVOutOfBounds.selector);
        mad.mint(collateral, borrow, RECEIVER);
    }

    function testMintFirstMintInitializesSystem(uint256 collateral, uint256 borrow) public {
        collateral = bound(collateral, _minimumCollateral(ORACLE_MIN_PRICE), MAX_COLLATERAL_AMOUNT);
        borrow = bound(borrow, 1, _maximumBorrow(collateral, ORACLE_MIN_PRICE));

        vm.deal(USER, collateral);
        vm.prank(USER);
        weth.deposit{value: collateral}();

        assertEq(weth.balanceOf(address(mad)), 0);
        assertEq(weth.balanceOf(USER), collateral);

        assertEq(mad.totalSupply(), 0);
        assertEq(mad.debtPerDebtPoint(), 0);
        assertEq(mad.totalSystemDebtPoints(), 0);
        assertEq(mad.collateralPerCollateralPoint(), 0);
        assertEq(mad.totalSystemCollateralPoints(), 0);

        uint256 positionId = mad.nextPositionId();

        vm.prank(USER);
        vm.expectEmit(true, true, false, true, address(mad));
        emit ERC20.Transfer(address(0), RECEIVER, borrow);
        mad.mint(collateral, borrow, RECEIVER);

        uint256 debt = borrow + borrow.mulWadUp(BASE_FEE_RATE_BPS);

        assertEq(mad.totalSupply(), borrow);
        assertEq(mad.debtPerDebtPoint(), 1);
        assertEq(mad.totalSystemDebtPoints(), debt);
        assertEq(mad.collateralPerCollateralPoint(), 1);
        assertEq(mad.totalSystemCollateralPoints(), collateral);

        assertEq(mad.balanceOf(RECEIVER), borrow);
        assertEq(weth.balanceOf(address(mad)), collateral);
        assertEq(weth.balanceOf(USER), 0);

        (uint256 id, address owner, uint256 debtPoints, uint256 collateralPoints) = mad.positions(positionId);
        assertEq(id, positionId);
        assertEq(owner, USER);
        assertEq(debtPoints, debt);
        assertEq(collateralPoints, collateral);

        assertEq(mad.nextPositionId(), positionId + 1);
    }

    function testMintTCROutOfBounds(uint256 collateral, uint256 crashedPrice) public {
        crashedPrice = bound(crashedPrice, 1, (ORACLE_MIN_PRICE * 9) / 10);
        collateral = bound(collateral, _minimumCollateral(crashedPrice), MAX_COLLATERAL_AMOUNT);

        uint256 borrow = _maximumBorrow(collateral, ORACLE_MIN_PRICE);

        vm.deal(USER, collateral);
        vm.prank(USER);
        weth.deposit{value: collateral}();

        assertTrue(oracle.price() > crashedPrice);

        vm.prank(USER);
        mad.mint(collateral, borrow, RECEIVER);

        OracleMock(address(oracle)).setPrice(crashedPrice);

        uint256 newBorrow = 1;

        vm.deal(USER, collateral);
        vm.prank(USER);
        weth.deposit{value: collateral}();

        vm.prank(USER);
        vm.expectRevert(MAD.TCROutOfBounds.selector);
        mad.mint(collateral, newBorrow, RECEIVER);
    }

    function testMintAfterSystemInitialized(uint256 x, uint256 y) public {
        uint256 collateral = bound(x, _minimumCollateral(ORACLE_MIN_PRICE), MAX_COLLATERAL_AMOUNT);
        uint256 borrow = bound(x, 1, _maximumBorrow(collateral, ORACLE_MIN_PRICE));

        vm.deal(USER, collateral);
        vm.prank(USER);
        weth.deposit{value: collateral}();

        vm.prank(USER);
        mad.mint(collateral, borrow, RECEIVER);

        uint256 debt = borrow + borrow.mulWadUp(BASE_FEE_RATE_BPS);

        uint256 newCollateral = bound(y, _minimumCollateral(ORACLE_MIN_PRICE), MAX_COLLATERAL_AMOUNT);
        uint256 newBorrow = bound(y, 1, _maximumBorrow(newCollateral, ORACLE_MIN_PRICE));

        vm.deal(USER, newCollateral);
        vm.prank(USER);
        weth.deposit{value: newCollateral}();

        assertEq(weth.balanceOf(address(mad)), collateral);
        assertEq(weth.balanceOf(USER), newCollateral);

        assertEq(mad.totalSupply(), borrow);
        assertEq(mad.debtPerDebtPoint(), 1);
        assertEq(mad.totalSystemDebtPoints(), debt);
        assertEq(mad.collateralPerCollateralPoint(), 1);
        assertEq(mad.totalSystemCollateralPoints(), collateral);

        uint256 positionId = mad.nextPositionId();
        assertEq(positionId, 1);

        vm.prank(USER);
        vm.expectEmit(true, true, false, true, address(mad));
        emit ERC20.Transfer(address(0), RECEIVER, newBorrow);
        mad.mint(newCollateral, newBorrow, RECEIVER);

        uint256 newDebt = newBorrow + newBorrow.mulWadUp(BASE_FEE_RATE_BPS);

        assertEq(mad.totalSupply(), borrow + newBorrow);
        assertEq(mad.debtPerDebtPoint(), 1);
        assertEq(mad.totalSystemDebtPoints(), debt + newDebt);
        assertEq(mad.collateralPerCollateralPoint(), 1);
        assertEq(mad.totalSystemCollateralPoints(), collateral + newCollateral);

        assertEq(mad.balanceOf(RECEIVER), borrow + newBorrow);
        assertEq(weth.balanceOf(address(mad)), collateral + newCollateral);
        assertEq(weth.balanceOf(USER), 0);

        (uint256 id, address owner, uint256 debtPoints, uint256 collateralPoints) = mad.positions(positionId);
        assertEq(id, positionId);
        assertEq(owner, USER);
        assertEq(debtPoints, newDebt);
        assertEq(collateralPoints, newCollateral);

        assertEq(mad.nextPositionId(), positionId + 1);
    }
}
