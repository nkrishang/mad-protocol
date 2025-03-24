// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../BaseTest.t.sol";

contract CloseIntegrationTest is BaseTest {

    function testClosePoistionDNE(uint256 id) public {}

    function testCloseUnauthorizedCaller(address caller) public {}

    function testCloseLTVOutOfBounds(uint256 collateral, uint256 borrow, uint256 crashedPrice) public {}

    function testCloseSuccessful(uint256 collateral, uint256 borrow, uint256 crashedPrice) public {}
}