# Gacha Hook

The Gacha Hook addresses high entry barriers, illiquidity, and inefficient revenue models in the NFT market by enabling fractionalization and cross-chain support for a more accessible and dynamic trading experience.

## Getting Started

Follow these steps to set up and run the project locally:

### 1. Install Foundry and Run `foundryup`

Foundry is a powerful toolkit for Ethereum development. If you haven't installed Foundry yet, follow the installation guide on [Foundry's GitHub](https://github.com/foundry-rs/foundry). After installation, run:

```bash
foundryup
```

This command ensures that you have the latest version of Foundry installed.

### 2. Install Dependencies using `pnpm`

We use `pnpm` for managing JavaScript dependencies. If you don’t have `pnpm` installed, follow the instructions on [pnpm's official site](https://pnpm.io/installation). Once you have `pnpm` installed, run:

```bash
pnpm install
```

This will install all the necessary dependencies for the project.

### 3. Install Solidity Libraries with forge install

To ensure that all Solidity libraries (such as OpenZeppelin and Uniswap contracts) are installed, run:

```bash
forge install
```

This command will download all the dependencies listed in your project’s remappings.

### 4. Build the Project with forge build
Once all the dependencies are installed, build the project to compile the Solidity smart contracts:

```bash
forge build
```

This will compile all the contracts and ensure that the project is set up correctly.

### 5. Run Tests with forge test
Finally, to make sure everything is working as expected, run the tests included in the project by executing:

```bash
forge test
```

This will run all the test cases and validate the functionality of the Gacha Hook contracts.

## Problem / Background

The current NFT market faces several key challenges that hinder broader participation and sustainable growth:

### 1. High Entry Barriers
Blue-chip NFT projects such as BAYC, Azuki, and CryptoPunks are prohibitively expensive, making it difficult for most participants to access or invest in these highly sought-after assets.

### 2. Illiquidity & Price Discovery Issues
Most NFTs, built on the ERC-721 standard, are unique and non-fungible. This uniqueness, while valuable for collectors, creates liquidity problems, as it's harder to trade NFTs quickly and at fair market prices compared to fungible tokens like ETH or UNI.

### 3. Inefficient Revenue Models
Many NFT projects rely on limited revenue streams, such as merchandise sales, overlooking the potential of integrating Web3 and DeFi to provide more value to both holders and developers.

## Our Solution

We are creating a fractionalized liquidity hub that allows NFT holders to tokenize and split their NFTs into fractions. This approach significantly lowers the high entry barriers, enabling more participants to own and trade fractionalized shares of premium NFTs. By integrating these fractional NFTs natively with Uniswap, we enhance liquidity, facilitating smoother price discovery and faster trading.

## Impact

By addressing these core issues, our solution democratizes access to blue-chip NFTs, creating more opportunities for both investors and collectors. Our liquidity hub aims to solve the liquidity challenges that plague the NFT market by providing a more flexible and efficient trading environment. Additionally, NFT holders will have access to new revenue models beyond merchandise sales, unlocking sustainable income opportunities. Ultimately, our approach drives broader participation and fosters innovation in the NFT space within the Web3 ecosystem.

## Future Extensions

### Different Pools
Currently, we support the ETH-gNFT pool, but we plan to add ERC20-gNFT pools in the future to increase diversity in our ecosystem.

### Expanded Callback Support
We aim to introduce hooks related to liquidity provision and distribute rewards to incentivize liquidity providers (LPs).

### Mode Selection
In the current design, the gacha is triggered when a user meets a specific threshold. In the future, we plan to offer users a choice between participating in the gacha or conducting a standard swap.

### Custom Router
We plan to develop a custom router, replacing the default Uniswap router, with support for cross-chain functionality in the afterSwap function.
