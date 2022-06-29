const config = require('../config.json');


async function main() {
    const usdtPoolId = 2;
    const networkId = 67;

    console.log('Start deploy ZunamiGateway');
    const ZunamiGateway = await ethers.getContractFactory('ZunamiGateway');
    const gateway = await ZunamiGateway.deploy(
      config.tokens[usdtPoolId],
      config["crosschain"][networkId.toString()]["usdtPoolId"],
      config["crosschain"][networkId.toString()]["stargate"],
      config["crosschain"][networkId.toString()]["layerzero"],
    );
    await gateway.deployed();
    console.log('ZunamiGateway deployed to:', gateway.address);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
