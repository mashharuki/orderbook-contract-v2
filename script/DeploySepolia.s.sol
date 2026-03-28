// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Vault} from "../src/Vault.sol";
import {Sera} from "../src/Sera.sol";
import {SeraBatcher} from "../src/SeraBatcher.sol";
import {SeraSOR} from "../src/SeraSOR.sol";

contract DeploySepolia is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address executor = vm.envOr("EXECUTOR_ADDRESS", deployer);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        address pauser = vm.envOr("PAUSER_ADDRESS", deployer);
        address timelockAddress = vm.envOr("TIMELOCK_ADDRESS", address(0));

        console2.log("Deploying Sepolia contracts with deployer:", deployer);
        console2.log("Executor:", executor);
        console2.log("Treasury:", treasury);
        console2.log("Pauser:", pauser);
        console2.log("Timelock recipient:", timelockAddress);

        vm.startBroadcast(deployerPrivateKey);

        Vault vault = new Vault(deployer);
        console2.log("Vault deployed at:", address(vault));

        Sera sera = new Sera(deployer, vault);
        console2.log("Sera deployed at:", address(sera));

        vault.grantRole(vault.TRADER_ROLE(), address(sera));
        console2.log("Granted TRADER_ROLE to Sera");

        if (treasury != deployer) {
            sera.setTreasury(treasury);
            console2.log("Treasury updated:", treasury);
        }

        if (executor != deployer) {
            sera.grantRole(sera.EXECUTOR_ROLE(), executor);
            console2.log("Granted EXECUTOR_ROLE to external executor");
        }

        if (pauser != deployer) {
            sera.grantRole(sera.PAUSER_ROLE(), pauser);
            console2.log("Granted PAUSER_ROLE to:", pauser);
        }

        SeraSOR sor = new SeraSOR(address(sera));
        console2.log("SeraSOR deployed at:", address(sor));

        SeraBatcher batcher = new SeraBatcher(address(sera), address(sor));
        console2.log("SeraBatcher deployed at:", address(batcher));

        sera.grantRole(sera.EXECUTOR_ROLE(), address(batcher));
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        console2.log("Configured wrappers with EXECUTOR_ROLE and trusted router");

        uint256 whitelistCount = vm.envOr("WHITELIST_TOKEN_COUNT", uint256(0));
        if (whitelistCount > 0) {
            address[] memory tokens = new address[](whitelistCount);
            uint256[] memory minAmounts = new uint256[](whitelistCount);
            for (uint256 i = 0; i < whitelistCount; ++i) {
                string memory suffix = Strings.toString(i);

                tokens[i] = vm.envAddress(string.concat("WHITELIST_TOKEN_", suffix));
                minAmounts[i] = vm.envUint(string.concat("WHITELIST_MIN_", suffix));

                console2.log("Prepared whitelist token", tokens[i], "with min", minAmounts[i]);
            }
            sera.batchModifyWhitelistedTokens(tokens, true, minAmounts);
            console2.log("Batch whitelisted", whitelistCount, "tokens");
        }

        if (timelockAddress != address(0) && timelockAddress != deployer) {
            bytes32 DEFAULT_ADMIN = 0x00;
            vault.grantRole(DEFAULT_ADMIN, timelockAddress);
            sera.grantRole(DEFAULT_ADMIN, timelockAddress);
            vault.renounceRole(DEFAULT_ADMIN, deployer);
            sera.renounceRole(DEFAULT_ADMIN, deployer);
            console2.log("Transferred DEFAULT_ADMIN_ROLE to:", timelockAddress);
        }

        vm.stopBroadcast();
        console2.log("Sepolia deployment complete");
    }
}
