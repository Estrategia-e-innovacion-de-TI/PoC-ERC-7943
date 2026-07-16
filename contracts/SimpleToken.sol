// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SimpleToken
 * @notice Minimal ERC-20 placeholder.
 *         This contract will be extended with the ERC-7943 uRWA interface
 *         (compliance checks, transfer controls, enforcement actions).
 */
contract SimpleToken is ERC20, Ownable {
    /// @notice Deploys the token and mints the initial supply to the deployer, who also becomes the owner.
    /// @param name          ERC-20 name of the token.
    /// @param symbol        ERC-20 symbol of the token.
    /// @param initialSupply Initial supply in whole token units (multiplied internally by `10 ** decimals()`).
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply
    ) ERC20(name, symbol) Ownable(msg.sender) {
        _mint(msg.sender, initialSupply * 10 ** decimals());
    }

    /**
     * @notice Mint new tokens. Restricted to the owner.
     * @param to      Recipient address.
     * @param amount  Amount to mint (in token units, not wei).
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount * 10 ** decimals());
    }
}
