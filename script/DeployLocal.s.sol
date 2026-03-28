// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Script.sol";

import "../src/Sera.sol";
import "../src/SeraBatcher.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";

/**
 * @title DeployLocal
 * @notice Deploy the full Sera stack to a local Anvil chain for E2E testing.
 *
 * Deploys: Vault, Sera, SeraBatcher, SeraSOR, 2 mock ERC-20 tokens.
 * Configures: whitelist, EXECUTOR_ROLE, TRADER_ROLE, trusted router.
 * Mints: 1M of each token to deployer + up to 2 extra test wallets.
 *
 * Usage:
 *   # Start Anvil in a separate terminal:
 *   anvil
 *
 *   # Deploy (uses Anvil's default account 0):
 *   PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
 *   forge script script/DeployLocal.s.sol:DeployLocalScript \
 *     --rpc-url http://127.0.0.1:8545 \
 *     --broadcast
 *
 *   # With extra test wallets (Anvil accounts 1 and 2):
 *   PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
 *   WALLET_1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
 *   WALLET_2=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC \
 *   forge script script/DeployLocal.s.sol:DeployLocalScript \
 *     --rpc-url http://127.0.0.1:8545 \
 *     --broadcast
 */
contract DeployLocalScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Optional: extra test wallets to fund with tokens
        address wallet1 = vm.envOr("WALLET_1", address(0));
        address wallet2 = vm.envOr("WALLET_2", address(0));

        console.log("=== DeployLocal (Anvil) ===");
        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Mock Tokens
        MockStableCoin tokenA = new MockStableCoin("USDT");
        MockStableCoin tokenB = new MockStableCoin("SGD");
        console.log("Token A (USDT):", address(tokenA));
        console.log("Token B (SGD): ", address(tokenB));

        // 2. Deploy Vault
        Vault vault = new Vault(deployer);
        console.log("Vault:         ", address(vault));

        // 3. Deploy Sera
        Sera sera = new Sera(deployer, vault);
        vault.grantRole(vault.TRADER_ROLE(), address(sera));
        console.log("Sera:          ", address(sera));

        // 4. Deploy SeraSOR
        SeraSOR sor = new SeraSOR(address(sera));
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        console.log("SeraSOR:       ", address(sor));

        // 5. Deploy SeraBatcher
        SeraBatcher batcher = new SeraBatcher(address(sera), address(sor));
        sera.grantRole(sera.EXECUTOR_ROLE(), address(batcher));
        console.log("SeraBatcher:   ", address(batcher));

        // 6. Whitelist tokens
        address[] memory wlTokens = new address[](2);
        wlTokens[0] = address(tokenA);
        wlTokens[1] = address(tokenB);
        uint256[] memory wlAmounts = new uint256[](2);
        wlAmounts[0] = 1;
        wlAmounts[1] = 1;
        sera.batchModifyWhitelistedTokens(wlTokens, true, wlAmounts);
        console.log("Whitelisted both tokens");

        // 7. Grant EXECUTOR_ROLE to deployer (so local-script convenience)
        // Deployer is already DEFAULT_ADMIN, but EXECUTOR_ROLE is separate
        sera.grantRole(sera.EXECUTOR_ROLE(), deployer);
        console.log("Granted EXECUTOR_ROLE to deployer");

        // 8. Mint tokens to deployer
        uint256 mintAmount = 1_000_000 ether;
        tokenA.mint(deployer, mintAmount);
        tokenB.mint(deployer, mintAmount);
        console.log("Minted 1M each to deployer");

        // 9. Mint tokens to extra test wallets (if provided)
        if (wallet1 != address(0)) {
            tokenA.mint(wallet1, mintAmount);
            tokenB.mint(wallet1, mintAmount);
            console.log("Minted 1M each to wallet1:", wallet1);
        }
        if (wallet2 != address(0)) {
            tokenA.mint(wallet2, mintAmount);
            tokenB.mint(wallet2, mintAmount);
            console.log("Minted 1M each to wallet2:", wallet2);
        }

        vm.stopBroadcast();

        // Print summary for .env configuration
        console.log("");
        console.log("=== Deployment summary ===");
        console.log("SERA_CONTRACT_ADDRESS=", address(sera));
        console.log("SERA_BATCHER_ADDRESS=", address(batcher));
        console.log("SERA_SOR_ADDRESS=", address(sor));
        console.log("VAULT_ADDRESS=", address(vault));
        console.log("");
        console.log("=== E2E environment variables ===");
        console.log("E2E_SERA_ADDRESS=", address(sera));
        console.log("E2E_TOKEN0_ADDRESS=", address(tokenA));
        console.log("E2E_TOKEN1_ADDRESS=", address(tokenB));
        console.log("E2E_RPC_URL=http://127.0.0.1:8545");
    }
}
