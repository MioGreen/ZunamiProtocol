//SPDX-License-Identifier: MIT
pragma solidity 0.8.0;


import {IERC20 as OzIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20 as OzSafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import '../interfaces/IStrategy.sol';
import '../interfaces/ICurveAavePool.sol';

import "hardhat/console.sol";

contract StrategyCurveAave is IStrategy {
    address constant internal usdcAddr = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    bytes32 constant internal usdcTicker = 'usdc';
    address constant internal curveTokenAddr = 0xFd2a8fA60Abd58Efe3EeE34dd494cD491dC14900;
    bytes32 constant internal curveTicker = 'a3CRV';

    address constant internal aavePoolAddr = 0xDeBF20617708857ebe4F679508E7b7863a8A8EeE;


    using OzSafeERC20 for OzIERC20;

    struct Token {
        bytes32 ticker;
        OzIERC20 token;
    }

    mapping(bytes32 => Token) public Coins;
    mapping(address => mapping(bytes32 => uint)) public depositerBalances;

    ICurveAavePool aavePool;

    constructor() {
        Coins[usdcTicker] = Token(usdcTicker, OzIERC20(usdcAddr));
        Coins[curveTicker] = Token(curveTicker, OzIERC20(curveTokenAddr));

        aavePool = ICurveAavePool(aavePoolAddr);
    }

    function deposit(address _depositer, uint _amount, bytes32 _ticker) external override {
        require(Coins[usdcTicker].token.balanceOf(_depositer) >= _amount,
                'Insufficent balance of the depositer');

        Coins[usdcTicker].token.safeApprove(aavePoolAddr, _amount);

        uint[3] memory coinAmounts;
        coinAmounts[0] = 0;
        coinAmounts[1] = _amount;
        coinAmounts[2] = 0;

        uint curveTokenAmount = aavePool.add_liquidity(coinAmounts, 0, true);
        depositerBalances[_depositer][_ticker] += _amount;
        depositerBalances[_depositer][curveTicker] += curveTokenAmount;
    }

     function withdraw(address _depositer, uint _amount,
         bytes32 _ticker) external override {
         require(depositerBalances[_depositer][_ticker] >= _amount,
                "Insufficient funds for withdraw");

        uint[3] memory coinAmounts;
        coinAmounts[0] = 0;
        coinAmounts[1] = _amount;
        coinAmounts[2] = 0;

        uint curveRequiredAmount = aavePool.calc_token_amount(coinAmounts, false);

        uint curveTokenAmount = aavePool.
            remove_liquidity_imbalance(coinAmounts, curveRequiredAmount, true);

        depositerBalances[_depositer][curveTicker] -= curveTokenAmount;

        Coins[usdcTicker].token.transfer(_depositer, _amount);
        depositerBalances[_depositer][_ticker] -= _amount;
     }


    function withdrawAll(address _depositer, int128 _coin, uint _minAmount,
        bytes32 _ticker) external override {
        require(depositerBalances[ _depositer][_ticker] > 0,
            "Insufficient funds for withdrawAll");

        uint amount = aavePool.remove_liquidity_one_coin(
            depositerBalances[_depositer][curveTicker]
            , _coin, _minAmount, true);

        depositerBalances[_depositer][curveTicker] = 0;
        Coins[usdcTicker].token.transfer(_depositer, amount);
        depositerBalances[_depositer][_ticker] = 0;
    }

}