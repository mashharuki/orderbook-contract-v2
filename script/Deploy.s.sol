// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Script.sol";

import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/SeraBatcher.sol";

contract DeployScript is Script {
    function run() external {
        // 从环境变量读取部署者私钥
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address:", deployer);

        // Optional: Pre-deployed Compound Timelock address for admin transfer
        address timelockAddress = vm.envOr("TIMELOCK_ADDRESS", address(0));

        // Guard: if a timelock was specified, it must already be deployed.
        // A typo here would silently leave governance orphaned after the
        // deployer renounces DEFAULT_ADMIN_ROLE at the end of this script.
        if (timelockAddress != address(0)) {
            require(timelockAddress.code.length > 0, "Deploy: TIMELOCK_ADDRESS has no code");
        }

        vm.startBroadcast(deployerPrivateKey);

        // 部署 Vault 合约
        Vault vault = new Vault(deployer);
        console.log("Vault deployed at:", address(vault));

        Sera sera = new Sera(deployer, vault);

        // 授予 Sera TRADER_ROLE 权限
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

            // Post-conditions: deployer must no longer hold DEFAULT_ADMIN on either
            // contract, and the timelock must hold it on both. If any of these fail
            // the whole broadcast reverts, preventing a half-transferred deploy.
            require(!vault.hasRole(DEFAULT_ADMIN, deployer), "Deploy: vault deployer still admin");
            require(!sera.hasRole(DEFAULT_ADMIN, deployer), "Deploy: sera deployer still admin");
            require(vault.hasRole(DEFAULT_ADMIN, timelockAddress), "Deploy: vault timelock missing admin");
            require(sera.hasRole(DEFAULT_ADMIN, timelockAddress), "Deploy: sera timelock missing admin");
        }

        vm.stopBroadcast();

        console.log("Deployment completed!");
    }
}
