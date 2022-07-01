const config = require('../../config.json');


async function main() {
    const forwarderNetworkId = 137;
    const gatewayAddress = "0x2d691C2492e056ADCAE7cA317569af25910fC4cb";
    const forwarderAddress = "0xC9eE652953D8069c5eD37bbB3F8142c6243EFDA0";

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
