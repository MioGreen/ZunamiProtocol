import { ethers, network } from 'hardhat';
import { waffle } from 'hardhat';
import { expect } from 'chai';
import "@nomiclabs/hardhat-web3";
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { ContractFactory, Signer } from 'ethers';
const  { expectRevert, advanceBlockTo, BN , time , ZERO_ADDRESS} = require('@openzeppelin/test-helpers');

const { web3 } = require('@openzeppelin/test-helpers/src/setup');
import { Contract } from '@ethersproject/contracts';
import { abi as erc20ABI } from '../artifacts/@openzeppelin/contracts/token/ERC20/ERC20.sol/ERC20.json';


const SUPPLY = '100000000000000';
const MIN_LOCK_TIME = time.duration.seconds(86400);
const provider = waffle.provider;
const BLOCKS = 1000;
const SKIP_TIMES = 10;
const daiAddress = '0x6B175474E89094C44Da98b954EedeAC495271d0F';
const usdcAddress = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
const usdtAddress = '0xdAC17F958D2ee523a2206206994597C13D831ec7';

describe('Zunami', function () {
    let owner: SignerWithAddress;
    let alice: SignerWithAddress;
    let bob: SignerWithAddress;
    let carol: SignerWithAddress;

    let zunami: Contract;
    let strategy: Contract;
    let referenceBlock: number;
    let dai: Contract;
    let usdc: Contract;
    let usdt: Contract;

    const daiAccount: string = '0x6F6C07d80D0D433ca389D336e6D1feBEA2489264';
    const usdcAccount: string = '0x6BB273bF25220D13C9b46c6eD3a5408A3bA9Bcc6';
    const usdtAccount: string = '0x67aB29354a70732CDC97f372Be81d657ce8822cd';

    function printBalances() {
        it('print balances', async () => {
            for (const user of [alice, bob, carol]) {
                let usdt_balance=await usdt.balanceOf(user.address);
                let usdc_balance=await usdc.balanceOf(user.address);
                let dai_balance=await dai.balanceOf(user.address);
                console.log("  zunami LP: ",ethers.utils.formatUnits((await zunami.balanceOf(user.address)),18));
                console.log("  usdt: ",ethers.utils.formatUnits( usdt_balance,6));
                console.log("  usdc: ",ethers.utils.formatUnits(usdc_balance,6));
                console.log("  dai: ",ethers.utils.formatUnits(dai_balance,18));
                console.log("  SUMM : ",parseFloat(ethers.utils.formatUnits(dai_balance,18))
                    +parseFloat(ethers.utils.formatUnits(usdc_balance,6))
                    +parseFloat(ethers.utils.formatUnits( usdt_balance,6)));
            }
        });
    };

    function testStrategy(){

        it('only the owner can add a pool', async () => {
            await expectRevert(zunami.connect(alice).add(strategy.address),
            'Ownable: caller is not the owner');
            await zunami.add(strategy.address);

            for (const user of [owner, alice, bob, carol]) {
                await usdc.connect(user).approve(zunami.address, web3.utils.toWei("1000000", "mwei"));
                await usdt.connect(user).approve(zunami.address, web3.utils.toWei("1000000", "mwei"));
                await dai.connect(user).approve(zunami.address, web3.utils.toWei("1000000", "ether"));
            }

        });

        it('deposit before strategy started should be fail', async () => {

            await expectRevert(zunami.deposit([
                web3.utils.toWei("1000", "ether"),
                web3.utils.toWei("1000", "mwei"),
                web3.utils.toWei("1000", "mwei"),
            ],0),
            'Zunami: strategy not started yet!');
        });

        it('deposit after MIN_LOCK_TIME should be successful', async () => {
            await time.increaseTo((await time.latest()).add(MIN_LOCK_TIME));
            for (const user of [alice, bob, carol]) {
                await zunami.connect(user).deposit([
                    web3.utils.toWei("1000", "ether"),
                    web3.utils.toWei("1000", "mwei"),
                    web3.utils.toWei("1000", "mwei"),
                ],0);
            }
        });

        it('check balances after deposit', async () => {
            for (const user of [alice, bob, carol]) {
               expect(ethers.utils.formatUnits((await zunami.balanceOf(user.address)),18)).to.equal("3000.0");
               expect(ethers.utils.formatUnits((await usdt.balanceOf(user.address)),6)).to.equal("0.0");
               expect(ethers.utils.formatUnits((await usdc.balanceOf(user.address)),6)).to.equal("0.0");
               expect(ethers.utils.formatUnits((await dai.balanceOf(user.address)),18)).to.equal("0.0");
            }
        });

        it('skip blocks', async () => {
            for(var i=0;i<SKIP_TIMES;i++){
                await time.advanceBlockTo((await provider.getBlockNumber()) + BLOCKS);
            }
        });

        it('withraw', async () => {
            for (const user of [alice, bob, carol]) {
                await zunami.connect(user).withdraw(await zunami.balanceOf(user.address), [
                    '0',
                    '0',
                    '0',
                ],0);
            }

        });

        it('check balances after withraw', async () => {
            for (const user of [alice, bob, carol]) {
               expect(ethers.utils.formatUnits((await zunami.balanceOf(user.address)),18)).to.equal("0.0");
               let usdt_balance=await usdt.balanceOf(user.address);
                let usdc_balance=await usdc.balanceOf(user.address);
                let dai_balance=await dai.balanceOf(user.address);
               let SUMM=parseFloat(ethers.utils.formatUnits(dai_balance,18))
               +parseFloat(ethers.utils.formatUnits(usdc_balance,6))
               +parseFloat(ethers.utils.formatUnits( usdt_balance,6));
               expect(SUMM).to.gt(2985);//99.5%
            }
        });

        //printBalances();

        it('claim', async () => {
            await zunami.claimManagementFees(strategy.address);
        });

        it('add one more pool and deposit to it', async () => {
            await zunami.add(strategy.address);
            await time.increaseTo((await time.latest()).add(MIN_LOCK_TIME));
            for (const user of [alice, bob, carol]) {
                let usdt_balance=await usdt.balanceOf(user.address);
                let usdc_balance=await usdc.balanceOf(user.address);
                let dai_balance=await dai.balanceOf(user.address);
                await zunami.connect(user).deposit([
                    dai_balance,
                    usdc_balance,
                    usdt_balance,
                ],1);
            }
        });

        it('moveFunds() (update strategy) ', async () => {
            await zunami.moveFunds(1, 0);
        });

        it('withraw after moveFunds()', async () => {
            for (const user of [alice, bob, carol]) {
                await zunami.connect(user).withdraw(await zunami.balanceOf(user.address), [
                    '0',
                    '0',
                    '0',
                ],0);
            }
        });

        it('check balances after withraw', async () => {
            for (const user of [alice, bob, carol]) {
               expect(ethers.utils.formatUnits((await zunami.balanceOf(user.address)),18)).to.equal("0.0");
               let usdt_balance=await usdt.balanceOf(user.address);
                let usdc_balance=await usdc.balanceOf(user.address);
                let dai_balance=await dai.balanceOf(user.address);
               let SUMM=parseFloat(ethers.utils.formatUnits(dai_balance,18))
               +parseFloat(ethers.utils.formatUnits(usdc_balance,6))
               +parseFloat(ethers.utils.formatUnits( usdt_balance,6));
               expect(SUMM).to.gt(2985);//99.5%
            }
        });

        it('delegateDeposit', async () => {
            for (const user of [alice, bob, carol]) {
                let usdt_balance=await usdt.balanceOf(user.address);
                let usdc_balance=await usdc.balanceOf(user.address);
                let dai_balance=await dai.balanceOf(user.address);
                await zunami.connect(user).delegateDeposit([
                    dai_balance,
                    usdc_balance,
                    usdt_balance,
                ]);
            }
        });

        it('create new pool and completeDeposits to it', async () => {
            await zunami.add(strategy.address);
            await time.increaseTo((await time.latest()).add(MIN_LOCK_TIME));
            // await zunami.completeDeposits(3,2);
            await zunami.completeDeposits([alice.address, bob.address,
                // carol.address
            ],2);
        });

        it('one user withdraw from pending', async () => {
            await zunami.connect(carol).pendingDepositRemove();
            let usdt_balance=await usdt.balanceOf(carol.address);
            let usdc_balance=await usdc.balanceOf(carol.address);
            let dai_balance=await dai.balanceOf(carol.address);
        });

        it('delegateWithdrawal', async () => {
            for (const user of [alice, bob
                // , carol
            ]) {
                let zunami_balance=await zunami.balanceOf(user.address);
                await zunami.connect(user).delegateWithdrawal(zunami_balance,[
                    0,
                    0,
                    0,
                ]);
            }
        });

        it('completeWithdrawals', async () => {
            await zunami.completeWithdrawals(10,2);
        });

        it('check balances after withraw', async () => {
            for (const user of [alice, bob, carol]) {
               expect(ethers.utils.formatUnits((await zunami.balanceOf(user.address)),18)).to.equal("0.0");
               let usdt_balance=await usdt.balanceOf(user.address);
                let usdc_balance=await usdc.balanceOf(user.address);
                let dai_balance=await dai.balanceOf(user.address);
               let SUMM=parseFloat(ethers.utils.formatUnits(dai_balance,18))
               +parseFloat(ethers.utils.formatUnits(usdc_balance,6))
               +parseFloat(ethers.utils.formatUnits( usdt_balance,6));
               expect(SUMM).to.gt(2985);//99.5%
            }
        });


        printBalances();

    }

    before(async function () {
        [owner, alice, bob, carol] = await ethers.getSigners();
        dai = new ethers.Contract(daiAddress, erc20ABI, owner);
        usdc = new ethers.Contract(usdcAddress, erc20ABI, owner);
        usdt = new ethers.Contract(usdtAddress, erc20ABI, owner);

        owner.sendTransaction({
            to: daiAccount,
            value: ethers.utils.parseEther('10'),
        });
        owner.sendTransaction({
            to: usdcAccount,
            value: ethers.utils.parseEther('10'),
        });
        owner.sendTransaction({
            to: usdtAccount,
            value: ethers.utils.parseEther('10'),
        });

        await network.provider.request({
            method: 'hardhat_impersonateAccount',
            params: [daiAccount],
        });
        const daiAccountSigner: Signer = ethers.provider.getSigner(daiAccount);
        await dai
            .connect(daiAccountSigner)
            .transfer(owner.address, web3.utils.toWei("1000000", "ether"));
        await network.provider.request({
            method: 'hardhat_stopImpersonatingAccount',
            params: [daiAccount],
        });

        await network.provider.request({
            method: 'hardhat_impersonateAccount',
            params: [usdcAccount],
        });
        const usdcAccountSigner: Signer =
            ethers.provider.getSigner(usdcAccount);
        await usdc
            .connect(usdcAccountSigner)
            .transfer(owner.address, web3.utils.toWei("1000000", "mwei"));
        await network.provider.request({
            method: 'hardhat_stopImpersonatingAccount',
            params: [usdcAccount],
        });

        await network.provider.request({
            method: 'hardhat_impersonateAccount',
            params: [usdtAccount],
        });
        const usdtAccountSigner: Signer =
            ethers.provider.getSigner(usdtAccount);
        await usdt
            .connect(usdtAccountSigner)
            .transfer(owner.address, web3.utils.toWei("1000000", "mwei"));
        await network.provider.request({
            method: 'hardhat_stopImpersonatingAccount',
            params: [usdtAccount],
        });

        for (const user of [alice, bob, carol]) {
            await usdt
            .connect(owner)
            .transfer(user.address, web3.utils.toWei("1000", "mwei"));
            await usdc
            .connect(owner)
            .transfer(user.address, web3.utils.toWei("1000", "mwei"));
            await dai
            .connect(owner)
            .transfer(user.address, web3.utils.toWei("1000", "ether"));
        }

    });

    // base1
    // describe('AaveCurveConvex', function () {
    //     before(async function () {
    //         let Zunami: ContractFactory = await ethers.getContractFactory('Zunami');
    //         let AaveCurveConvex: ContractFactory = await ethers.getContractFactory('AaveCurveConvex');;
    //         strategy = await AaveCurveConvex.deploy();
    //         await strategy.deployed();
    //         zunami = await Zunami.deploy();
    //         await zunami.deployed();
    //         strategy.setZunami(zunami.address);
    //     });
    //     testStrategy();
    // });

    // base2
    // describe('FraxCurveConvex', function () {
    //     before(async function () {
    //         let Zunami: ContractFactory = await ethers.getContractFactory('Zunami');
    //         let FraxCurveConvex: ContractFactory = await ethers.getContractFactory('FraxCurveConvex');
    //         strategy = await FraxCurveConvex.deploy();
    //         await strategy.deployed();
    //         zunami = await Zunami.deploy();
    //         await zunami.deployed();
    //         strategy.setZunami(zunami.address);
    //     });
    //     testStrategy();
    // });

    // base4
    describe('SUSDCurveConvex', function () {
        before(async function () {
            let Zunami: ContractFactory = await ethers.getContractFactory('Zunami');
            let FraxCurveConvex: ContractFactory = await ethers.getContractFactory('SUSDCurveConvex');
            strategy = await FraxCurveConvex.deploy();
            await strategy.deployed();
            zunami = await Zunami.deploy();
            await zunami.deployed();
            strategy.setZunami(zunami.address);
        });
        testStrategy();
    });







    /*

        it('zunami moveFunds(update strategy)', async () => {
            strategy = await AaveCurveConvex.deploy();
            await strategy.deployed();
            strategy.setZunami(zunami.address);
            zunami.add(strategy.address);
            await time.increaseTo((await time.latest()).add(MIN_LOCK_TIME));
            await dai.approve(zunami.address, '1000000000000000000000');
            await usdc.approve(zunami.address, '1000000000');
            await usdt.approve(zunami.address, '1000000000');
            await zunami.deposit([
                '1000000000000000000000',
                '1000000000',
                '1000000000',
            ],0);

            await time.advanceBlockTo((await provider.getBlockNumber()) + BLOCKS);
            await zunami.claimManagementFees(strategy.address);

            strategy = await USDPCurveConvex.deploy();
            await strategy.deployed();
            strategy.setZunami(zunami.address);
            zunami.add(strategy.address);
            await time.increaseTo((await time.latest()).add(MIN_LOCK_TIME));
            await dai.approve(zunami.address, '1000000000000000000000');
            await usdc.approve(zunami.address, '1000000000');
            await usdt.approve(zunami.address, '1000000000');
            await zunami.deposit([
                '1000000000000000000000',
                '1000000000',
                '1000000000',
            ],0);
            await time.advanceBlockTo((await provider.getBlockNumber()) + BLOCKS);
            await zunami.claimManagementFees(strategy.address);
            await zunami.moveFunds(0, 1);
        });
    */

});
