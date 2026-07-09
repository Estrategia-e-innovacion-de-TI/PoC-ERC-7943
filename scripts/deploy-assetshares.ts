import { ethers } from "hardhat";
import { writeFileSync, mkdirSync } from "fs";
import { join } from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with account:", deployer.address);

  const AssetShares = await ethers.getContractFactory("AssetShares");
  const token = await AssetShares.deploy(
    "Asset Shares Token", // name
    "ASH"                 // symbol
  );
  await token.waitForDeployment();

  const address = await token.getAddress();
  console.log("AssetShares deployed to:", address);

  // Separate metadata file so it never collides with SimpleToken's last-deploy.json.
  const outputDir = join(process.cwd(), "frontend");
  mkdirSync(outputDir, { recursive: true });
  const outputPath = join(outputDir, "asset-shares-last-deploy.json");
  const payload = {
    contract: "AssetShares",
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
