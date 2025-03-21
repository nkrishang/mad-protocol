// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../BaseTest.t.sol";

import {MAD} from "src/MAD.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

contract MintIntegrationTest is BaseTest {
    using FixedPointMathLib for uint256;

    function testMintInsufficientCollateral() public {}

    function testMintLTVOutOfBounds() public {}

    function testMintFirstMintInitializesSystem() public {}

    function testMintPreDebtTCROutOfBounds() public {}

    function testMintPostDebtTCROutOfBounds() public {}

    function testMintAfterSystemInitialized() public {}
}
