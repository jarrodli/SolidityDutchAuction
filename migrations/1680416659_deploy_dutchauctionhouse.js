const DutchAuctionHouse = artifacts.require("DutchAuctionHouse");

module.exports = function(_deployer) {
  _deployer.deploy(DutchAuctionHouse)
};
