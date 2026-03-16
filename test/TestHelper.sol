// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/mock/MockStableCoin.sol";

/**
 * @title TestHelper — Shared test utilities for all Sera test files
 * @dev Provides common helpers: signing, minting, depositing, order creation.
 *      All test contracts should inherit from this instead of Test directly.
 */
abstract contract TestHelper is Test {
    // ORDER_TYPEHASH is imported from SeraLib.sol globally via Sera.sol

    /**
     * @notice Sign an order with EIP-712 typed data
     * @param pk The signer's private key
     * @param p The order to sign
     * @param sera The Sera contract (for domain separator params)
     */
    function _signOrder(uint256 pk, Order memory p, Sera sera) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                p.user,
                p.expiration,
                p.feeBps,
                p.recipient,
                p.fromToken,
                p.toToken,
                p.fromAmount,
                p.toAmount,
                p.initialDepositAmount,
                p.routeHash,
                p.uuid
            )
        );
        bytes32 domainSeparator = sera.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @notice Mint tokens and deposit into vault for a user
     */
    function _mintAndDeposit(address user, address token, uint256 amount, Sera sera) internal {
        Vault v = sera.vault();
        MockStableCoin(token).mint(user, amount);
        vm.startPrank(user);
        IERC20(token).approve(address(v), amount);
        sera.depositFund(token, user, amount);
        vm.stopPrank();
    }

    /**
     * @notice Mint tokens to a user's wallet (no deposit)
     */
    function _mintInWallet(address user, address token, uint256 amount) internal {
        MockStableCoin(token).mint(user, amount);
    }

    /**
     * @notice Sign a permit (EIP-2612) for a token
     */
    function _signPermit(uint256 pk, address token, address spender, uint256 amount, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 DOMAIN_SEPARATOR = MockStableCoin(token).DOMAIN_SEPARATOR();
        uint256 nonce = MockStableCoin(token).nonces(vm.addr(pk));

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, vm.addr(pk), spender, amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @notice Sign a route hash (for SOR tests)
     */
    function _signRoute(uint256 pk, bytes32 routeHash, Sera sera) internal view returns (bytes memory) {
        bytes32 domainSeparator = sera.DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(abi.encode(keccak256("Route(bytes32 routeHash)"), routeHash));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @notice Deploy Sera directly and return the instance
     */
    function _deploySera(address owner) internal returns (Sera) {
        // 1. Deploy Vault
        Vault vault = new Vault(owner);

        // 2. Deploy Sera and initialize with Vault
        Sera sera = new Sera(owner, vault);

        // 3. Grant TRADER_ROLE to Sera engine
        vm.startPrank(owner);
        vault.grantRole(vault.TRADER_ROLE(), address(sera));
        vm.stopPrank();

        return sera;
    }

    /**
     * @notice Helper to whitelist a single token using the batch command
     */
    function _whitelistToken(Sera sera, address token, bool isWhitelisted, uint256 minAmount) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = minAmount;
        sera.batchModifyWhitelistedTokens(tokens, isWhitelisted, amounts);
    }
}
