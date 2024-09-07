// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { MockERC721 } from "solmate/src/test/utils/mocks/MockERC721.sol";

import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";

import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";

import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import "forge-std/console.sol";
import { GachaHook } from "../src/GachaHook.sol";

contract TestGachaHook is Test, Deployers {
    using CurrencyLibrary for Currency;

    MockERC20 private _token;
    MockERC721 private _nft;

    Currency private _ethCurrency = Currency.wrap(address(0));
    Currency private _tokenCurrency;

    GachaHook private _hook;

    function setUp() public {
        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our NFT contract
        _nft = new MockERC721("Test NFT", "NFT");

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        deployCodeTo("GachaHook.sol", abi.encode(manager, address(_nft), "GachaTest NFT", "gNFT"), address(flags));

        // Deploy our hook
        _hook = GachaHook(address(flags));

        // Deploy our TOKEN contract
        _token = new MockERC20("Test Token", "TEST", 18);
        _tokenCurrency = Currency.wrap(address(_hook));

        // Mint a bunch of TOKEN to ourselves and to address(1)
        _token.mint(address(this), 1000 ether);
        _token.mint(address(1), 1000 ether);

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        _token.approve(address(swapRouter), type(uint256).max);
        _token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key,) = initPool(
            _ethCurrency, // Currency 0 = ETH
            _tokenCurrency, // Currency 1 = TOKEN
            _hook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1, // Initial Sqrt(P) value = 1
            ZERO_BYTES // No additional `initData`
        );
    }

    function test_setUp() public { }
}
