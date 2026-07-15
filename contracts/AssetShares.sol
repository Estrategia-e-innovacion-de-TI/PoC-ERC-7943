// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title AssetShares
 * @notice RWA share token implementing the ERC-7943 (uRWA) fungible interface:
 *         https://eips.ethereum.org/EIPS/eip-7943
 *
 *         Access control is split into three roles instead of a single owner,
 *         so the issuer, the compliance function and enforcement can be held
 *         by different addresses (formal separation of duties):
 *           - ISSUER_ROLE:      asset lifecycle (create/activate/issue/mature)
 *           - COMPLIANCE_ROLE:  investor allow/block list (KYC/AML)
 *           - ENFORCEMENT_ROLE: freeze and forced transfer
 *         DEFAULT_ADMIN_ROLE (AccessControl's built-in admin role) can grant
 *         and revoke all of the above.
 */
contract AssetShares is ERC20, AccessControl {
    // ERC-7943 fungible interfaceId, per the EIP.
    bytes4 private constant _INTERFACE_ID_ERC7943_FUNGIBLE = 0x3edbb4c4;

    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant ENFORCEMENT_ROLE = keccak256("ENFORCEMENT_ROLE");

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
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount);
    event ForcedTransferReason(address indexed from, address indexed to, uint256 amount, string reason);
    event AssetMatured();

    error ERC7943CannotSend(address account);
    error ERC7943CannotReceive(address account);
    error ERC7943CannotTransfer(address from, address to, uint256 amount);
    error ERC7943InsufficientUnfrozenBalance(address account, uint256 amount, uint256 unfrozen);

    constructor(string memory tokenName, string memory tokenSymbol) ERC20(tokenName, tokenSymbol) {
        // Deployer starts holding every role; DEFAULT_ADMIN_ROLE lets it
        // delegate ISSUER/COMPLIANCE/ENFORCEMENT to separate addresses later
        // via grantRole/revokeRole (inherited from AccessControl).
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ISSUER_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
        _grantRole(ENFORCEMENT_ROLE, msg.sender);
    }

    function decimals() public pure override returns (uint8) {
        

        
    }

    function createAsset(
        string memory name,
        uint256 _totalShares,
        uint256 _maturityDate,
        string memory _documentHash
    ) external onlyRole(ISSUER_ROLE) {
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

    function activateAsset() external onlyRole(ISSUER_ROLE) {
        require(assetStatus == AssetStatus.Created, "Asset must be created first");

        assetStatus = AssetStatus.Active;

        emit AssetActivated();
    }

    function approveInvestor(address investor) external onlyRole(COMPLIANCE_ROLE) {
        require(investor != address(0), "Invalid investor");

        approvedInvestor[investor] = true;
        blockedInvestor[investor] = false;

        emit InvestorApproved(investor);
    }

    function blockInvestor(address investor) external onlyRole(COMPLIANCE_ROLE) {
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

        uint256 balance = balanceOf(from);
        if (balance < amount) return false;

        // Frozen amount MAY exceed the current balance (per ERC-7943), so this
        // must saturate at zero instead of underflowing.
        uint256 frozen = frozenTokens[from];
        uint256 availableBalance = frozen >= balance ? 0 : balance - frozen;
        if (availableBalance < amount) return false;

        return true;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == _INTERFACE_ID_ERC7943_FUNGIBLE || super.supportsInterface(interfaceId);
    }

    function issueShares(address to, uint256 amount) external onlyRole(ISSUER_ROLE) {
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

    function setFrozenTokens(address investor, uint256 amount) external onlyRole(ENFORCEMENT_ROLE) returns (bool) {
        require(investor != address(0), "Invalid investor");

        frozenTokens[investor] = amount;

        emit Frozen(investor, amount);

        return true;
    }

    function getFrozenTokens(address investor) external view returns (uint256) {
        return frozenTokens[investor];
    }

    function forcedTransfer(address from, address to, uint256 amount) external onlyRole(ENFORCEMENT_ROLE) returns (bool) {
        return _executeForcedTransfer(from, to, amount);
    }

    function forcedTransferWithReason(
        address from,
        address to,
        uint256 amount,
        string calldata reason
    ) external onlyRole(ENFORCEMENT_ROLE) returns (bool) {
        bool ok = _executeForcedTransfer(from, to, amount);
        emit ForcedTransferReason(from, to, amount, reason);
        return ok;
    }

    function _executeForcedTransfer(address from, address to, uint256 amount) internal returns (bool) {
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

        emit ForcedTransfer(from, to, amount);

        return true;
    }

    function markMatured() external onlyRole(ISSUER_ROLE) {
        require(assetStatus == AssetStatus.Active, "Asset must be active");
        require(block.timestamp >= maturityDate, "Maturity date has not arrived");

        assetStatus = AssetStatus.Matured;

        emit AssetMatured();
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && !_forcedTransferInProgress) {
            if (!canSend(from)) revert ERC7943CannotSend(from);
            if (!canReceive(to)) revert ERC7943CannotReceive(to);

            uint256 balance = balanceOf(from);
            uint256 frozen = frozenTokens[from];
            uint256 availableBalance = frozen >= balance ? 0 : balance - frozen;
            if (amount > availableBalance) {
                revert ERC7943InsufficientUnfrozenBalance(from, amount, availableBalance);
            }

            if (!canTransfer(from, to, amount)) revert ERC7943CannotTransfer(from, to, amount);
        }

        super._update(from, to, amount);
    }
}