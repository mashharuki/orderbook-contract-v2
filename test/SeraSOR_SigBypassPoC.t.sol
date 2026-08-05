// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

/**
 * @title SeraSOR_SigBypassPoC
 * @notice PoC + regression for the shared-`filledAmount` signature-verification bypass.
 *
 * VULNERABILITY (against unpatched commit 9b6708c):
 *   `filledAmount[hash]` is ONE mapping written by BOTH the signature-checked `matchOrders` path
 *   AND the signature-EXEMPT SOR taker path. `_validateMakerOrder` skips the signature whenever
 *   `filled != 0` (Sera.sol:491). So a compromised EXECUTOR_ROLE could seed `filledAmount[H] != 0`
 *   for a fabricated, UNSIGNED order H via one hijacked SOR intent, then replay H in `matchOrders`
 *   with an EMPTY signature to drain the victim's vault. On unpatched code this seeded
 *   `filledAmount[H] = 1` and drained 99 of the victim's 100 WETH (see finding md §5).
 *
 * FIX (drop the taker-leg fill write, src/Sera.sol `_calculateSettlement` / `trackOrder0`):
 *   The routed taker leg no longer writes `filledAmount`. The seed can therefore never be planted
 *   (`filledAmount[H]` stays 0), and any `matchOrders` replay of H sees `filled == 0`, runs the
 *   signature check, and reverts on the empty signature.
 *
 * The tests below assert the FIXED behavior and PASS against the patched working tree. The exploit
 * *construction* (the forged order H, the hijacked-intent seed route, the empty-sig drain match) is
 * preserved from the original PoC — only the asserted OUTCOME is inverted from "attacker drains
 * 99 WETH" to "attack is blocked". The one construction change forced by the Finding-1 patch: the
 * victim's SOR intent now carries a non-zero envelope (maxInput=type(uint256).max, minOutput=1)
 * because SeraSOR now rejects a zero envelope (ZeroEnvelope); the seed leg still executes and — with
 * the drop-taker-write fix — plants nothing.
 */
contract SeraSOR_SigBypassPoC is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    MockStableCoin public weth;
    MockStableCoin public usdc;

    address public owner;
    address public executor; // compromised EXECUTOR_ROLE key

    address public victim;
    uint256 public victimPK;

    address public attacker; // also acts as the counterparty maker
    uint256 public attackerPK;

    uint48 internal EXP;

    function setUp() public {
        owner = makeAddr("owner");
        executor = makeAddr("executor");
        (victim, victimPK) = makeAddrAndKey("victim");
        (attacker, attackerPK) = makeAddrAndKey("attacker");
        EXP = uint48(block.timestamp + 30 days);

        weth = new MockStableCoin("WETH");
        usdc = new MockStableCoin("USDC");

        sera = _deploySera(owner);
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(weth), true, 1);
        _whitelistToken(sera, address(usdc), true, 1);
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        // 100% positive-slippage capture to protocol (isolates the bug from spread logic).
        sera.setSlippageShares(0, 0, 10000, 10000);
        vm.stopPrank();

        // Victim is an ordinary depositor: 100 WETH in the vault.
        _mintAndDeposit(victim, address(weth), 100 ether, sera);

        // Attacker seeds a little USDC into the vault to fund its own maker legs (recovered later).
        _mintAndDeposit(attacker, address(usdc), 10 ether, sera);
    }

    /// @dev The forged, UNSIGNED order the attacker uses IDENTICALLY in seed and drain.
    ///      user = victim, but the victim never signs it. Terrible rate; fromAmount huge so the
    ///      cumulative-fill cap never limits re-drains (on unpatched code).
    function _forgedOrderH() internal view returns (Order memory) {
        return Order({
            user: victim,
            expiration: EXP,
            feeBps: 0,
            recipient: victim,
            fromToken: address(weth),
            toToken: address(usdc),
            fromAmount: 1e30,
            toAmount: 1,
            initialDepositAmount: 0,
            uuid: 1
        });
    }

    // ------------------------------------------------------------------
    // ATTACK CONSTRUCTION (unchanged from the original PoC — this is the "input").
    // PHASE 1 — the executor hijacks the victim's SOR intent and tries to plant filledAmount[H]
    // via a 1-wei taker leg carrying an EMPTY signature.
    // ------------------------------------------------------------------
    function _seedForgedOrder(Order memory H) internal {
        Order memory seedMaker = Order({
            user: attacker,
            expiration: EXP,
            feeBps: 0,
            recipient: address(0),
            fromToken: address(usdc),
            toToken: address(weth),
            fromAmount: 1000 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            uuid: 2
        });

        MatchData[] memory seedMatches = new MatchData[](1);
        seedMatches[0] = MatchData({
            order0: H, // forged victim order, UNSIGNED
            signature0: bytes(""), // EMPTY taker signature
            matchAmount0: 1, // seed just 1 wei of WETH
            order1: seedMaker,
            signature1: _signOrder(attackerPK, seedMaker, sera),
            matchAmount1: 1
        });

        // Victim signs ONE ordinary intent: "swap my WETH for USDC".
        bytes memory intentSig =
            _signIntent(victimPK, victim, address(weth), address(usdc), type(uint256).max, 1, victim, 0, 1, EXP, sera);

        vm.prank(executor);
        sor.executeIntent(
            seedMatches,
            intentSig,
            IntentParams(victim, address(weth), address(usdc), type(uint256).max, 1, victim, 0, 1, EXP),
            uint8(seedMatches.length * 2 + 1),
            0,
            bytes("")
        );
    }

    // PHASE 2 — the executor replays the byte-identical H in matchOrders with an EMPTY signature
    // against its own signed maker order. (Kept separate so a test can wrap ONLY matchOrders in
    // vm.expectRevert.)
    function _buildDrain(Order memory H, uint256 amount, uint256 makerUuid)
        internal
        view
        returns (MatchData memory)
    {
        Order memory drainMaker = Order({
            user: attacker,
            expiration: EXP,
            feeBps: 0,
            recipient: attacker,
            fromToken: address(usdc),
            toToken: address(weth),
            fromAmount: 1,
            toAmount: amount,
            initialDepositAmount: 0,
            uuid: makerUuid
        });

        return MatchData({
            order0: H,
            signature0: bytes(""), // EMPTY signature
            matchAmount0: amount,
            order1: drainMaker,
            signature1: _signOrder(attackerPK, drainMaker, sera),
            matchAmount1: 1
        });
    }

    // ==================================================================
    // REGRESSION TESTS (post-fix). All pass against the patched working tree.
    // ==================================================================

    /// @notice The SOR taker path must NOT seed filledAmount for a forged, unsigned order.
    ///         (On unpatched 9b6708c this asserted `> 0`; the exploit seeded 1.)
    function test_Fixed_SeedCannotBePlanted() public {
        Order memory H = _forgedOrderH();
        bytes32 hHash = _getOrderHashMemory(H);

        assertEq(sera.filledAmount(hHash), 0, "precondition: H unseeded");

        // Run the exact hijacked-intent construction from the original exploit.
        _seedForgedOrder(H);

        // FIX: the routed taker leg no longer persists fill, so no seed exists.
        assertEq(sera.filledAmount(hHash), 0, "FIX: SOR taker path must not seed filledAmount[H]");
    }

    /// @notice Replaying the forged order in matchOrders with an empty signature is rejected, and
    ///         the victim's vault is untouched. (On unpatched 9b6708c this drained 99 WETH.)
    function test_Fixed_EmptySigDrainReverts() public {
        Order memory H = _forgedOrderH();
        Vault v = sera.vault();

        _seedForgedOrder(H); // seed attempt is now a no-op for filledAmount

        // FIX: filled == 0 -> signature IS verified -> empty signature -> InvalidSignature.
        MatchData memory drain = _buildDrain(H, 99 ether, 3);
        vm.prank(executor);
        vm.expectRevert(Sera.InvalidSignature.selector);
        sera.matchOrders(drain, type(uint256).max);

        // Victim keeps the ~99 WETH the exploit would have taken (only the 1-wei seed leg executed).
        assertGe(v.balanceOf(address(weth), victim), 99 ether, "FIX: victim vault not drained");
        assertEq(weth.balanceOf(attacker), 0, "FIX: attacker received no WETH");
    }

    /// @notice Control (also passed pre-fix): with no seed at all, the empty-signature matchOrders
    ///         call is rejected. Confirms the signature check is the gate.
    function test_PoC_Control_UnseededEmptySigReverts() public {
        Order memory H = _forgedOrderH();
        assertEq(sera.filledAmount(_getOrderHashMemory(H)), 0, "not seeded");

        MatchData memory drain = _buildDrain(H, 99 ether, 3);
        vm.prank(executor);
        vm.expectRevert(Sera.InvalidSignature.selector);
        sera.matchOrders(drain, type(uint256).max);
    }
}
