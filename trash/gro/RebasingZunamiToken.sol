//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ZunamiToken.sol";

contract RebasingZunamiToken is ZunamiToken {
    using SafeERC20 for IERC20;

    event TransferBase(address indexed sender, address indexed recipient, uint256 indexed amount);

    constructor(
        string memory name,
        string memory symbol,
        address controller
    ) public ZToken(name, symbol, controller) {}

    function totalSupply() public view override returns (uint256) {
        uint256 f = factor();
        return f > 0 ? applyFactor(totalSupplyBase(), f, false) : 0;
    }

    function balanceOf(address account) public view override returns (uint256) {
        uint256 f = factor();
        return f > 0 ? applyFactor(balanceOfBase(account), f, false) : 0;
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        uint256 transferAmount = applyFactor(amount, factor(), true);
        super._transfer(msg.sender, recipient, transferAmount, amount);
        emit TransferBase(msg.sender, recipient, amount);
        return true;
    }

    function getPricePerShare() external view override returns (uint256) {
        return BASE;
    }

    function getAssets(address account) external view override returns (uint256) {
        return balanceOf(account);
    }

    function mint(
        address account,
        uint256 _factor,
        uint256 amount
    ) external override onlyWhitelist {
        require(account != address(0), "mint: 0x");
        require(amount > 0, "Amount is zero.");
        uint256 mintAmount = applyFactor(amount, _factor, true);
        _mint(account, mintAmount, amount);
    }

    function burn(
        address account,
        uint256 _factor,
        uint256 amount
    ) external override onlyWhitelist {
        require(account != address(0), "burn: 0x");
        require(amount > 0, "Amount is zero.");
        uint256 burnAmount = applyFactor(amount, _factor, true);
        _burn(account, burnAmount, amount);
    }

    function burnAll(address account) external override onlyWhitelist {
        require(account != address(0), "burnAll: 0x");
        uint256 burnAmount = balanceOfBase(account);
        uint256 amount = applyFactor(burnAmount, factor(), false);
        _burn(account, burnAmount, amount);
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        super._decreaseApproved(sender, msg.sender, amount);
        uint256 transferAmount = applyFactor(amount, factor(), true);
        super._transfer(sender, recipient, transferAmount, amount);
        return true;
    }
}
