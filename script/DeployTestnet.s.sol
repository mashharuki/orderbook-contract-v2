// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Script.sol";

import "../src/Sera.sol";
import "../src/SeraBatcher.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";

contract DeploySeraTestnet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Optional: Load Executor address from env, default to deployer if not set
        address executor = vm.envOr("EXECUTOR_ADDRESS", deployer);

        console.log("Deploying to Testnet with address:", deployer);
        console.log("Executor address:", executor);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Mock Tokens (if needed for testing environment)
        MockStableCoin mockUSDT = new MockStableCoin("USDT");
        MockStableCoin mockSGD = new MockStableCoin("SGD");

        console.log("Mock USDT deployed at:", address(mockUSDT));
        console.log("Mock SGD deployed at:", address(mockSGD));

        // 2. Deploy Vault Contract
        Vault vault = new Vault(deployer);
        console2.log("Vault deployed at:", address(vault));

        Sera sera = new Sera(deployer, vault);

        // Grant TRADER_ROLE to Sera proxy
        vault.grantRole(vault.TRADER_ROLE(), address(sera));

        console.log("Sera proxy deployed at:", address(sera));

        // 3b. Deploy non-upgradeable execution wrappers
        SeraSOR sor = new SeraSOR(address(sera));
        SeraBatcher batcher = new SeraBatcher(address(sera), address(sor));
        console.log("SeraBatcher deployed at:", address(batcher));
        console.log("SeraSOR deployed at:", address(sor));

        // 4. Configure Whitelist
        address[] memory wlTokens = new address[](2);
        wlTokens[0] = address(mockUSDT);
        wlTokens[1] = address(mockSGD);

        uint256[] memory wlAmounts = new uint256[](2);
        wlAmounts[0] = 1;
        wlAmounts[1] = 1;

        sera.batchModifyWhitelistedTokens(wlTokens, true, wlAmounts);
        console.log("Whitelisted Mock USDT and SGD in batch");

        // 5. Configure Executor
        if (executor != deployer) {
            sera.grantRole(sera.EXECUTOR_ROLE(), executor);
            console.log("Granted EXECUTOR_ROLE to:", executor);
        } else {
            console.log("Executor matches deployer (Owner), skipping explicit set.");
        }

        // Wrappers must hold EXECUTOR_ROLE in Sera to call matchOrders
        sera.grantRole(sera.EXECUTOR_ROLE(), address(batcher));
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        // SeraSOR must be set as trusted router to call settleRoutedLeg
        sera.setTrustedRouter(address(sor));
        console.log("Granted EXECUTOR_ROLE to wrappers");

        // 6. Mint initial tokens to deployer for testing
        mockUSDT.mint(deployer, 1000000 ether);
        mockSGD.mint(deployer, 1000000 ether);
        console.log("Minted 1M Mock USDT and SGD to deployer");

        vm.stopBroadcast();

        console.log("NOTE: Sera is now upgradeable via UUPS. Implementation can be upgraded by owner.");
    }
}
