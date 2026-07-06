import { ethers } from "hardhat";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

describe("SimpleToken", function () {
  async function deployFixture() {
    const [owner, alice, bob] = await ethers.getSigners();

    const SimpleToken = await ethers.getContractFactory("SimpleToken");
    const token = await SimpleToken.deploy("Simple RWA Token", "SRWA", 1_000_000);
    await token.waitForDeployment();

    return { token, owner, alice, bob };
  }

  it("deploys with correct name, symbol and initial supply", async function () {
    const { token, owner } = await loadFixture(deployFixture);

    expect(await token.name()).to.equal("Simple RWA Token");
    expect(await token.symbol()).to.equal("SRWA");
    expect(await token.totalSupply()).to.equal(ethers.parseEther("1000000"));
    expect(await token.balanceOf(owner.address)).to.equal(ethers.parseEther("1000000"));
  });

  it("owner can mint tokens to another address", async function () {
    const { token, alice } = await loadFixture(deployFixture);

    await token.mint(alice.address, 500);
    expect(await token.balanceOf(alice.address)).to.equal(ethers.parseEther("500"));
  });

  it("reverts when a non-owner tries to mint", async function () {
    const { token, alice, bob } = await loadFixture(deployFixture);

    await expect(
      token.connect(alice).mint(bob.address, 100)
    ).to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount");
  });

  it("transfers tokens between accounts", async function () {
    const { token, owner, alice } = await loadFixture(deployFixture);

    await token.transfer(alice.address, ethers.parseEther("100"));
    expect(await token.balanceOf(alice.address)).to.equal(ethers.parseEther("100"));
    expect(await token.balanceOf(owner.address)).to.equal(ethers.parseEther("999900"));
  });
});
