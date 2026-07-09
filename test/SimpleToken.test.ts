import { ethers } from "hardhat";
import { expect } from "chai";

describe("SimpleToken", function () {
  let owner: any;
  let alice: any;
  let token: any;

  beforeEach(async function () {
    [owner, alice] = await ethers.getSigners();

    const SimpleToken = await ethers.getContractFactory("SimpleToken");
    token = await SimpleToken.deploy("Simple RWA Token", "SRWA", 1_000_000);
    await token.waitForDeployment();
  });

  it("deployment: setea nombre, simbolo y supply inicial", async function () {
    expect(await token.name()).to.equal("Simple RWA Token");
    expect(await token.symbol()).to.equal("SRWA");
    expect(await token.totalSupply()).to.equal(ethers.parseEther("1000000"));
    expect(await token.balanceOf(owner.address)).to.equal(ethers.parseEther("1000000"));
  });

  it("owner puede mintear y luego transferir", async function () {
    await token.mint(alice.address, 500);
    expect(await token.balanceOf(alice.address)).to.equal(ethers.parseEther("500"));

    await token.transfer(alice.address, ethers.parseEther("100"));
    expect(await token.balanceOf(alice.address)).to.equal(ethers.parseEther("600"));
    expect(await token.balanceOf(owner.address)).to.equal(ethers.parseEther("999900"));
  });

  it("solo owner puede mintear", async function () {
    await expect(token.connect(alice).mint(alice.address, 100)).to.be.revertedWithCustomError(
      token,
      "OwnableUnauthorizedAccount"
    );
  });
});
