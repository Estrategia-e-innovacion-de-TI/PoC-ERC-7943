import { ethers } from "hardhat";
import { writeFileSync, mkdirSync } from "fs";
import { join } from "path";

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

  const address = await token.getAddress();
  console.log("SimpleToken deployed to:", address);
  console.log("Total supply:", ethers.formatEther(await token.totalSupply()), "SRWA");

  // Small file for the simple frontend to auto-load latest address.
  const outputDir = join(process.cwd(), "frontend");
  mkdirSync(outputDir, { recursive: true });
  const outputPath = join(outputDir, "last-deploy.json");
  const payload = {
    contract: "SimpleToken",
    address,
    network: (await ethers.provider.getNetwork()).name,
    chainId: Number((await ethers.provider.getNetwork()).chainId),
  };
  writeFileSync(outputPath, JSON.stringify(payload, null, 2), "utf8");
  console.log("Saved deploy metadata to:", outputPath);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
