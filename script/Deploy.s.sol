// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Script.sol";

import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/SeraBatcher.sol";

contract DeployScript is Script {
    function run() external {
        // 
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address:", deployer);

        // Optional: Pre-deployed Compound Timelock address for admin transfer
        address timelockAddress = vm.envOr("TIMELOCK_ADDRESS", address(0));

        vm.startBroadcast(deployerPrivateKey);

        // 
        Vault vault = new Vault(deployer);
        console.log("Vault deployed at:", address(vault));

        Sera sera = new Sera(deployer, vault);

        // 
        vault.grantRole(vault.TRADER_ROLE(), address(sera));
        console.log("Granted TRADER_ROLE to Sera");

        console.log("Sera deployed at:", address(sera));
        console.log("Vault deployed at:", address(sera.vault()));

        // Deploy SOR wrapper and wire required roles
        SeraSOR sor = new SeraSOR(address(sera));
        console.log("SeraSOR deployed at:", address(sor));

        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        console.log("Granted EXECUTOR_ROLE to SeraSOR and set it as trusted router");

        // Deploy Batcher wrapper and wire required roles
        SeraBatcher batcher = new SeraBatcher(address(sera), address(sor));
        console.log("SeraBatcher deployed at:", address(batcher));

        sera.grantRole(sera.EXECUTOR_ROLE(), address(batcher));
        console.log("Granted EXECUTOR_ROLE to SeraBatcher");

        // Configure whitelist tokens (uncomment and replace with actual addresses):
        // address[] memory wlTokens = new address[](2);
        // wlTokens[0] = 0x...; // USDT
        // wlTokens[1] = 0x...; // SGD
        // uint256[] memory wlAmounts = new uint256[](2);
        // wlAmounts[0] = 1; wlAmounts[1] = 1;
        // sera.batchModifyWhitelistedTokens(wlTokens, true, wlAmounts);

        // Production: Transfer admin to Compound Timelock and renounce deployer admin
        if (timelockAddress != address(0)) {
            bytes32 DEFAULT_ADMIN = 0x00;

            vault.grantRole(DEFAULT_ADMIN, timelockAddress);
            sera.grantRole(DEFAULT_ADMIN, timelockAddress);
            console.log("Granted DEFAULT_ADMIN_ROLE to Timelock:", timelockAddress);

            vault.renounceRole(DEFAULT_ADMIN, deployer);
            sera.renounceRole(DEFAULT_ADMIN, deployer);
            console.log("Renounced deployer admin. Timelock is now sole admin.");
        }

        vm.stopBroadcast();

        console.log("Deployment completed!");
    }
}
