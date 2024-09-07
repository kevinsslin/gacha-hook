// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseHook } from "v4-periphery/src/base/hooks/BaseHook.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { ERC721 } from "solmate/src/tokens/ERC721.sol";

import { CurrencyLibrary, Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { BalanceDeltaLibrary, BalanceDelta } from "v4-core/types/BalanceDelta.sol";

import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";

import { Hooks } from "v4-core/libraries/Hooks.sol";

contract GachaHook is BaseHook, ERC20 {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    ERC721 private _nft;
    uint256[] private _collateralTokenIds;
    uint256 private _collateralCounter;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant NFT_TO_TOKEN_RATE = 1e6 * 1e18; // 1 NFT = 1,000,000 gNFT

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event BeforeInitializeSetting(PoolKey key, address indexed nft);
    event AfterSwapRedeemNFT(address indexed recipient, uint256 indexed tokenId);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error GachaHook__INVALID_POOL(Currency token0_, Currency token1_, IHooks hook_);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IPoolManager manager_,
        address nftAddress_,
        string memory name_,
        string memory symbol_
    )
        BaseHook(manager_)
        ERC20(name_, symbol_, 18)
    {
        _nft = ERC721(nftAddress_);
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
        address sender_,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        // if swaper's gNFT token > NFT_TO_TOKEN_RATE, redeem NFT
        if (ERC20(address(this)).balanceOf(sender_) >= NFT_TO_TOKEN_RATE) {
            // randomly select a collateral NFT to redeem
            // TODO: implement random selection with Chainlink VRF
            uint256 randomIndex_ = block.timestamp % _collateralCounter;
            uint256 tokenId_ = _collateralTokenIds[randomIndex_];
            _redeemNFT(sender_, tokenId_);
            emit AfterSwapRedeemNFT(sender_, tokenId_);
        }
        return (this.afterSwap.selector, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function fractionalizeNFT(uint256 tokenId_) external {
        _nft.transferFrom(msg.sender, address(this), tokenId_);
        _collateralTokenIds.push(tokenId_);
        _collateralCounter++;
        _mint(msg.sender, NFT_TO_TOKEN_RATE);
    }

    /*//////////////////////////////////////////////////////////////
                      EXTERNAL CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getHookData(address referrer, address referree) public pure returns (bytes memory) {
        return abi.encode(referrer, referree);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _redeemNFT(address recipient_, uint256 tokenId_) internal {
        _burn(recipient_, NFT_TO_TOKEN_RATE);

        // remove tokenId_ from _collateralTokenIds
        for (uint256 i = 0; i < _collateralCounter; i++) {
            if (_collateralTokenIds[i] == tokenId_) {
                // swap with last element
                _collateralTokenIds[i] = _collateralTokenIds[_collateralCounter - 1];
                // remove last element
                delete _collateralTokenIds[_collateralCounter - 1];
                _collateralCounter--;
                break;
            }
        }
        _nft.safeTransferFrom(address(this), recipient_, tokenId_);
    }
}
