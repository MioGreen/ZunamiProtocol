const config = require('../config.json');


async function main() {
    const networkId = 1;
    const zunami = "";
    const curvePool = "";

    console.log('Start deploy ZunamiForwarder');
    const ZunamiForwarder = await ethers.getContractFactory('ZunamiForwarder');
    const forwarder = await ZunamiForwarder.deploy(
      config.tokens,
      config["crosschain"][networkId.toString()]["usdtPoolId"],
      zunami,
      curvePool,
      config["crosschain"][networkId.toString()]["stargate"],
      config["crosschain"][networkId.toString()]["layerzero"],
    );
    await forwarder.deployed();
    console.log('ZunamiForwarder deployed to:', forwarder.address);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
