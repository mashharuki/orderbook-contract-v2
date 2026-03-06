// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/Vault.sol";
import "../src/Sera.sol";

/**
 * @title DeployAll
 * @notice 部署 Sera 合约
 * 部署流程：
 * 1. 运行此脚本部署 Vault 和 Sera
 *
 * 部署命令：
 * forge script script/DeployAll.s.sol:DeployAllScript \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --verify
 *
 * 环境变量：
 * - PRIVATE_KEY: 部署者私钥
 */
contract DeployAllScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address owner = deployer;

        console.log("Deployer:", deployer);
        console.log("Owner:", owner);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. 部署 Vault
        Vault vault = new Vault(owner);
        console.log("Vault deployed at:", address(vault));

        // 2. 部署 Sera
        Sera sera = new Sera(owner, vault);

        // 授予 Sera TRADER_ROLE 权限
        vault.grantRole(vault.TRADER_ROLE(), address(sera));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Sera:          ", address(sera));
        console.log("Vault:         ", address(vault));
        console.log("Owner:         ", owner);
        console.log("");
    }
}
