// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ERC20Mock
 * @dev Simple ERC20 Token with a mint limit per wallet (100 tokens), excluding the owner.
 */
contract ERC20MockWithCap is ERC20, Ownable {
    uint8 private immutable _decimals;
    // Set the max mint amount directly as an immutable variable (100 tokens with 18 decimals)
    uint256 private immutable _maxMintAmountPerWallet = 100 * 10**18;
    mapping(address => uint256) private _mintedAmounts; // Tracks total amount minted per address

    /**
     * @dev Constructor that sets the name, symbol, decimals, and owner.
     * @param name_ Name of the token.
     * @param symbol_ Symbol of the token.
     * @param decimals_ Decimals of the token.
     * @param initialOwner The address to set as the initial owner.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        // Removed maxMintAmountPerWallet_ parameter
        address initialOwner // Specify initial owner
    )
        ERC20(name_, symbol_)
        Ownable(initialOwner) // Set the owner during deployment
    {
        require(initialOwner != address(0), "ERC20Mock: initial owner is the zero address");
        _decimals = decimals_;
        // Removed assignment: _maxMintAmountPerWallet = maxMintAmountPerWallet_;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `account`.
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     * - `account` cannot be the zero address.
     * - If the caller (`msg.sender`) is not the owner, the total amount minted
     *   to `account` must not exceed the immutable `_maxMintAmountPerWallet`.
     */
    function mint(address account, uint256 amount) public virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        // Only enforce the limit if the caller is NOT the owner
        if (_msgSender() != owner()) {
            uint256 currentMinted = _mintedAmounts[account];
            require(
                currentMinted + amount <= _maxMintAmountPerWallet, // Compare against the immutable variable
                "ERC20Mock: Mint amount exceeds maximum limit for this wallet"
            );
        }

        _mintedAmounts[account] += amount;
        _mint(account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`.
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     *
     * Note: Burning tokens does NOT decrease the tracked minted amount for limit purposes.
     */
    function burn(address account, uint256 amount) public virtual {
        _burn(account, amount);
    }

    /**
     * @dev Returns the maximum total amount a non-owner address can mint.
     */
    function maxMintAmountPerWallet() public pure returns (uint256) {
        return _maxMintAmountPerWallet;
    }

    /**
     * @dev Returns the total amount minted to a specific address so far.
     */
    function mintedAmount(address account) public view returns (uint256) {
        return _mintedAmounts[account];
    }

    // This function is excluded from coverage reports.
    function test() public {}
}
