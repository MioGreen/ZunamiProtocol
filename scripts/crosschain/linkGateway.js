const config = require('../../config.json');


async function main() {
    const forwarderNetworkId = 137;
    const gatewayAddress = "0x9B43E47BEc96A9345cd26fDDE7EFa5F8C06e126c";
    const forwarderAddress = "0x7b608af1Ab97204B348277090619Aa43b6033dE0";

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
