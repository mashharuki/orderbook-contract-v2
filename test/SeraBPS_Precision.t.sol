// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "../src/mock/MockStableCoinDecimals.sol";
import "./TestHelper.sol";

/**
 * @title SeraBPS_Precision_Test
 * @notice Validates the expanded BPS_DENOMINATOR (1e14) can precisely charge
 *         sub-basis-point fees, including the target $0.01 fee on a $1M order
 *         with 6-decimal tokens. Also stress-tests overflow boundaries.
 */
contract SeraBPS_Precision_Test is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    Vault public vault;
    MockStableCoin public USDC; // 6 decimals simulated via 18-decimal mock (1e12 = $1)

    address public owner;
    address public executor;
    address public taker;
    uint256 public takerPK;
    address public maker;
    uint256 public makerPK;

    // BPS_DENOMINATOR from SeraLib
    uint256 constant BPS = 100_000_000_000_000; // 1e14

    function setUp() public {
        owner = makeAddr("owner");
        executor = makeAddr("executor");
        (taker, takerPK) = makeAddrAndKey("taker");
        (maker, makerPK) = makeAddrAndKey("maker");

        USDC = new MockStableCoin("USDC");
        MockStableCoin ETH = new MockStableCoin("ETH");

        sera = _deploySera(owner);
        vault = sera.vault();
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(USDC), true, 1);
        _whitelistToken(sera, address(ETH), true, 1);
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        sera.setTreasury(owner);
        sera.setSlippageShares(0, 0, 10000, 10000); // 100% protocol spread
        vm.stopPrank();
    }

    // ========================================================================
    // 1. Core precision: $0.01 fee on $1M order (6-decimal token)
    // ========================================================================

    /// @notice With BPS_DENOMINATOR = 1e14, feeBps=1 yields exactly $0.01 on $1M.
    ///         For a 6-decimal token, $1M = 1e12 units.
    ///         fee = mulDiv(1e12, 1, 1e14) = 1e12 / 1e14 = 0.01 = 1e10 (raw units)
    ///         But with 18-decimal mock tokens: $1M = 1e24 wei.
    ///         fee = mulDiv(1e24, 1, 1e14) = 1e10 wei = $0.01 equivalent.
    function test_OneCentFeeOnMillionDollarOrder() public {
        // Math verification (pure, no contract interaction needed)
        uint256 orderAmount = 1_000_000 ether; // $1M in 18-decimal tokens
        uint256 feeBps = 1; // Minimum granularity

        uint256 fee = Math.mulDiv(orderAmount, feeBps, BPS);
        // 1e24 * 1 / 1e14 = 1e10
        assertEq(fee, 1e10, "1 bps on $1M = $0.01 (1e10 wei)");

        // For true 6-decimal token: $1M = 1e12 raw units
        uint256 orderAmount6Dec = 1e12; // $1M in 6-decimal
        uint256 fee6Dec = Math.mulDiv(orderAmount6Dec, feeBps, BPS);
        // 1e12 * 1 / 1e14 = 0.01 → rounds to 0 (floor)
        // This is expected: for 6-decimal tokens, the smallest representable
        // amount is 1 unit = $0.000001. $0.01 = 10000 units (1e4).
        // To get fee=1e4 from 1e12: feeBps = 1e4 * 1e14 / 1e12 = 1e6
        // i.e. feeBps = 1_000_000 gives exactly $0.01 on a 6-dec $1M order.
        uint256 fee6DecCent = Math.mulDiv(orderAmount6Dec, 1_000_000, BPS);
        assertEq(fee6DecCent, 10000, "1e6 bps on 6-dec $1M = 10000 units = $0.01");
    }

    function test_OneCentFeeOnTenMillionUSDCOrder_True6Decimals() public pure {
        uint256 orderAmount6Dec = 10_000_000 * 10 ** 6;
        uint256 feeBps = 100_000;

        uint256 fee = Math.mulDiv(orderAmount6Dec, feeBps, BPS);
        assertEq(fee, 10_000, "10M USDC at feeBps=100000 should charge exactly $0.01");
    }

    // ========================================================================
    // 2. Fee granularity at various levels
    // ========================================================================

    function test_FeeGranularity() public pure {
        uint256 orderAmount = 1_000_000 ether; // $1M / 18 decimals

        // 1 bps = 0.000001% = $0.01
        assertEq(Math.mulDiv(orderAmount, 1, BPS), 1e10);

        // 100 bps = 0.0001% = $1.00
        assertEq(Math.mulDiv(orderAmount, 100, BPS), 1e12);

        // 10,000 bps = 0.01% = $100 (equivalent to 1 old bps)
        assertEq(Math.mulDiv(orderAmount, 10_000, BPS), 1e14);

        // 1e12 bps = 1% = $10,000
        assertEq(Math.mulDiv(orderAmount, 1e12, BPS), 10_000 ether);

        // 1e14 bps = 100% = $1,000,000
        assertEq(Math.mulDiv(orderAmount, BPS, BPS), orderAmount);
    }

    // ========================================================================
    // 3. Overflow safety: max uint256 amounts with max fee
    // ========================================================================

    function test_OverflowSafety_MaxAmountMaxFee() public pure {
        // Math.mulDiv handles 512-bit intermediate, so this must not overflow
        uint256 maxAmount = type(uint256).max;
        uint256 maxFee = BPS; // 100%

        uint256 fee = Math.mulDiv(maxAmount, maxFee, BPS);
        assertEq(fee, maxAmount, "100% fee on max amount = max amount");
    }

    function test_OverflowSafety_LargeAmountSmallFee() public pure {
        // $1 trillion in 18-decimal = 1e30
        uint256 trillion = 1_000_000_000_000 ether;
        uint256 fee = Math.mulDiv(trillion, 1, BPS);
        // 1e30 * 1 / 1e14 = 1e16
        assertEq(fee, 1e16, "$0.01 fee on $1T = 1e16 wei");
    }

    function test_OverflowSafety_NearMaxU256() public pure {
        // Test with a very large (but not max) amount near the 256-bit boundary
        uint256 large = type(uint128).max; // ~3.4e38
        uint256 fee = Math.mulDiv(large, 50_000_000_000_000, BPS); // 50%
        assertEq(fee, large / 2, "50% of uint128.max");
    }

    // ========================================================================
    // 4. Zero fee, minimum fee, boundary fees
    // ========================================================================

    function test_ZeroFee() public pure {
        uint256 fee = Math.mulDiv(1_000_000 ether, 0, BPS);
        assertEq(fee, 0, "0 bps = 0 fee");
    }

    function test_MinimumNonZeroFee() public pure {
        // Smallest order where feeBps=1 yields a non-zero fee
        // Need: amount * 1 / 1e14 >= 1 → amount >= 1e14
        uint256 minOrder = BPS; // 1e14 wei ≈ $0.0001 for 18-dec token
        uint256 fee = Math.mulDiv(minOrder, 1, BPS);
        assertEq(fee, 1, "Minimum non-zero fee: 1 wei");
    }

    function test_BelowMinimumFee_RoundsToZero() public pure {
        // Order below the threshold where feeBps=1 rounds to zero
        uint256 smallOrder = BPS - 1;
        uint256 fee = Math.mulDiv(smallOrder, 1, BPS);
        assertEq(fee, 0, "Below minimum rounds to 0");
    }

    // ========================================================================
    // 5. On-chain settlement: $1M trade with 1 bps fee
    // ========================================================================

    /// @notice Full E2E settlement verifying the fee distribution on-chain
    function test_Settlement_OneCentFee_OnChain() public {
        MockStableCoin ETH = new MockStableCoin("ETH");
        vm.startPrank(owner);
        _whitelistToken(sera, address(ETH), true, 1);
        vm.stopPrank();

        uint256 orderAmount = 1_000_000 ether; // $1M
        _mintAndDeposit(taker, address(USDC), orderAmount, sera);
        _mintAndDeposit(maker, address(ETH), orderAmount, sera);

        // Taker: 1M USDC -> 1M ETH. feeBps = 1 (1 unit out of 1e14)
        // Maker: 1M ETH -> 1M USDC. feeBps = 0.
        // Zero spread (exact pricing).
        Order memory takerOrder = Order({
            user: taker, fromToken: address(USDC), toToken: address(ETH),
            fromAmount: orderAmount, toAmount: orderAmount, initialDepositAmount: 0,
            feeBps: 1, recipient: taker,
            expiration: uint48(block.timestamp + 1 days), uuid: 1
        });
        Order memory makerOrder = Order({
            user: maker, fromToken: address(ETH), toToken: address(USDC),
            fromAmount: orderAmount, toAmount: orderAmount, initialDepositAmount: 0,
            feeBps: 0, recipient: maker,
            expiration: uint48(block.timestamp + 1 days), uuid: 2
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(
            takerOrder, bytes(""), orderAmount,
            makerOrder, _signOrder(makerPK, makerOrder, sera), orderAmount
        );
        bytes memory sig = _signIntent(
            takerPK, taker, address(USDC), address(ETH), type(uint256).max, 1, taker, 0,
            block.timestamp, uint48(block.timestamp + 1 days), sera
        );

        vm.prank(executor);
        sor.executeIntent(
            matches, sig,
            IntentParams(taker, address(USDC), address(ETH), type(uint256).max, 1, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)),
            uint8(3), 0, bytes("")
        );

        // Expected fee: mulDiv(1e24, 1, 1e14) = 1e10
        uint256 expectedFee = Math.mulDiv(orderAmount, 1, BPS);
        assertEq(expectedFee, 1e10, "Computed fee = 1e10");

        // Taker receives: orderAmount - fee
        uint256 takerReceived = ETH.balanceOf(taker);
        assertEq(takerReceived, orderAmount - expectedFee, "Taker got $1M minus $0.01 fee");

        // Protocol treasury received the fee
        uint256 treasuryETH = vault.balanceOf(address(ETH), owner);
        assertEq(treasuryETH, expectedFee, "Treasury captured exactly $0.01 fee");

        // Solvency check
        uint256 totalLedger = vault.balanceOf(address(ETH), taker)
            + vault.balanceOf(address(ETH), maker)
            + vault.balanceOf(address(ETH), owner);
        assertGe(ETH.balanceOf(address(vault)), totalLedger, "Vault solvent");
    }

    function test_Settlement_TenMillionUSDC_OneCentFee_True6Decimals() public {
        MockStableCoinDecimals USDC6 = new MockStableCoinDecimals("USDC6", 6);
        MockStableCoin ETH18 = new MockStableCoin("ETH18");

        vm.startPrank(owner);
        _whitelistToken(sera, address(USDC6), true, 1);
        _whitelistToken(sera, address(ETH18), true, 1);
        vm.stopPrank();

        uint256 usdcAmount = 10_000_000 * 10 ** 6;
        uint256 ethAmount = 10_000_000 ether;
        uint256 feeBps = 100_000;

        _mintAndDeposit(taker, address(ETH18), ethAmount, sera);
        _mintAndDeposit(maker, address(USDC6), usdcAmount, sera);

        Order memory takerOrder = Order({
            user: taker, fromToken: address(ETH18), toToken: address(USDC6),
            fromAmount: ethAmount, toAmount: usdcAmount, initialDepositAmount: 0,
            feeBps: uint48(feeBps), recipient: taker,
            expiration: uint48(block.timestamp + 1 days), uuid: 10
        });
        Order memory makerOrder = Order({
            user: maker, fromToken: address(USDC6), toToken: address(ETH18),
            fromAmount: usdcAmount, toAmount: ethAmount, initialDepositAmount: 0,
            feeBps: 0, recipient: maker,
            expiration: uint48(block.timestamp + 1 days), uuid: 11
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(
            takerOrder, bytes(""), ethAmount,
            makerOrder, _signOrder(makerPK, makerOrder, sera), usdcAmount
        );
        bytes memory sig = _signIntent(
            takerPK, taker, address(ETH18), address(USDC6), type(uint256).max, 1, taker, 0,
            block.timestamp, uint48(block.timestamp + 1 days), sera
        );

        vm.prank(executor);
        sor.executeIntent(
            matches, sig,
            IntentParams(taker, address(ETH18), address(USDC6), type(uint256).max, 1, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)),
            uint8(2), 0, bytes("")
        );

        uint256 expectedFee = Math.mulDiv(usdcAmount, feeBps, BPS);
        assertEq(expectedFee, 10_000, "Expected a one-cent fee in 6-decimal USDC units");

        uint256 takerReceived = USDC6.balanceOf(taker);
        assertEq(takerReceived, usdcAmount - expectedFee, "Taker should receive 10M USDC minus $0.01 fee");

        uint256 treasuryUsdc = vault.balanceOf(address(USDC6), owner);
        assertEq(treasuryUsdc, expectedFee, "Treasury should capture exactly 10000 raw units = $0.01");

        uint256 totalLedger = vault.balanceOf(address(USDC6), taker)
            + vault.balanceOf(address(USDC6), maker)
            + vault.balanceOf(address(USDC6), owner);
        assertGe(USDC6.balanceOf(address(vault)), totalLedger, "Vault solvent for 6-decimal fee token");
    }

    // ========================================================================
    // 6. uint48 boundary: max feeBps = BPS_DENOMINATOR = 1e14
    // ========================================================================

    function test_MaxFeeBps_IsExactly100Percent() public pure {
        // uint48 max = 281474976710655 ≈ 2.81e14
        // BPS_DENOMINATOR = 1e14 = 100000000000000
        // Verify it fits in uint48
        assertLe(BPS, type(uint48).max, "BPS_DENOMINATOR fits in uint48");

        // 100% fee
        uint256 fee = Math.mulDiv(1000 ether, BPS, BPS);
        assertEq(fee, 1000 ether, "100% fee = full amount");
    }

    function test_FeeBps_JustOverMax_Reverts() public {
        _mintAndDeposit(taker, address(USDC), 1000 ether, sera);

        MockStableCoin ETH = new MockStableCoin("ETH");
        vm.prank(owner);
        _whitelistToken(sera, address(ETH), true, 1);
        _mintAndDeposit(maker, address(ETH), 1000 ether, sera);

        // feeBps = BPS + 1 = 100000000000001 (still fits in uint48)
        Order memory takerOrder = Order({
            user: taker, fromToken: address(USDC), toToken: address(ETH),
            fromAmount: 1000 ether, toAmount: 1000 ether, initialDepositAmount: 0,
            feeBps: uint48(BPS + 1), recipient: taker,
            expiration: uint48(block.timestamp + 1 days), uuid: 1
        });
        Order memory makerOrder = Order({
            user: maker, fromToken: address(ETH), toToken: address(USDC),
            fromAmount: 1000 ether, toAmount: 1000 ether, initialDepositAmount: 0,
            feeBps: 0, recipient: maker,
            expiration: uint48(block.timestamp + 1 days), uuid: 2
        });

        MatchData memory m = MatchData(
            takerOrder, _signOrder(takerPK, takerOrder, sera), 1000 ether,
            makerOrder, _signOrder(makerPK, makerOrder, sera), 1000 ether
        );

        vm.prank(executor);
        vm.expectRevert(Sera.InvalidFee.selector);
        sera.matchOrders(m, type(uint256).max);
    }

    // ========================================================================
    // 7. Fuzz: arbitrary feeBps always produces fee <= amount
    // ========================================================================

    function testFuzz_FeeNeverExceedsAmount(uint48 feeBps, uint128 amount) public pure {
        vm.assume(feeBps <= BPS);
        vm.assume(amount > 0);

        uint256 fee = Math.mulDiv(uint256(amount), uint256(feeBps), BPS);
        assertLe(fee, amount, "Fee must never exceed amount");
    }

    function testFuzz_FeeMonotonicallyIncreases(uint48 fee1, uint48 fee2, uint128 amount) public pure {
        vm.assume(fee1 <= fee2);
        vm.assume(fee2 <= BPS);
        vm.assume(amount > 0);

        uint256 f1 = Math.mulDiv(uint256(amount), uint256(fee1), BPS);
        uint256 f2 = Math.mulDiv(uint256(amount), uint256(fee2), BPS);
        assertLe(f1, f2, "Higher feeBps must produce >= fee");
    }
}
