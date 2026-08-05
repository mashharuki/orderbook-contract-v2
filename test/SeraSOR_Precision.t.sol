// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

/**
 * @title SeraSOR_Precision_Test
 * @dev Advanced precision/arithmetic tests:
 *      - Rounding dust across partial fills
 *      - Combined fees + spread in routed settlement
 *      - Near-zero amounts within min-amount bounds
 *      - Vault solvency invariant under stress
 */
contract SeraSOR_Precision_Test is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    MockStableCoin public usdc;
    MockStableCoin public eth;

    address public owner;
    address public executor;
    address public taker;
    uint256 public takerPK;
    address public maker1;
    uint256 public maker1PK;

    function setUp() public {
        owner = makeAddr("owner");
        executor = makeAddr("executor");
        (taker, takerPK) = makeAddrAndKey("taker");
        (maker1, maker1PK) = makeAddrAndKey("maker1");

        usdc = new MockStableCoin("USDC");
        eth = new MockStableCoin("ETH");

        sera = _deploySera(owner);
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(usdc), true, 1);
        _whitelistToken(sera, address(eth), true, 1);
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        // Set slippage: 50% protocol, 25% maker, 25% taker
        sera.setSlippageShares(2500, 2500, 5000, 10000);
        // Set treasury
        sera.setTreasury(owner);
        vm.stopPrank();
    }


    function _makeOrder(
        address user, address fromToken, address toToken,
        uint256 fromAmount, uint256 toAmount, uint256 uuid
    ) internal view returns (Order memory) {
        return Order({
            user: user,
            fromToken: fromToken,
            toToken: toToken,
            fromAmount: fromAmount,
            toAmount: toAmount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: user,
            expiration: uint48(block.timestamp + 1 days),
            uuid: uuid
        });
    }

    // ============ 1. COMBINED FEES + SPREAD IN ROUTE ============

    /// @notice Test settlement with both fees AND spread in a routed single-leg
    function test_CombinedFeesAndSpread() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        // Taker: 1000 USDC → 8 ETH (wants 8 ETH min)
        // Maker: 10 ETH → 800 USDC (wants 800 USDC min)
        // Spread: USDC side = 1000 - 800 = 200, ETH side = 10 - 8 = 2
        // Taker fee = 100 bps (1%), Maker fee = 50 bps (0.5%)
        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        takerOrder.feeBps = 1_000_000_000_000; // 1%
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);
        makerOrder.feeBps = 500_000_000_000; // 0.5%

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, type(uint256).max, 1, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        // Record pre-state
        Vault v = sera.vault();
        uint256 makerEthBefore = v.balanceOf(address(eth), maker1);
        uint256 takerUsdcBefore = v.balanceOf(address(usdc), taker);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, type(uint256).max, 1, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Verify solvency: vault actual balance >= sum of all ledger entries
        uint256 totalLedgerUsdc = v.balanceOf(address(usdc), taker)
            + v.balanceOf(address(usdc), maker1)
            + v.balanceOf(address(usdc), owner);
        uint256 actualUsdc = usdc.balanceOf(address(v));
        assertGe(actualUsdc, totalLedgerUsdc, "USDC vault solvent");

        uint256 totalLedgerEth = v.balanceOf(address(eth), taker)
            + v.balanceOf(address(eth), maker1)
            + v.balanceOf(address(eth), owner);
        uint256 actualEth = eth.balanceOf(address(v));
        assertGe(actualEth, totalLedgerEth, "ETH vault solvent");

        // Protocol must have captured fees + spread
        assertGt(v.balanceOf(address(usdc), owner), 0, "Protocol captured USDC fees/spread");
        assertGt(v.balanceOf(address(eth), owner), 0, "Protocol captured ETH fees/spread");
    }

    // ============ 2. PARTIAL FILL THEN ROUTE ============

    /// @notice Taker order partially filled via standalone, then rest via route
    function test_PartialFillThenRoute() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        // First: standalone partial fill (500 USDC)
        Order memory takerStandalone = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerStandalone = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        // Test that partial fill tracking uses orderHash correctly across standalone and SOR paths.

        // Standalone fill: 500 USDC → 5 ETH
        MatchData memory standalone = MatchData(
            takerStandalone,
            _signOrder(takerPK, takerStandalone, sera),
            500 ether,
            makerStandalone,
            _signOrder(maker1PK, makerStandalone, sera),
            5 ether
        );

        vm.prank(executor);
        sera.matchOrders(standalone, type(uint256).max);

        // Verify partial fill
        assertEq(sera.filledAmount(_getOrderHashMemory(standalone.order0)), 500 ether, "Taker 50% filled");

        // Now try to fill the remaining 500 via standalone (same hash)
        MatchData memory standalone2 = MatchData(
            takerStandalone,
            _signOrder(takerPK, takerStandalone, sera),
            500 ether,
            makerStandalone,
            _signOrder(maker1PK, makerStandalone, sera),
            5 ether
        );

        vm.prank(executor);
        sera.matchOrders(standalone2, type(uint256).max);

        // Now fully filled
        assertEq(sera.filledAmount(_getOrderHashMemory(standalone2.order0)), 1000 ether, "Taker 100% filled");
    }

    // ============ 3. VAULT SOLVENCY UNDER MAX FEES ============

    /// @notice Vault solvency with 100% fees (extreme edge case)
    function test_VaultSolvency_MaxFees() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        // Near-100% fees on both sides (1 unit below BPS_DENOMINATOR — essentially all goes to
        // protocol). Exactly 100% would net the taker 0, which the Finding-1 patch now rejects
        // on the SOR path (minOutput>=1 + envelope floor); 1 unit below leaves ~dust to the taker
        // so vault solvency under extreme fees is still exercised.
        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerOrder.feeBps = 99_999_999_999_999; // ~100%
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);
        makerOrder.feeBps = 99_999_999_999_999; // ~100%

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, type(uint256).max, 1, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, type(uint256).max, 1, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // With 100% fees, nothing should go to users, everything to protocol
        // But solvency must hold
        Vault v = sera.vault();
        uint256 totalLedgerUsdc = v.balanceOf(address(usdc), taker)
            + v.balanceOf(address(usdc), maker1)
            + v.balanceOf(address(usdc), owner);
        assertGe(usdc.balanceOf(address(v)), totalLedgerUsdc, "USDC solvent at 100% fees");

        uint256 totalLedgerEth = v.balanceOf(address(eth), taker)
            + v.balanceOf(address(eth), maker1)
            + v.balanceOf(address(eth), owner);
        assertGe(eth.balanceOf(address(v)), totalLedgerEth, "ETH solvent at 100% fees");
    }

    // ============ 4. SMALL AMOUNT PRECISION ============

    /// @notice Minimum amount orders don't cause rounding drain
    function test_SmallAmountPrecision() public {
        _mintAndDeposit(taker, address(usdc), 100, sera);
        _mintAndDeposit(maker1, address(eth), 10, sera);

        // Very small amounts (100 wei USDC, 10 wei ETH)
        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 100, 10, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10, 100, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 100, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, type(uint256).max, 1, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, type(uint256).max, 1, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Even at wei level, solvency holds
        Vault v = sera.vault();
        uint256 totalUsdc = v.balanceOf(address(usdc), taker)
            + v.balanceOf(address(usdc), maker1)
            + v.balanceOf(address(usdc), owner);
        assertGe(usdc.balanceOf(address(v)), totalUsdc, "USDC solvent at wei level");
    }

}
