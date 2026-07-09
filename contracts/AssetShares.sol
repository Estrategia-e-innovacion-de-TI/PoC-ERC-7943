// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AssetShares is ERC20, Ownable {
    enum AssetStatus {
        NotCreated,
        Created,
        Active,
        Matured,
        Cancelled
    }

    string public assetName;
    uint256 public totalShares;
    uint256 public issuedShares;
    uint256 public maturityDate;
    string public documentHash;
    AssetStatus public assetStatus;

    mapping(address => bool) public approvedInvestor;
    mapping(address => bool) public blockedInvestor;
    mapping(address => uint256) public frozenTokens;

    bool private _forcedTransferInProgress;

    event AssetCreated(string name, uint256 totalShares, uint256 maturityDate, string documentHash);
    event AssetActivated();
    event InvestorApproved(address indexed investor);
    event InvestorBlocked(address indexed investor);
    event SharesIssued(address indexed to, uint256 amount);
    event Frozen(address indexed account, uint256 amount);
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount, string reason);
    event AssetMatured();

    constructor(
        string memory tokenName,
        string memory tokenSymbol
    ) ERC20(tokenName, tokenSymbol) Ownable(msg.sender) {}

    function decimals() public pure override returns (uint8) {
        return 0;
    }

    function createAsset(
        string memory name,
        uint256 _totalShares,
        uint256 _maturityDate,
        string memory _documentHash
    ) external onlyOwner {
        require(assetStatus == AssetStatus.NotCreated, "Asset already created");
        require(_totalShares > 0, "Total shares must be greater than zero");
        require(_maturityDate > block.timestamp, "Maturity date must be future");
        require(bytes(_documentHash).length > 0, "Document hash is required");

        assetName = name;
        totalShares = _totalShares;
        maturityDate = _maturityDate;
        documentHash = _documentHash;
        assetStatus = AssetStatus.Created;

        emit AssetCreated(name, _totalShares, _maturityDate, _documentHash);
    }

    function activateAsset() external onlyOwner {
        require(assetStatus == AssetStatus.Created, "Asset must be created first");

        assetStatus = AssetStatus.Active;

        emit AssetActivated();
    }

    function approveInvestor(address investor) external onlyOwner {
        require(investor != address(0), "Invalid investor");

        approvedInvestor[investor] = true;
        blockedInvestor[investor] = false;

        emit InvestorApproved(investor);
    }

    function blockInvestor(address investor) external onlyOwner {
        require(investor != address(0), "Invalid investor");

        blockedInvestor[investor] = true;

        emit InvestorBlocked(investor);
    }

    function canReceive(address to) public view returns (bool) {
        if (assetStatus != AssetStatus.Active) return false;
        if (block.timestamp >= maturityDate) return false;
        if (!approvedInvestor[to]) return false;
        if (blockedInvestor[to]) return false;

        return true;
    }

    function canSend(address from) public view returns (bool) {
        if (assetStatus != AssetStatus.Active) return false;
        if (block.timestamp >= maturityDate) return false;
        if (blockedInvestor[from]) return false;

        return true;
    }

    function canTransfer(address from, address to, uint256 amount) public view returns (bool) {
        if (amount == 0) return false;
        if (!canSend(from)) return false;
        if (!canReceive(to)) return false;
        if (balanceOf(from) < amount) return false;

        uint256 availableBalance = balanceOf(from) - frozenTokens[from];
        if (availableBalance < amount) return false;

        return true;
    }

    function issueShares(address to, uint256 amount) external onlyOwner {
        require(assetStatus == AssetStatus.Active, "Asset is not active");
        require(amount > 0, "Amount must be greater than zero");
        require(issuedShares + amount <= totalShares, "Exceeds total shares");
        require(canReceive(to), "Receiver cannot receive shares");

        issuedShares += amount;
        _mint(to, amount);

        emit SharesIssued(to, amount);
    }

    function transferShares(address to, uint256 amount) external returns (bool) {
        transfer(to, amount);
        return true;
    }

    function setFrozenTokens(address investor, uint256 amount) external onlyOwner {
        require(investor != address(0), "Invalid investor");

        frozenTokens[investor] = amount;

        emit Frozen(investor, amount);
    }

    function getFrozenTokens(address investor) external view returns (uint256) {
        return frozenTokens[investor];
    }

    function forcedTransfer(
        address from,
        address to,
        uint256 amount,
        string memory reason
    ) external onlyOwner returns (bool) {
        require(amount > 0, "Amount must be greater than zero");
        require(balanceOf(from) >= amount, "Insufficient balance");
        require(canReceive(to), "Receiver cannot receive shares");

        uint256 remainingBalance = balanceOf(from) - amount;

        if (frozenTokens[from] > remainingBalance) {
            frozenTokens[from] = remainingBalance;
            emit Frozen(from, frozenTokens[from]);
        }

        _forcedTransferInProgress = true;
        _update(from, to, amount);
        _forcedTransferInProgress = false;

        emit ForcedTransfer(from, to, amount, reason);

        return true;
    }

    function markMatured() external onlyOwner {
        require(assetStatus == AssetStatus.Active, "Asset must be active");
        require(block.timestamp >= maturityDate, "Maturity date has not arrived");

        assetStatus = AssetStatus.Matured;

        emit AssetMatured();
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && !_forcedTransferInProgress) {
            require(canTransfer(from, to, amount), "Transfer not allowed");
        }

        super._update(from, to, amount);
    }
}