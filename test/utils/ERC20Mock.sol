// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// TODO: add Ownable

/**
 * @title ERC20Mock
 * @dev Very simple ERC20 Token example, where all tokens are pre-assigned to the creator.
 * Note they can later distribute these tokens as they wish using transfer methods.
 */
contract ERC20Mock is ERC20 {
    uint8 private _decimals;

    /**
     * @dev Constructor that gives msg.sender all of existing tokens.
     */
    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `account`.
     */
    function mint(address account, uint256 amount) public {
        _mint(account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`.
     */
    function burn(address account, uint256 amount) public {
        _burn(account, amount);
    }

    // add this to be excluded from coverage report
    function test() public {}
}
