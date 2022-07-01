const config = require('../../config.json');


async function main() {
    const gatewayNetworkId = 56;
    const forwarderAddress = "0xC9eE652953D8069c5eD37bbB3F8142c6243EFDA0";
    const gatewayAddress = "0x2d691C2492e056ADCAE7cA317569af25910fC4cb";

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
