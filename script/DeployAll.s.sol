// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/Vault.sol";
import "../src/Sera.sol";

/**
 * @title DeployAll
 * @notice 
 * 
 * 1. 
 *
 * 
 * forge script script/DeployAll.s.sol:DeployAllScript \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --verify
 *
 * 
 * - PRIVATE_KEY
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

        // 
        Vault vault = new Vault(owner);
        console.log("Vault deployed at:", address(vault));

        // 
        Sera sera = new Sera(owner, vault);

        // 
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
