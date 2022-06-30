const config = require('../../config.json');


async function main() {
    const gatewayNetworkId = 56;
    const forwarderAddress = "0x7b608af1Ab97204B348277090619Aa43b6033dE0";
    const gatewayAddress = "0x9B43E47BEc96A9345cd26fDDE7EFa5F8C06e126c";

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
