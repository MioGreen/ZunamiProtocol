//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import '@openzeppelin/contracts/utils/Context.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
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

contract Zunami is Context, Ownable, ERC20 {
    using SafeERC20 for IERC20Metadata;

    struct PendingDeposit {  //TODO: может лучше DepositRequest ?
        uint256[3] amounts; //TODO: сложно расширять новыми ативами - перейти безразмерное хранилище потенциальных валют
        address depositor; //TODO: добавить indexed для быстрого поиска по депозиторам
    }

    struct PendingWithdrawal { //TODO: может лучше WithdrawalRequest ?
        uint256 lpAmount;
        uint256[3] minAmounts;
        address withdrawer; //TODO: добавить indexed для быстрого поиска по депозиторам
    }

    struct PoolInfo { //TODO: перенести сюда LP долю пула и запрашивать из каждой стратегии при расчетах пропорции
        IStrategy strategy;
        uint256 startTime;
    }

    uint8 private constant POOL_ASSETS = 3; //TODO: перейти на неограниченный массив

    address[POOL_ASSETS] public tokens; //TODO: хранить в виде безразмерного массива со стркутурой Token (address, uint8)
    uint256[POOL_ASSETS] public decimalsMultiplierS;
    mapping(address => uint256) public deposited; //TODO: так как тут USD я бы назвал depositedValue
    // Info of each pool
    PoolInfo[] public poolInfo;
    uint256 public totalDeposited; //TODO: так как тут USD я бы назвал totalDepositedValue

    uint256 public constant FEE_DENOMINATOR = 1000;
    uint256 public managementFee = 10; // 1%
    bool public isLock = false; //TODO: openzeppelin Pausable ?
    uint256 public constant MIN_LOCK_TIME = 1 days; //TODO: STRATEGY_START_DELAY

    mapping(address => uint256[3]) public accDepositPending;
    mapping(address => PendingWithdrawal) public pendingWithdrawals;

    event PendingDepositEvent(address depositor, uint256[3] amounts); //TODO: добавить индексы на все адреса
    event PendingWithdrawEvent(address withdrawer, uint256[3] amounts); //TODO: Event на конце избыточен - CreatedPendingWithdraw или CreatedWithdrawRequest
    event Deposited(address depositor, uint256[3] amounts, uint256 lpShares);
    event Withdrawn(address withdrawer, uint256[3] amounts, uint256 lpShares);
    event AddStrategy(address strategyAddr); //TODO: AddedPool, если мы используем термин PoolInfo; также добавить в событие время начала работы пула
    event BadDeposit(address depositor, uint256[3] amounts, uint256 lpShares); //TODO: FailedDeposit или FailedDepositRequest
    event BadWithdraw(address withdrawer, uint256[3] amounts, uint256 lpShares); //TODO: FailedWithdraw или FailedWithdrawRequest

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier isNotLocked() {
        require(!isLock, 'Zunami: Deposit functions locked');
        _;
    }

    modifier isStrategyStarted(uint256 pid) {
        require(block.timestamp >= poolInfo[pid].startTime, 'Zunami: strategy not started yet!');
        _;
    }

    constructor() ERC20('ZunamiLP', 'ZLP') {
        tokens[0] = Constants.DAI_ADDRESS; //TODO: почему не передаются через конструктор? Как переходить на другой чейн?
        tokens[1] = Constants.USDC_ADDRESS;
        tokens[2] = Constants.USDT_ADDRESS;
        for (uint256 i; i < POOL_ASSETS; i++) { //TODO: если базовые активы это кностанты, то их децималы тоже константы
            if (IERC20Metadata(tokens[i]).decimals() < 18) { //TODO: сохранить значение в локальную переменную, чтобы не запрашивать дважды
                decimalsMultiplierS[i] = 10**(18 - IERC20Metadata(tokens[i]).decimals()); //TODO: revert если decimals > 18
            } else {
                decimalsMultiplierS[i] = 1;
            }
        }
    }

    /**
     * @dev update managementFee, this is a Zunami commission from protocol profit
     * @param  newManagementFee - minAmount 0, maxAmount FEE_DENOMINATOR - 1
     */

    function setManagementFee(uint256 newManagementFee) external onlyOwner {
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
     * @dev Returns commission total holdings for all pools (strategy's) //TODO: почему commission ?
     * @return Returns sum holdings (USD) for all pools
     */
    function totalHoldings() public view returns (uint256) {
        uint256 length = poolInfo.length; //TODO: inline variable - тут отдельная переменная не имеет смысла
        uint256 totalHold = 0;
        for (uint256 pid = 0; pid < length; pid++) { //TODO: в случае большого количества одновременно запущенных стратегий расчет может не войти в блок
            totalHold += poolInfo[pid].strategy.totalHoldings();
        }
        return totalHold;
    }

    /**
     * @dev Returns price depends on the income of users
     * @return Returns currently price of ZLP (1e18 = 1$) //TODO: 1e18 = 1 ZUNAMI LP TOKEN - доллар тут непричем - мы же долларовый эквивалент делим на дробное представление количеста LP токенов
     */
    function lpPrice() external view returns (uint256) {
        return (totalHoldings() * 1e18) / totalSupply();
    }

    /**
     * @dev Returns number (length of poolInfo)
     * @return Returns number (length of poolInfo)
     */
    function poolInfoLength() external view returns (uint256) { //TODO: getPoolCount - снаружи протокола нет понятия PoolInfo, а есть понятие Пула как запущеной стратегии
        return poolInfo.length;
    }

    /**
     * @dev in this func user sends funds to the contract and then waits for the completion of the transaction for all users
     * @param amounts - array of deposit amounts by user
     */
    function delegateDeposit(uint256[3] memory amounts) external isNotLocked { //TODO: delegateDeposit -> requestDeposit
        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] > 0) {
                IERC20Metadata(tokens[i]).safeTransferFrom(_msgSender(), address(this), amounts[i]);
                accDepositPending[_msgSender()][i] += amounts[i];
            }
        }

        emit PendingDepositEvent(_msgSender(), amounts);
    }

    /**
     * @dev in this func user sends pending withdraw to the contract and then waits for the completion of the transaction for all users
     * @param  lpAmount - amount of ZLP for withdraw
     * @param minAmounts - array of amounts stablecoins that user want minimum receive
     */
    function delegateWithdrawal(uint256 lpAmount, uint256[3] memory minAmounts) external { //TODO: delegateWithdrawal -> requestWithdrawal
        PendingWithdrawal memory user; //TODO: переименовать в withdrawal - не понял почему PendingWithdrawal везде называется user
        address userAddr = _msgSender();

        user.lpAmount = lpAmount;
        user.minAmounts = minAmounts;
        user.withdrawer = userAddr;

        pendingWithdrawals[userAddr] = user;

        emit PendingWithdrawEvent(userAddr, minAmounts);
    }

    /**
     * @dev Zunami protocol owner complete all active pending deposits of users
     * @param userList - dev send array of users from pending to complete
     * @param pid - number of the pool to which the deposit goes
     */
    function completeDeposits(address[] memory userList, uint256 pid) //TODO: может ли данная функция обрабатывать по частям список пользователей?
        external
        onlyOwner
        isStrategyStarted(pid)
    {
        IStrategy strategy = poolInfo[pid].strategy; //TODO: исключение елси стратегия не существует
        uint256[3] memory totalAmounts;
        // total sum deposit, contract => strategy
        uint256 addHoldings = 0; //TODO: newHoldings
        uint256 completeAmount = 0; //TODO: лишняя переменная, для расчетов пользовательских нолдингов можно использовать переменную выше
        uint256[] memory userCompleteHoldings = new uint256[](userList.length); //TODO: userNewHoldings

        for (uint256 i = 0; i < userList.length; i++) {
            completeAmount = 0;

            for (uint256 x = 0; x < totalAmounts.length; x++) {
                totalAmounts[x] += accDepositPending[userList[i]][x]; //TODO: local variable - выделить получение текущего депозита пользователя по токену в локальну переменную
                completeAmount += accDepositPending[userList[i]][x] * decimalsMultiplierS[x];
            }
            userCompleteHoldings[i] = completeAmount;
        }

        for (uint256 y = 0; y < POOL_ASSETS; y++) {
            if (totalAmounts[y] > 0) {
                addHoldings += totalAmounts[y] * decimalsMultiplierS[y];
                IERC20Metadata(tokens[y]).safeTransfer(address(strategy), totalAmounts[y]);
            }
        }
        uint256 holdings = totalHoldings(); //TODO: currentHoldings
        uint256 sum = strategy.deposit(totalAmounts); //TODO: при чем тут sum? это же newDepositedValue в USD
        require(sum > 0, 'too low amount!'); //TODO: привести все require к формату 'Zunami: ошибка'
        uint256 lpShares = 0;
        uint256 changedHoldings = 0;
        uint256 currentUserAmount = 0;
        address userAddr;

        for (uint256 z = 0; z < userList.length; z++) {
            userAddr = userList[z];
            currentUserAmount = (sum * userCompleteHoldings[z]) / addHoldings; //TODO: userDepositedValue
            if (totalSupply() == 0) {
                lpShares = currentUserAmount;
            } else {
                lpShares = (currentUserAmount * totalSupply()) / (holdings + changedHoldings); //TODO: убрал лишнее вычитание за счет обновления changedHoldings после расчета пологающихся LP токенов
            }
            _mint(userAddr, lpShares);
            strategy.updateZunamiLpInStrat(lpShares, true); //TODO: баланс лучше перенести сюда в PoolInfo
            deposited[userAddr] += currentUserAmount;
            changedHoldings += currentUserAmount;
            // remove deposit from list
            delete accDepositPending[userAddr]; //TODO: MEDIUM пропущено событие Deposited
        }
        totalDeposited += changedHoldings;
    }

    /**
     * @dev Zunami protocol owner complete all active pending withdrawals of users
     * @param userList - array of users from pending withdraw to complete
     * @param pid - number of the pool from which the funds are withdrawn
     */
    function completeWithdrawals(address[] memory userList, uint256 pid)
        external
        onlyOwner
        isStrategyStarted(pid)
    {
        require(userList.length > 0, 'there are no pending withdrawals requests');

        PendingWithdrawal memory user;
        IStrategy strategy = poolInfo[pid].strategy;

        for (uint256 i = 0; i < userList.length; i++) {
            user = pendingWithdrawals[userList[i]];
            uint256 balance = balanceOf(user.withdrawer);

            if (balance >= user.lpAmount && user.lpAmount > 0) { //TODO: разве можно создать запрос на нулевой вывод и как запрос на вывод может быть больше чем баланс пользователя? Проверить в момент создания запроса на вывод
                if (!(strategy.withdraw(user.withdrawer, user.lpAmount, user.minAmounts))) {
                    emit BadWithdraw(user.withdrawer, user.minAmounts, user.lpAmount); //TODO: event FailedWithdraw

                    return; //TODO: почему не крешимся? Почему не обратбатываем другие запросы на вывод? если мы выходим то этот запрос на выдо так и останется висеть тут навсегда
                }

                uint256 userDeposit = (totalDeposited * user.lpAmount) / totalSupply();
                _burn(user.withdrawer, user.lpAmount);
                strategy.updateZunamiLpInStrat(user.lpAmount, false);

                if (userDeposit > deposited[user.withdrawer]) { //TODO: выглядит странно, что мы получаем меньше, чем задепозитили в баксе и у нас в totalDeposited останется эта разница
                    userDeposit = deposited[user.withdrawer];
                }

                deposited[user.withdrawer] -= userDeposit;
                totalDeposited -= userDeposit;

                emit Withdrawn(user.withdrawer, user.minAmounts, user.lpAmount);
            }

            delete pendingWithdrawals[userList[i]];
        }
    }

    /**
     * @dev deposit in one tx, without waiting complete by dev
     * @return Returns amount of lpShares minted for user
     * @param amounts - user send amounts of stablecoins to deposit
     * @param pid - number of the pool to which the deposit goes
     */
    function deposit(uint256[3] memory amounts, uint256 pid) //TODO: хочется, конечно чтобы депозит шел по tid - айдишнику токена в протоколе и не гонял пустой массив если хочется задепозитить один токен или депозитить по безмерному массиву TokenDeposit (tid, amount)
        external
        isNotLocked
        isStrategyStarted(pid)
        returns (uint256)
    {
        IStrategy strategy = poolInfo[pid].strategy; //TODO: везде проверять, что стратегия существует
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
        uint256 sum = strategy.deposit(amounts); //TODO: аналогичные замечания как и в общем депозите по именованию
        require(sum > 0, 'too low amount!');

        uint256 lpShares = 0;
        if (totalSupply() == 0) {
            lpShares = sum;
        } else {
            lpShares = (sum * totalSupply()) / holdings; //TODO: думаю тут всеже логично (totalSupply() * sum) / holdings - мы ищем пропорцию новой добавленной ценности к уже ранее добавленной
        }
        _mint(_msgSender(), lpShares);
        strategy.updateZunamiLpInStrat(lpShares, true);
        deposited[_msgSender()] += sum;
        totalDeposited += sum;

        emit Deposited(_msgSender(), amounts, lpShares);
        return lpShares;
    }

    /**
     * @dev withdraw in one tx, without waiting complete by dev
     * @param lpShares - amount of ZLP for withdraw
     * @param minAmounts -  array of amounts stablecoins that user want minimum receive
     * @param pid - number of the pool from which the funds are withdrawn
     */
    function withdraw(
        uint256 lpShares,
        uint256[3] memory minAmounts,
        uint256 pid
    ) external isStrategyStarted(pid) {
        IStrategy strategy = poolInfo[pid].strategy;
        address userAddr = _msgSender();

        require(balanceOf(userAddr) >= lpShares, 'Zunami: not enough LP balance');
        require(
            strategy.withdraw(userAddr, lpShares, minAmounts),
            'user lps share should be at least required' //TODO: Zunami:
        );

        uint256 userDeposit = (totalDeposited * lpShares) / totalSupply();
        _burn(userAddr, lpShares);
        strategy.updateZunamiLpInStrat(lpShares, false);

        if (userDeposit > deposited[userAddr]) { //TODO: аналогисно странная ситуация
            userDeposit = deposited[userAddr];
        }

        deposited[userAddr] -= userDeposit;
        totalDeposited -= userDeposit;

        emit Withdrawn(userAddr, minAmounts, lpShares);
    }

    /**
     * @dev security func, dev can disable all new deposits (not withdrawals)
     * @param _lock - dev can lock or unlock deposits
     */

    function setLock(bool _lock) external onlyOwner {
        isLock = _lock;
    }

    /**
     * @dev dev withdraw commission from one strategy
     * @param strategyAddr - address from which strategy managementFees withdrawn
     */

    function claimManagementFees(address strategyAddr) external onlyOwner { //TODO: почему стратегия берется не по PID? в итоге можно дернуть произвольный адрес стратегии
        IStrategy(strategyAddr).claimManagementFees();
    }

    /**
     * @dev add new strategy in strategy list, deposits in the new strategy are blocked for one day for safety
     * @param _strategy - add new address strategy in poolInfo Array
     */

    //TODO: addPool
    function add(address _strategy) external onlyOwner { //TODO: проверить на нулевой адрес
        poolInfo.push(
            PoolInfo({ strategy: IStrategy(_strategy), startTime: block.timestamp + MIN_LOCK_TIME })
        );
        //TODO: неплохо бы сделать emit AddedPool (или как сейчас AddStrategy )
    }

    /**
     * @dev dev can transfer funds between strategy's for better APY
     * @param  _from - number strategy, from which funds are withdrawn
     * @param _to - number strategy, to which funds are deposited
     */
    function moveFunds(uint256 _from, uint256 _to) external onlyOwner {
        IStrategy fromStrat = poolInfo[_from].strategy;
        IStrategy toStrat = poolInfo[_to].strategy;
        uint256[3] memory amountsBefore;
        for (uint256 y = 0; y < POOL_ASSETS; y++) {
            amountsBefore[y] = IERC20Metadata(tokens[y]).balanceOf(address(this));
        }
        fromStrat.withdrawAll();
        uint256[3] memory amounts;
        for (uint256 i = 0; i < POOL_ASSETS; i++) {
            amounts[i] = IERC20Metadata(tokens[i]).balanceOf(address(this)) - amountsBefore[i];
            if (amounts[i] > 0) {
                IERC20Metadata(tokens[i]).safeTransfer(address(toStrat), amounts[i]);
            }
        }
        toStrat.deposit(amounts);
        uint256 transferLpAmount = fromStrat.getZunamiLpInStrat();
        fromStrat.updateZunamiLpInStrat(transferLpAmount, false);
        toStrat.updateZunamiLpInStrat(transferLpAmount, true);
    }

    /**
     * @dev dev can transfer funds from few strategy's to one strategy for better APY
     * @param _from - array of strategy's, from which funds are withdrawn
     * @param _to - number strategy, to which funds are deposited
     */
    function moveFundsBatch(uint256[] memory _from, uint256 _to) external onlyOwner {
        uint256 length = _from.length;
        uint256[3] memory amounts;
        uint256[3] memory amountsBefore;
        uint256 zunamiLp = 0;
        for (uint256 y = 0; y < POOL_ASSETS; y++) {
            amountsBefore[y] = IERC20Metadata(tokens[y]).balanceOf(address(this));
        }
        for (uint256 i = 0; i < length; i++) {
            poolInfo[_from[i]].strategy.withdrawAll();
            uint256 thisPidLpAmount = poolInfo[_from[i]].strategy.getZunamiLpInStrat();
            zunamiLp += thisPidLpAmount;
            poolInfo[_from[i]].strategy.updateZunamiLpInStrat(thisPidLpAmount, false);
        }
        for (uint256 y = 0; y < POOL_ASSETS; y++) {
            amounts[y] = IERC20Metadata(tokens[y]).balanceOf(address(this)) - amountsBefore[y];
            if (amounts[y] > 0) {
                IERC20Metadata(tokens[y]).safeTransfer(address(poolInfo[_to].strategy), amounts[y]);
            }
        }
        poolInfo[_to].strategy.updateZunamiLpInStrat(zunamiLp, true);
        require(poolInfo[_to].strategy.deposit(amounts) > 0, 'too low amount!');
    }

    /**
     * @dev dev can emergency transfer funds from all strategy's to zero pool (strategy)
     */
    function emergencyWithdraw() external onlyOwner { //TODO: почему не переиспользовать метод moveFundsBatch ? в данном случаем можно дважды пройтись по массиву пулов - первый чтобы сформировать массив pids пулов за вычетом первого
        uint256 length = poolInfo.length; //TODO: poolCount
        require(length > 1, 'Zunami: Nothing withdraw');
        uint256[3] memory amounts;
        uint256[3] memory amountsBefore;
        uint256 zunamiLp = 0;
        for (uint256 y = 0; y < POOL_ASSETS; y++) {
            amountsBefore[y] = IERC20Metadata(tokens[y]).balanceOf(address(this));
        }
        for (uint256 i = 1; i < length; i++) {
            poolInfo[i].strategy.withdrawAll();
            uint256 thisPidLpAmount = poolInfo[i].strategy.getZunamiLpInStrat();
            zunamiLp += thisPidLpAmount;
            poolInfo[i].strategy.updateZunamiLpInStrat(thisPidLpAmount, false);
        }
        for (uint256 y = 0; y < POOL_ASSETS; y++) {
            amounts[y] = IERC20Metadata(tokens[y]).balanceOf(address(this)) - amountsBefore[y];
            if (amounts[y] > 0) {
                IERC20Metadata(tokens[y]).safeTransfer(address(poolInfo[0].strategy), amounts[y]);
            }
        }
        poolInfo[0].strategy.updateZunamiLpInStrat(zunamiLp, true);
        require(poolInfo[0].strategy.deposit(amounts) > 0, 'too low amount!');
    }

    /**
     * @dev user remove his active pending deposit
     */
    function pendingDepositRemove() external {
        for (uint256 i = 0; i < POOL_ASSETS; i++) {
            if (accDepositPending[_msgSender()][i] > 0) { //TODO: accDepositPending[_msgSender()][i] - лучше выгрузитьв локальную переменную
                IERC20Metadata(tokens[i]).safeTransfer(
                    _msgSender(),
                    accDepositPending[_msgSender()][i]
                );
            }
        }
        delete accDepositPending[_msgSender()];
    }

    /**
     * @dev disable renounceOwnership for safety
     */
    function renounceOwnership() public view override onlyOwner {
        revert('Zunami must have an owner');
    }
}
