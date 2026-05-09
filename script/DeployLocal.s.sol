// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Script.sol";

import "../src/Sera.sol";
import "../src/SeraBatcher.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "../src/mock/MockStableCoinDecimals.sol";

/**
 * @title DeployLocal
 * @notice Deploy the full Sera stack to a local Anvil chain for E2E testing.
 *
 * Deploys: Vault, Sera, SeraBatcher, SeraSOR, 5 mock ERC-20 tokens.
 *   - TOKEN_A: USDT (18-decimal MockStableCoin)
 *   - TOKEN_B: SGD  (18-decimal MockStableCoin)
 *   - TOKEN_C: USDC (6-decimal MockStableCoinDecimals)
 *   - TOKEN_D: WBTC (8-decimal MockStableCoinDecimals)
 *   - TOKEN_E: WETH (18-decimal MockStableCoinDecimals)
 *
 * The 5-token fixture supports multi-leg SOR tests and a decimal /
 * pair-shape matrix across 6/8/18-decimal mixes.
 *
 * Configures: whitelist all 5 tokens, EXECUTOR_ROLE, TRADER_ROLE,
 * trusted router.
 * Mints: 1M units of each token (raw scaled by per-token decimals)
 * to deployer + up to 2 extra test wallets.
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
        // Order matters: TOKEN_A and TOKEN_B must be deployed FIRST and
        // SECOND so they land at deterministic Anvil addresses (nonces 0
        // and 1 of the deployer). Downstream tooling depends on this.
        MockStableCoin tokenA = new MockStableCoin("USDT");
        MockStableCoin tokenB = new MockStableCoin("SGD");
        console.log("Token A (USDT, 18d):", address(tokenA));
        console.log("Token B (SGD, 18d): ", address(tokenB));

        // 1b. Deploy non-18-decimal tokens (TOKEN_C/D/E) for multi-leg
        // SOR tests and the decimal / pair-shape matrix.
        MockStableCoinDecimals tokenC = new MockStableCoinDecimals("USDC", 6);
        MockStableCoinDecimals tokenD = new MockStableCoinDecimals("WBTC", 8);
        MockStableCoinDecimals tokenE = new MockStableCoinDecimals("WETH", 18);
        console.log("Token C (USDC, 6d): ", address(tokenC));
        console.log("Token D (WBTC, 8d): ", address(tokenD));
        console.log("Token E (WETH, 18d):", address(tokenE));

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

        // 6. Whitelist all 5 tokens. Per-token min_amount stays at 1
        // (smallest possible) so test code can drive both tiny-fill
        // and dust-threshold scenarios. Production runbook overrides
        // these via batchModifyWhitelistedTokens at deploy time.
        address[] memory wlTokens = new address[](5);
        wlTokens[0] = address(tokenA);
        wlTokens[1] = address(tokenB);
        wlTokens[2] = address(tokenC);
        wlTokens[3] = address(tokenD);
        wlTokens[4] = address(tokenE);
        uint256[] memory wlAmounts = new uint256[](5);
        wlAmounts[0] = 1;
        wlAmounts[1] = 1;
        wlAmounts[2] = 1;
        wlAmounts[3] = 1;
        wlAmounts[4] = 1;
        sera.batchModifyWhitelistedTokens(wlTokens, true, wlAmounts);
        console.log("Whitelisted all 5 tokens");

        // 7. Grant EXECUTOR_ROLE to deployer for local-script convenience
        // Deployer is already DEFAULT_ADMIN, but EXECUTOR_ROLE is separate
        sera.grantRole(sera.EXECUTOR_ROLE(), deployer);
        console.log("Granted EXECUTOR_ROLE to deployer");

        // 8. Mint tokens to deployer. Each mint amount is scaled by
        // the token's decimals (1M whole units regardless of decimal
        // representation). 18-decimal tokens use `ether` (=1e18); 6
        // and 8-decimal tokens use the explicit denominator.
        uint256 mintAmount18 = 1_000_000 ether;          // 1M with 18 decimals
        uint256 mintAmount6 = 1_000_000 * 10**6;         // 1M with 6 decimals
        uint256 mintAmount8 = 1_000_000 * 10**8;         // 1M with 8 decimals
        tokenA.mint(deployer, mintAmount18);
        tokenB.mint(deployer, mintAmount18);
        tokenC.mint(deployer, mintAmount6);
        tokenD.mint(deployer, mintAmount8);
        tokenE.mint(deployer, mintAmount18);
        console.log("Minted 1M each (decimal-scaled) to deployer");

        // 9. Mint tokens to extra test wallets (if provided)
        if (wallet1 != address(0)) {
            tokenA.mint(wallet1, mintAmount18);
            tokenB.mint(wallet1, mintAmount18);
            tokenC.mint(wallet1, mintAmount6);
            tokenD.mint(wallet1, mintAmount8);
            tokenE.mint(wallet1, mintAmount18);
            console.log("Minted 1M each to wallet1:", wallet1);
        }
        if (wallet2 != address(0)) {
            tokenA.mint(wallet2, mintAmount18);
            tokenB.mint(wallet2, mintAmount18);
            tokenC.mint(wallet2, mintAmount6);
            tokenD.mint(wallet2, mintAmount8);
            tokenE.mint(wallet2, mintAmount18);
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
        console.log("E2E_TOKEN2_ADDRESS=", address(tokenC));
        console.log("E2E_TOKEN3_ADDRESS=", address(tokenD));
        console.log("E2E_TOKEN4_ADDRESS=", address(tokenE));
        console.log("E2E_RPC_URL=http://127.0.0.1:8545");
    }
}
