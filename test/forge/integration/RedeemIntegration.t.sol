// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../BaseTest.t.sol";

import {MAD} from "src/MAD.sol";
import {OracleMock} from "src/mock/OracleMock.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

contract RedeemIntegrationTest is BaseTest {
    using FixedPointMathLib for uint256;

    event Redeem(address indexed owner, uint256 burned, uint256 redeemed);

    function testRedeemRevertTCROutOfBounds(uint256 collateral, uint256 crashedPrice) public {
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

        vm.prank(USER);
        vm.expectRevert(MAD.TCROutOfBounds.selector);
        mad.redeem(1, RECEIVER);
    }

    function testRedeemSuccessful(uint256 collateral, uint256 borrow, uint256 redeemAmount) public {
        collateral = bound(collateral, _minimumCollateral(ORACLE_MIN_PRICE), MAX_COLLATERAL_AMOUNT);
        borrow = bound(borrow, 1, _maximumBorrow(collateral, ORACLE_MIN_PRICE));
        redeemAmount = bound(redeemAmount, 1, borrow);

        vm.deal(USER, collateral);
        vm.prank(USER);
        weth.deposit{value: collateral}();

        vm.prank(USER);
        mad.mint(collateral, borrow, RECEIVER);

        assertEq(weth.balanceOf(RECEIVER), 0);
        assertEq(weth.balanceOf(address(mad)), collateral);

        assertEq(mad.totalSupply(), borrow);
        assertEq(mad.balanceOf(RECEIVER), borrow);
        assertEq(mad.balanceOf(address(mad)), 0);

        uint256 priceWAD = (oracle.price() * 1 ether) / (10 ** oracle.scale());
        uint256 redemptionFee = redeemAmount.mulWadUp(BASE_FEE_RATE_BPS);
        uint256 expectedCollateralReturn = (redeemAmount - redemptionFee).divWad(priceWAD);

        vm.prank(RECEIVER);
        vm.expectEmit(true, false, false, true, address(mad));
        emit Redeem(RECEIVER, redeemAmount, expectedCollateralReturn);
        mad.redeem(redeemAmount, RECEIVER);

        assertEq(weth.balanceOf(RECEIVER), expectedCollateralReturn);
        assertEq(weth.balanceOf(address(mad)), collateral - expectedCollateralReturn);

        assertEq(mad.totalSupply(), borrow- redeemAmount + redemptionFee);
        assertEq(mad.balanceOf(RECEIVER), borrow - redeemAmount);
        assertEq(mad.balanceOf(address(mad)), redemptionFee);
    }
}