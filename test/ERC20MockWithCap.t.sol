// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
// Revert to relative path - check project structure/remappings if this fails
import {ERC20MockWithCap} from "./utils/ERC20MockWithCap.sol"; 
// Comment out other attempts
// import {ERC20MockWithCap} from "src/utils/ERC20MockWithCap.sol"; 
// import {ERC20MockWithCap} from "contracts/utils/ERC20MockWithCap.sol"; 

contract ERC20MockWithCapTest is Test {
    ERC20MockWithCap public token;
    address public owner;
    address public user1;
    address public user2;

    // --- Constants based on the contract ---
    string constant TOKEN_NAME = "Test Token";
    string constant TOKEN_SYMBOL = "TST";
    uint8 constant TOKEN_DECIMALS = 18;
    uint256 constant MAX_MINT_PER_WALLET = 100 * 10**TOKEN_DECIMALS; // 100 tokens

    // --- Revert Messages from contract ---
    string constant REVERT_MINT_EXCEEDS_LIMIT = "ERC20Mock: Mint amount exceeds maximum limit for this wallet";
    string constant REVERT_MINT_TO_ZERO = "ERC20: mint to the zero address";

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy the token
        token = new ERC20MockWithCap(
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS,
            owner // Set initial owner
        );
    }

    // --- Test Deployment ---

    function test_Deployment_SetsCorrectValues() public {
        assertEq(token.name(), TOKEN_NAME, "Name mismatch");
        assertEq(token.symbol(), TOKEN_SYMBOL, "Symbol mismatch");
        assertEq(token.decimals(), TOKEN_DECIMALS, "Decimals mismatch");
        assertEq(token.owner(), owner, "Owner mismatch");
        assertEq(token.maxMintAmountPerWallet(), MAX_MINT_PER_WALLET, "Max mint amount mismatch");
    }

    // --- Test Minting Logic ---

    function test_OwnerCanMint_AboveLimit() public {
        uint256 mintAmount = MAX_MINT_PER_WALLET + (1 ether); // More than the limit

        vm.prank(owner);
        token.mint(owner, mintAmount); // Owner mints to themself

        assertEq(token.balanceOf(owner), mintAmount, "Owner balance incorrect after mint");
        assertEq(token.mintedAmount(owner), mintAmount, "Owner minted amount incorrect");

        vm.prank(owner);
        token.mint(user1, mintAmount); // Owner mints to user1

        assertEq(token.balanceOf(user1), mintAmount, "User1 balance incorrect after owner mint");
        assertEq(token.mintedAmount(user1), mintAmount, "User1 minted amount incorrect after owner mint");
    }

    function test_NonOwnerCanMint_UpToLimit() public {
        uint256 amount1 = MAX_MINT_PER_WALLET / 2;
        uint256 amount2 = MAX_MINT_PER_WALLET / 2; // Total = MAX_MINT_PER_WALLET

        // First mint
        vm.prank(user1);
        token.mint(user1, amount1);
        assertEq(token.balanceOf(user1), amount1, "Balance after first mint incorrect");
        assertEq(token.mintedAmount(user1), amount1, "Minted amount after first mint incorrect");

        // Second mint up to limit
        vm.prank(user1);
        token.mint(user1, amount2);
        assertEq(token.balanceOf(user1), MAX_MINT_PER_WALLET, "Balance after second mint incorrect");
        assertEq(token.mintedAmount(user1), MAX_MINT_PER_WALLET, "Minted amount after second mint incorrect");
    }

    function test_Revert_NonOwnerMints_AboveLimit_SingleTx() public {
        uint256 mintAmount = MAX_MINT_PER_WALLET + 1; // Just above the limit

        vm.expectRevert(bytes(REVERT_MINT_EXCEEDS_LIMIT));
        vm.prank(user1);
        token.mint(user1, mintAmount);
    }

    function test_Revert_NonOwnerMints_AboveLimit_Cumulative() public {
        uint256 amount1 = MAX_MINT_PER_WALLET / 2;
        uint256 amount2 = (MAX_MINT_PER_WALLET / 2) + 1; // Exceeds limit when added

        // Mint first part
        vm.prank(user1);
        token.mint(user1, amount1);

        // Expect revert on second mint
        vm.expectRevert(bytes(REVERT_MINT_EXCEEDS_LIMIT));
        vm.prank(user1);
        token.mint(user1, amount2);
    }

     function test_NonOwnerCanMint_ExactlyLimit() public {
        vm.prank(user1);
        token.mint(user1, MAX_MINT_PER_WALLET);
        assertEq(token.balanceOf(user1), MAX_MINT_PER_WALLET, "Balance incorrect after minting exact limit");
        assertEq(token.mintedAmount(user1), MAX_MINT_PER_WALLET, "Minted amount incorrect after minting exact limit");

        // Cannot mint even 1 wei more
        vm.expectRevert(bytes(REVERT_MINT_EXCEEDS_LIMIT));
        vm.prank(user1);
        token.mint(user1, 1);
    }

    function test_DifferentNonOwners_HaveSeparateLimits() public {
        // User1 mints up to limit
        vm.prank(user1);
        token.mint(user1, MAX_MINT_PER_WALLET);
        assertEq(token.mintedAmount(user1), MAX_MINT_PER_WALLET, "User1 minted amount incorrect");

        // User2 can still mint up to their limit
        vm.prank(user2);
        token.mint(user2, MAX_MINT_PER_WALLET);
        assertEq(token.balanceOf(user2), MAX_MINT_PER_WALLET, "User2 balance incorrect");
        assertEq(token.mintedAmount(user2), MAX_MINT_PER_WALLET, "User2 minted amount incorrect");

        // User1 cannot mint more
        vm.expectRevert(bytes(REVERT_MINT_EXCEEDS_LIMIT));
        vm.prank(user1);
        token.mint(user1, 1);

        // User2 cannot mint more
        vm.expectRevert(bytes(REVERT_MINT_EXCEEDS_LIMIT));
        vm.prank(user2);
        token.mint(user2, 1);
    }

    function test_Revert_MintToZeroAddress() public {
        vm.expectRevert(bytes(REVERT_MINT_TO_ZERO));
        // Can be called by owner or anyone, should revert
        vm.prank(owner);
        token.mint(address(0), 1 ether);

        vm.expectRevert(bytes(REVERT_MINT_TO_ZERO));
        vm.prank(user1);
        token.mint(address(0), 1 ether);
    }

    // --- Test Burn Logic (Optional, but good practice) ---

    function test_Burn_DecreasesBalance_ButNotMintedAmount() public {
        uint256 burnAmount = MAX_MINT_PER_WALLET / 4;

        // User1 mints up to limit
        vm.prank(user1);
        token.mint(user1, MAX_MINT_PER_WALLET);

        // User1 burns some tokens
        vm.prank(user1); // Or just use startPrank/stopPrank if preferred
        token.burn(user1, burnAmount);

        assertEq(token.balanceOf(user1), MAX_MINT_PER_WALLET - burnAmount, "Balance after burn incorrect");
        // Crucially, mintedAmount should NOT change
        assertEq(token.mintedAmount(user1), MAX_MINT_PER_WALLET, "Minted amount changed after burn");

        // User1 still cannot mint more due to the mintedAmount tracking
        vm.expectRevert(bytes(REVERT_MINT_EXCEEDS_LIMIT));
        vm.prank(user1);
        token.mint(user1, 1);
    }

    // --- Test View Functions ---

    function test_ViewFunctions_ReturnCorrectValues() public {
        assertEq(token.decimals(), TOKEN_DECIMALS);
        assertEq(token.maxMintAmountPerWallet(), MAX_MINT_PER_WALLET);
        assertEq(token.mintedAmount(user1), 0, "Initial minted amount non-zero");

        vm.prank(user1);
        token.mint(user1, 50 ether);
        assertEq(token.mintedAmount(user1), 50 ether, "Minted amount after mint incorrect");
    }
}