//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import "../interfaces/IZunami.sol";
import "./IRebasingZunamiToken.sol";

abstract contract ZunamiToken is Ownable, ERC20, IRebasingZunamiToken {
    uint8 public constant DEFAULT_DECIMALS = 18;
    uint256 public constant DEFAULT_DECIMALS_FACTOR = uint256(10)**DEFAULT_DECIMALS;
    uint256 public constant BASE = DEFAULT_DECIMALS_FACTOR;

    using SafeERC20 for IERC20;

    IZunami public zunami;

    constructor(
        string memory name,
        string memory symbol,
        address zunamiAddr
    ) public ERC20(name, symbol, DEFAULT_DECIMALS) {
        zunami = IZunami(zunamiAddr);
    }

    function setController(address zunamiAddr) external onlyOwner {
        zunami = IZunami(zunamiAddr);
    }

    function totalSupplyBase() public view returns (uint256) {
        return super.totalSupply();
    }

    function balanceOfBase(address account) public view returns (uint256) {
        return super.balances(account);
    }

    function applyFactor(
        uint256 a,
        uint256 b,
        bool base
    ) internal pure returns (uint256 resultant) {
        uint256 diff;
        if (base) {
            diff = a * b;
            resultant = diff / BASE;
            diff %= BASE;
        } else {
            diff = a * BASE;
            resultant = diff / b;
            diff %= b;
        }
        if (diff >= 5E17) {
            resultant = resultant + 1;
        }
    }

    function totalAssets() public view override returns (uint256) {
        return zunami.totalHoldings();
    }

    function factor() public view override returns (uint256) {
        return factor(totalAssets());
    }

    function getInitialBase() internal pure virtual returns (uint256) {
        return BASE;
    }

    function factor(uint256 totalAssets) public view override returns (uint256) {
        if (totalSupplyBase() == 0) {
            return getInitialBase();
        }

        if (totalAssets > 0) {
            return totalSupplyBase() * BASE / totalAssets;
        }

        return 0;
    }
}
