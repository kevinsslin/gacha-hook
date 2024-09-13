// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, console2 } from "forge-std/Test.sol";

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

import { GachaHook } from "../src/GachaHook.sol";
import { Config } from "./Helper/Config.t.sol";

import { VRFCoordinatorV2_5Mock } from "chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

import { LinkToken } from "./Mocks/LinkToken.sol";

contract TestGachaHook is Test, Deployers {
    using CurrencyLibrary for Currency;

    // Users
    address caller;
    address trader;

    // Token
    MockERC20 token;
    MockERC721 nft;

    // Pair Token
    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    // Contract
    GachaHook hook;

    // Configuration
    Config internal helperConfig;
    Config.NetworkConfig internal config;

    function setUp() public {
        // Set up user accounts
        caller = makeAddr("CALLER");
        trader = makeAddr("TRADER");

        // Deploy Pool Manager & Router
        deployFreshManagerAndRouters();

        helperConfig = new Config();
        config = helperConfig.getConfig();

        // Deploy our NFT contract
        nft = new MockERC721("Test NFT", "NFT");

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);

        string memory name_ = "GachaTest NFT";
        string memory symbol_ = "gNFT";

        address vrfCoordinator = config.vrfCoordinatorV2_5;
        bytes32 gasLane = config.gasLane;
        uint256 subscriptionId = config.subscriptionId;
        uint32 callbackGasLimit = config.callbackGasLimit;
        address link = config.link;

        // Link Token funding
        LinkToken(link).mint(address(this), 100 ether);

        bytes memory initData =
            abi.encode(manager, address(nft), name_, symbol_, vrfCoordinator, gasLane, subscriptionId, callbackGasLimit);

        deployCodeTo("GachaHook.sol", initData, address(flags));

        // Deploy our hook
        hook = GachaHook(address(flags));

        VRFCoordinatorV2_5Mock(vrfCoordinator).addConsumer(subscriptionId, address(hook));

        // Deploy our TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(hook)); // Currency 1 = Hook

        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key,) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1, // Initial Sqrt(P) value = 1
            ZERO_BYTES // No additional `initData`
        );
    }

    function test_SetUp() public {
        // Check that the hook is set up correctly
        assertEq(hook.getHookPermissions().beforeInitialize, true);
        assertEq(hook.getHookPermissions().afterSwap, true);

        assertEq(hook.getNFT(), address(nft));
        assertEq(hook.name(), "GachaTest NFT");
        assertEq(hook.symbol(), "gNFT");
        assertEq(hook.decimals(), 18);
    }

    function test_FractionalizeNFT() public {
        vm.startPrank(caller);

        uint256 tokenId = 100;
        // Mint NFT token id 100 to the caller
        nft.mint(caller, tokenId);

        assertEq(nft.balanceOf(caller), 1);

        // Fractionalize the NFT
        nft.approve(address(hook), tokenId);
        hook.fractionalizeNFT(tokenId);

        // Check that the NFT has been fractionalized
        assertEq(nft.balanceOf(caller), 0);
        assertEq(nft.balanceOf(address(hook)), 1);
        assertEq(nft.ownerOf(tokenId), address(hook));

        assertEq(hook.balanceOf(caller), hook.NFT_TO_TOKEN_RATE());

        uint256 collateralCounter_ = hook.getCollateralCounter();
        assertEq(collateralCounter_, 1);
        assertEq(hook.getCollateralTokenIds()[collateralCounter_ - 1], tokenId);
    }

    function test_RequestRandomNumber() public {
        uint256 requestId = hook.requestRandomNumber();

        address vrfCoordinator = config.vrfCoordinatorV2_5;
        VRFCoordinatorV2_5Mock(vrfCoordinator).fundSubscription(config.subscriptionId, 100 ether);

        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(hook));
        uint256 d = hook.ReturnCount();
        console2.log(d); // `d` should be some random number.
    }
}
