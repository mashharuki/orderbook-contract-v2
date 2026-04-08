// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "./TestHelper.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";

/**
 * @title SeraSOR_PermitTests
 * @notice Comprehensive test suite for executeSorWithPermit:
 *         - Happy path: standard 65-byte permit + wallet swap
 *         - Happy path: compact 64-byte EIP-2098 permit
 *         - Front-run DoS protection (permit already consumed)
 *         - Pre-approved user (permit skipped, allowance sufficient)
 *         - Vault-only flow (initialDepositAmount = 0, no permit needed)
 *         - Bad permit signature length (reverts)
 *         - Expired permit deadline (graceful degradation via try/catch if allowance exists)
 *         - Non-executor caller (reverts)
 *         - Replay protection (SOR uuid reuse)
 */
contract SeraSOR_PermitTests is TestHelper {
    MockStableCoin public usdc;
    MockStableCoin public eth;

    Vault public v;
    SeraSOR public sor;

    address public taker;
    uint256 public takerPK;
    address public maker;
    uint256 public makerPK;
    address public executor;
    uint256 public executorPK;
    address public owner;
    uint256 public ownerPK;

    function setUp() public {
        // Keys
        (taker, takerPK) = makeAddrAndKey("taker");
        (maker, makerPK) = makeAddrAndKey("maker");
        (executor, executorPK) = makeAddrAndKey("executor");
        (owner, ownerPK) = makeAddrAndKey("owner");

        // Deploy tokens
        usdc = new MockStableCoin("USDC");
        eth = new MockStableCoin("ETH");

        // Deploy protocol
        v = new Vault(owner);
        Sera sera_ = new Sera(owner, v);
        sor = new SeraSOR(address(sera_));

        // Grant roles
        vm.startPrank(owner);
        v.grantRole(v.TRADER_ROLE(), address(sera_));
        sera_.grantRole(sera_.EXECUTOR_ROLE(), executor);
        sera_.setTrustedRouter(address(sor));

        // Whitelist tokens
        address[] memory tokens = new address[](2);
        uint256[] memory minAmounts = new uint256[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(eth);
        minAmounts[0] = 0;
        minAmounts[1] = 0;
        sera_.batchModifyWhitelistedTokens(tokens, true, minAmounts);
        vm.stopPrank();

        // Fund maker with ETH in vault for matching
        _mintAndDeposit(maker, address(eth), 100 ether, sera_);
    }

    function _sera() internal view returns (Sera) {
        return Sera(address(sor.sera()));
    }

    function _buildSingleLegSwap(uint256 inputAmount, uint256 outputAmount, uint256 takerUuid, uint256 makerUuid)
        internal view returns (MatchData[] memory matches, bytes memory makerSig)
    {
        Order memory takerOrder = Order({
            user: taker,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: inputAmount,
            toAmount: outputAmount,
            initialDepositAmount: inputAmount, // Full amount from wallet
            uuid: takerUuid
        });
        Order memory makerOrder = Order({
            user: maker,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: address(0), // credit to vault
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: outputAmount,
            toAmount: inputAmount,
            initialDepositAmount: 0,
            uuid: makerUuid
        });

        makerSig = _signOrder(makerPK, makerOrder, _sera());
        matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), inputAmount, makerOrder, makerSig, outputAmount);
    }

    // =========================================================================
    // HAPPY PATH: Standard 65-byte permit + wallet swap
    // =========================================================================
    function test_permitSwap_Standard65Byte() public {
        // Mint USDC to taker's wallet (NOT deposited to vault)
        usdc.mint(taker, 1000 ether);

        // Build trade: 1000 USDC → 10 ETH
        (MatchData[] memory matches, ) = _buildSingleLegSwap(1000 ether, 10 ether, 1, 2);

        // Sign SOR intent
        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 100, uint48(block.timestamp + 1 days), _sera()
        );

        // Sign EIP-2612 permit (spender = SeraSOR)
        bytes memory permitSig = _signPermit(takerPK, address(usdc), address(sor), 1000 ether, block.timestamp + 1 days);

        // Execute
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 100, uint48(block.timestamp + 1 days)), 3, block.timestamp + 1 days, permitSig);

        // Verify: taker received ETH in wallet
        assertEq(eth.balanceOf(taker), 10 ether, "Taker should receive 10 ETH");
        // Verify: taker's USDC was spent
        assertEq(usdc.balanceOf(taker), 0, "Taker should have 0 USDC left");
    }

    // =========================================================================
    // HAPPY PATH: Compact 64-byte EIP-2098 permit
    // =========================================================================
    function test_permitSwap_Compact64Byte_EIP2098() public {
        usdc.mint(taker, 1000 ether);

        (MatchData[] memory matches, ) = _buildSingleLegSwap(1000 ether, 10 ether, 1, 2);

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 200, uint48(block.timestamp + 1 days), _sera()
        );

        // Generate standard permit, then compact to 64-byte EIP-2098
        bytes memory stdPermit = _signPermit(takerPK, address(usdc), address(sor), 1000 ether, block.timestamp + 1 days);
        bytes32 r;
        bytes32 s;
        uint8 vv;
        assembly {
            r := mload(add(stdPermit, 0x20))
            s := mload(add(stdPermit, 0x40))
            vv := byte(0, mload(add(stdPermit, 0x60)))
        }
        // Encode as EIP-2098: vs = (v - 27) << 255 | s
        bytes32 vs = bytes32((uint256(vv - 27) << 255) | uint256(s));
        bytes memory compactSig = abi.encodePacked(r, vs);
        assertEq(compactSig.length, 64, "Compact sig must be 64 bytes");

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 200, uint48(block.timestamp + 1 days)), 3, block.timestamp + 1 days, compactSig);

        assertEq(eth.balanceOf(taker), 10 ether, "Taker should receive 10 ETH via compact permit");
        assertEq(usdc.balanceOf(taker), 0, "All USDC spent");
    }

    // =========================================================================
    // Front-run DoS protection: permit already consumed
    // =========================================================================
    function test_permitSwap_FrontRunProtection() public {
        usdc.mint(taker, 1000 ether);

        (MatchData[] memory matches, ) = _buildSingleLegSwap(1000 ether, 10 ether, 1, 2);

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 300, uint48(block.timestamp + 1 days), _sera()
        );

        bytes memory permitSig = _signPermit(takerPK, address(usdc), address(sor), 1000 ether, block.timestamp + 1 days);

        // Simulate front-runner calling permit() directly
        {
            bytes32 r;
            bytes32 s;
            uint8 vv;
            assembly {
                r := mload(add(permitSig, 0x20))
                s := mload(add(permitSig, 0x40))
                vv := byte(0, mload(add(permitSig, 0x60)))
            }
            // Front-runner calls permit directly
            usdc.permit(taker, address(sor), 1000 ether, block.timestamp + 1 days, vv, r, s);
        }

        // Now executor calls executeSorWithPermit — permit will fail but allowance exists
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 300, uint48(block.timestamp + 1 days)), 3, block.timestamp + 1 days, permitSig);

        // Should succeed regardless of front-run
        assertEq(eth.balanceOf(taker), 10 ether, "Swap should succeed despite front-run");
    }

    // =========================================================================
    // Pre-approved user: permit skipped when allowance sufficient
    // =========================================================================
    function test_permitSwap_SkipsPermitWhenAllowanceSufficient() public {
        usdc.mint(taker, 1000 ether);

        // Pre-approve SeraSOR
        vm.prank(taker);
        usdc.approve(address(sor), type(uint256).max);

        (MatchData[] memory matches, ) = _buildSingleLegSwap(1000 ether, 10 ether, 1, 2);

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 400, uint48(block.timestamp + 1 days), _sera()
        );

        // Pass any bytes as permit sig — it should never be decoded
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 400, uint48(block.timestamp + 1 days)), 3, block.timestamp + 1 days, bytes(""));

        assertEq(eth.balanceOf(taker), 10 ether, "Swap succeeds with pre-approval");
    }

    // =========================================================================
    // Vault-only flow: initialDepositAmount = 0, no wallet pull or permit
    // =========================================================================
    function test_permitSwap_VaultOnlyFlow_NoPermitNeeded() public {
        // Deposit USDC into vault for taker (traditional flow)
        _mintAndDeposit(taker, address(usdc), 1000 ether, _sera());

        // Build swap with initialDepositAmount = 0 (vault-only)
        Order memory takerOrder = Order({
            user: taker,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0, // VAULT ONLY
            uuid: 1
        });
        Order memory makerOrder = Order({
            user: maker,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: address(0),
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            uuid: 2
        });

        bytes memory makerSig = _signOrder(makerPK, makerOrder, _sera());
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, makerSig, 10 ether);

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth), 0, 0, taker, 0, 500, uint48(block.timestamp + 1 days), _sera()
        );

        // Call executeSorWithPermit with empty permit — should work like executeIntent
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(usdc), address(eth), 0, 0, taker, 0, 500, uint48(block.timestamp + 1 days)), 3, block.timestamp + 1 days, bytes(""));

        assertEq(eth.balanceOf(taker), 10 ether, "Vault-only flow should work with empty permit");
    }

    // =========================================================================
    // Bad permit signature length (reverts)
    // =========================================================================
    function test_permitSwap_BadSigLength_Reverts() public {
        usdc.mint(taker, 1000 ether);

        (MatchData[] memory matches, ) = _buildSingleLegSwap(1000 ether, 10 ether, 1, 2);

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 600, uint48(block.timestamp + 1 days), _sera()
        );

        // 63-byte sig (invalid length)
        bytes memory badSig = new bytes(63);

        vm.prank(executor);
        vm.expectRevert(Sera.InvalidSignatureLength.selector);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 600, uint48(block.timestamp + 1 days)), 3, block.timestamp + 1 days, badSig);
    }

    // =========================================================================
    // Non-executor caller (reverts)
    // =========================================================================
    function test_permitSwap_NonExecutor_Reverts() public {
        usdc.mint(taker, 1000 ether);

        (MatchData[] memory matches, ) = _buildSingleLegSwap(1000 ether, 10 ether, 1, 2);

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 700, uint48(block.timestamp + 1 days), _sera()
        );
        bytes memory permitSig = _signPermit(takerPK, address(usdc), address(sor), 1000 ether, block.timestamp + 1 days);

        // Random user tries to call
        vm.prank(taker);
        vm.expectRevert();
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 700, uint48(block.timestamp + 1 days)), 3, block.timestamp + 1 days, permitSig);
    }

    // =========================================================================
    // Replay protection: reusing SOR uuid
    // =========================================================================
    function test_permitSwap_ReplayProtection_Reverts() public {
        usdc.mint(taker, 2000 ether);

        {
            (MatchData[] memory matches, ) = _buildSingleLegSwap(1000 ether, 10 ether, 1, 2);

            bytes memory sorSig = _signIntent(
                takerPK, taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 800, uint48(block.timestamp + 1 days), _sera()
            );
            bytes memory permitSig = _signPermit(takerPK, address(usdc), address(sor), 1000 ether, block.timestamp + 1 days);

            vm.prank(executor);
            sor.executeIntent(matches, sorSig, IntentParams(taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 800, uint48(block.timestamp + 1 days)), 3, block.timestamp + 1 days, permitSig);
        }

        // Fund maker again and try replay with same uuid
        _mintAndDeposit(maker, address(eth), 10 ether, _sera());

        {
            (MatchData[] memory matches2, ) = _buildSingleLegSwap(1000 ether, 10 ether, 3, 4);

            bytes memory sorSig2 = _signIntent(
                takerPK, taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 800, uint48(block.timestamp + 1 days), _sera() // same uuid = 800
            );
            bytes memory permitSig2 = _signPermit(takerPK, address(usdc), address(sor), 1000 ether, block.timestamp + 1 days);

            vm.prank(executor);
            vm.expectRevert(Sera.UuidAlreadyUsed.selector);
            sor.executeIntent(matches2, sorSig2, IntentParams(taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 800, uint48(block.timestamp + 1 days)), 3, block.timestamp + 1 days, permitSig2);
        }
    }

    // =========================================================================
    // Partial wallet deposit with permit
    // =========================================================================
    function test_permitSwap_PartialWalletDeposit() public {
        // Taker has 500 USDC in wallet + 500 in vault
        usdc.mint(taker, 500 ether);
        _mintAndDeposit(taker, address(usdc), 500 ether, _sera());

        // Build swap where only 500 is from wallet
        Order memory takerOrder = Order({
            user: taker,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 500 ether, // Only 500 from wallet
            uuid: 1
        });
        Order memory makerOrder = Order({
            user: maker,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: address(0),
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            uuid: 2
        });

        bytes memory makerSig = _signOrder(makerPK, makerOrder, _sera());
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, makerSig, 10 ether);

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 500 ether, 900, uint48(block.timestamp + 1 days), _sera()
        );
        bytes memory permitSig = _signPermit(takerPK, address(usdc), address(sor), 500 ether, block.timestamp + 1 days);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 500 ether, 900, uint48(block.timestamp + 1 days)), 3, block.timestamp + 1 days, permitSig);

        assertEq(eth.balanceOf(taker), 10 ether, "Taker receives 10 ETH");
        assertEq(usdc.balanceOf(taker), 0, "All wallet USDC spent");
        assertEq(v.balanceOf(address(usdc), taker), 0, "All vault USDC spent");
    }

    // =========================================================================
    // Expired permit but sufficient allowance (graceful fallback)
    // =========================================================================
    function test_permitSwap_ExpiredPermitWithSufficientAllowance() public {
        usdc.mint(taker, 1000 ether);

        // Pre-approve enough allowance
        vm.prank(taker);
        usdc.approve(address(sor), 1000 ether);

        (MatchData[] memory matches, ) = _buildSingleLegSwap(1000 ether, 10 ether, 1, 2);

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 1000, uint48(block.timestamp + 1 days), _sera()
        );

        // Sign permit with already-expired deadline
        bytes memory expiredPermit = _signPermit(takerPK, address(usdc), address(sor), 1000 ether, block.timestamp - 1);

        // Should succeed because allowance is already sufficient (permit skipped entirely)
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 1000, uint48(block.timestamp + 1 days)), 3, block.timestamp - 1, expiredPermit);

        assertEq(eth.balanceOf(taker), 10 ether, "Swap succeeds with expired permit + existing allowance");
    }

    // =========================================================================
    // Expired permit without allowance (reverts at safeTransferFrom)
    // =========================================================================
    function test_permitSwap_ExpiredPermitNoAllowance_Reverts() public {
        usdc.mint(taker, 1000 ether);

        (MatchData[] memory matches, ) = _buildSingleLegSwap(1000 ether, 10 ether, 1, 2);

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 1100, uint48(block.timestamp + 1 days), _sera()
        );

        // Expired permit, no existing allowance
        bytes memory expiredPermit = _signPermit(takerPK, address(usdc), address(sor), 1000 ether, block.timestamp - 1);

        // Should revert at safeTransferFrom because permit failed and no allowance
        vm.prank(executor);
        vm.expectRevert(); // ERC20InsufficientAllowance
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 1000 ether, 1100, uint48(block.timestamp + 1 days)), 3, block.timestamp - 1, expiredPermit);
    }

    // =========================================================================
    // Empty permit + empty matches (reverts EmptyRoute, not permit)
    // =========================================================================
    function test_permitSwap_EmptyRoute_Reverts() public {
        MatchData[] memory matches = new MatchData[](0);
        bytes memory sorSig = new bytes(65);

        vm.prank(executor);
        vm.expectRevert(SeraSOR.EmptyRoute.selector);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(usdc), address(eth), 0, 0, taker, 0, 1200, uint48(block.timestamp + 1 days)), 3, block.timestamp + 1 days, bytes(""));
    }

    // =========================================================================
    // Expired SOR deadline (reverts MatchExpired)
    // =========================================================================
    function test_permitSwap_ExpiredSORDeadline_Reverts() public {
        usdc.mint(taker, 1000 ether);

        (MatchData[] memory matches, ) = _buildSingleLegSwap(1000 ether, 10 ether, 1, 2);

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 0, 1300, uint48(block.timestamp - 1), _sera()
        );
        bytes memory permitSig = _signPermit(takerPK, address(usdc), address(sor), 1000 ether, block.timestamp + 1 days);

        vm.prank(executor);
        vm.expectRevert(MatchExpired.selector);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(usdc), address(eth), 1000 ether, 10 ether, taker, 0, 1300, uint48(block.timestamp - 1)), 3, block.timestamp + 1 days, permitSig);
    }
}
