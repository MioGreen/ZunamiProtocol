// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';

interface IElasticVaultMigrator {
    function migrate(IERC20Metadata currentAsset, IERC20Metadata newAsset, uint256 amount) external;
}
