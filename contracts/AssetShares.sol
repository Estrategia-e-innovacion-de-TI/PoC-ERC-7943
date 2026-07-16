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
    /// @dev ERC-7943 fungible interfaceId, per the EIP. Returned by
    ///      `supportsInterface` so external contracts can detect uRWA support.
    bytes4 private constant _INTERFACE_ID_ERC7943_FUNGIBLE = 0x3edbb4c4;

    /// @notice Role allowed to manage the asset lifecycle: create, activate, issue shares and mark as matured.
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    /// @notice Role allowed to manage investor compliance (KYC/AML allow/block list).
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    /// @notice Role allowed to freeze balances and execute forced transfers.
    bytes32 public constant ENFORCEMENT_ROLE = keccak256("ENFORCEMENT_ROLE");

    /// @notice Lifecycle states an asset moves through, in order (Cancelled is reserved, currently unused).
    enum AssetStatus {
        NotCreated,
        Created,
        Active,
        Matured,
        Cancelled
    }

    /// @notice Human-readable name of the underlying real-world asset.
    string public assetName;
    /// @notice Maximum number of shares that may ever be issued for this asset.
    uint256 public totalShares;
    /// @notice Number of shares issued so far (monotonically increasing, capped at `totalShares`).
    uint256 public issuedShares;
    /// @notice Timestamp after which the asset is considered matured and transfers/issuance stop.
    uint256 public maturityDate;
    /// @notice Reference to off-chain legal/asset documentation (e.g. an IPFS hash or URI).
    string public documentHash;
    /// @notice Current lifecycle state of the asset.
    AssetStatus public assetStatus;

    /// @notice Whether an address has passed compliance (KYC/AML) checks and may hold/receive shares.
    mapping(address => bool) public approvedInvestor;
    /// @notice Whether an address is blocked from sending or receiving shares, regardless of approval.
    mapping(address => bool) public blockedInvestor;
    /// @notice Amount of an investor's balance that is frozen and excluded from transferable/available balance.
    mapping(address => uint256) public frozenTokens;

    /// @dev Set while `_executeForcedTransfer` runs so `_update` skips the normal
    ///      compliance/frozen-balance checks for that single transfer.
    bool private _forcedTransferInProgress;

    /// @notice Emitted when a new asset is defined via `createAsset`.
    event AssetCreated(string name, uint256 totalShares, uint256 maturityDate, string documentHash);
    /// @notice Emitted when the asset transitions from Created to Active via `activateAsset`.
    event AssetActivated();
    /// @notice Emitted when an investor is approved (allow-listed) via `approveInvestor`.
    event InvestorApproved(address indexed investor);
    /// @notice Emitted when an investor is blocked via `blockInvestor`.
    event InvestorBlocked(address indexed investor);
    /// @notice Emitted when new shares are minted to an investor via `issueShares`.
    event SharesIssued(address indexed to, uint256 amount);
    /// @notice Emitted when an account's frozen balance is set via `setFrozenTokens`, and internally
    ///         when a forced transfer reduces frozen tokens to fit the sender's remaining balance.
    event Frozen(address indexed account, uint256 amount);
    /// @notice Emitted after a compliance-bypassing forced transfer via `forcedTransfer`/`forcedTransferWithReason`.
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount);
    /// @notice Emitted alongside `ForcedTransfer` when `forcedTransferWithReason` is used, carrying a human-readable reason.
    event ForcedTransferReason(address indexed from, address indexed to, uint256 amount, string reason);
    /// @notice Emitted when the asset transitions from Active to Matured via `markMatured`.
    event AssetMatured();

    /// @notice Thrown by `_update` when the sender fails `canSend` (wrong asset status, matured, or blocked).
    error ERC7943CannotSend(address account);
    /// @notice Thrown by `_update` when the recipient fails `canReceive` (wrong asset status, matured, not approved, or blocked).
    error ERC7943CannotReceive(address account);
    /// @notice Thrown by `_update` when `canTransfer` returns false for reasons not covered by the more specific errors above.
    error ERC7943CannotTransfer(address from, address to, uint256 amount);
    /// @notice Thrown by `_update` when the transfer amount exceeds the sender's unfrozen (available) balance.
    error ERC7943InsufficientUnfrozenBalance(address account, uint256 amount, uint256 unfrozen);

    /// @notice Deploys the share token and grants the deployer every role.
    /// @dev The deployer starts holding DEFAULT_ADMIN_ROLE, ISSUER_ROLE, COMPLIANCE_ROLE and
    ///      ENFORCEMENT_ROLE. DEFAULT_ADMIN_ROLE can later delegate the other three roles to
    ///      separate addresses via `grantRole`/`revokeRole` (inherited from AccessControl), enabling
    ///      formal separation of duties.
    /// @param tokenName   ERC-20 name of the share token.
    /// @param tokenSymbol ERC-20 symbol of the share token.
    constructor(string memory tokenName, string memory tokenSymbol) ERC20(tokenName, tokenSymbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ISSUER_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
        _grantRole(ENFORCEMENT_ROLE, msg.sender);
    }

    /// @notice Number of decimals used to display share amounts.
    /// @dev The function body is currently empty; Solidity gives an unnamed `returns (uint8)`
    ///      its default value when no explicit `return` is hit, so this always returns 0
    ///      (i.e. shares are treated as whole, indivisible units). This appears to be
    ///      unfinished/placeholder code rather than an intentional override — confirm the
    ///      intended decimals value before relying on it.
    /// @return Always 0 with the current (empty) implementation.
    function decimals() public pure override returns (uint8) {



    }

    /// @notice Defines the underlying asset's terms. Can only be called once, before any shares are issued.
    /// @dev Requires `assetStatus == NotCreated`. Moves `assetStatus` to `Created`; call `activateAsset`
    ///      afterwards to allow issuance and transfers.
    /// @param name           Human-readable name of the asset.
    /// @param _totalShares   Maximum number of shares that may be issued (must be > 0).
    /// @param _maturityDate  Unix timestamp the asset matures at (must be in the future).
    /// @param _documentHash  Reference to off-chain supporting documentation (must be non-empty).
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

    /// @notice Activates a previously created asset, allowing share issuance and transfers to begin.
    /// @dev Requires `assetStatus == Created`. Moves `assetStatus` to `Active`.
    function activateAsset() external onlyRole(ISSUER_ROLE) {
        require(assetStatus == AssetStatus.Created, "Asset must be created first");

        assetStatus = AssetStatus.Active;

        emit AssetActivated();
    }

    /// @notice Allow-lists an investor so it can receive/hold shares, and clears any prior block.
    /// @param investor Address to approve (must not be the zero address).
    function approveInvestor(address investor) external onlyRole(COMPLIANCE_ROLE) {
        require(investor != address(0), "Invalid investor");

        approvedInvestor[investor] = true;
        blockedInvestor[investor] = false;

        emit InvestorApproved(investor);
    }

    /// @notice Blocks an investor from sending or receiving shares. Does not clear its approval flag.
    /// @dev A blocked investor fails both `canSend` and `canReceive` regardless of `approvedInvestor`.
    /// @param investor Address to block (must not be the zero address).
    function blockInvestor(address investor) external onlyRole(COMPLIANCE_ROLE) {
        require(investor != address(0), "Invalid investor");

        blockedInvestor[investor] = true;

        emit InvestorBlocked(investor);
    }

    /// @notice ERC-7943 check: whether `to` is currently allowed to receive shares.
    /// @dev False when the asset is not Active, has matured, `to` is not approved, or `to` is blocked.
    /// @param to Candidate recipient address.
    /// @return True if `to` may receive shares right now.
    function canReceive(address to) public view returns (bool) {
        if (assetStatus != AssetStatus.Active) return false;
        if (block.timestamp >= maturityDate) return false;
        if (!approvedInvestor[to]) return false;
        if (blockedInvestor[to]) return false;

        return true;
    }

    /// @notice ERC-7943 check: whether `from` is currently allowed to send shares.
    /// @dev False when the asset is not Active, has matured, or `from` is blocked. Unlike `canReceive`,
    ///      this does not require `from` to be in `approvedInvestor` (only receivers need approval).
    /// @param from Candidate sender address.
    /// @return True if `from` may send shares right now.
    function canSend(address from) public view returns (bool) {
        if (assetStatus != AssetStatus.Active) return false;
        if (block.timestamp >= maturityDate) return false;
        if (blockedInvestor[from]) return false;

        return true;
    }

    /// @notice ERC-7943 check: whether a transfer of `amount` shares from `from` to `to` would currently succeed.
    /// @dev Combines `canSend`, `canReceive`, a sufficient-balance check, and a frozen-balance check
    ///      (frozen amount may exceed balance per ERC-7943, so the available balance saturates at zero).
    /// @param from   Sender address.
    /// @param to     Recipient address.
    /// @param amount Amount of shares to transfer.
    /// @return True if the transfer would be allowed right now.
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

    /// @notice ERC-165 interface detection. Reports support for ERC-7943 fungible in addition to
    ///         whatever ERC20/AccessControl already report via `super.supportsInterface`.
    /// @param interfaceId Interface identifier to check, per ERC-165.
    /// @return True if this contract supports `interfaceId`.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == _INTERFACE_ID_ERC7943_FUNGIBLE || super.supportsInterface(interfaceId);
    }

    /// @notice Mints new shares to an approved investor, up to the asset's `totalShares` cap.
    /// @dev Requires the asset to be Active and `to` to currently pass `canReceive`.
    /// @param to     Recipient of the newly issued shares.
    /// @param amount Amount of shares to issue (must be > 0).
    function issueShares(address to, uint256 amount) external onlyRole(ISSUER_ROLE) {
        require(assetStatus == AssetStatus.Active, "Asset is not active");
        require(amount > 0, "Amount must be greater than zero");
        require(issuedShares + amount <= totalShares, "Exceeds total shares");
        require(canReceive(to), "Receiver cannot receive shares");

        issuedShares += amount;
        _mint(to, amount);

        emit SharesIssued(to, amount);
    }

    /// @notice Convenience wrapper around the standard ERC-20 `transfer`, kept for API symmetry with
    ///         the other ERC-7943 actions in this contract.
    /// @dev Subject to the same compliance/frozen-balance checks as `transfer`, enforced in `_update`.
    /// @param to     Recipient address.
    /// @param amount Amount of shares to transfer.
    /// @return Always true (reverts on failure, like the underlying `transfer`).
    function transferShares(address to, uint256 amount) external returns (bool) {
        transfer(to, amount);
        return true;
    }

    /// @notice Sets the absolute amount of `investor`'s balance that is frozen (non-transferable).
    /// @dev Overwrites any previous frozen amount; it is not additive. The frozen amount may exceed
    ///      the investor's current balance (allowed per ERC-7943) and simply blocks all sends until
    ///      the balance grows or the frozen amount is reduced.
    /// @param investor Address whose frozen balance is being set (must not be the zero address).
    /// @param amount   New frozen amount for `investor`.
    /// @return Always true.
    function setFrozenTokens(address investor, uint256 amount) external onlyRole(ENFORCEMENT_ROLE) returns (bool) {
        require(investor != address(0), "Invalid investor");

        frozenTokens[investor] = amount;

        emit Frozen(investor, amount);

        return true;
    }

    /// @notice Reads the amount of `investor`'s balance currently frozen.
    /// @param investor Address to query.
    /// @return Frozen amount for `investor` (may exceed its current balance).
    function getFrozenTokens(address investor) external view returns (uint256) {
        return frozenTokens[investor];
    }

    /// @notice Forcibly moves shares from `from` to `to`, bypassing `canSend`/`canReceive` compliance
    ///         checks (e.g. for legal/regulatory recovery of assets). Frozen balance is still respected
    ///         in the sense that it is trimmed down if it would otherwise exceed the sender's remaining balance.
    /// @dev Restricted to ENFORCEMENT_ROLE. Emits `ForcedTransfer`.
    /// @param from   Address to take shares from.
    /// @param to     Address to send shares to (must currently pass `canReceive`).
    /// @param amount Amount of shares to move (must be > 0 and <= `from`'s balance).
    /// @return Always true.
    function forcedTransfer(address from, address to, uint256 amount) external onlyRole(ENFORCEMENT_ROLE) returns (bool) {
        return _executeForcedTransfer(from, to, amount);
    }

    /// @notice Same as `forcedTransfer`, but also emits a human-readable `reason` for the forced move
    ///         (e.g. a court order reference or compliance case ID).
    /// @param from   Address to take shares from.
    /// @param to     Address to send shares to (must currently pass `canReceive`).
    /// @param amount Amount of shares to move (must be > 0 and <= `from`'s balance).
    /// @param reason Free-text justification, emitted via `ForcedTransferReason`.
    /// @return Always true.
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

    /// @dev Shared implementation for `forcedTransfer`/`forcedTransferWithReason`. Trims `from`'s frozen
    ///      balance down to its post-transfer balance if it would otherwise exceed it (so a forced
    ///      transfer never leaves an investor with a frozen amount larger than what it now holds),
    ///      then performs the raw `_update` with the compliance checks bypassed via
    ///      `_forcedTransferInProgress`.
    /// @param from   Address to take shares from.
    /// @param to     Address to send shares to (must currently pass `canReceive`).
    /// @param amount Amount of shares to move (must be > 0 and <= `from`'s balance).
    /// @return Always true.
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

    /// @notice Transitions the asset from Active to Matured once its maturity date has passed.
    /// @dev Requires `assetStatus == Active` and `block.timestamp >= maturityDate`. After this call,
    ///      `canSend`/`canReceive` return false (asset status is no longer Active), so shares can no
    ///      longer be transferred or issued through the normal path (forced transfers are unaffected).
    function markMatured() external onlyRole(ISSUER_ROLE) {
        require(assetStatus == AssetStatus.Active, "Asset must be active");
        require(block.timestamp >= maturityDate, "Maturity date has not arrived");

        assetStatus = AssetStatus.Matured;

        emit AssetMatured();
    }

    /// @dev ERC-20 hook overridden to enforce ERC-7943 compliance and frozen-balance checks on every
    ///      transfer, mint and burn. Checks are skipped for mints/burns (`from`/`to` == address(0)) and
    ///      for the single `_update` call made from `_executeForcedTransfer` (guarded by
    ///      `_forcedTransferInProgress`), which intentionally bypasses compliance.
    /// @param from   Sender address (address(0) for mints).
    /// @param to     Recipient address (address(0) for burns).
    /// @param amount Amount of shares being moved.
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