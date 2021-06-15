//SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

interface IStrategiesMStable {
    function deposit(uint _amount) external;
    function withdraw(uint _amount) external;
    function balanceOf(address _addr) external returns(uint);
}
