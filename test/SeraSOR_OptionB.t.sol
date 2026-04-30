// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

/**
 * @title SeraSOR_OptionB_Test
 * @dev Tests covering the Option B change: line 92 (ExcessiveInput proxy check) removed
 *      and the universal transient zero-balance check at the end of executeIntent.
 *      Pinned scenarios:
 *        - Single-leg over-deposit must revert TransientBalanceNotZero (was: ExcessiveInput).
 *        - Multi-leg split-input where wallet pull spans multiple legs must succeed.
 *        - Multi-leg split-input with partial consumption reverts TransientBalanceNotZero.
 *        - Adversarial no-fund-leak on revert: balances bit-identical pre/post.
 *        - Sentinel + non-zero initialDepositAmount on first leg.
 *        - Boundary: initialDepositAmount == matchAmount0.
 *        - Vault top-up: initialDepositAmount < matchAmount0 with vault contribution.
 *        - Gas overhead bound for single-leg.
 */
contract SeraSOR_OptionB_Test is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    Vault public v;
    MockStableCoin public usdc;
    MockStableCoin public eth;

    address public owner;
    address public executor;
    address public taker;
    uint256 public takerPK;
    address public maker1;
    uint256 public maker1PK;
    address public maker2;
    uint256 public maker2PK;

    function setUp() public {
        owner = makeAddr("owner");
        executor = makeAddr("executor");
        (taker, takerPK) = makeAddrAndKey("taker");
        (maker1, maker1PK) = makeAddrAndKey("maker1");
        (maker2, maker2PK) = makeAddrAndKey("maker2");

        usdc = new MockStableCoin("USDC");
        eth = new MockStableCoin("ETH");

        sera = _deploySera(owner);
        v = sera.vault();
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(usdc), true, 1);
        _whitelistToken(sera, address(eth), true, 1);
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        sera.setTreasury(owner);
        vm.stopPrank();
    }

    // ============ HELPERS ============

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

    // ============ TEST #3: SINGLE-LEG OVER-DEPOSIT REVERTS ============

    /// @notice Under Option B, a single-leg with initialDepositAmount > matchAmount0
    ///         reverts TransientBalanceNotZero (the residual stays in the transient table,
    ///         and the now-universal zero-check catches it).
    function test_OptionB_SingleLeg_OverDepositRevertsTransientNotZero() public {
        _mintAndDeposit(maker1, address(eth), 9 ether, sera);
        usdc.mint(taker, 1000 ether);
        vm.prank(taker);
        usdc.approve(address(sor), 1000 ether);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerOrder.initialDepositAmount = 1000 ether;
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 9 ether, 900 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        // matchAmount0 (900) < initialDepositAmount (1000) — the over-deposit case.
        matches[0] = MatchData(
            takerOrder, bytes(""), 900 ether,
            makerOrder, _signOrder(maker1PK, makerOrder, sera), 9 ether
        );

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth),
            0, 0, taker, 1000 ether, 0,
            uint48(block.timestamp + 1 days), sera
        );

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(
            SeraSOR.TransientBalanceNotZero.selector,
            address(usdc),
            100 ether
        ));
        sor.executeIntent(
            matches, sorSig,
            IntentParams(taker, address(usdc), address(eth), 0, 0, taker, 1000 ether, 0, uint48(block.timestamp + 1 days)),
            3, 0, bytes("")
        );
    }

    // ============ TEST #4: SPLIT-INPUT MULTI-LEG (HAPPY PATH) ============

    /// @notice Option B unblocks routes where the wallet deposit is split across multiple
    ///         input-token legs (each fromToken == intent.inputToken). Both legs are terminal,
    ///         delivering outputToken to the signed recipient.
    function test_OptionB_SplitInputMultiLeg_HappyPath() public {
        _mintAndDeposit(maker1, address(eth), 6 ether, sera);
        _mintAndDeposit(maker2, address(eth), 4 ether, sera);
        usdc.mint(taker, 100 ether);
        vm.prank(taker);
        usdc.approve(address(sor), 100 ether);

        Order memory takerLeg0 = _makeOrder(taker, address(usdc), address(eth), 60 ether, 6 ether, 1);
        takerLeg0.initialDepositAmount = 100 ether;
        Order memory makerLeg0 = _makeOrder(maker1, address(eth), address(usdc), 6 ether, 60 ether, 10);

        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 40 ether, 4 ether, 2);
        Order memory makerLeg1 = _makeOrder(maker2, address(eth), address(usdc), 4 ether, 40 ether, 11);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(
            takerLeg0, bytes(""), 60 ether,
            makerLeg0, _signOrder(maker1PK, makerLeg0, sera), 6 ether
        );
        matches[1] = MatchData(
            takerLeg1, bytes(""), 40 ether,
            makerLeg1, _signOrder(maker2PK, makerLeg1, sera), 4 ether
        );

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth),
            0, 0, taker, 100 ether, 0,
            uint48(block.timestamp + 1 days), sera
        );

        vm.prank(executor);
        sor.executeIntent(
            matches, sorSig,
            IntentParams(taker, address(usdc), address(eth), 0, 0, taker, 100 ether, 0, uint48(block.timestamp + 1 days)),
            5, 0, bytes("")
        );

        assertEq(eth.balanceOf(taker), 10 ether, "taker should receive aggregate ETH from both legs");
        assertEq(usdc.balanceOf(address(sera)), 0, "no USDC dust in Sera");
        assertEq(eth.balanceOf(address(sera)), 0, "no ETH dust in Sera");
    }

    // ============ TEST #5: SPLIT-INPUT MULTI-LEG WITH PARTIAL CONSUMPTION ============

    /// @notice If split legs sum to less than initialDepositAmount, the residual is caught
    ///         by the universal zero-check and the route reverts TransientBalanceNotZero.
    function test_OptionB_SplitInputMultiLeg_PartialConsumption_Reverts() public {
        _mintAndDeposit(maker1, address(eth), 6 ether, sera);
        _mintAndDeposit(maker2, address(eth), 3 ether, sera);
        usdc.mint(taker, 100 ether);
        vm.prank(taker);
        usdc.approve(address(sor), 100 ether);

        Order memory takerLeg0 = _makeOrder(taker, address(usdc), address(eth), 60 ether, 6 ether, 1);
        takerLeg0.initialDepositAmount = 100 ether;
        Order memory makerLeg0 = _makeOrder(maker1, address(eth), address(usdc), 6 ether, 60 ether, 10);

        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 30 ether, 3 ether, 2);
        Order memory makerLeg1 = _makeOrder(maker2, address(eth), address(usdc), 3 ether, 30 ether, 11);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(
            takerLeg0, bytes(""), 60 ether,
            makerLeg0, _signOrder(maker1PK, makerLeg0, sera), 6 ether
        );
        // Sum is 60 + 30 = 90, leaving 10 ether residual in transient[USDC].
        matches[1] = MatchData(
            takerLeg1, bytes(""), 30 ether,
            makerLeg1, _signOrder(maker2PK, makerLeg1, sera), 3 ether
        );

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth),
            0, 0, taker, 100 ether, 0,
            uint48(block.timestamp + 1 days), sera
        );

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(
            SeraSOR.TransientBalanceNotZero.selector,
            address(usdc),
            10 ether
        ));
        sor.executeIntent(
            matches, sorSig,
            IntentParams(taker, address(usdc), address(eth), 0, 0, taker, 100 ether, 0, uint48(block.timestamp + 1 days)),
            5, 0, bytes("")
        );
    }

    // ============ TEST #6: ADVERSARIAL — NO FUND LEAK ON REVERT ============

    /// @notice The core security claim of Option B: a buggy/malicious executor cannot
    ///         strand taker funds via single-leg over-deposit. The reverting tx must
    ///         atomically roll back safeTransferFrom; balances must be bit-identical.
    function test_OptionB_NoFundLeak_OnRevert() public {
        _mintAndDeposit(maker1, address(eth), 9 ether, sera);
        usdc.mint(taker, 1000 ether);
        vm.prank(taker);
        usdc.approve(address(sor), 1000 ether);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerOrder.initialDepositAmount = 1000 ether;
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 9 ether, 900 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(
            takerOrder, bytes(""), 900 ether,
            makerOrder, _signOrder(maker1PK, makerOrder, sera), 9 ether
        );

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth),
            0, 0, taker, 1000 ether, 0,
            uint48(block.timestamp + 1 days), sera
        );

        // Snapshot balances before the reverting call.
        uint256 seraUsdcBefore = usdc.balanceOf(address(sera));
        uint256 takerUsdcBefore = usdc.balanceOf(taker);
        uint256 takerVaultUsdcBefore = v.balanceOf(address(usdc), taker);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(
            SeraSOR.TransientBalanceNotZero.selector,
            address(usdc),
            100 ether
        ));
        sor.executeIntent(
            matches, sorSig,
            IntentParams(taker, address(usdc), address(eth), 0, 0, taker, 1000 ether, 0, uint48(block.timestamp + 1 days)),
            3, 0, bytes("")
        );

        // EVM tx atomicity: the safeTransferFrom must have been rolled back.
        assertEq(usdc.balanceOf(address(sera)), seraUsdcBefore, "Sera USDC balance changed on revert");
        assertEq(usdc.balanceOf(taker), takerUsdcBefore, "Taker wallet USDC changed on revert");
        assertEq(v.balanceOf(address(usdc), taker), takerVaultUsdcBefore, "Taker vault USDC changed on revert");
    }

    // ============ TEST #7: SENTINEL + NON-ZERO initialDepositAmount ============

    /// @notice Sentinel matchAmount0 with non-zero initialDepositAmount: the wallet deposit
    ///         credits transient[inputToken], the sentinel branch in _consumeTransientBalance
    ///         drains it all, and the universal zero-check passes.
    function test_OptionB_Sentinel_WithNonZeroInitialDeposit() public {
        _mintAndDeposit(maker1, address(eth), 1 ether, sera);
        usdc.mint(taker, 100 ether);
        vm.prank(taker);
        usdc.approve(address(sor), 100 ether);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 100 ether, 1 ether, 1);
        takerOrder.initialDepositAmount = 100 ether;
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 1 ether, 100 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(
            takerOrder, bytes(""), type(uint256).max,
            makerOrder, _signOrder(maker1PK, makerOrder, sera), 1 ether
        );

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth),
            0, 0, taker, 100 ether, 0,
            uint48(block.timestamp + 1 days), sera
        );

        vm.prank(executor);
        sor.executeIntent(
            matches, sorSig,
            IntentParams(taker, address(usdc), address(eth), 0, 0, taker, 100 ether, 0, uint48(block.timestamp + 1 days)),
            3, 0, bytes("")
        );

        assertEq(eth.balanceOf(taker), 1 ether, "taker should receive 1 ETH");
        assertEq(usdc.balanceOf(address(sera)), 0, "no USDC dust in Sera");
    }

    // ============ TEST #8: BOUNDARY — initialDepositAmount == matchAmount0 ============

    /// @notice Exact-match boundary on single-leg: wallet pull is fully consumed by leg 0.
    function test_OptionB_Boundary_InitialDepositEqualsMatchAmount() public {
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        usdc.mint(taker, 1000 ether);
        vm.prank(taker);
        usdc.approve(address(sor), 1000 ether);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerOrder.initialDepositAmount = 1000 ether;
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(
            takerOrder, bytes(""), 1000 ether,
            makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether
        );

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth),
            0, 0, taker, 1000 ether, 0,
            uint48(block.timestamp + 1 days), sera
        );

        vm.prank(executor);
        sor.executeIntent(
            matches, sorSig,
            IntentParams(taker, address(usdc), address(eth), 0, 0, taker, 1000 ether, 0, uint48(block.timestamp + 1 days)),
            3, 0, bytes("")
        );

        assertEq(eth.balanceOf(taker), 10 ether, "taker should receive 10 ETH");
        assertEq(usdc.balanceOf(address(sera)), 0, "no USDC dust in Sera");
    }

    // ============ TEST #9: VAULT TOP-UP — initialDepositAmount < matchAmount0 ============

    /// @notice Hybrid wallet+vault path: wallet deposit covers part of leg 0; the rest
    ///         comes from the taker's vault ledger via the line 120 inputToken-only allowance.
    function test_OptionB_VaultTopUp_SingleLeg() public {
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(taker, address(usdc), 400 ether, sera);
        usdc.mint(taker, 600 ether);
        vm.prank(taker);
        usdc.approve(address(sor), 600 ether);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerOrder.initialDepositAmount = 600 ether;
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(
            takerOrder, bytes(""), 1000 ether,
            makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether
        );

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth),
            0, 0, taker, 600 ether, 0,
            uint48(block.timestamp + 1 days), sera
        );

        vm.prank(executor);
        sor.executeIntent(
            matches, sorSig,
            IntentParams(taker, address(usdc), address(eth), 0, 0, taker, 600 ether, 0, uint48(block.timestamp + 1 days)),
            3, 0, bytes("")
        );

        assertEq(eth.balanceOf(taker), 10 ether, "taker should receive 10 ETH");
        assertEq(v.balanceOf(address(usdc), taker), 0, "taker's vault USDC fully consumed");
        assertEq(usdc.balanceOf(address(sera)), 0, "no USDC dust in Sera");
    }

    // ============ TEST #11: GAS OVERHEAD BOUND ============

    /// @notice Coarse upper bound on single-leg gas. Option B adds the universal zero-check
    ///         loop (~150 gas for tableSize=3). This test fails loudly if the loop ever
    ///         degenerates (e.g., quadratic via a future refactor).
    function test_OptionB_SingleLeg_GasOverheadBounded() public {
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(
            takerOrder, bytes(""), 1000 ether,
            makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether
        );

        bytes memory sorSig = _signIntent(
            takerPK, taker, address(usdc), address(eth),
            0, 0, taker, 0, 0,
            uint48(block.timestamp + 1 days), sera
        );

        IntentParams memory intent = IntentParams(
            taker, address(usdc), address(eth), 0, 0, taker, 0, 0,
            uint48(block.timestamp + 1 days)
        );

        vm.prank(executor);
        uint256 g0 = gasleft();
        sor.executeIntent(matches, sorSig, intent, 3, 0, bytes(""));
        uint256 used = g0 - gasleft();

        // Single-leg vault-funded happy path; bound is intentionally generous (catches only
        // pathological regressions).
        assertLt(used, 500_000, "single-leg executeIntent gas spiked unexpectedly");
    }
}
