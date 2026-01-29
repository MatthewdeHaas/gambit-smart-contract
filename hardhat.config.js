require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.28",
  networks: {
    hardhat: {
      forking: {
        url: "https://eth-sepolia.g.alchemy.com/v2/7golHVt_llyZHdfzzP536",
        enabled: true // Manually force this to true
      },
        chainId: 11155111,
    },
  },
};
