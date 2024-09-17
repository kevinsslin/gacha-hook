// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Foundry Cheatcode
import { Vm } from "forge-std/Vm.sol";
import { Test, console2 } from "forge-std/Test.sol";

// Helper Contract
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";

import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";

import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/types/BalanceDelta.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import { VRFCoordinatorV2_5Mock } from "chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {
    CCIPLocalSimulator,
    IRouterClient,
    LinkToken,
    BurnMintERC677Helper
} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import { Client } from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

// Mock Token
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { MockERC721 } from "solmate/src/test/utils/mocks/MockERC721.sol";
import { Link } from "./Mocks/LinkToken.sol";

// Gacha Hook

import { GachaHook } from "../src/GachaHook.sol";
import { Config } from "./Helper/Config.t.sol";

contract TestGachaHook is Test, Deployers {
    using CurrencyLibrary for Currency;

    /*//////////////////////////////////////////////////////////////
                                 USER
    //////////////////////////////////////////////////////////////*/

    address caller;
    address user;
    address vrfAdmin;

    address alice;
    address bob;

    /*//////////////////////////////////////////////////////////////
                                 TOKEN
    //////////////////////////////////////////////////////////////*/

    MockERC721 nft;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    /*//////////////////////////////////////////////////////////////
                               CONTRACT
    //////////////////////////////////////////////////////////////*/
    GachaHook hook;
    CCIPLocalSimulator public ccipLocalSimulator;
    IRouterClient router;
    BurnMintERC677Helper ccipBnMToken;
    LinkToken linkToken;

    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    Config internal helperConfig;
    Config.NetworkConfig internal config;
    uint64 destinationChainSelector;

    /*//////////////////////////////////////////////////////////////
                              CONSTANT
    //////////////////////////////////////////////////////////////*/

    uint256[10] INIT_NFT_IDS = [100, 101, 102, 103, 104, 105, 106, 107, 108, 109];
    uint160 public constant SQRT_PRICE_1E6_1 = 79_228_162_514_264_337_593_543_950_336_000;

    int24 TICK_SPACING = 60;
    int24 TICK_AT_SQRT_PRICE_1E6_1 = TickMath.getTickAtSqrtPrice(SQRT_PRICE_1E6_1) / TICK_SPACING * TICK_SPACING;

    uint256 internal constant PRIVATE_KEY = 0xabc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1;
    uint256 internal constant INITIAL_BALANCE = 100 ether;

    /*//////////////////////////////////////////////////////////////
                                EVENT
    //////////////////////////////////////////////////////////////*/
    event FractionalizeNFT(address indexed originalOwner, uint256 indexed tokenId);

    function setUp() public {
        // User Account Setup
        caller = vm.addr(PRIVATE_KEY);
        vm.deal(caller, INITIAL_BALANCE);

        vrfAdmin = address(this);
        vm.deal(vrfAdmin, INITIAL_BALANCE);

        user = makeAddr("user");
        vm.deal(user, INITIAL_BALANCE);

        alice = makeAddr("alice");
        vm.deal(alice, INITIAL_BALANCE);

        bob = makeAddr("bob");
        vm.deal(bob, INITIAL_BALANCE);

        // Pool Manager & Router Seployment
        deployFreshManagerAndRouters();

        // Chainlink VRF Service Creation
        helperConfig = new Config();
        config = helperConfig.getConfig();

        // NFT Contract Creation
        nft = new MockERC721("Test NFT", "NFT");

        // CCIP Configuration
        ccipLocalSimulator = new CCIPLocalSimulator();

        (uint64 chainSelector, IRouterClient sourceRouter,,,, BurnMintERC677Helper ccipBnM,) =
            ccipLocalSimulator.configuration();

        router = sourceRouter;
        destinationChainSelector = chainSelector;
        ccipBnMToken = ccipBnM;
        linkToken = LinkToken(config.link);

        // Hook Address Configuration
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);

        // Hook Construction Parameter
        string memory name_ = "GachaTest NFT";
        string memory symbol_ = "gNFT";
        address vrfCoordinator = config.vrfCoordinatorV2_5;
        bytes32 gasLane = config.gasLane;
        uint256 subscriptionId = config.subscriptionId;
        uint32 callbackGasLimit = config.callbackGasLimit;
        address link = config.link;

        bytes memory initData = // solhint-disable-next-line
        abi.encode(
            manager,
            address(nft),
            name_,
            symbol_,
            vrfCoordinator,
            gasLane,
            subscriptionId,
            callbackGasLimit,
            address(router)
        );

        deployCodeTo("GachaHook.sol", initData, address(flags));

        // Hook Deployment
        hook = GachaHook(address(flags));
        tokenCurrency = Currency.wrap(address(hook)); // Currency 1 = Hook

        // VRF Configuration
        Link(link).mint(address(this), 100 ether);
        VRFCoordinatorV2_5Mock(vrfCoordinator).addConsumer(subscriptionId, address(hook));
        VRFCoordinatorV2_5Mock(vrfCoordinator).fundSubscription(config.subscriptionId, 100 ether);

        // Approve Hook Token
        vm.startPrank(caller);
        hook.approve(address(swapRouter), type(uint256).max); // For swap router
        hook.approve(address(modifyLiquidityRouter), type(uint256).max); // For modify liquidiy router
        vm.stopPrank();

        vm.startPrank(user);
        hook.approve(address(swapRouter), type(uint256).max);
        hook.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        // Pool Initialization
        (key,) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = HOOK TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            TICK_SPACING, // Tick Spacing
            SQRT_PRICE_1E6_1,
            ZERO_BYTES // No additional `initData`
        );

        // Contract Labeling
        vm.label(address(hook), "GachaHook");
        vm.label(address(manager), "PoolManager");
        vm.label(address(swapRouter), "SwapRouter");
        vm.label(address(modifyLiquidityRouter), "ModifyLiquidityRouter");
        vm.label(address(nft), "NFT");
        vm.label(address(link), "LinkToken");
        vm.label(address(vrfCoordinator), "VRFCoordinatorV2_5");
        vm.label(address(ccipLocalSimulator), "CCIP");
        vm.label(address(router), "Router");
        vm.label(address(ccipBnMToken), "CCIP Token");
    }

    function test_InitialState() public view {
        // User Balance
        assertEq(caller.balance, INITIAL_BALANCE);
        assertEq(vrfAdmin.balance, INITIAL_BALANCE);
        assertEq(user.balance, INITIAL_BALANCE);

        // Hook Permission
        assertEq(hook.getHookPermissions().beforeInitialize, true);
        assertEq(hook.getHookPermissions().afterSwap, true);

        // Hook Variable
        assertEq(hook.getNFT(), address(nft));
        assertEq(hook.name(), "GachaTest NFT");
        assertEq(hook.symbol(), "gNFT");
        assertEq(hook.decimals(), 18);
        assertEq(hook.NFT_TO_TOKEN_RATE(), 1e24);

        // Chainlink Configuration
        assertEq(hook.i_keyHash(), config.gasLane);
        assertEq(hook.i_subscriptionId(), config.subscriptionId);
        assertEq(hook.i_callbackGasLimit(), config.callbackGasLimit);

        assertEq(hook.REQUEST_CONFIRMATIONS(), 3);
        assertEq(hook.NUM_WORDS(), 1);
    }

    function test_FractionalizeNFT() public {
        vm.startPrank(caller);

        // Mint NFT Token
        uint256 tokenId = 100;
        nft.mint(caller, tokenId);

        assertEq(nft.balanceOf(caller), 1);

        // NFT Fractionalization
        nft.approve(address(hook), tokenId);

        vm.expectEmit();
        emit FractionalizeNFT(caller, tokenId);
        hook.fractionalizeNFT(tokenId);

        vm.stopPrank();

        // Check that the NFT has been fractionalized
        assertEq(nft.balanceOf(caller), 0);
        assertEq(nft.balanceOf(address(hook)), 1);
        assertEq(nft.ownerOf(tokenId), address(hook));
        assertEq(hook.balanceOf(caller), hook.NFT_TO_TOKEN_RATE());

        uint256 collateralCounter_ = hook.getCollateralCounter();
        assertEq(collateralCounter_, 1);
        assertEq(hook.getCollateralTokenIds()[collateralCounter_ - 1], tokenId);
    }

    function test_SwapWithNFTRedeem() public {
        _addInitialLiquidityToPool();

        // Original balances
        uint256 originalCallerEthBalance = address(caller).balance;
        uint256 originalCallerHookTokenBalance = hook.balanceOf(address(caller));
        uint256 originalHookNFTBalance = nft.balanceOf(address(hook));

        vm.startPrank(user);
        // Fractionalize NFT
        uint256[2] memory nftIds = [uint256(1), uint256(2)];
        for (uint256 i = 0; i < 2; i++) {
            uint256 tokenId = nftIds[i];
            nft.mint(user, tokenId);
            nft.approve(address(hook), tokenId);
            hook.fractionalizeNFT(tokenId);
        }

        assertEq(nft.balanceOf(user), 0);
        assertEq(nft.balanceOf(address(hook)), originalHookNFTBalance + 2);
        vm.stopPrank();

        vm.startPrank(caller);
        // Sign Message
        bytes32 message = keccak256(abi.encodePacked(uint256(0), uint256(block.chainid)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PRIVATE_KEY, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Swap Token
        vm.recordLogs();
        BalanceDelta delta = swapRouter.swap{ value: 2 ether }(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(hook.NFT_TO_TOKEN_RATE() * 3 / 2),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            abi.encode(0, block.chainid, signature)
        );
        vm.stopPrank();

        // Chainlink Mock -> Redeem NFT
        vm.startPrank(vrfAdmin);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (uint256 requestId,,,,,) = abi.decode(entries[1].data, (uint256, uint256, uint16, uint32, uint32, bytes));
        VRFCoordinatorV2_5Mock(config.vrfCoordinatorV2_5).fundSubscription(config.subscriptionId, 100 ether);
        VRFCoordinatorV2_5Mock(config.vrfCoordinatorV2_5).fulfillRandomWords(requestId, address(hook));
        vm.stopPrank();

        assertEq(address(caller).balance + uint256(uint128(-delta.amount0())), originalCallerEthBalance);
        assertEq(
            hook.balanceOf(caller),
            originalCallerHookTokenBalance + uint256(uint128(delta.amount1())) - hook.NFT_TO_TOKEN_RATE()
        );
        assertEq(nft.balanceOf(address(hook)), 11);
        assertEq(nft.balanceOf(address(caller)), 1);
    }

    function test_AddLiquidity() public {
        vm.startPrank(user);

        // NFT Creation & Fractionalization
        uint256 tokenId = 110;
        nft.mint(user, tokenId);
        nft.approve(address(hook), tokenId);
        hook.fractionalizeNFT(tokenId);

        assertEq(nft.balanceOf(user), 0);
        assertEq(nft.balanceOf(address(hook)), 1);

        int256 amount1 = int256(hook.NFT_TO_TOKEN_RATE() * 1);
        assertEq(hook.balanceOf(user), uint256(amount1));

        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(TICK_AT_SQRT_PRICE_1E6_1 - TICK_SPACING);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(TICK_AT_SQRT_PRICE_1E6_1 + TICK_SPACING);

        (uint256 amount0Delta,) = LiquidityAmounts.getAmountsForLiquidity(
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

    // Add Inital Liquidity
    function _addInitialLiquidityToPool() internal {
        vm.startPrank(user);

        // NFT Fractionalization
        for (uint256 i = 0; i < INIT_NFT_IDS.length; i++) {
            uint256 tokenId = INIT_NFT_IDS[i];
            nft.mint(user, tokenId);
            nft.approve(address(hook), tokenId);
            hook.fractionalizeNFT(tokenId);
        }

        assertEq(nft.balanceOf(user), 0);
        assertEq(nft.balanceOf(address(hook)), INIT_NFT_IDS.length);

        for (uint256 i = 0; i < INIT_NFT_IDS.length; i++) {
            uint256 tokenId = INIT_NFT_IDS[i];
            assertEq(nft.ownerOf(tokenId), address(hook));
        }

        int256 amount1 = int256(hook.NFT_TO_TOKEN_RATE() * INIT_NFT_IDS.length);
        assertEq(hook.balanceOf(user), uint256(amount1));

        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(TICK_AT_SQRT_PRICE_1E6_1 - TICK_SPACING);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(TICK_AT_SQRT_PRICE_1E6_1 + TICK_SPACING);

        (uint256 amount0Delta,) = LiquidityAmounts.getAmountsForLiquidity(
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

    function prepareScenario()
        public
        returns (Client.EVMTokenAmount[] memory tokensToSendDetails, uint256 amountToSend)
    {
        vm.startPrank(alice);

        uint256 tokenId = 110;
        nft.mint(alice, tokenId);
        nft.approve(address(hook), tokenId);
        hook.fractionalizeNFT(tokenId);

        amountToSend = hook.balanceOf(alice);
        hook.approve(address(router), amountToSend);

        tokensToSendDetails = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenToSendDetails =
            Client.EVMTokenAmount({ token: address(hook), amount: amountToSend });
        tokensToSendDetails[0] = tokenToSendDetails;

        vm.stopPrank();
    }

    function test_transferTokensFromEoaToEoaPayFeesInLink() external {
        (Client.EVMTokenAmount[] memory tokensToSendDetails, uint256 amountToSend) = prepareScenario();

        uint256 balanceOfAliceBefore = hook.balanceOf(alice);
        uint256 balanceOfBobBefore = hook.balanceOf(bob);

        vm.startPrank(alice);
        ccipLocalSimulator.requestLinkFromFaucet(alice, 5 ether);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(bob),
            data: abi.encode(""),
            tokenAmounts: tokensToSendDetails,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: 0 })),
            feeToken: address(linkToken)
        });

        uint256 fees = router.getFee(destinationChainSelector, message);
        linkToken.approve(address(router), fees);

        router.ccipSend(destinationChainSelector, message);
        vm.stopPrank();

        uint256 balanceOfAliceAfter = hook.balanceOf(alice);
        uint256 balanceOfBobAfter = hook.balanceOf(bob);

        assertEq(balanceOfAliceAfter, balanceOfAliceBefore - amountToSend);
        assertEq(balanceOfBobAfter, balanceOfBobBefore + amountToSend);
    }

    function test_transferTokensFromEoaToEoaPayFeesInNative() external {
        (Client.EVMTokenAmount[] memory tokensToSendDetails, uint256 amountToSend) = prepareScenario();

        uint256 balanceOfAliceBefore = hook.balanceOf(alice);
        uint256 balanceOfBobBefore = hook.balanceOf(bob);

        vm.startPrank(alice);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(bob),
            data: abi.encode(""),
            tokenAmounts: tokensToSendDetails,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: 0 })),
            feeToken: address(0)
        });

        uint256 fees = router.getFee(destinationChainSelector, message);
        router.ccipSend{ value: fees }(destinationChainSelector, message);
        vm.stopPrank();

        uint256 balanceOfAliceAfter = hook.balanceOf(alice);
        uint256 balanceOfBobAfter = hook.balanceOf(bob);
        assertEq(balanceOfAliceAfter, balanceOfAliceBefore - amountToSend);
        assertEq(balanceOfBobAfter, balanceOfBobBefore + amountToSend);
    }

    function test_GachaHookCrosschain() public {
        uint256 amountToSend = hook.balanceOf(alice);

        uint256 balanceOfAliceBefore = hook.balanceOf(alice);
        uint256 balanceOfBobBefore = hook.balanceOf(bob);

        vm.prank(alice);
        hook.sendCrosschain(amountToSend, destinationChainSelector, bob);

        uint256 balanceOfAliceAfter = hook.balanceOf(alice);
        uint256 balanceOfBobAfter = hook.balanceOf(bob);

        assertEq(balanceOfAliceAfter, balanceOfAliceBefore - amountToSend);
        assertEq(balanceOfBobAfter, balanceOfBobBefore + amountToSend);
    }
}
