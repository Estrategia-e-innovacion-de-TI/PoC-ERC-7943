import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("AssetShares", function () {
  let owner: any;
  let a: any;
  let b: any;
  let token: any;

  const DOCUMENT_HASH = "ipfs://document-hash";
  const ERC7943_FUNGIBLE_INTERFACE_ID = "0x3edbb4c4";

  beforeEach(async function () {
    [owner, a, b] = await ethers.getSigners();

    const AssetShares = await ethers.getContractFactory("AssetShares");
    token = await AssetShares.deploy("Asset Shares Token", "ASH");
    await token.waitForDeployment();
  });

  async function futureMaturity(daysAhead = 30) {
    const latest = await time.latest();
    return latest + daysAhead * 24 * 60 * 60;
  }

  describe("Conformidad ERC-7943", function () {
    it("supportsInterface reporta el interfaceId fungible del EIP", async function () {
      expect(await token.supportsInterface(ERC7943_FUNGIBLE_INTERFACE_ID)).to.equal(true);
    });

    it("supportsInterface rechaza el identificador reservado 0xffffffff", async function () {
      expect(await token.supportsInterface("0xffffffff")).to.equal(false);
    });

    it("canTransfer no revierte aunque lo congelado supere el balance actual", async function () {
      const maturityDate = await futureMaturity();
      await token.createAsset("Bono Demo", 1000, maturityDate, DOCUMENT_HASH);
      await token.activateAsset();
      await token.approveInvestor(a.address);
      await token.approveInvestor(b.address);
      await token.issueShares(a.address, 50);

      await token.setFrozenTokens(a.address, 999); // mas que el balance

      expect(await token.canTransfer(a.address, b.address, 1)).to.equal(false);
    });
  });

  describe("Escenario 1: tokenizar el activo", function () {
    it("createAsset -> activateAsset -> issueShares", async function () {
      const maturityDate = await futureMaturity();

      await token.createAsset("Bono Demo", 1000, maturityDate, DOCUMENT_HASH);
      expect(await token.assetStatus()).to.equal(1); // Created

      await token.activateAsset();
      expect(await token.assetStatus()).to.equal(2); // Active

      await token.approveInvestor(a.address);
      await token.issueShares(a.address, 100);

      expect(await token.issuedShares()).to.equal(100);
      expect(await token.balanceOf(a.address)).to.equal(100);
    });
  });

  describe("Escenario 2: comercializacion entre inversionistas aprobados", function () {
    it("approveInvestor(A) + approveInvestor(B) -> transferShares(B, 20)", async function () {
      const maturityDate = await futureMaturity();
      await token.createAsset("Bono Demo", 1000, maturityDate, DOCUMENT_HASH);
      await token.activateAsset();

      await token.approveInvestor(a.address);
      await token.approveInvestor(b.address);
      await token.issueShares(a.address, 100);

      await token.connect(a).transferShares(b.address, 20);

      expect(await token.balanceOf(a.address)).to.equal(80);
      expect(await token.balanceOf(b.address)).to.equal(20);
    });

    it("rechaza transferShares hacia un inversionista no aprobado", async function () {
      const maturityDate = await futureMaturity();
      await token.createAsset("Bono Demo", 1000, maturityDate, DOCUMENT_HASH);
      await token.activateAsset();

      await token.approveInvestor(a.address);
      await token.issueShares(a.address, 100);

      await expect(token.connect(a).transferShares(b.address, 20))
        .to.be.revertedWithCustomError(token, "ERC7943CannotReceive")
        .withArgs(b.address);
    });
  });

  describe("Escenario 3: congelamiento de tokens", function () {
    it("setFrozenTokens(A, 80) -> transferShares(B, 100) es rechazado", async function () {
      const maturityDate = await futureMaturity();
      await token.createAsset("Bono Demo", 1000, maturityDate, DOCUMENT_HASH);
      await token.activateAsset();

      await token.approveInvestor(a.address);
      await token.approveInvestor(b.address);
      await token.issueShares(a.address, 100);

      await token.setFrozenTokens(a.address, 80);

      await expect(token.connect(a).transferShares(b.address, 100))
        .to.be.revertedWithCustomError(token, "ERC7943InsufficientUnfrozenBalance")
        .withArgs(a.address, 100, 20);

      // Pero si transfiere solo lo disponible (100 - 80), si funciona.
      await token.connect(a).transferShares(b.address, 20);
      expect(await token.balanceOf(b.address)).to.equal(20);
    });
  });

  describe("Escenario 4: transferencia forzada", function () {
    it("forcedTransfer mueve balance aunque este bloqueado/congelado", async function () {
      const maturityDate = await futureMaturity();
      await token.createAsset("Bono Demo", 1000, maturityDate, DOCUMENT_HASH);
      await token.activateAsset();

      await token.approveInvestor(a.address);
      await token.approveInvestor(b.address);
      await token.issueShares(a.address, 100);

      await token.blockInvestor(a.address);

      await token.forcedTransfer(a.address, b.address, 50);

      expect(await token.balanceOf(a.address)).to.equal(50);
      expect(await token.balanceOf(b.address)).to.equal(50);
    });

    it("forcedTransferWithReason hace lo mismo y ademas deja el motivo en el evento", async function () {
      const maturityDate = await futureMaturity();
      await token.createAsset("Bono Demo", 1000, maturityDate, DOCUMENT_HASH);
      await token.activateAsset();

      await token.approveInvestor(a.address);
      await token.approveInvestor(b.address);
      await token.issueShares(a.address, 100);

      await token.blockInvestor(a.address);

      await expect(token.forcedTransferWithReason(a.address, b.address, 50, "orden judicial"))
        .to.emit(token, "ForcedTransfer")
        .withArgs(a.address, b.address, 50)
        .and.to.emit(token, "ForcedTransferReason")
        .withArgs(a.address, b.address, 50, "orden judicial");

      expect(await token.balanceOf(b.address)).to.equal(50);
    });

    it("solo el owner puede ejecutar forcedTransfer", async function () {
      const maturityDate = await futureMaturity();
      await token.createAsset("Bono Demo", 1000, maturityDate, DOCUMENT_HASH);
      await token.activateAsset();

      await token.approveInvestor(a.address);
      await token.approveInvestor(b.address);
      await token.issueShares(a.address, 100);

      await expect(
        token.connect(a).forcedTransfer(a.address, b.address, 50)
      ).to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount");
    });
  });

  describe("Escenario 5: vencimiento del activo", function () {
    it("markMatured cambia el estado tras la fecha de vencimiento", async function () {
      const maturityDate = await futureMaturity(1);
      await token.createAsset("Bono Demo", 1000, maturityDate, DOCUMENT_HASH);
      await token.activateAsset();

      await expect(token.markMatured()).to.be.revertedWith("Maturity date has not arrived");

      await time.increaseTo(maturityDate + 1);
      await token.markMatured();

      expect(await token.assetStatus()).to.equal(3); // Matured
    });

    it("no permite transferencias despues de vencido", async function () {
      const maturityDate = await futureMaturity(1);
      await token.createAsset("Bono Demo", 1000, maturityDate, DOCUMENT_HASH);
      await token.activateAsset();

      await token.approveInvestor(a.address);
      await token.approveInvestor(b.address);
      await token.issueShares(a.address, 100);

      await time.increaseTo(maturityDate + 1);
      await token.markMatured();

      await expect(token.connect(a).transferShares(b.address, 10))
        .to.be.revertedWithCustomError(token, "ERC7943CannotSend")
        .withArgs(a.address);
    });
  });
});
