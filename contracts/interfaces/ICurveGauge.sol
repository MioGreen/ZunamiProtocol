//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface ICurveGauge {
    function balanceOf(address account) external view returns (uint256);
}