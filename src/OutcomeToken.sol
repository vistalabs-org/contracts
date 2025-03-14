// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title OutcomeToken
/// @notice Outcome tokens that MarketMaker can mint
contract OutcomeToken is ERC20, Ownable {

    constructor(string memory name, string memory symbol) 
        ERC20(name, symbol)
        Ownable(msg.sender) // Initialize Ownable with creator
    {}

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

}