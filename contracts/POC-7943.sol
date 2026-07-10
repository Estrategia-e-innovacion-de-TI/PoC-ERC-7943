// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title AssetShares
 * @notice PoC de un activo financiero tokenizado usando ERC-20 + ERC-7943.
 *
 * Objetivo de la PoC:
 * - Representar participaciones tokenizadas de un activo financiero.
 * - Validar reglas mínimas de cumplimiento usando funciones ERC-7943:
 *   - canSend()
 *   - canReceive()
 *   - canTransfer()
 *   - getFrozenTokens()
 *   - setFrozenTokens()
 *   - forcedTransfer()
 */

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @notice Interfaz simplificada de ERC-7943 para tokens fungibles.
 *
 * Esta interfaz define las funciones necesarias para la PoC.
 * No incluye lógica de implementación; solo firma las funciones esperadas.
 */
interface IERC7943FungiblePoC {
    function canSend(address account) external view returns (bool);

    function canReceive(address account) external view returns (bool);

    function canTransfer(
        address from,
        address to,
        uint256 amount
    ) external view returns (bool);

    function getFrozenTokens(address account) external view returns (uint256);

    function setFrozenTokens(
        address account,
        uint256 amount
    ) external returns (bool);

    function forcedTransfer(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

contract AssetShares is
    ERC20,
    AccessControlEnumerable,
    Pausable,
    IERC7943FungiblePoC
{
    // =============================================================
    //                            ROLES
    // =============================================================

    /**
     * @notice Rol operativo de administrador de la PoC.
     *
     * Puede:
     * - Crear y activar el activo.
     * - Emitir participaciones.
     * - Aprobar y bloquear inversionistas.
     * - Congelar participaciones.
     * - Ejecutar transferencias forzadas.
     * - Pausar y despausar el contrato.
     */
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // =============================================================
    //                        ERC-7943 EVENTS
    // =============================================================

    /**
     * @notice Evento ERC-7943 para transferencia forzada.
     */
    event ForcedTransfer(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    /**
     * @notice Evento ERC-7943 para cambio de tokens congelados.
     */
    event Frozen(address indexed account, uint256 amount);

    // =============================================================
    //                         PoC EVENTS
    // =============================================================

    event AssetCreated(
        string assetName,
        address indexed issuer,
        uint256 totalShares,
        uint256 maturityDate,
        bytes32 documentHash
    );

    event AssetActivated();
    event AssetMatured();
    event AssetCancelled();

    event SharesIssued(address indexed to, uint256 amount);

    event InvestorApproved(address indexed investor);
    event InvestorUnapproved(address indexed investor);
    event InvestorBlocked(address indexed investor);
    event InvestorUnblocked(address indexed investor);

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);
    event SuperAdminAdded(address indexed account);
    event SuperAdminRemoved(address indexed account);

    event ForcedTransferReason(
        address indexed from,
        address indexed to,
        uint256 amount,
        string reason
    );

    // =============================================================
    //                            ERRORS
    // =============================================================

    error ZeroAddress();
    error AssetAlreadyCreated();
    error AssetNotCreated();
    error AssetNotActive();
    error InvalidState();
    error InvalidTotalShares();
    error InvalidMaturityDate();
    error InvalidDocumentHash();
    error IssuanceExceedsTotalShares();
    error InvestorNotAllowedToReceive();
    error TransferNotAllowed();
    error FrozenAmountExceedsBalance();
    error InsufficientBalance();
    error CannotRemoveLastAdmin();
    error CannotRemoveLastSuperAdmin();

    // =============================================================
    //                       ASSET MODEL
    // =============================================================

    enum AssetState {
        None,
        Created,
        Active,
        Matured,
        Cancelled
    }

    /**
     * @notice Nombre del activo financiero.
     * Ejemplo: "Participaciones Fondo PoC".
     */
    string public assetName;

    /**
     * @notice Emisor del activo financiero.
     */
    address public issuer;

    /**
     * @notice Total máximo de participaciones que podrán emitirse.
     */
    uint256 public totalShares;

    /**
     * @notice Total de participaciones emitidas hasta el momento.
     */
    uint256 public issuedShares;

    /**
     * @notice Fecha de vencimiento del activo.
     * Después de esta fecha, las transferencias normales quedan bloqueadas.
     */
    uint256 public maturityDate;

    /**
     * @notice Hash del documento soporte del activo.
     * Puede ser hash del PDF, metadata o documento legal simulado.
     */
    bytes32 public documentHash;

    /**
     * @notice Estado actual del activo.
     */
    AssetState public assetState;

    // =============================================================
    //                   SIMPLE COMPLIANCE MODEL
    // =============================================================

    /**
     * @notice Inversionistas aprobados.
     * Simula una allowlist básica de KYC/AML.
     */
    mapping(address => bool) public approvedInvestor;

    /**
     * @notice Inversionistas bloqueados.
     * Simula bloqueo AML, operativo o regulatorio.
     */
    mapping(address => bool) public blockedInvestor;

    /**
     * @notice Cantidad de participaciones congeladas por inversionista.
     */
    mapping(address => uint256) private frozenTokens;

    /**
     * @dev Permite que forcedTransfer salte la validación normal de transferencia.
     */
    bool private bypassTransferValidation;

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    /**
     * @notice Inicializa el token y asigna roles iniciales.
     *
     * @param tokenName Nombre ERC-20 del token.
     * @param tokenSymbol Símbolo ERC-20 del token.
     * @param initialAdmin Administrador inicial de la PoC.
     */
    constructor(
        string memory tokenName,
        string memory tokenSymbol,
        address initialAdmin
    ) ERC20(tokenName, tokenSymbol) {
        if (initialAdmin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
    }

    // =============================================================
    //                          DECIMALS
    // =============================================================

    /**
     * @notice Para la PoC, las participaciones son indivisibles.
     *
     * Ejemplo:
     * - Si el activo tiene 1000 participaciones, se emiten 1000 unidades.
     * - No se usa 1000 * 10^18.
     */
    function decimals() public pure override returns (uint8) {
        return 0;
    }

    // =============================================================
    //                 ADMIN MANAGEMENT - SIMPLE VERSION
    // =============================================================

    /**
     * @notice Agrega un administrador operativo.
     * @dev Solo puede ejecutarlo un superadministrador.
     */
    function addAdmin(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();

        grantRole(ADMIN_ROLE, account);

        emit AdminAdded(account);
    }

    /**
     * @notice Quita un administrador operativo.
     * @dev No permite remover el último administrador.
     */
    function removeAdmin(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();

        if (
            hasRole(ADMIN_ROLE, account) &&
            getRoleMemberCount(ADMIN_ROLE) <= 1
        ) {
            revert CannotRemoveLastAdmin();
        }

        revokeRole(ADMIN_ROLE, account);

        emit AdminRemoved(account);
    }

    /**
     * @notice Agrega un superadministrador.
     * @dev El superadministrador puede administrar roles.
     */
    function addSuperAdmin(
        address account
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();

        grantRole(DEFAULT_ADMIN_ROLE, account);

        emit SuperAdminAdded(account);
    }

    /**
     * @notice Quita un superadministrador.
     * @dev No permite remover el último superadministrador.
     */
    function removeSuperAdmin(
        address account
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();

        if (
            hasRole(DEFAULT_ADMIN_ROLE, account) &&
            getRoleMemberCount(DEFAULT_ADMIN_ROLE) <= 1
        ) {
            revert CannotRemoveLastSuperAdmin();
        }

        revokeRole(DEFAULT_ADMIN_ROLE, account);

        emit SuperAdminRemoved(account);
    }

    /**
     * @notice Override para evitar quitar el último admin o superadmin usando revokeRole directamente.
     */
    function revokeRole(
        bytes32 role,
        address account
    )
        public
        override(AccessControl, IAccessControl)
        onlyRole(getRoleAdmin(role))
    {
        _validateLastRoleMember(role, account);

        super.revokeRole(role, account);
    }

    /**
     * @notice Override para evitar que el último admin o superadmin renuncie.
     */
    function renounceRole(
        bytes32 role,
        address callerConfirmation
    ) public override(AccessControl, IAccessControl) {
        _validateLastRoleMember(role, callerConfirmation);

        super.renounceRole(role, callerConfirmation);
    }

    // =============================================================
    //                    ASSET LIFECYCLE
    // =============================================================

    /**
     * @notice Crea el activo financiero base.
     *
     * Reglas:
     * - Solo ADMIN_ROLE.
     * - Solo puede crearse una vez.
     * - totalShares debe ser mayor a cero.
     * - maturityDate debe ser futura.
     * - documentHash no puede estar vacío.
     */
    function createAsset(
        string calldata _assetName,
        address _issuer,
        uint256 _totalShares,
        uint256 _maturityDate,
        bytes32 _documentHash
    ) external onlyRole(ADMIN_ROLE) {
        if (assetState != AssetState.None) revert AssetAlreadyCreated();
        if (_issuer == address(0)) revert ZeroAddress();
        if (_totalShares == 0) revert InvalidTotalShares();
        if (_maturityDate <= block.timestamp) revert InvalidMaturityDate();
        if (_documentHash == bytes32(0)) revert InvalidDocumentHash();

        assetName = _assetName;
        issuer = _issuer;
        totalShares = _totalShares;
        maturityDate = _maturityDate;
        documentHash = _documentHash;
        assetState = AssetState.Created;

        emit AssetCreated(
            _assetName,
            _issuer,
            _totalShares,
            _maturityDate,
            _documentHash
        );
    }

    /**
     * @notice Activa el activo para poder emitir y comercializar participaciones.
     */
    function activateAsset() external onlyRole(ADMIN_ROLE) {
        if (assetState != AssetState.Created) revert InvalidState();

        assetState = AssetState.Active;

        emit AssetActivated();
    }

    /**
     * @notice Marca el activo como vencido.
     *
     * Nota:
     * - Aunque nadie llame esta función, las validaciones ya bloquean transferencias si block.timestamp >= maturityDate.
     * - Esta función sirve para dejar trazabilidad explícita.
     */
    function markMatured() external onlyRole(ADMIN_ROLE) {
        if (assetState != AssetState.Active) revert AssetNotActive();
        if (block.timestamp < maturityDate) revert InvalidMaturityDate();

        assetState = AssetState.Matured;

        emit AssetMatured();
    }

    /**
     * @notice Cancela el activo.
     */
    function cancelAsset() external onlyRole(ADMIN_ROLE) {
        if (assetState == AssetState.None) revert AssetNotCreated();
        if (assetState == AssetState.Matured) revert InvalidState();

        assetState = AssetState.Cancelled;

        emit AssetCancelled();
    }

    // =============================================================
    //                     SHARE ISSUANCE
    // =============================================================

    /**
     * @notice Emite participaciones tokenizadas.
     *
     * Reglas:
     * - Solo ADMIN_ROLE.
     * - El activo debe estar activo.
     * - No puede superar totalShares.
     * - El receptor debe estar aprobado y no bloqueado.
     */
    function issueShares(
        address to,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (!_isAssetOperational()) revert AssetNotActive();
        if (issuedShares + amount > totalShares) {
            revert IssuanceExceedsTotalShares();
        }
        if (!canReceive(to)) revert InvestorNotAllowedToReceive();

        issuedShares += amount;

        _mint(to, amount);

        emit SharesIssued(to, amount);
    }

    // =============================================================
    //                  INVESTOR MANAGEMENT
    // =============================================================

    /**
     * @notice Aprueba un inversionista.
     * @dev Simula KYC/AML aprobado.
     */
    function approveInvestor(address investor) external onlyRole(ADMIN_ROLE) {
        if (investor == address(0)) revert ZeroAddress();

        approvedInvestor[investor] = true;

        emit InvestorApproved(investor);
    }

    /**
     * @notice Quita la aprobación de un inversionista.
     */
    function unapproveInvestor(address investor) external onlyRole(ADMIN_ROLE) {
        if (investor == address(0)) revert ZeroAddress();

        approvedInvestor[investor] = false;

        emit InvestorUnapproved(investor);
    }

    /**
     * @notice Bloquea un inversionista.
     */
    function blockInvestor(address investor) external onlyRole(ADMIN_ROLE) {
        if (investor == address(0)) revert ZeroAddress();

        blockedInvestor[investor] = true;

        emit InvestorBlocked(investor);
    }

    /**
     * @notice Desbloquea un inversionista.
     */
    function unblockInvestor(address investor) external onlyRole(ADMIN_ROLE) {
        if (investor == address(0)) revert ZeroAddress();

        blockedInvestor[investor] = false;

        emit InvestorUnblocked(investor);
    }

    // =============================================================
    //                    ERC-7943 VALIDATIONS
    // =============================================================

    /**
     * @notice Valida si una cuenta puede enviar participaciones.
     *
     * Reglas PoC:
     * - El activo debe estar activo y no vencido.
     * - El contrato no debe estar pausado.
     * - La cuenta debe estar aprobada.
     * - La cuenta no debe estar bloqueada.
     *
     * Nota:
     * - Esta función no recibe amount.
     * - La validación de monto se hace en canTransfer().
     */
    function canSend(address account) public view override returns (bool) {
        if (account == address(0)) return false;
        if (!_isAssetOperational()) return false;
        if (paused()) return false;
        if (!approvedInvestor[account]) return false;
        if (blockedInvestor[account]) return false;

        return true;
    }

    /**
     * @notice Valida si una cuenta puede recibir participaciones.
     *
     * Reglas PoC:
     * - El activo debe estar activo y no vencido.
     * - El contrato no debe estar pausado.
     * - La cuenta debe estar aprobada.
     * - La cuenta no debe estar bloqueada.
     */
    function canReceive(address account) public view override returns (bool) {
        if (account == address(0)) return false;
        if (!_isAssetOperational()) return false;
        if (paused()) return false;
        if (!approvedInvestor[account]) return false;
        if (blockedInvestor[account]) return false;

        return true;
    }

    /**
     * @notice Valida si una transferencia específica puede ejecutarse.
     *
     * Reglas PoC:
     * - from debe poder enviar.
     * - to debe poder recibir.
     * - from debe tener saldo suficiente.
     * - from debe tener suficiente saldo no congelado.
     */
    function canTransfer(
        address from,
        address to,
        uint256 amount
    ) public view override returns (bool) {
        if (amount == 0) return false;
        if (!canSend(from)) return false;
        if (!canReceive(to)) return false;
        if (balanceOf(from) < amount) return false;

        uint256 availableBalance = _availableBalance(from);

        if (availableBalance < amount) return false;

        return true;
    }

    /**
     * @notice Consulta cuántas participaciones están congeladas para una cuenta.
     */
    function getFrozenTokens(
        address account
    ) public view override returns (uint256) {
        return frozenTokens[account];
    }

    // =============================================================
    //                   ERC-7943 ENFORCEMENT
    // =============================================================

    /**
     * @notice Congela una cantidad absoluta de participaciones de una cuenta.
     *
     * Reglas PoC:
     * - Solo ADMIN_ROLE.
     * - No se puede congelar más que el balance actual.
     * - El valor nuevo reemplaza el valor anterior.
     */
    function setFrozenTokens(
        address account,
        uint256 amount
    ) public override onlyRole(ADMIN_ROLE) returns (bool) {
        if (account == address(0)) revert ZeroAddress();
        if (amount > balanceOf(account)) revert FrozenAmountExceedsBalance();

        frozenTokens[account] = amount;

        emit Frozen(account, amount);

        return true;
    }

    /**
     * @notice Ejecuta una transferencia forzada.
     *
     * Reglas PoC:
     * - Solo ADMIN_ROLE.
     * - from debe tener saldo suficiente.
     * - to debe poder recibir.
     * - La transferencia forzada puede mover tokens aunque estén congelados.
     *
     * Uso esperado:
     * - Corrección operativa.
     * - Enforcement administrativo.
     * - Simulación de orden regulatoria.
     */
    function forcedTransfer(
        address from,
        address to,
        uint256 amount
    ) public override onlyRole(ADMIN_ROLE) returns (bool) {
        _forcedTransfer(from, to, amount);

        return true;
    }

    /**
     * @notice Variante de PoC para registrar un motivo de transferencia forzada.
     * @dev No es estrictamente necesaria para ERC-7943, pero ayuda a trazabilidad.
     */
    function forcedTransferWithReason(
        address from,
        address to,
        uint256 amount,
        string calldata reason
    ) external onlyRole(ADMIN_ROLE) returns (bool) {
        _forcedTransfer(from, to, amount);

        emit ForcedTransferReason(from, to, amount, reason);

        return true;
    }

    // =============================================================
    //                    NORMAL SHARE TRANSFER
    // =============================================================

    /**
     * @notice Función explícita para transferir participaciones.
     * @dev Usa transfer() de ERC-20, que pasa por la validación interna.
     */
    function transferShares(
        address to,
        uint256 amount
    ) external returns (bool) {
        return transfer(to, amount);
    }

    // =============================================================
    //                         PAUSE
    // =============================================================

    /**
     * @notice Pausa transferencias normales.
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Despausa transferencias normales.
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // =============================================================
    //                  ERC-20 TRANSFER VALIDATION
    // =============================================================

    /**
     * @dev Hook central de OpenZeppelin ERC-20 v5.
     *
     * Aquí se fuerza que toda transferencia normal pase por canTransfer().
     *
     * No aplica a:
     * - Mint: from == address(0)
     * - Burn: to == address(0)
     * - Forced transfer: bypassTransferValidation == true
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        bool isMint = from == address(0);
        bool isBurn = to == address(0);

        if (!isMint && !isBurn && !bypassTransferValidation) {
            if (!canTransfer(from, to, value)) {
                revert TransferNotAllowed();
            }
        }

        super._update(from, to, value);
    }

    // =============================================================
    //                       INTERNAL HELPERS
    // =============================================================

    /**
     * @dev Retorna true si el activo está activo y no ha vencido.
     */
    function _isAssetOperational() internal view returns (bool) {
        return assetState == AssetState.Active && block.timestamp < maturityDate;
    }

    /**
     * @dev Calcula el balance disponible, descontando tokens congelados.
     */
    function _availableBalance(address account) internal view returns (uint256) {
        uint256 balance = balanceOf(account);
        uint256 frozen = frozenTokens[account];

        if (frozen >= balance) {
            return 0;
        }

        return balance - frozen;
    }

    /**
     * @dev Ejecuta la transferencia forzada.
     *
     * La transferencia forzada:
     * - No evalúa canSend(from), porque precisamente puede ser una acción administrativa.
     * - Sí evalúa canReceive(to), para no mover tokens hacia una wallet no elegible.
     * - Puede tocar saldo congelado.
     */
    function _forcedTransfer(
        address from,
        address to,
        uint256 amount
    ) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert TransferNotAllowed();
        if (balanceOf(from) < amount) revert InsufficientBalance();
        if (!canReceive(to)) revert InvestorNotAllowedToReceive();

        _reduceFrozenIfNeeded(from, amount);

        bypassTransferValidation = true;
        _transfer(from, to, amount);
        bypassTransferValidation = false;

        emit ForcedTransfer(from, to, amount);
    }

    /**
     * @dev Si forcedTransfer mueve parte del saldo congelado, reduce el congelamiento.
     *
     * Ejemplo:
     * - Balance A: 100
     * - Frozen A: 80
     * - Disponible: 20
     * - forcedTransfer(A, B, 50)
     *
     * Los primeros 20 salen del saldo disponible.
     * Los otros 30 salen de la porción congelada.
     * Nuevo frozen A: 50.
     */
    function _reduceFrozenIfNeeded(address from, uint256 amount) internal {
        uint256 frozen = frozenTokens[from];

        if (frozen == 0) {
            return;
        }

        uint256 available = _availableBalance(from);

        if (amount > available) {
            uint256 frozenUsed = amount - available;

            if (frozenUsed > frozen) {
                frozenUsed = frozen;
            }

            frozenTokens[from] = frozen - frozenUsed;

            emit Frozen(from, frozenTokens[from]);
        }
    }

    /**
     * @dev Evita que el contrato quede sin administradores críticos.
     */
    function _validateLastRoleMember(
        bytes32 role,
        address account
    ) internal view {
        if (
            role == ADMIN_ROLE &&
            hasRole(ADMIN_ROLE, account) &&
            getRoleMemberCount(ADMIN_ROLE) <= 1
        ) {
            revert CannotRemoveLastAdmin();
        }

        if (
            role == DEFAULT_ADMIN_ROLE &&
            hasRole(DEFAULT_ADMIN_ROLE, account) &&
            getRoleMemberCount(DEFAULT_ADMIN_ROLE) <= 1
        ) {
            revert CannotRemoveLastSuperAdmin();
        }
    }

    // =============================================================
    //                         ERC-165
    // =============================================================

    /**
     * @notice Declara soporte para AccessControl y la interfaz PoC de ERC-7943.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControlEnumerable) returns (bool) {
        return
            interfaceId == type(IERC7943FungiblePoC).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}