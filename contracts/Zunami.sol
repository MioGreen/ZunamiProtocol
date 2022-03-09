//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/utils/Context.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import './utils/Constants.sol';
import './interfaces/IStrategy.sol';

/**
 *
 * @title Zunami Protocol
 *
 * @notice Contract for Convex&Curve protocols optimize.
 * Users can use this contract for optimize yield and gas.
 *
 *
 * @dev Zunami is main contract.
 * Contract does not store user funds.
 * All user funds goes to Convex&Curve pools.
 *
 */

contract Zunami is Context, ERC20, Pausable, AccessControl {
    using SafeERC20 for IERC20Metadata;

    bytes32 public constant OPERATOR_ROLE = keccak256('OPERATOR_ROLE');

    struct PendingWithdrawal {
        uint256 lpShares;
        uint256[3] minAmounts;
    }

    struct PoolInfo {
        IStrategy strategy;
        uint256 startTime;
        uint256 lpShares;
    }

    uint8 private constant POOL_ASSETS = 3;
    uint256 public constant FEE_DENOMINATOR = 1000;
    uint256 public constant MIN_LOCK_TIME = 1 days;

    PoolInfo[] internal _poolInfo;
    uint256 public defaultDepositPid;
    uint256 public defaultWithdrawPid;

    address[POOL_ASSETS] public tokens;
    uint256[POOL_ASSETS] public decimalsMultiplierS;

    mapping(address => uint256[3]) public pendingDeposits;
    mapping(address => PendingWithdrawal) public pendingWithdrawals;

    uint256 public totalDeposited = 0;
    uint256 public managementFee = 10; // 1%
    bool public launched = false;

    event CreatedPendingDeposit(address indexed depositor, uint256[3] amounts);
    event CreatedPendingWithdrawal(
        address indexed withdrawer,
        uint256[3] amounts,
        uint256 lpShares
    );
    event Deposited(address indexed depositor, uint256[3] amounts, uint256 lpShares);
    event Withdrawn(address indexed withdrawer, uint256[3] amounts, uint256 lpShares);
    event AddedPool(uint256 pid, address strategyAddr, uint256 startTime);
    event FailedDeposit(address indexed depositor, uint256[3] amounts, uint256 lpShares);
    event FailedWithdrawal(address indexed withdrawer, uint256[3] amounts, uint256 lpShares);
    event SetDefaultDepositPid(uint256 pid);
    event SetDefaultWithdrawPid(uint256 pid);
    event ClaimedAllManagementFee(uint256 feeValue);

    modifier startedPool() {
        require(_poolInfo.length != 0, 'Zunami: pool not existed!');
        require(
            block.timestamp >= _poolInfo[defaultDepositPid].startTime,
            'Zunami: default deposit pool not started yet!'
        );
        require(
            block.timestamp >= _poolInfo[defaultWithdrawPid].startTime,
            'Zunami: default withdraw pool not started yet!'
        );
        _;
    }

    constructor(address[POOL_ASSETS] memory _tokens) ERC20('ZunamiLP', 'ZLP') {
        tokens = _tokens;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);

        for (uint256 i; i < POOL_ASSETS; i++) {
            uint256 decimals = IERC20Metadata(tokens[i]).decimals();
            if (decimals < 18) {
                decimalsMultiplierS[i] = 10**(18 - decimals);
            } else {
                decimalsMultiplierS[i] = 1;
            }
        }
    }

    function poolInfo(uint256 pid) external view returns (PoolInfo memory) {
        return _poolInfo[pid];
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev update managementFee, this is a Zunami commission from protocol profit
     * @param  newManagementFee - minAmount 0, maxAmount FEE_DENOMINATOR - 1
     */
    function setManagementFee(uint256 newManagementFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newManagementFee < FEE_DENOMINATOR, 'Zunami: wrong fee');
        managementFee = newManagementFee;
    }

    /**
     * @dev Returns managementFee for strategy's when contract sell rewards
     * @return Returns commission on the amount of profit in the transaction
     * @param amount - amount of profit for calculate managementFee
     */
    function calcManagementFee(uint256 amount) external view returns (uint256) {
        return (amount * managementFee) / FEE_DENOMINATOR;
    }

    /**
     * @dev Claims managementFee from all active strategys
     */
    function claimAllManagementFee() external {
        uint256 feeTotalValue;
        for (uint256 i = 0; i < _poolInfo.length; i++) {
            feeTotalValue += _poolInfo[i].strategy.claimManagementFees();
        }

        emit ClaimedAllManagementFee(feeTotalValue);
    }

    /**
     * @dev Returns total holdings for all pools (strategy's)
     * @return Returns sum holdings (USD) for all pools
     */
    function totalHoldings() public view returns (uint256) {
        uint256 length = _poolInfo.length;
        uint256 totalHold = 0;
        for (uint256 pid = 0; pid < length; pid++) {
            totalHold += _poolInfo[pid].strategy.totalHoldings();
        }
        return totalHold;
    }

    /**
     * @dev Returns price depends on the income of users
     * @return Returns currently price of ZLP (1e18 = 1$)
     */
    function lpPrice() external view returns (uint256) {
        return (totalHoldings() * 1e18) / totalSupply();
    }

    /**
     * @dev Returns number of pools
     * @return number of pools
     */
    function poolCount() external view returns (uint256) {
        return _poolInfo.length;
    }

    /**
     * @dev in this func user sends funds to the contract and then waits for the completion
     * of the transaction for all users
     * @param amounts - array of deposit amounts by user
     */
    function delegateDeposit(uint256[3] memory amounts) external whenNotPaused {
        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] > 0) {
                IERC20Metadata(tokens[i]).safeTransferFrom(_msgSender(), address(this), amounts[i]);
                pendingDeposits[_msgSender()][i] += amounts[i];
            }
        }

        emit CreatedPendingDeposit(_msgSender(), amounts);
    }

    /**
     * @dev in this func user sends pending withdraw to the contract and then waits
     * for the completion of the transaction for all users
     * @param  lpAmount - amount of ZLP for withdraw
     * @param minAmounts - array of amounts stablecoins that user want minimum receive
     */
    function delegateWithdrawal(uint256 lpAmount, uint256[3] memory minAmounts)
        external
        whenNotPaused
    {
        PendingWithdrawal memory withdrawal;
        address userAddr = _msgSender();
        require(lpAmount > 0, 'Zunami: lpAmount must be higher 0');

        withdrawal.lpShares = lpAmount;
        withdrawal.minAmounts = minAmounts;

        pendingWithdrawals[userAddr] = withdrawal;

        emit CreatedPendingWithdrawal(userAddr, minAmounts, lpAmount);
    }

    /**
     * @dev Zunami protocol owner complete all active pending deposits of users
     * @param userList - dev send array of users from pending to complete
     */
    function completeDeposits(address[] memory userList)
        external
        onlyRole(OPERATOR_ROLE)
        startedPool
    {
        IStrategy strategy = _poolInfo[defaultDepositPid].strategy;
        uint256 currentTotalHoldings = totalHoldings();

        uint256 newHoldings = 0;
        uint256[3] memory totalAmounts;
        uint256[] memory userCompleteHoldings = new uint256[](userList.length);
        for (uint256 i = 0; i < userList.length; i++) {
            newHoldings = 0;

            for (uint256 x = 0; x < totalAmounts.length; x++) {
                uint256 userTokenDeposit = pendingDeposits[userList[i]][x];
                totalAmounts[x] += userTokenDeposit;
                newHoldings += userTokenDeposit * decimalsMultiplierS[x];
            }
            userCompleteHoldings[i] = newHoldings;
        }

        newHoldings = 0;
        for (uint256 y = 0; y < POOL_ASSETS; y++) {
            uint256 totalTokenAmount = totalAmounts[y];
            if (totalTokenAmount > 0) {
                newHoldings += totalTokenAmount * decimalsMultiplierS[y];
                IERC20Metadata(tokens[y]).safeTransfer(address(strategy), totalTokenAmount);
            }
        }
        uint256 totalDepositedNow = strategy.deposit(totalAmounts);
        require(totalDepositedNow > 0, 'Zunami: too low deposit!');
        uint256 lpShares = 0;
        uint256 addedHoldings = 0;
        uint256 userDeposited = 0;

        for (uint256 z = 0; z < userList.length; z++) {
            userDeposited = (totalDepositedNow * userCompleteHoldings[z]) / newHoldings;
            address userAddr = userList[z];
            if (totalSupply() == 0) {
                lpShares = userDeposited;
            } else {
                lpShares = (totalSupply() * userDeposited) / (currentTotalHoldings + addedHoldings);
            }
            addedHoldings += userDeposited;
            _mint(userAddr, lpShares);
            _poolInfo[defaultDepositPid].lpShares += lpShares;
            emit Deposited(userAddr, pendingDeposits[userAddr], lpShares);

            // remove deposit from list
            delete pendingDeposits[userAddr];
        }
        totalDeposited += addedHoldings;
    }

    /**
     * @dev Zunami protocol owner complete all active pending withdrawals of users
     * @param userList - array of users from pending withdraw to complete
     */
    function completeWithdrawals(address[] memory userList)
        external
        onlyRole(OPERATOR_ROLE)
        startedPool
    {
        require(userList.length > 0, 'Zunami: there are no pending withdrawals requests');

        IStrategy strategy = _poolInfo[defaultWithdrawPid].strategy;

        address user;
        PendingWithdrawal memory withdrawal;
        for (uint256 i = 0; i < userList.length; i++) {
            user = userList[i];
            withdrawal = pendingWithdrawals[user];

            if (balanceOf(user) >= withdrawal.lpShares) {
                if (
                    !(
                        strategy.withdraw(
                            user,
                            withdrawal.lpShares,
                            _poolInfo[defaultWithdrawPid].lpShares,
                            withdrawal.minAmounts
                        )
                    )
                ) {
                    emit FailedWithdrawal(user, withdrawal.minAmounts, withdrawal.lpShares);
                    delete pendingWithdrawals[user];
                    continue;
                }

                uint256 userDeposit = (totalDeposited * withdrawal.lpShares) / totalSupply();
                _burn(user, withdrawal.lpShares);
                _poolInfo[defaultWithdrawPid].lpShares -= withdrawal.lpShares;

                totalDeposited -= userDeposit;

                emit Withdrawn(user, withdrawal.minAmounts, withdrawal.lpShares);
            }

            delete pendingWithdrawals[user];
        }
    }

    /**
     * @dev deposit in one tx, without waiting complete by dev
     * @return Returns amount of lpShares minted for user
     * @param amounts - user send amounts of stablecoins to deposit
     */
    function deposit(uint256[3] memory amounts)
        external
        whenNotPaused
        startedPool
        returns (uint256)
    {
        IStrategy strategy = _poolInfo[defaultDepositPid].strategy;
        uint256 holdings = totalHoldings();

        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] > 0) {
                IERC20Metadata(tokens[i]).safeTransferFrom(
                    _msgSender(),
                    address(strategy),
                    amounts[i]
                );
            }
        }
        uint256 newDeposited = strategy.deposit(amounts);
        require(newDeposited > 0, 'Zunami: too low deposit!');

        uint256 lpShares = 0;
        if (totalSupply() == 0) {
            lpShares = newDeposited;
        } else {
            lpShares = (totalSupply() * newDeposited) / holdings;
        }
        _mint(_msgSender(), lpShares);
        _poolInfo[defaultDepositPid].lpShares += lpShares;
        totalDeposited += newDeposited;

        emit Deposited(_msgSender(), amounts, lpShares);
        return lpShares;
    }

    /**
     * @dev withdraw in one tx, without waiting complete by dev
     * @param lpShares - amount of ZLP for withdraw
     * @param minAmounts -  array of amounts stablecoins that user want minimum receive
     */
    function withdraw(uint256 lpShares, uint256[3] memory minAmounts)
        external
        whenNotPaused
        startedPool
    {
        IStrategy strategy = _poolInfo[defaultWithdrawPid].strategy;
        address userAddr = _msgSender();

        require(balanceOf(userAddr) >= lpShares, 'Zunami: not enough LP balance');
        require(
            strategy.withdraw(
                userAddr,
                lpShares,
                _poolInfo[defaultWithdrawPid].lpShares,
                minAmounts
            ),
            'Zunami: user lps share should be at least required'
        );

        uint256 userDeposit = (totalDeposited * lpShares) / totalSupply();
        _burn(userAddr, lpShares);
        _poolInfo[defaultWithdrawPid].lpShares -= lpShares;

        totalDeposited -= userDeposit;

        emit Withdrawn(userAddr, minAmounts, lpShares);
    }

    /**
     * @dev add a new pool, deposits in the new pool are blocked for one day for safety
     * @param _strategyAddr - the new pool strategy address
     */

    function addPool(address _strategyAddr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_strategyAddr != address(0), 'Zunami: zero strategy addr');
        uint256 startTime = block.timestamp + (launched ? MIN_LOCK_TIME : 0);
        _poolInfo.push(
            PoolInfo({ strategy: IStrategy(_strategyAddr), startTime: startTime, lpShares: 0 })
        );
        emit AddedPool(_poolInfo.length - 1, _strategyAddr, startTime);
    }

    /**
     * @dev set a default pool for deposit funds
     * @param _newPoolId - new pool id
     */
    function setDefaultDepositPid(uint256 _newPoolId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newPoolId < _poolInfo.length, 'Zunami: incorrect default deposit pool id');

        defaultDepositPid = _newPoolId;
        emit SetDefaultDepositPid(_newPoolId);
    }

    /**
     * @dev set a default pool for withdraw funds
     * @param _newPoolId - new pool id
     */
    function setDefaultWithdrawPid(uint256 _newPoolId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newPoolId < _poolInfo.length, 'Zunami: incorrect default withdraw pool id');

        defaultWithdrawPid = _newPoolId;
        emit SetDefaultWithdrawPid(_newPoolId);
    }

    function launch() external onlyRole(DEFAULT_ADMIN_ROLE) {
        launched = true;
    }

    /**
     * @dev dev can transfer funds from few strategy's to one strategy for better APY
     * @param _from - array of strategy's, from which funds are withdrawn
     * @param _to - number strategy, to which funds are deposited
     */
    function moveFundsBatch(uint256[] memory _from, uint256 _to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint256 length = _from.length;
        uint256[3] memory amounts;
        uint256[3] memory amountsBefore;
        uint256 zunamiLp = 0;
        for (uint256 y = 0; y < POOL_ASSETS; y++) {
            amountsBefore[y] = IERC20Metadata(tokens[y]).balanceOf(address(this));
        }
        for (uint256 i = 0; i < length; i++) {
            _poolInfo[_from[i]].strategy.withdrawAll();
            zunamiLp += _poolInfo[_from[i]].lpShares;
            _poolInfo[_from[i]].lpShares = 0;
        }
        for (uint256 y = 0; y < POOL_ASSETS; y++) {
            amounts[y] = IERC20Metadata(tokens[y]).balanceOf(address(this)) - amountsBefore[y];
            if (amounts[y] > 0) {
                IERC20Metadata(tokens[y]).safeTransfer(
                    address(_poolInfo[_to].strategy),
                    amounts[y]
                );
            }
        }
        _poolInfo[_to].lpShares += zunamiLp;
        require(_poolInfo[_to].strategy.deposit(amounts) > 0, 'Zunami: Too low amount!');
    }

    /**
     * @dev user remove his active pending deposit
     */
    function pendingDepositRemove() external {
        for (uint256 i = 0; i < POOL_ASSETS; i++) {
            if (pendingDeposits[_msgSender()][i] > 0) {
                IERC20Metadata(tokens[i]).safeTransfer(
                    _msgSender(),
                    pendingDeposits[_msgSender()][i]
                );
            }
        }
        delete pendingDeposits[_msgSender()];
    }

    /**
     * @dev governance can withdraw all stuck funds in emergency case
     * @param _token - IERC20Metadata token that should be fully withdraw from Zunami
     */
    function withdrawStuckToken(IERC20Metadata _token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 tokenBalance = _token.balanceOf(address(this));
        _token.safeTransfer(_msgSender(), tokenBalance);
    }

    /**
     * @dev governance can add new operator for complete pending deposits and withdrawals
     * @param _newOperator - address that governance add in list of operators
     */
    function updateOperator(address _newOperator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(OPERATOR_ROLE, _newOperator);
    }
}
