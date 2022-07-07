//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import "./interfaces/layerzero/ILayerZeroReceiver.sol";
import "./interfaces/stargate/IStargateReceiver.sol";
import "./interfaces/stargate/IStargateRouter.sol";
import "./interfaces/layerzero/ILayerZeroEndpoint.sol";

contract ZunamiGateway is ERC20, Pausable, AccessControl, ILayerZeroReceiver, IStargateReceiver {
    using SafeERC20 for IERC20Metadata;

    bytes32 public constant OPERATOR_ROLE = keccak256('OPERATOR_ROLE');

    struct CrosschainDeposit {
        uint256 id;
        uint256 totalTokenAmount;
        address[] users;
        uint256[] tokenAmounts;
        uint256 totalLpShares;
    }

    struct CrosschainWithdrawal {
        uint256 id;
        uint256 totalLpShares;
        address[] users;
        uint256[] lpSharesAmounts;
        uint256 totalTokenAmount;
    }

    IStargateRouter public stargateRouter;
    ILayerZeroEndpoint public layerZeroEndpoint;

    uint8 public constant POOL_ASSETS = 3;
    uint8 public constant USDT_TOKEN_ID = 2;

    uint256 public constant SG_SLIPPAGE_DIVIDER = 10000;

    uint256 public stargateSlippage = 20;
    IERC20Metadata public token;
    uint256 public tokenPoolId;

    uint16 public forwarderChainId;
    address public forwarderAddress;
    uint256 public forwarderTokenPoolId;

    CrosschainDeposit public processingCrosschainDeposit;
    CrosschainWithdrawal public processingCrosschainWithdrawal;

    mapping(address => uint256) internal _pendingDeposits;
    mapping(address => uint256) internal _pendingWithdrawals;

    event CreatedPendingDeposit(address indexed depositor, uint256 amount);
    event SentCrosschainDepositRequest(uint256 depositId, uint256 totalTokenAmount);
    event ReceivedCrosschainDepositResponse(
        uint256 depositId,
        uint256 lpShares
    );
    event Deposited(address indexed depositor, uint256 tokenAmount, uint256 lpShares);

    event CreatedPendingWithdrawal(
        address indexed withdrawer,
        uint256 lpShares
    );
    event SentCrosschainWithdrawalRequest(uint256 withdrawalId, uint256 totalLpShares);
    event ReceivedCrosschainWithdrawalResponse(
        uint256 withdrawalId,
        uint256 tokenAmount
    );
    event Withdrawn(
        address indexed withdrawer,
        uint256 tokenAmount,
        uint256 lpShares
    );

    event RemovedPendingDeposit(address indexed depositor);
    event RemovedPendingWithdrawal(address indexed depositor);

    event SetForwarderParams(
        uint256 _chainId,
        address _address,
        uint256 _tokenPoolId
    );

    event SetStargateSlippage(
        uint256 slippage
    );

    constructor(
        address _token,
        uint256 _tokenPoolId,
        address _stargateRouter,
        address _layerZeroEndpoint
    ) ERC20('Gateway Zunami LP', 'GZLP') {
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(OPERATOR_ROLE, _msgSender());

        token = IERC20Metadata(_token);
        tokenPoolId = _tokenPoolId;

        stargateRouter = IStargateRouter(_stargateRouter);
        layerZeroEndpoint = ILayerZeroEndpoint(_layerZeroEndpoint);
    }

    receive() external payable {}

    function setForwarderParams(
        uint16 _chainId,
        address _address,
        uint256 _tokenPoolId
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        forwarderChainId = _chainId;
        forwarderAddress = _address;
        forwarderTokenPoolId =  _tokenPoolId;

        emit SetForwarderParams(_chainId, _address, _tokenPoolId);
    }

    function setStargateSlippage(
        uint16 _slippage
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_slippage <= SG_SLIPPAGE_DIVIDER,"Gateway: wrong stargate slippage");
        stargateSlippage = _slippage;

        emit SetStargateSlippage(_slippage);
    }

    function pendingDeposits(address user) external view returns (uint256) {
        return _pendingDeposits[user];
    }

    function pendingWithdrawals(address user) external view returns (uint256) {
        return _pendingWithdrawals[user];
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev in this func user sends funds to the contract and then waits for the completion
     * of the transaction for all users
     * @param amounts - array of deposit amounts by user
     */
    function delegateDeposit(uint256[POOL_ASSETS] memory amounts) external whenNotPaused {
        if (amounts[USDT_TOKEN_ID] > 0) {
            token.safeTransferFrom(_msgSender(), address(this), amounts[USDT_TOKEN_ID]);
            _pendingDeposits[_msgSender()] += amounts[USDT_TOKEN_ID];
        }

        emit CreatedPendingDeposit(_msgSender(), amounts[USDT_TOKEN_ID]);
    }

    /**
     * @dev Zunami protocol owner complete all active pending deposits of users
     * @param userList - dev send array of users from pending to complete
     */
    function sendCrosschainDeposit(address[] memory userList)
    external
    payable
    onlyRole(OPERATOR_ROLE)
    {
        require(processingCrosschainDeposit.id == 0, "Gateway: deposit was sent");
        uint256 depositId = block.number;

        uint256 totalTokenAmount = 0;
        uint256[] memory tokenAmounts = new uint256[](userList.length);
        // 1/ clone all deposits with specific stable USDT - copy to separate mapping and remove from official mapping
        for (uint256 i = 0; i < userList.length; i++) {
            address user = userList[i];
            uint256 deposit = _pendingDeposits[user];
            tokenAmounts[i] = deposit;
            require(deposit > 0, "Gateway: wrong deposit token amount");
            totalTokenAmount += deposit;
            delete _pendingDeposits[user];
        }
        processingCrosschainDeposit = CrosschainDeposit(depositId, totalTokenAmount, userList, tokenAmounts, 0);

        token.safeIncreaseAllowance(address(stargateRouter), totalTokenAmount);

        // 2/ send cloned deposits to forwarder by stargate
        // the address(this).balance is the "fee" that Stargate needs to pay for the cross chain message
        stargateRouter.swap{value:address(this).balance}(
            forwarderChainId,                       // LayerZero chainId
            tokenPoolId,                            // source pool id
            forwarderTokenPoolId,                   // dest pool id
            payable(address(this)),                    // refund address. extra gas (if any) is returned to this address
            totalTokenAmount,                       // quantity to swap
            totalTokenAmount * (SG_SLIPPAGE_DIVIDER - stargateSlippage) / SG_SLIPPAGE_DIVIDER,                                      // the min qty you would accept on the destination
            IStargateRouter.lzTxObj(150000, 0, "0x"),     // 350000 additional gasLimit increase, 0 airdrop, at 0x address
            abi.encodePacked(forwarderAddress),     // the address to send the tokens to on the destination
            abi.encode(depositId)                   // bytes param, if you wish to send additional payload you can abi.encode() them here
        );

        emit SentCrosschainDepositRequest(depositId, totalTokenAmount);
    }

    // @notice LayerZero endpoint will invoke this function to deliver the message on the destination
    // @param _srcChainId - the source endpoint identifier
    // @param _srcAddress - the source sending contract address from the source chain
    // @param _nonce - the ordered message nonce
    // @param _payload - the signed payload is the UA bytes has encoded to be sent
    function lzReceive(uint16 _srcChainId, bytes calldata _srcAddress, uint64 _nonce, bytes calldata _payload) external {
        require(
            _msgSender() == address(layerZeroEndpoint),
            "Gateway: only zero layer endpoint can call lzReceive!"
        );

        require(_srcChainId == forwarderChainId, "Gateway: wrong source chain id");
//        require(_srcAddress == forwarderAddress, "Gateway: wrong source address");

        // 3/ receive ZLP amount on lzReceive method for sent deposits and mint GZLP to each depositer proportionaly deposits
        (uint256 depositId, uint256 totalLpShares, uint256 storedLpShares) = abi.decode(_payload, (uint256, uint256, uint256));
        require( IERC20Metadata(address(this)).totalSupply() == storedLpShares - totalLpShares, "Gateway: stored ZLP != minted GZLP");

        processingCrosschainDeposit.totalLpShares = totalLpShares;

        emit ReceivedCrosschainDepositResponse(depositId, totalLpShares);
    }

    function finalizeCrosschainDeposit()
    external
    onlyRole(OPERATOR_ROLE)
    {
        require(processingCrosschainDeposit.id != 0, "Gateway: deposit was not sent");
        require(processingCrosschainDeposit.totalLpShares != 0, "Gateway: callback wasn't received");

        for (uint256 i = 0; i < processingCrosschainDeposit.users.length; i++) {
            uint256 tokenAmount = processingCrosschainDeposit.tokenAmounts[i];
            uint256 lpShares = (processingCrosschainDeposit.totalLpShares * tokenAmount) / processingCrosschainDeposit.totalTokenAmount;
            _mint(processingCrosschainDeposit.users[i], lpShares);

            emit Deposited(processingCrosschainDeposit.users[i], tokenAmount, lpShares);
        }

        delete processingCrosschainDeposit;
    }

    /**
     * @dev user remove his active pending deposit
     */
    function removePendingDeposit() external {
        address depositor = _msgSender();
        if (_pendingDeposits[depositor] > 0) {
            IERC20Metadata(token).safeTransfer(
                depositor,
                _pendingDeposits[depositor]
            );
        }
        delete _pendingDeposits[depositor];

        emit RemovedPendingDeposit(depositor);
    }

    function delegateWithdrawal(uint256 lpShares)
        external
        whenNotPaused
    {
        require(lpShares > 0, 'Gateway: lpAmount must be higher 0');

        IERC20Metadata(address(this)).safeTransferFrom(_msgSender(), address(this), lpShares);

        address userAddr = _msgSender();
        _pendingWithdrawals[userAddr] = lpShares;

        emit CreatedPendingWithdrawal(userAddr, lpShares);
    }

    function sendCrosschainWithdrawal(address[] memory userList)
        external
        payable
        onlyRole(OPERATOR_ROLE)
    {
        require(userList.length > 0, 'Gateway: there are no pending withdrawals requests');
        require(processingCrosschainWithdrawal.id == 0, "Gateway: withdrawal was sent");

        // 1/ clone withdrawals
        uint256 withdrawalId = block.number;

        uint256 totalLpShares = 0;
        uint256[] memory lpSharesAmounts = new uint256[](userList.length);
        // 1/ create crosschain withdrawal
        for (uint256 i = 0; i < userList.length; i++) {
            address user = userList[i];
            uint256 lpShares = _pendingWithdrawals[user];
            lpSharesAmounts[i] = lpShares;
            require(lpShares > 0, "Gateway: wrong withdrawal token amount");
            totalLpShares += lpShares;
            delete _pendingWithdrawals[user];
        }
        _burn(address(this), totalLpShares);
        processingCrosschainWithdrawal = CrosschainWithdrawal(withdrawalId, totalLpShares, userList, lpSharesAmounts, 0);

        // 2/ send withdrawal by zero layer request to forwarder with total withdrawing ZLP amount
        bytes memory payload = abi.encode(withdrawalId, totalLpShares);

        // use adapterParams v1 to specify more gas for the destination
        bytes memory adapterParams = abi.encodePacked(uint16(1), uint256(150000));

        layerZeroEndpoint.send{value: address(this).balance}(
            forwarderChainId, // destination chainId
            abi.encodePacked(forwarderAddress), // destination address
            payload, // abi.encode()'ed bytes
            payable(address(this)),
            address(0x0), // future param
            adapterParams // v1 adapterParams, specify custom destination gas qty
        );

        emit SentCrosschainWithdrawalRequest(withdrawalId, totalLpShares);
    }

    function sgReceive(
        uint16 _srcChainId,              // the remote chainId sending the tokens
        bytes memory _srcAddress,        // the remote Bridge address
        uint256 _nonce,
        address _token,                  // the token contract on the local chain
        uint256 _amountLD,                // the qty of local _token contract tokens
        bytes memory _payload
    ) external {
        require(
            _msgSender() == address(stargateRouter),
            "Gateway: only stargate router can call sgReceive!"
        );

        require(_srcChainId == forwarderChainId, "Gateway: wrong source chain id");
        //require(_srcAddress == forwarderAddress, "Gateway: wrong source address");

        // 3/ receive USDT stables by star gate and transfer to customers
        // 4/ burn GZLP and remove cloned mapping
        (uint256 withdrawalId) = abi.decode(_payload, (uint256));
        processingCrosschainWithdrawal.totalTokenAmount = _amountLD;
        emit ReceivedCrosschainWithdrawalResponse(withdrawalId, _amountLD);
    }

    function finalizeCrosschainWithdrawal()
    external
    onlyRole(OPERATOR_ROLE)
    {
        require(processingCrosschainWithdrawal.id != 0, "Gateway: withdrawal was not sent");
        require(processingCrosschainWithdrawal.totalTokenAmount != 0, "Gateway: callback wasn't received");

        for (uint256 i = 0; i < processingCrosschainWithdrawal.users.length; i++) {
            uint256 lpShares = processingCrosschainWithdrawal.lpSharesAmounts[i];
            address user = processingCrosschainWithdrawal.users[i];
            uint256 tokenAmount = (processingCrosschainWithdrawal.totalTokenAmount * lpShares) / processingCrosschainWithdrawal.totalLpShares;
            IERC20Metadata(token).safeTransfer(user, tokenAmount);
            emit Withdrawn(user, tokenAmount, lpShares);
        }

        delete processingCrosschainWithdrawal;
    }

    function removePendingWithdrawal() external {
        address withdrawer = _msgSender();
        if (_pendingWithdrawals[withdrawer] > 0) {
            IERC20Metadata(address(this)).safeTransfer(
                withdrawer,
                _pendingWithdrawals[withdrawer]
            );
        }

        delete _pendingWithdrawals[withdrawer];
        emit RemovedPendingWithdrawal(withdrawer);
    }

    /**
     * @dev governance can withdraw all stuck funds in emergency case
     * @param _token - IERC20Metadata token that should be fully withdraw from ZunamiGateway
     */
    function withdrawStuckToken(IERC20Metadata _token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 tokenBalance = _token.balanceOf(address(this));
        if (tokenBalance > 0) {
            _token.safeTransfer(_msgSender(), tokenBalance);
        }
    }

    function withdrawStuckNative() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            payable(_msgSender()).transfer(balance);
        }
    }
}
