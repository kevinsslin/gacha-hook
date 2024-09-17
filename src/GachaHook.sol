// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { VRFCoordinatorV2Interface } from "chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";

import { VRFConsumerBaseV2Plus } from "chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";

import { VRFV2PlusClient } from "chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

import { BaseHook } from "v4-periphery/src/base/hooks/BaseHook.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { ERC721 } from "solmate/src/tokens/ERC721.sol";

import { CurrencyLibrary, Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { BalanceDeltaLibrary, BalanceDelta } from "v4-core/types/BalanceDelta.sol";

import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";

import { Hooks } from "v4-core/libraries/Hooks.sol";

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { Client } from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

import { IRouterClient } from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";

contract GachaHook is BaseHook, ERC20, VRFConsumerBaseV2Plus {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // Gacha
    ERC721 private _nft;
    uint256[] private _collateralTokenIds;
    uint256 private _collateralCounter;
    address[] requestedSenders;
    mapping(address => mapping(bytes32 => bool)) GachaSignature;

    // Chainlink
    bytes32 public immutable i_keyHash;
    uint256 public immutable i_subscriptionId;
    uint32 public immutable i_callbackGasLimit;

    // CCIP
    IRouterClient public immutable router;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint32 public constant NUM_WORDS = 1;
    uint256 public constant NFT_TO_TOKEN_RATE = 1e6 * 1e18; // 1 NFT = 1,000,000 gNFT

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event BeforeInitializeSetting(PoolKey key, address indexed nft);
    event AfterSwapRedeemRequest(address indexed sender, uint256 indexed requestId);
    event FractionalizeNFT(address indexed originalOwner, uint256 indexed tokenId);
    event RedeemNFT(address indexed recipient, uint256 indexed tokenId);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error GachaHook__INVALID_POOL(Currency token0_, Currency token1_, IHooks hook_);
    error GachaHook__DUPLICATE_SIGNATURE(address initiator, uint256 nounce);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IPoolManager manager_,
        address nftAddress_,
        string memory name_,
        string memory symbol_,
        address vrfCoordinator_,
        bytes32 gasLane_,
        uint256 subscriptionId_,
        uint32 callbackGasLimit_,
        address router_
    )
        VRFConsumerBaseV2Plus(vrfCoordinator_)
        BaseHook(manager_)
        ERC20(name_, symbol_, 18)
    {
        _nft = ERC721(nftAddress_);
        i_keyHash = gasLane_;
        i_subscriptionId = subscriptionId_;
        i_callbackGasLimit = callbackGasLimit_;
        router = IRouterClient(router_);
    }

    /*//////////////////////////////////////////////////////////////
                             HOOK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(
        address,
        PoolKey calldata key_,
        uint160,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        // If this is not an ETH-gNFT pool with this hook attached, revert
        if (!key_.currency0.isNative() || Currency.unwrap(key_.currency1) != address(this)) {
            revert GachaHook__INVALID_POOL(key_.currency0, key_.currency1, key_.hooks);
        }
        emit BeforeInitializeSetting(key_, address(_nft));
        return (this.beforeInitialize.selector);
    }

    function afterSwap(
        address sender,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta d,
        bytes calldata data
    )
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        (uint256 nounce,, bytes memory signature) = abi.decode(data, (uint256, uint256, bytes));
        bytes32 message = keccak256(abi.encodePacked(nounce, block.chainid));
        address initiator = ECDSA.recover(message, signature);

        if (GachaSignature[initiator][message]) {
            revert GachaHook__DUPLICATE_SIGNATURE(initiator, nounce);
        }
        GachaSignature[initiator][message] = true;

        uint256 deltaAmount_ = d.amount0() > 0 ? 0 : uint256(uint128(d.amount0()));

        if (sender == initiator) {
            if (ERC20(address(this)).balanceOf(initiator) >= NFT_TO_TOKEN_RATE) {
                uint256 requestId = _requestRandomNumber();
                requestedSenders.push(initiator);
                emit AfterSwapRedeemRequest(initiator, requestId);
            }
        } else {
            if (ERC20(address(this)).balanceOf(initiator) + deltaAmount_ >= NFT_TO_TOKEN_RATE) {
                uint256 requestId = _requestRandomNumber();
                requestedSenders.push(initiator);
                emit AfterSwapRedeemRequest(initiator, requestId);
            }
        }
        return (this.afterSwap.selector, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function fractionalizeNFT(uint256 tokenId_) external {
        address originalOwner_ = _nft.ownerOf(tokenId_);
        _nft.safeTransferFrom(msg.sender, address(this), tokenId_);
        _collateralTokenIds.push(tokenId_);
        _collateralCounter++;
        _mint(msg.sender, NFT_TO_TOKEN_RATE);
        emit FractionalizeNFT(originalOwner_, tokenId_);
    }

    /*//////////////////////////////////////////////////////////////
                      EXTERNAL CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getHookData(address referrer, address referree) public pure returns (bytes memory) {
        return abi.encode(referrer, referree);
    }

    function getNFT() external view returns (address) {
        return address(_nft);
    }

    function getCollateralTokenIds() external view returns (uint256[] memory) {
        return _collateralTokenIds;
    }

    function getCollateralCounter() external view returns (uint256) {
        return _collateralCounter;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _redeemNFT(address[] memory recipients_, uint256 tokenId_) internal {
        for (uint256 i = 0; i < recipients_.length; i++) {
            address recipient_ = recipients_[i];
            _burn(recipient_, NFT_TO_TOKEN_RATE);

            // remove tokenId_ from _collateralTokenIds
            for (uint256 j = 0; j < _collateralCounter; j++) {
                if (_collateralTokenIds[j] == tokenId_) {
                    // swap with last element
                    _collateralTokenIds[j] = _collateralTokenIds[_collateralCounter - 1];
                    // remove last element
                    delete _collateralTokenIds[_collateralCounter - 1];
                    _collateralCounter--;
                    break;
                }
            }
            _nft.transferFrom(address(this), recipient_, tokenId_);
            // remove recipient_ from requestedSenders
            delete requestedSenders[i];
            emit RedeemNFT(recipient_, tokenId_);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           CHAINLINK FUNCTION
    //////////////////////////////////////////////////////////////*/

    function _requestRandomNumber() internal returns (uint256) {
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: i_callbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({ nativePayment: false }))
            })
        );
        return requestId;
    }

    function fulfillRandomWords(uint256, uint256[] calldata randomWords) internal override {
        uint256 randomIndex_ = randomWords[0] % _collateralCounter;
        uint256 tokenId_ = _collateralTokenIds[randomIndex_];
        _redeemNFT(requestedSenders, tokenId_);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function prepareSendCrossChain(uint256 _amountToSend)
        public
        returns (Client.EVMTokenAmount[] memory tokensToSendDetails, uint256 amountToSend)
    {
        ERC20(address(this)).approve(address(router), _amountToSend);

        tokensToSendDetails = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenToSendDetails =
            Client.EVMTokenAmount({ token: address(this), amount: _amountToSend });
        tokensToSendDetails[0] = tokenToSendDetails;
        amountToSend = _amountToSend;
    }

    function sendCrosschain(uint256 amountToSend, uint64 destinationChainSelector, address receiver) public payable {
        (Client.EVMTokenAmount[] memory tokensToSendDetails, uint256 amountToSend) = prepareSendCrossChain(amountToSend);
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: abi.encode(""),
            tokenAmounts: tokensToSendDetails,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: 0 })),
            feeToken: address(0)
        });
        uint256 fees = router.getFee(destinationChainSelector, message);
        router.ccipSend{ value: fees }(destinationChainSelector, message);
    }
}
