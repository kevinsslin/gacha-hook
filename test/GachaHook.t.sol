// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Vm } from "forge-std/Vm.sol";
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
    address tester;
    address vrfOwner;

    // Token
    MockERC721 nft;

    // Pair Token
    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    // Contract
    GachaHook hook;

    // Configuration
    Config internal helperConfig;
    Config.NetworkConfig internal config;

    // Constants
    uint256[10] INIT_NFT_IDS = [100, 101, 102, 103, 104, 105, 106, 107, 108, 109];
    uint160 public constant SQRT_PRICE_1E6_1 = 79_228_162_514_264_337_593_543_950_336_000;

    int24 TICK_SPACING = 60;
    int24 TICK_AT_SQRT_PRICE_1E6_1 = TickMath.getTickAtSqrtPrice(SQRT_PRICE_1E6_1) / TICK_SPACING * TICK_SPACING;

    // Events
    event FractionalizeNFT(address indexed originalOwner, uint256 indexed tokenId);

    function setUp() public {
        // Set up user accounts
        caller = makeAddr("CALLER");
        trader = makeAddr("TRADER");
        tester = makeAddr("TESTER");
        vrfOwner = makeAddr("VRFOwner");

        vm.deal(caller, 100 ether);
        vm.deal(trader, 100 ether);
        vm.deal(tester, 100 ether);
        vm.deal(vrfOwner, 100 ether);

        // Deploy Pool Manager & Router
        deployFreshManagerAndRouters();

        // vm.startPrank(vrfOwner);
        helperConfig = new Config();
        config = helperConfig.getConfig();
        // vm.stopPrank();

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

        bytes memory initData = // solhint-disable-next-line
         abi.encode(manager, address(nft), name_, symbol_, vrfCoordinator, gasLane, subscriptionId, callbackGasLimit);

        deployCodeTo("GachaHook.sol", initData, address(flags));

        // Deploy our hook
        hook = GachaHook(address(flags));
        tokenCurrency = Currency.wrap(address(hook)); // Currency 1 = Hook

        VRFCoordinatorV2_5Mock(vrfCoordinator).addConsumer(subscriptionId, address(hook));

        // Approve our HOOK TOKEN for spending on the swap router and modify liquidity router
        vm.startPrank(caller);
        hook.approve(address(swapRouter), type(uint256).max);
        hook.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(trader);
        hook.approve(address(swapRouter), type(uint256).max);
        hook.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(tester);
        hook.approve(address(swapRouter), type(uint256).max);
        hook.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        // Initialize a pool
        (key,) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = HOOK TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            TICK_SPACING, // Tick Spacing
            SQRT_PRICE_1E6_1,
            ZERO_BYTES // No additional `initData`
        );

        VRFCoordinatorV2_5Mock(vrfCoordinator).fundSubscription(config.subscriptionId, 100 ether);

        // label contract
        vm.label(address(hook), "GachaHook");
        vm.label(address(manager), "PoolManager");
        vm.label(address(swapRouter), "SwapRouter");
        vm.label(address(modifyLiquidityRouter), "ModifyLiquidityRouter");
        vm.label(address(nft), "NFT");
        vm.label(address(link), "LinkToken");
        vm.label(address(vrfCoordinator), "VRFCoordinatorV2_5");
    }

    function test_SetUp() public view {
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

        vm.expectEmit();
        emit FractionalizeNFT(caller, tokenId);

        hook.fractionalizeNFT(tokenId);

        // Check that the NFT has been fractionalized
        assertEq(nft.balanceOf(caller), 0);
        assertEq(nft.balanceOf(address(hook)), 1);
        assertEq(nft.ownerOf(tokenId), address(hook));

        assertEq(hook.balanceOf(caller), hook.NFT_TO_TOKEN_RATE());

        uint256 collateralCounter_ = hook.getCollateralCounter();
        assertEq(collateralCounter_, 1);
        assertEq(hook.getCollateralTokenIds()[collateralCounter_ - 1], tokenId);

        vm.stopPrank();
    }

    function test_SwapWithNFTRedeem() public {
        _addInitialLiquidityToPool();

        vm.startPrank(caller);

        // Original balances
        uint256 originalCallerEthBalance = address(caller).balance;
        uint256 originalCallerHookTokenBalance = hook.balanceOf(address(caller));
        uint256 originalCallerNFTBalance = nft.balanceOf(address(caller));

        uint256 originalHookNFTBalance = nft.balanceOf(address(hook));

        console2.log("Original Caller ETH Balance: ", originalCallerEthBalance);
        console2.log("Original Caller Hook Token Balance: ", originalCallerHookTokenBalance);
        console2.log("Original Caller NFT Balance: ", originalCallerNFTBalance);
        console2.log("Original Hook NFT Balance: ", originalHookNFTBalance);

        // Fractionalize the 2 NFTs
        uint256[2] memory nftIds = [uint256(1), uint256(2)];
        for (uint256 i = 0; i < 2; i++) {
            uint256 tokenId = nftIds[i];
            nft.mint(caller, tokenId);
            nft.approve(address(hook), tokenId);
            hook.fractionalizeNFT(tokenId);
        }

        assertEq(nft.balanceOf(caller), 0);
        assertEq(nft.balanceOf(address(hook)), originalHookNFTBalance + 2);

        int256 amount1 = int256(hook.NFT_TO_TOKEN_RATE() * 1);
        assertEq(hook.balanceOf(caller), hook.NFT_TO_TOKEN_RATE() * 2);

        // Add liquidity
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(TICK_AT_SQRT_PRICE_1E6_1 - TICK_SPACING);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(TICK_AT_SQRT_PRICE_1E6_1 + TICK_SPACING);

        (uint256 amount0Delta, uint256 amount1Delta) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1E6_1, sqrtPriceAtTickLower, sqrtPriceAtTickUpper, uint128(uint256(amount1))
        );

        uint128 liquidityToAdd = LiquidityAmounts.getLiquidityForAmount1(
            sqrtPriceAtTickLower, sqrtPriceAtTickUpper, uint128(uint256(amount1))
        );

        // swap
        vm.recordLogs();
        // modifyLiquidityRouter.modifyLiquidity{ value: amount0Delta + 1 }(
        //     key,
        //     IPoolManager.ModifyLiquidityParams({
        //         tickLower: TICK_AT_SQRT_PRICE_1E6_1 - TICK_SPACING,
        //         tickUpper: TICK_AT_SQRT_PRICE_1E6_1 + TICK_SPACING,
        //         liquidityDelta: int256(uint256(liquidityToAdd)),
        //         salt: bytes32(0)
        //     }),
        //     ZERO_BYTES
        // );
        swapRouter.swap{ value: 2 ether }(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(hook.NFT_TO_TOKEN_RATE() * 3 / 2), // Exact output
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 requestId = 1;
        console2.log("requestId: ", requestId);

        // TODO: remove this after fixing the issue
        console2.log("vrfCoordinator: ", config.vrfCoordinatorV2_5);
        console2.log("entries[1].emitter: ", entries[1].emitter);

        vm.stopPrank();

        uint256 now = block.timestamp;
        vm.warp(now + 30);

        // Wait for the VRF response
        vm.startPrank(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496);

        console2.log("config.subscriptionId: ", config.subscriptionId);
        VRFCoordinatorV2_5Mock(config.vrfCoordinatorV2_5).fundSubscription(config.subscriptionId, 100 ether);
        VRFCoordinatorV2_5Mock(config.vrfCoordinatorV2_5).fulfillRandomWords(requestId, address(hook));
        vm.stopPrank();

        vm.startPrank(caller);
        // Post balance check
        uint256 postCallerEthBalance = address(caller).balance;
        uint256 postCallerHookTokenBalance = hook.balanceOf(address(caller));
        uint256 postCallerNFTBalance = nft.balanceOf(address(caller));
        uint256 postHookNFTBalance = nft.balanceOf(address(hook));

        console2.log("Post Caller ETH Balance: ", postCallerEthBalance);
        console2.log("Post Caller Hook Token Balance: ", postCallerHookTokenBalance);
        console2.log("Post Caller NFT Balance: ", postCallerNFTBalance);
        console2.log("Post Hook NFT Balance: ", postHookNFTBalance);

        _printCollateralInfo();

        vm.stopPrank();
    }

    function test_RequestRandomNumber() public {
        uint256 requestId = hook._requestRandomNumber();

        address vrfCoordinator = config.vrfCoordinatorV2_5;
        VRFCoordinatorV2_5Mock(vrfCoordinator).fundSubscription(config.subscriptionId, 100 ether);

        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(hook));
    }

    // Helper functions
    function _addInitialLiquidityToPool() internal {
        vm.startPrank(tester);
        // Fractionalize the NFT
        for (uint256 i = 0; i < INIT_NFT_IDS.length; i++) {
            uint256 tokenId = INIT_NFT_IDS[i];
            nft.mint(tester, tokenId);
            nft.approve(address(hook), tokenId);
            hook.fractionalizeNFT(tokenId);
        }
        assertEq(nft.balanceOf(tester), 0);
        assertEq(nft.balanceOf(address(hook)), INIT_NFT_IDS.length);

        int256 amount1 = int256(hook.NFT_TO_TOKEN_RATE() * INIT_NFT_IDS.length);
        assertEq(hook.balanceOf(tester), uint256(amount1));

        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(TICK_AT_SQRT_PRICE_1E6_1 - TICK_SPACING);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(TICK_AT_SQRT_PRICE_1E6_1 + TICK_SPACING);

        (uint256 amount0Delta, uint256 amount1Delta) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1E6_1, sqrtPriceAtTickLower, sqrtPriceAtTickUpper, uint128(uint256(amount1))
        );

        uint128 liquidityToAdd = LiquidityAmounts.getLiquidityForAmount1(
            sqrtPriceAtTickLower, sqrtPriceAtTickUpper, uint128(uint256(amount1))
        );

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity{ value: amount0Delta + 1 }(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_AT_SQRT_PRICE_1E6_1 - TICK_SPACING,
                tickUpper: TICK_AT_SQRT_PRICE_1E6_1 + TICK_SPACING,
                liquidityDelta: int256(uint256(liquidityToAdd)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
    }

    function _printCollateralInfo() internal {
        console2.log("Collateral Info -------------------");
        uint256 collateralCounter = hook.getCollateralCounter();
        uint256[] memory collateralTokenIds = hook.getCollateralTokenIds();

        console2.log("Collateral Counter: ", collateralCounter);
        for (uint256 i = 0; i < collateralCounter; i++) {
            console2.log("Collateral Token ID: ", collateralTokenIds[i]);
        }
    }
}
