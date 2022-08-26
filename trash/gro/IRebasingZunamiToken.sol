//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRebasingZunamiToken {
    function factor() external view returns (uint256);

    function factor(uint256 totalAssets) external view returns (uint256);

    function mint(
        address account,
        uint256 _factor,
        uint256 amount
    ) external;

    function burn(
        address account,
        uint256 _factor,
        uint256 amount
    ) external;

    function burnAll(address account) external;

    function totalAssets() external view returns (uint256);

    function getPricePerShare() external view returns (uint256);

    function getAssets(address account) external view returns (uint256);
}
