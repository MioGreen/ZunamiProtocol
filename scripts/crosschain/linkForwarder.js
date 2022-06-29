const config = require('../config.json');


async function main() {
    const forwarderNetworkId = 1;
    const gatewayNetworkId = 67;
    const forwarderAddress = "";
    const gatewayAddress = "";

    const ZunamiForwarder = await ethers.getContractFactory('ZunamiForwarder');
    const forwarder = await ZunamiForwarder.at(forwarderAddress);
    await forwarder.deployed();
    console.log('ZunamiForwarder: ', forwarder.address);

    const setParams = [
        config["crosschain"][gatewayNetworkId.toString()]["chainId"],
        gatewayAddress,
        config["crosschain"][gatewayNetworkId.toString()]["usdtPoolId"]
    ];

    await forwarder.setGatewayParams(...setParams);
    console.log("Sett gateway params: ", setParams);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
