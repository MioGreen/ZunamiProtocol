const config = require('../../config.json');


async function main() {
    const forwarderNetworkId = 137;
    const gatewayAddress = "0xe766e26AcFF668a3Fd4Df2c01A00eb5aA712cD8C";
    const forwarderAddress = "0x3694Db838a8cAf3b1c234529bB1b447bd849F357";

    const ZunamiGateway = await ethers.getContractFactory('ZunamiGateway');
    const gateway = await ZunamiGateway.attach(gatewayAddress);
    await gateway.deployed();
    console.log('ZunamiGateway: ', gateway.address);

    const setParams = [
        config["crosschain"][forwarderNetworkId.toString()]["chainId"],
        forwarderAddress,
        config["crosschain"][forwarderNetworkId.toString()]["usdtPoolId"]
    ];

    await gateway.setForwarderParams(...setParams);
    console.log("Set forwarder params: ", setParams);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
