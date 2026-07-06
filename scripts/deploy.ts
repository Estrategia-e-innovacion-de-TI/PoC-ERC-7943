import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with account:", deployer.address);

  const SimpleToken = await ethers.getContractFactory("SimpleToken");
  const token = await SimpleToken.deploy(
    "Simple RWA Token", // name
    "SRWA",             // symbol
    1_000_000           // initial supply (in token units)
  );
  await token.waitForDeployment();

  console.log("SimpleToken deployed to:", await token.getAddress());
  console.log("Total supply:", ethers.formatEther(await token.totalSupply()), "SRWA");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
