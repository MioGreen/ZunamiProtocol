// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IVeZunToken.sol";


contract StakingPool is Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint256 public immutable maxBonus;
    uint256 public immutable maxLockDuration;
    uint256 public constant MIN_LOCK_DURATION = 2 weeks;

    struct Deposit {
        uint256 amount;
        uint256 mintedAmount;
        uint256 rewardDebt;
        uint256 usdtRewardDebt;
        uint64 start;
        uint64 end;
    }

    mapping(address => Deposit[]) public depositsOf;
    mapping(address => uint256) public totalDepositOf;

    IERC20 public Zun; // main&reward token
    IVeZunToken public veZun; // governance token
    IERC20 public constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    uint256 public lpSupply; // total supply
    uint256 public accZunPerShare = 0;
    uint256 public accUsdtPerShare = 0;
    uint256 public lastRewardBlock = 0; // change in prod
    uint256 public ZunPerBlock = 1e18; // change in prod

    bool public isClaimLock = false;

    constructor(
        IERC20 _Zun,
        IVeZunToken _veZun,
        uint256 _maxBonus,
        uint256 _maxLockDuration
    ) {
        Zun = _Zun;
        veZun = _veZun;
        require(_maxLockDuration >= MIN_LOCK_DURATION, "bad _maxLockDuration");
        maxBonus = _maxBonus;
        maxLockDuration = _maxLockDuration;
    }

    event Deposited(uint256 amount, uint256 duration, address indexed receiver);
    event Withdrawn(uint256 indexed depositId, address indexed receiver, uint256 amount);

    modifier isClaimLocked() {
        require(!isClaimLock, 'ZunStaker: Claim functions locked');
        _;
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool() public {
        if (block.number <= lastRewardBlock) {
            return;
        }
        if (lpSupply == 0 || ZunPerBlock == 0) {
            lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = block.number - lastRewardBlock;
        uint256 ZunReward = multiplier * ZunPerBlock;
        accZunPerShare += ZunReward * 1e18 / lpSupply;
        lastRewardBlock = block.number;
    }

    function deposit(
        uint256 _amount,
        uint256 _duration
    ) external {
        require(_amount > 0, "bad _amount");
        // Don't allow locking > maxLockDuration
        uint256 duration = _duration.min(maxLockDuration);
        // Enforce min lockup duration to prevent flash loan or MEV transaction ordering
        duration = duration.max(MIN_LOCK_DURATION);
        updatePool();

        Zun.safeTransferFrom(_msgSender(), address(this), _amount);
        uint256 mintAmount = (_amount * getMultiplier(duration)) / 1e18;

        depositsOf[_msgSender()].push(
            Deposit({amount : _amount,
        mintedAmount : mintAmount,
        rewardDebt : mintAmount * accZunPerShare / 1e18,
        usdtRewardDebt : mintAmount * accUsdtPerShare / 1e18,
        start : uint64(block.timestamp),
        end : uint64(block.timestamp) + uint64(duration)})
        );
        totalDepositOf[_msgSender()] += _amount;

        veZun.mint(_msgSender(), mintAmount);
        lpSupply = lpSupply + mintAmount;
        emit Deposited(_amount, duration, _msgSender());
    }

    function getMultiplier(uint256 _lockDuration) public view returns (uint256) {
        return 1e18 + ((maxBonus * _lockDuration) / maxLockDuration);
    }

    function getDepositsOf(
        address _account,
        uint256 skip,
        uint256 limit
    ) public view returns (Deposit[] memory) {
        Deposit[] memory _depositsOf = new Deposit[](limit);
        uint256 depositsOfLength = depositsOf[_account].length;

        if (skip >= depositsOfLength) return _depositsOf;

        for (uint256 i = skip; i < (skip + limit).min(depositsOfLength); i++) {
            _depositsOf[i - skip] = depositsOf[_account][i];
        }

        return _depositsOf;
    }

    function getDepositsOfLength(address _account) public view returns (uint256) {
        return depositsOf[_account].length;
    }

    function withdraw(uint256 _depositId) external {
        require(_depositId < depositsOf[_msgSender()].length, "!exist");
        Deposit memory userDeposit = depositsOf[_msgSender()][_depositId];
        require(block.timestamp >= userDeposit.end, "too soon");
        updatePool();

        // No risk of wrapping around on casting to uint256 since deposit end always > deposit start and types are 64 bits
        uint256 shareAmount = userDeposit.mintedAmount;

        // get rewards
        uint256 pending = userDeposit.mintedAmount * accZunPerShare / 1e18 - userDeposit.rewardDebt;
        if (pending > 0) {
            safeZunTransfer(msg.sender, pending);
        }
        uint256 usdtPending = userDeposit.mintedAmount * accUsdtPerShare / 1e18 - userDeposit.usdtRewardDebt;
        if (usdtPending > 0) {
            safeUsdtTransfer(msg.sender, usdtPending);
        }
        // remove Deposit
        totalDepositOf[_msgSender()] -= userDeposit.amount;
        depositsOf[_msgSender()][_depositId] = depositsOf[_msgSender()][depositsOf[_msgSender()].length - 1];
        depositsOf[_msgSender()][_depositId] = depositsOf[_msgSender()][depositsOf[_msgSender()].length - 1];
        depositsOf[_msgSender()].pop();

        // burn pool shares
        veZun.burn(_msgSender(), shareAmount);
        lpSupply = lpSupply - shareAmount;

        // return tokens
        safeZunTransfer(_msgSender(), userDeposit.amount);
        emit Withdrawn(_depositId, _msgSender(), userDeposit.amount);
    }



    // View function to see pending Zunes on frontend.
    function pendingZun(uint256 _depositId, address _user) external view returns (uint256) {
        Deposit memory userDeposit = depositsOf[_user][_depositId];
        uint256 localShare = accZunPerShare;
        if (block.number > lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = block.number - lastRewardBlock;
            uint256 ZunReward = multiplier * ZunPerBlock;
            localShare = accZunPerShare + (ZunReward * 1e18 / lpSupply);
        }
        return userDeposit.mintedAmount * localShare / 1e18 - userDeposit.rewardDebt;
    }

    function pendingUsdt(uint256 _depositId, address _user) external view returns (uint256) {
        Deposit memory userDeposit = depositsOf[_user][_depositId];
        uint256 localShare = accUsdtPerShare;
        if (lpSupply != 0) {
            localShare = accUsdtPerShare * 1e18 / lpSupply;
        }
        return userDeposit.mintedAmount * localShare / 1e18 - userDeposit.usdtRewardDebt;
    }

    function safeZunTransfer(address _to, uint256 _amount) internal {
        uint256 ZunBal = Zun.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > ZunBal) {
            transferSuccess = Zun.transfer(_to, ZunBal);
        } else {
            transferSuccess = Zun.transfer(_to, _amount);
        }
        require(transferSuccess, "safeZunTransfer: Transfer failed");
    }

    function safeUsdtTransfer(address _to, uint256 _amount) internal {
        uint256 usdtBal = USDT.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > usdtBal) {
            transferSuccess = USDT.transfer(_to, usdtBal);
        } else {
            transferSuccess = USDT.transfer(_to, _amount);
        }
        require(transferSuccess, "safeUsdtTransfer: Transfer failed");
    }

    // change rewards per block
    function updateZunPerBlock(uint256 _ZunPerBlock) external onlyOwner {
        updatePool();
        ZunPerBlock = _ZunPerBlock;
    }

    // claim functions

    function changeClaimLock(bool _isClaimLock) external onlyOwner {
        isClaimLock = _isClaimLock;
    }

    function Claim(uint256 _depositId) external isClaimLocked {
        Deposit memory userDeposit = depositsOf[_msgSender()][_depositId];
        uint256 pending = userDeposit.mintedAmount * accZunPerShare / 1e18 - userDeposit.rewardDebt;
        if (pending > 0) {
            safeZunTransfer(msg.sender, pending);
        }
        uint256 usdtPending = userDeposit.mintedAmount * accUsdtPerShare / 1e18 - userDeposit.usdtRewardDebt;
        if (usdtPending > 0) {
            safeUsdtTransfer(msg.sender, usdtPending);
        }
        userDeposit.rewardDebt = userDeposit.mintedAmount * accZunPerShare / 1e18;
    }

    function ClaimAll() external isClaimLocked {
        uint256 length = depositsOf[_msgSender()].length;

        for (uint256 depId = 0; depId < length; ++depId) {
            uint256 pending = depositsOf[_msgSender()][depId].mintedAmount * accZunPerShare / 1e18 - depositsOf[_msgSender()][depId].rewardDebt;
            if (pending > 0) {
                safeZunTransfer(msg.sender, pending);
            }
            depositsOf[_msgSender()][depId].rewardDebt = depositsOf[_msgSender()][depId].mintedAmount * accZunPerShare / 1e18;
        }
    }

    // update management fee rewards by Zunami
    function updateUsdtPerShare(uint256 _amount) external {
        USDT.safeTransferFrom(_msgSender(), address(this), _amount);
        accUsdtPerShare += _amount * 1e18 / lpSupply;
    }

}