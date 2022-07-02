const config = require('../../config.json');


async function main() {
    const gatewayNetworkId = 56;
    const gatewayAddress = "0xe766e26AcFF668a3Fd4Df2c01A00eb5aA712cD8C";
    const forwarderAddress = "0x3694Db838a8cAf3b1c234529bB1b447bd849F357";

    const ZunamiForwarder = await ethers.getContractFactory('ZunamiForwarder');
    const forwarder = await ZunamiForwarder.attach(forwarderAddress);
    await forwarder.deployed();
    console.log('ZunamiForwarder: ', forwarder.address);

    const setParams = [
        config["crosschain"][gatewayNetworkId.toString()]["chainId"],
        gatewayAddress,
        config["crosschain"][gatewayNetworkId.toString()]["usdtPoolId"]
    ];

    await forwarder.setGatewayParams(...setParams);
    console.log("Set gateway params: ", setParams);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
