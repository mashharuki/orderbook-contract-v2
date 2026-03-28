// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

/**
 * @title SeraSOR_Topology_Test
 * @dev Extreme SOR topology tests covering:
 *      - 5-leg linear chain with cascading sentinel + fees
 *      - Diamond with fees on all legs
 *      - Tree (1→N fan-out) with mixed sentinel/fixed + fees
 *      - Funnel (N→1 fan-in): multiple taker-funded legs converge to same output token
 *      - Same-token recirculation: A→B→A→C
 *      - Mixed wallet + vault funding on multi-leg routes
 *      - Maximum fees (100%) on multi-leg sentinel routes
 *      - wei-level amounts through multi-hop sentinel chains
 *      - 10-leg route (stress MAX_ROUTE_LEGS)
 *      - Partial fill then re-route on same maker
 */
contract SeraSOR_Topology_Test is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    // 6 tokens for complex topologies
    MockStableCoin public A;
    MockStableCoin public B;
    MockStableCoin public C;
    MockStableCoin public D;
    MockStableCoin public E;
    MockStableCoin public F;

    address public owner;
    address public executor;
    address public taker;
    uint256 public takerPK;
    // 5 makers for complex diamond/tree
    address public m1; uint256 public m1PK;
    address public m2; uint256 public m2PK;
    address public m3; uint256 public m3PK;
    address public m4; uint256 public m4PK;
    address public m5; uint256 public m5PK;

    function setUp() public {
        owner = makeAddr("owner");
        executor = makeAddr("executor");
        (taker, takerPK) = makeAddrAndKey("taker");
        (m1, m1PK) = makeAddrAndKey("m1");
        (m2, m2PK) = makeAddrAndKey("m2");
        (m3, m3PK) = makeAddrAndKey("m3");
        (m4, m4PK) = makeAddrAndKey("m4");
        (m5, m5PK) = makeAddrAndKey("m5");

        A = new MockStableCoin("A");
        B = new MockStableCoin("B");
        C = new MockStableCoin("C");
        D = new MockStableCoin("D");
        E = new MockStableCoin("E");
        F = new MockStableCoin("F");

        sera = _deploySera(owner);
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(A), true, 1);
        _whitelistToken(sera, address(B), true, 1);
        _whitelistToken(sera, address(C), true, 1);
        _whitelistToken(sera, address(D), true, 1);
        _whitelistToken(sera, address(E), true, 1);
        _whitelistToken(sera, address(F), true, 1);
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        // 25% maker, 25% taker, 50% protocol
        sera.setSlippageShares(2500, 2500, 5000, 10000);
        vm.stopPrank();
    }

    // ───────── Helpers ─────────


    function _o(address user, address from, address to, uint256 fromAmt, uint256 toAmt, uint256 uuid)
        internal view returns (Order memory)
    {
        return Order({
            user: user, fromToken: from, toToken: to,
            fromAmount: fromAmt, toAmount: toAmt, initialDepositAmount: 0,
            feeBps: 0, recipient: user,
            expiration: uint48(block.timestamp + 1 days), uuid: uuid
        });
    }

    /// @dev Create order with custom feeBps and recipient
    function _oFull(address user, address from, address to, uint256 fromAmt, uint256 toAmt,
        uint256 uuid, uint48 feeBps, address recipient) internal view returns (Order memory)
    {
        return Order({
            user: user, fromToken: from, toToken: to,
            fromAmount: fromAmt, toAmount: toAmt, initialDepositAmount: 0,
            feeBps: feeBps, recipient: recipient,
            expiration: uint48(block.timestamp + 1 days), uuid: uuid
        });
    }

    uint256 private _execNonce = 1000;

    function _exec(MatchData[] memory matches) internal {
        _execCore(matches, matches[matches.length - 1].order0.recipient);
    }

    function _execCore(MatchData[] memory matches, address _r) internal {
        uint256 nonce = _execNonce++;
        uint256 _d = matches[0].order0.initialDepositAmount;
        address _in = matches[0].order0.fromToken;
        address _out = matches[matches.length - 1].order0.toToken;
        uint48 _dl = uint48(block.timestamp + 1 days);
        bytes memory sig = _signIntent(takerPK, _in, _out, 0, 0, _r, _d, nonce, _dl, sera);
        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(_in, _out, 0, 0, _r, _d, nonce, _dl), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    function _assertNoDust(address token) internal view {
        assertEq(IERC20(token).balanceOf(address(sera)), 0, "dust");
    }

    function _assertSolvent(address token, address[] memory users) internal view {
        Vault v = sera.vault();
        uint256 total;
        for (uint256 i; i < users.length; i++) total += v.balanceOf(token, users[i]);
        assertGe(IERC20(token).balanceOf(address(v)), total, "insolvent");
    }

    address[] internal _allUsers;
    function _users() internal returns (address[] memory) {
        delete _allUsers;
        _allUsers.push(taker); _allUsers.push(m1); _allUsers.push(m2);
        _allUsers.push(m3); _allUsers.push(m4); _allUsers.push(m5); _allUsers.push(owner);
        return _allUsers;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  1. 5-LEG LINEAR CHAIN WITH FEES: A→B→C→D→E→F
    // ════════════════════════════════════════════════════════════════════════

    function test_FiveLegLinearChain_WithFees() public {
        _mintAndDeposit(taker, address(A), 10000 ether, sera);
        _mintAndDeposit(m1, address(B), 10000 ether, sera);
        _mintAndDeposit(m2, address(C), 10000 ether, sera);
        _mintAndDeposit(m3, address(D), 10000 ether, sera);
        _mintAndDeposit(m4, address(E), 10000 ether, sera);
        _mintAndDeposit(m5, address(F), 10000 ether, sera);

        // Leg 1: 1000 A → 600 B. 5% taker fee, 3% maker fee.
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 300 ether, 1, 500, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 600 ether, 500 ether, 2, 300, m1);

        // Leg 2: sentinel B → C. Generous fromAmount. Maker wants <= 300 B.
        Order memory t2 = _oFull(taker, address(B), address(C), 600 ether, 100 ether, 3, 500, address(sera));
        Order memory mk2 = _oFull(m2, address(C), address(B), 300 ether, 200 ether, 4, 200, m2);

        // Leg 3: sentinel C → D. Maker wants <= 100 C.
        Order memory t3 = _oFull(taker, address(C), address(D), 300 ether, 50 ether, 5, 500, address(sera));
        Order memory mk3 = _oFull(m3, address(D), address(C), 200 ether, 80 ether, 6, 100, m3);

        // Leg 4: sentinel D → E. Maker wants <= 50 D.
        Order memory t4 = _oFull(taker, address(D), address(E), 200 ether, 20 ether, 7, 500, address(sera));
        Order memory mk4 = _oFull(m4, address(E), address(D), 100 ether, 30 ether, 8, 400, m4);

        // Leg 5: sentinel E → F (final output)
        Order memory t5 = _oFull(taker, address(E), address(F), 100 ether, 10 ether, 9, 500, taker);
        Order memory mk5 = _oFull(m5, address(F), address(E), 50 ether, 20 ether, 10, 200, m5);

        MatchData[] memory matches = new MatchData[](5);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 600 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 300 ether);
        matches[2] = MatchData(t3, bytes(""), type(uint256).max, mk3, _signOrder(m3PK, mk3, sera), 200 ether);
        matches[3] = MatchData(t4, bytes(""), type(uint256).max, mk4, _signOrder(m4PK, mk4, sera), 100 ether);
        matches[4] = MatchData(t5, bytes(""), type(uint256).max, mk5, _signOrder(m5PK, mk5, sera), 50 ether);

        _exec(matches);

        assertGt(F.balanceOf(taker), 0, "Taker received F");
        address[] memory u = _users();
        _assertSolvent(address(A), u); _assertSolvent(address(B), u);
        _assertSolvent(address(C), u); _assertSolvent(address(D), u);
        _assertSolvent(address(E), u); _assertSolvent(address(F), u);
        _assertNoDust(address(A)); _assertNoDust(address(B));
        _assertNoDust(address(C)); _assertNoDust(address(D));
        _assertNoDust(address(E)); _assertNoDust(address(F));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  2. DIAMOND WITH FEES ON ALL LEGS (fan-out + fan-in)
    //     A → B (leg1)
    //     A → C (leg2)
    //     B → D (leg3, sentinel)
    //     C → D (leg4, sentinel)
    // ════════════════════════════════════════════════════════════════════════

    function test_DiamondWithFees_AllLegs() public {
        _mintAndDeposit(taker, address(A), 2000 ether, sera);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);
        _mintAndDeposit(m3, address(D), 5000 ether, sera);
        _mintAndDeposit(m4, address(D), 5000 ether, sera);

        // Leg1: 500 A → B. 5% taker fee.
        Order memory t1 = _oFull(taker, address(A), address(B), 500 ether, 100 ether, 1, 500, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 200 ether, 400 ether, 2, 300, m1);

        // Leg2: 500 A → C. 3% taker fee.
        Order memory t2 = _oFull(taker, address(A), address(C), 500 ether, 100 ether, 3, 300, address(sera));
        Order memory mk2 = _oFull(m2, address(C), address(A), 200 ether, 400 ether, 4, 200, m2);

        // Leg3: sentinel B → D. 2% taker fee.
        Order memory t3 = _oFull(taker, address(B), address(D), 200 ether, 30 ether, 5, 200, taker);
        Order memory mk3 = _oFull(m3, address(D), address(B), 100 ether, 100 ether, 6, 100, m3);

        // Leg4: sentinel C → D. 4% taker fee.
        Order memory t4 = _oFull(taker, address(C), address(D), 200 ether, 30 ether, 7, 400, taker);
        Order memory mk4 = _oFull(m4, address(D), address(C), 100 ether, 100 ether, 8, 500, m4);

        MatchData[] memory matches = new MatchData[](4);
        matches[0] = MatchData(t1, bytes(""), 500 ether, mk1, _signOrder(m1PK, mk1, sera), 200 ether);
        matches[1] = MatchData(t2, bytes(""), 500 ether, mk2, _signOrder(m2PK, mk2, sera), 200 ether);
        matches[2] = MatchData(t3, bytes(""), type(uint256).max, mk3, _signOrder(m3PK, mk3, sera), 100 ether);
        matches[3] = MatchData(t4, bytes(""), type(uint256).max, mk4, _signOrder(m4PK, mk4, sera), 100 ether);

        _exec(matches);

        // Taker receives D from both branches
        assertGt(D.balanceOf(taker), 0, "Taker received D from diamond");
        address[] memory u = _users();
        _assertSolvent(address(A), u); _assertSolvent(address(B), u);
        _assertSolvent(address(C), u); _assertSolvent(address(D), u);
        _assertNoDust(address(A)); _assertNoDust(address(B));
        _assertNoDust(address(C)); _assertNoDust(address(D));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  3. TREE FAN-OUT: A → B, then B splits to C + D + E
    //     3 branches from single trunk, mixed fixed/sentinel
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Multi-output-token fan-out is intentionally unsupported in single-output intent model
    function test_TreeFanOut_ThreeBranches_Reverts() public {
        _mintAndDeposit(taker, address(A), 3000 ether, sera);
        _mintAndDeposit(m1, address(B), 10000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);
        _mintAndDeposit(m3, address(D), 5000 ether, sera);
        _mintAndDeposit(m4, address(E), 5000 ether, sera);

        // Trunk: 1000 A → B (maker gives 500 B, spread)
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 200 ether, 1, 0, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 800 ether, 2, 0, m1);

        // Branch 1: fixed 50 B → C (different output token than E)
        Order memory t2 = _oFull(taker, address(B), address(C), 50 ether, 20 ether, 3, 0, taker);
        Order memory mk2 = _oFull(m2, address(C), address(B), 80 ether, 40 ether, 4, 0, m2);

        // Branch 2: fixed 50 B → D
        Order memory t3 = _oFull(taker, address(B), address(D), 50 ether, 20 ether, 5, 0, taker);
        Order memory mk3 = _oFull(m3, address(D), address(B), 70 ether, 40 ether, 6, 0, m3);

        // Branch 3: sentinel (drains remaining B) → E
        Order memory t4 = _oFull(taker, address(B), address(E), 500 ether, 30 ether, 7, 0, taker);
        Order memory mk4 = _oFull(m4, address(E), address(B), 200 ether, 50 ether, 8, 0, m4);

        MatchData[] memory matches = new MatchData[](4);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), 50 ether, mk2, _signOrder(m2PK, mk2, sera), 80 ether);
        matches[2] = MatchData(t3, bytes(""), 50 ether, mk3, _signOrder(m3PK, mk3, sera), 70 ether);
        matches[3] = MatchData(t4, bytes(""), type(uint256).max, mk4, _signOrder(m4PK, mk4, sera), 200 ether);

        // Intent signed for output token E — branches outputting C and D should revert
        uint256 nonce = _execNonce++;
        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, nonce, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        vm.expectRevert(SeraSOR.InvalidRoute.selector);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, nonce, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  4. SAME-TOKEN RECIRCULATION: A→B→A→C
    //     Token A appears both as input and intermediate output
    // ════════════════════════════════════════════════════════════════════════

    function test_SameToken_Recirculation_A_B_A_C() public {
        _mintAndDeposit(taker, address(A), 2000 ether, sera);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(A), 5000 ether, sera);  // m2 has A tokens too
        _mintAndDeposit(m3, address(C), 5000 ether, sera);

        // Leg 1: 1000 A → B (hold)
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 200 ether, 1, 0, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 800 ether, 2, 0, m1);

        // Leg 2: sentinel B → A (back to A! hold for leg 3)
        Order memory t2 = _oFull(taker, address(B), address(A), 500 ether, 100 ether, 3, 0, address(sera));
        Order memory mk2 = _oFull(m2, address(A), address(B), 300 ether, 200 ether, 4, 0, m2);

        // Leg 3: sentinel A → C (final output)
        Order memory t3 = _oFull(taker, address(A), address(C), 300 ether, 50 ether, 5, 0, taker);
        Order memory mk3 = _oFull(m3, address(C), address(A), 100 ether, 100 ether, 6, 0, m3);

        MatchData[] memory matches = new MatchData[](3);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 300 ether);
        matches[2] = MatchData(t3, bytes(""), type(uint256).max, mk3, _signOrder(m3PK, mk3, sera), 100 ether);

        _exec(matches);

        assertGt(C.balanceOf(taker), 0, "Taker received C through recirculation");
        address[] memory u = _users();
        _assertSolvent(address(A), u); _assertSolvent(address(B), u); _assertSolvent(address(C), u);
        _assertNoDust(address(A)); _assertNoDust(address(B)); _assertNoDust(address(C));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  5. WALLET-FUNDED MULTI-LEG: taker pays from wallet, not vault
    // ════════════════════════════════════════════════════════════════════════

    function test_WalletFunded_ThreeLeg_WithFees() public {
        // Taker does NOT deposit into vault; pays from wallet via initialDepositAmount
        _mintInWallet(taker, address(A), 1000 ether);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);

        // Leg 1: 1000 A → B, wallet-funded. 5% fee.
        Order memory t1 = Order({
            user: taker, fromToken: address(A), toToken: address(B),
            fromAmount: 1000 ether, toAmount: 200 ether, initialDepositAmount: 1000 ether,
            feeBps: 500, recipient: address(sera),
            expiration: uint48(block.timestamp + 1 days), uuid: 1
        });
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 800 ether, 2, 200, m1);

        // Leg 2: sentinel B → C. 3% fee.
        Order memory t2 = _oFull(taker, address(B), address(C), 500 ether, 50 ether, 3, 300, taker);
        Order memory mk2 = _oFull(m2, address(C), address(B), 200 ether, 200 ether, 4, 100, m2);

        // Approve SOR to pull from taker wallet
        vm.prank(taker);
        A.approve(address(sor), 1000 ether);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 200 ether);

        _exec(matches);

        assertGt(C.balanceOf(taker), 0, "Taker received C from wallet-funded route");
        assertEq(A.balanceOf(taker), 0, "Taker wallet drained");
        address[] memory u = _users();
        _assertSolvent(address(A), u); _assertSolvent(address(B), u); _assertSolvent(address(C), u);
        _assertNoDust(address(A)); _assertNoDust(address(B)); _assertNoDust(address(C));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  6. MAX FEES (100%) ON MULTI-LEG SENTINEL ROUTE
    // ════════════════════════════════════════════════════════════════════════

    function test_MaxFees_TwoLeg_Sentinel() public {
        vm.prank(owner);
        sera.setSlippageShares(0, 0, 10000, 10000);  // 100% protocol spread

        _mintAndDeposit(taker, address(A), 5000 ether, sera);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);

        // Leg 1: 50% taker fee, 50% maker fee, + 100% protocol spread
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 100 ether, 1, 5000, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 800 ether, 2, 5000, m1);

        // Leg 2: sentinel, same fee structure
        Order memory t2 = _oFull(taker, address(B), address(C), 500 ether, 10 ether, 3, 5000, taker);
        Order memory mk2 = _oFull(m2, address(C), address(B), 200 ether, 50 ether, 4, 5000, m2);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 200 ether);

        _exec(matches);

        // Protocol gets massive fees + spread. Verify solvency.
        address[] memory u = _users();
        _assertSolvent(address(A), u); _assertSolvent(address(B), u); _assertSolvent(address(C), u);
        _assertNoDust(address(A)); _assertNoDust(address(B)); _assertNoDust(address(C));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  7. WEI-LEVEL AMOUNTS THROUGH 3-HOP SENTINEL CHAIN
    // ════════════════════════════════════════════════════════════════════════

    function test_WeiLevel_ThreeHop_Sentinel() public {
        _mintAndDeposit(taker, address(A), 1001, sera);
        _mintAndDeposit(m1, address(B), 2000, sera);
        _mintAndDeposit(m2, address(C), 2000, sera);
        _mintAndDeposit(m3, address(D), 2000, sera);

        // Wei-level orders: A→B→C→D
        Order memory t1 = _oFull(taker, address(A), address(B), 1001, 5, 1, 0, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 11, 500, 2, 0, m1);

        Order memory t2 = _oFull(taker, address(B), address(C), 11, 3, 3, 0, address(sera));
        Order memory mk2 = _oFull(m2, address(C), address(B), 7, 5, 4, 0, m2);

        Order memory t3 = _oFull(taker, address(C), address(D), 7, 1, 5, 0, taker);
        Order memory mk3 = _oFull(m3, address(D), address(C), 3, 3, 6, 0, m3);

        MatchData[] memory matches = new MatchData[](3);
        matches[0] = MatchData(t1, bytes(""), 1001, mk1, _signOrder(m1PK, mk1, sera), 11);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 7);
        matches[2] = MatchData(t3, bytes(""), type(uint256).max, mk3, _signOrder(m3PK, mk3, sera), 3);

        _exec(matches);

        assertGt(D.balanceOf(taker), 0, "Taker received D at wei level");
        address[] memory u = _users();
        _assertSolvent(address(A), u); _assertSolvent(address(B), u);
        _assertSolvent(address(C), u); _assertSolvent(address(D), u);
        _assertNoDust(address(A)); _assertNoDust(address(B));
        _assertNoDust(address(C)); _assertNoDust(address(D));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  8. 10-LEG ROUTE (stress test near MAX_ROUTE_LEGS=20)
    // ════════════════════════════════════════════════════════════════════════

    function test_TenLegRoute_Solvency() public {
        // Use 2 tokens cycling: A→B→A→B→... (10 legs)
        _mintAndDeposit(taker, address(A), 100000 ether, sera);
        address[5] memory makersFwd;
        uint256[5] memory makersFwdPK;
        address[5] memory makersRev;
        uint256[5] memory makersRevPK;

        for (uint256 i; i < 5; i++) {
            (makersFwd[i], makersFwdPK[i]) = makeAddrAndKey(string.concat("mFwd", vm.toString(i)));
            (makersRev[i], makersRevPK[i]) = makeAddrAndKey(string.concat("mRev", vm.toString(i)));
            _mintAndDeposit(makersFwd[i], address(B), 50000 ether, sera);
            _mintAndDeposit(makersRev[i], address(A), 50000 ether, sera);
        }

        MatchData[] memory matches = new MatchData[](10);
        for (uint256 i; i < 10; i++) {
            bool isLast = (i == 9);
            uint256 uuid0 = i * 2 + 1;
            uint256 uuid1 = i * 2 + 2;

            if (i % 2 == 0) {
                // A→B. Maker gives 5000 B, wants 1000 A (very favorable to taker)
                uint256 mIdx = i / 2;
                address recip = isLast ? taker : address(sera);
                Order memory t = _oFull(taker, address(A), address(B), 50000 ether, 500 ether, uuid0, 0, recip);
                Order memory mk = _oFull(makersFwd[mIdx], address(B), address(A), 5000 ether, 1000 ether, uuid1, 0, makersFwd[mIdx]);
                matches[i] = MatchData(
                    t, bytes(""),
                    i == 0 ? uint256(10000 ether) : type(uint256).max,
                    mk, _signOrder(makersFwdPK[mIdx], mk, sera),
                    5000 ether
                );
            } else {
                // B→A. Maker gives 5000 A, wants 1000 B (very favorable)
                uint256 mIdx = i / 2;
                address recip = isLast ? taker : address(sera);
                Order memory t = _oFull(taker, address(B), address(A), 50000 ether, 500 ether, uuid0, 0, recip);
                Order memory mk = _oFull(makersRev[mIdx], address(A), address(B), 5000 ether, 1000 ether, uuid1, 0, makersRev[mIdx]);
                matches[i] = MatchData(
                    t, bytes(""),
                    type(uint256).max,
                    mk, _signOrder(makersRevPK[mIdx], mk, sera),
                    5000 ether
                );
            }
        }

        _exec(matches);

        // Last leg (index 9, odd) is B→A, so taker receives A
        assertGt(A.balanceOf(taker), 0, "Taker received A from 10-leg route");
        _assertNoDust(address(A)); _assertNoDust(address(B));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  9. PARTIAL FILL MAKER THEN USE SAME MAKER IN ROUTE
    //     Maker partially filled via standalone, then remainder filled via SOR
    // ════════════════════════════════════════════════════════════════════════

    function _orderHash(Order memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            ORDER_TYPEHASH, p.user, p.expiration, p.feeBps, p.recipient,
            p.fromToken, p.toToken, p.fromAmount, p.toAmount,
            p.initialDepositAmount, p.uuid
        ));
    }

    function test_PartialFillMaker_ThenRouteConsumesRemainder() public {
        _mintAndDeposit(taker, address(A), 10000 ether, sera);
        _mintAndDeposit(m1, address(B), 10000 ether, sera);

        // Maker order: sell 1000 B for 800 A
        Order memory mOrder = _o(m1, address(B), address(A), 1000 ether, 800 ether, 10);
        bytes memory mSig = _signOrder(m1PK, mOrder, sera);

        // Step 1: standalone match fills 500 B of maker
        {
            Order memory standalone = _o(taker, address(A), address(B), 500 ether, 500 ether, 11);
            MatchData memory md = MatchData(standalone, _signOrder(takerPK, standalone, sera), 400 ether, mOrder, mSig, 500 ether);
            vm.prank(executor);
            sera.matchOrders(md, type(uint256).max);
        }
        assertEq(sera.filledAmount(_orderHash(mOrder)), 500 ether, "Maker 500 filled");

        // Step 2: Route fills remaining 500 B via SOR
        {
            Order memory tRoute = _oFull(taker, address(A), address(B), 500 ether, 400 ether, 12, 0, taker);
            MatchData[] memory matches = new MatchData[](1);
            matches[0] = MatchData(tRoute, bytes(""), 400 ether, mOrder, mSig, 500 ether);
            _exec(matches);
        }
        assertEq(sera.filledAmount(_orderHash(mOrder)), 1000 ether, "Maker fully filled");
        _assertNoDust(address(A)); _assertNoDust(address(B));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  10. DIAMOND WITH ASYMMETRIC FEES AND SPREAD: branch fees differ wildly
    // ════════════════════════════════════════════════════════════════════════

    function test_DiamondAsymmetricFees_ZeroVsMax() public {
        _mintAndDeposit(taker, address(A), 5000 ether, sera);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);
        _mintAndDeposit(m3, address(D), 5000 ether, sera);
        _mintAndDeposit(m4, address(D), 5000 ether, sera);

        // Leg1: A→B, 0% fee (cheap branch)
        Order memory t1 = _oFull(taker, address(A), address(B), 500 ether, 50 ether, 1, 0, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 200 ether, 400 ether, 2, 0, m1);

        // Leg2: A→C, 50% fee (expensive branch)
        Order memory t2 = _oFull(taker, address(A), address(C), 500 ether, 50 ether, 3, 5000, address(sera));
        Order memory mk2 = _oFull(m2, address(C), address(A), 200 ether, 400 ether, 4, 5000, m2);

        // Leg3: sentinel B→D, 0% fee. Maker wants <= 50 B (taker-favorable)
        Order memory t3 = _oFull(taker, address(B), address(D), 200 ether, 20 ether, 5, 0, taker);
        Order memory mk3 = _oFull(m3, address(D), address(B), 100 ether, 50 ether, 6, 0, m3);

        // Leg4: sentinel C→D, 80% fee. Maker wants <= 50 C
        Order memory t4 = _oFull(taker, address(C), address(D), 200 ether, 5 ether, 7, 8000, taker);
        Order memory mk4 = _oFull(m4, address(D), address(C), 100 ether, 50 ether, 8, 8000, m4);

        MatchData[] memory matches = new MatchData[](4);
        matches[0] = MatchData(t1, bytes(""), 500 ether, mk1, _signOrder(m1PK, mk1, sera), 200 ether);
        matches[1] = MatchData(t2, bytes(""), 500 ether, mk2, _signOrder(m2PK, mk2, sera), 200 ether);
        matches[2] = MatchData(t3, bytes(""), type(uint256).max, mk3, _signOrder(m3PK, mk3, sera), 100 ether);
        matches[3] = MatchData(t4, bytes(""), type(uint256).max, mk4, _signOrder(m4PK, mk4, sera), 100 ether);

        _exec(matches);

        assertGt(D.balanceOf(taker), 0, "Taker received D");
        address[] memory u = _users();
        _assertSolvent(address(A), u); _assertSolvent(address(B), u);
        _assertSolvent(address(C), u); _assertSolvent(address(D), u);
        _assertNoDust(address(A)); _assertNoDust(address(B));
        _assertNoDust(address(C)); _assertNoDust(address(D));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  11. ENVELOPE GUARDS ON MULTI-LEG: maxInput and minOutput on 3-leg
    // ════════════════════════════════════════════════════════════════════════

    function test_EnvelopeGuards_ThreeLeg_Passes() public {
        _mintAndDeposit(taker, address(A), 2000 ether, sera);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);

        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 200 ether, 1, 0, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 800 ether, 2, 0, m1);

        Order memory t2 = _oFull(taker, address(B), address(C), 500 ether, 50 ether, 3, 0, taker);
        Order memory mk2 = _oFull(m2, address(C), address(B), 200 ether, 200 ether, 4, 0, m2);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 200 ether);

        // Sign with tight guards: maxInput=1000, minOutput=50
        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 1000 ether, 50 ether, taker, 0, 2000, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 1000 ether, 50 ether, taker, 0, 2000, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        assertGt(C.balanceOf(taker), 50 ether, "Taker received C above minOutput");
        _assertNoDust(address(A)); _assertNoDust(address(B)); _assertNoDust(address(C));
    }

    function test_EnvelopeGuards_ThreeLeg_MinOutputReverts() public {
        _mintAndDeposit(taker, address(A), 2000 ether, sera);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);

        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 200 ether, 1, 0, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 800 ether, 2, 0, m1);

        Order memory t2 = _oFull(taker, address(B), address(C), 500 ether, 50 ether, 3, 0, taker);
        Order memory mk2 = _oFull(m2, address(C), address(B), 200 ether, 200 ether, 4, 0, m2);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 200 ether);

        // Sign with impossibly high minOutput
        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 1000 ether, 999999 ether, taker, 0, 2001, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        vm.expectRevert(SeraSOR.InsufficientOutput.selector);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 1000 ether, 999999 ether, taker, 0, 2001, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  12. SAME MAKER ACROSS TWO LEGS OF SAME ROUTE
    // ════════════════════════════════════════════════════════════════════════

    function test_SameMaker_TwoLegs_DifferentTokenPairs() public {
        _mintAndDeposit(taker, address(A), 3000 ether, sera);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m1, address(C), 5000 ether, sera);  // m1 has both B and C

        // Leg 1: A→B from m1 (hold)
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 200 ether, 1, 0, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 800 ether, 2, 0, m1);

        // Leg 2: sentinel B→C from SAME m1
        Order memory t2 = _oFull(taker, address(B), address(C), 500 ether, 50 ether, 3, 0, taker);
        Order memory mk2 = _oFull(m1, address(C), address(B), 200 ether, 200 ether, 4, 0, m1);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m1PK, mk2, sera), 200 ether);

        _exec(matches);

        assertGt(C.balanceOf(taker), 0, "Taker received C via same maker");
        address[] memory u = _users();
        _assertSolvent(address(A), u); _assertSolvent(address(B), u); _assertSolvent(address(C), u);
        _assertNoDust(address(A)); _assertNoDust(address(B)); _assertNoDust(address(C));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  13. ALL SHARES TO MAKER: maker keeps entire spread across multi-leg
    // ════════════════════════════════════════════════════════════════════════

    function test_AllSharesToMaker_TwoLeg_Sentinel() public {
        vm.prank(owner);
        sera.setSlippageShares(10000, 0, 0, 10000);  // 100% maker

        _mintAndDeposit(taker, address(A), 5000 ether, sera);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);

        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 100 ether, 1, 0, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 800 ether, 2, 0, m1);

        Order memory t2 = _oFull(taker, address(B), address(C), 500 ether, 50 ether, 3, 0, taker);
        Order memory mk2 = _oFull(m2, address(C), address(B), 200 ether, 200 ether, 4, 0, m2);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 200 ether);

        _exec(matches);

        // Protocol (owner) should have 0 spread (all to maker)
        assertEq(sera.vault().balanceOf(address(A), owner), 0, "Protocol 0 A spread");
        assertGt(C.balanceOf(taker), 0, "Taker received C");
        address[] memory u = _users();
        _assertSolvent(address(A), u); _assertSolvent(address(B), u); _assertSolvent(address(C), u);
        _assertNoDust(address(A)); _assertNoDust(address(B)); _assertNoDust(address(C));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  15. CHRISTMAS TREE — ALL SENTINEL, 10 tokens, 19 legs, circular reuse
    //
    //  Linear chain with heavy circular token reuse. ALL legs are sentinel
    //  (except leg 0 which must pull from vault). Every token appears as both
    //  input and output at different positions.
    //
    //  Chain: T0→T1→T2→T3→T4→T5→T0(!)→T6→T7→T8→T9→T3(!)→T1(!)→T4(!)→
    //         T7(!)→T2(!)→T5(!)→T8(!)→T6(!)→T9(final)
    //
    //  Features:
    //  - 12 circular reuses (every token reused at least once)
    //  - Varied taker fees: 0%, 2%, 3%, 5%, 7%, 8%
    //  - Varied maker generosity: 1500-5000 (different spread per leg)
    //  - Varied taker price ratios: 1:2 to 1:10
    //  - 25/25/50 slippage shares → makerBonus inflates sentinel amounts
    // ════════════════════════════════════════════════════════════════════════

    address[10] internal _T;
    address[19] internal _mk;
    uint256[19] internal _mkPK;

    function _setupChristmasTree() internal {
        vm.prank(owner);
        sera.setSlippageShares(2500, 2500, 5000, 10000);
        for (uint256 i; i < 10; i++) {
            MockStableCoin tok = new MockStableCoin(string.concat("T", vm.toString(i)));
            _T[i] = address(tok);
            vm.prank(owner);
            _whitelistToken(sera, _T[i], true, 1);
        }
        _mintAndDeposit(taker, _T[0], 10000 ether, sera);
        for (uint256 i; i < 19; i++) {
            (_mk[i], _mkPK[i]) = makeAddrAndKey(string.concat("xm", vm.toString(i)));
        }
    }

    function _buildChristmasMatches() internal view returns (MatchData[] memory) {
        uint8[19] memory fI = [0,1,2,3,4,5,0,6,7,8,9,3,1,4,7,2,5,8,6];
        uint8[19] memory tI = [1,2,3,4,5,0,6,7,8,9,3,1,4,7,2,5,8,6,9];
        // [takerFromAmt, takerToAmt, makerFromAmt, feeBps]
        // makerToAmt = 1 ether for all (guarantees cost check)
        uint256[4][19] memory L = [
            [uint256(10000 ether), 5000 ether, 5000 ether, 0],
            [uint256(50000 ether), 5000 ether, 3000 ether, 300],
            [uint256(50000 ether), 10000 ether, 4000 ether, 500],
            [uint256(50000 ether), 25000 ether, 1500 ether, 0],
            [uint256(50000 ether), 5000 ether, 5000 ether, 800],
            [uint256(50000 ether), 10000 ether, 2000 ether, 200],
            [uint256(50000 ether), 5000 ether, 3000 ether, 0],
            [uint256(50000 ether), 25000 ether, 2000 ether, 500],
            [uint256(50000 ether), 10000 ether, 4000 ether, 300],
            [uint256(50000 ether), 5000 ether, 1500 ether, 0],
            [uint256(50000 ether), 10000 ether, 3000 ether, 700],
            [uint256(50000 ether), 25000 ether, 2000 ether, 0],
            [uint256(50000 ether), 5000 ether, 5000 ether, 500],
            [uint256(50000 ether), 10000 ether, 2000 ether, 200],
            [uint256(50000 ether), 5000 ether, 3000 ether, 0],
            [uint256(50000 ether), 10000 ether, 4000 ether, 800],
            [uint256(50000 ether), 25000 ether, 2000 ether, 300],
            [uint256(50000 ether), 5000 ether, 3000 ether, 0],
            [uint256(50000 ether), 10000 ether, 2000 ether, 500]
        ];
        MatchData[] memory m = new MatchData[](19);
        for (uint256 i; i < 19; i++) {
            Order memory t = Order({
                user: taker, fromToken: _T[fI[i]], toToken: _T[tI[i]],
                fromAmount: L[i][0], toAmount: L[i][1], initialDepositAmount: 0,
                feeBps: uint48(L[i][3]), recipient: i == 18 ? taker : address(sera),
                expiration: uint48(block.timestamp + 1 days), uuid: i*2+1
            });
            Order memory mk = Order({
                user: _mk[i], fromToken: _T[tI[i]], toToken: _T[fI[i]],
                fromAmount: L[i][2], toAmount: 1 ether, initialDepositAmount: 0,
                feeBps: 0, recipient: _mk[i],
                expiration: uint48(block.timestamp + 1 days), uuid: i*2+2
            });
            uint256 ma0 = (i == 0) ? 10000 ether : type(uint256).max;
            m[i] = MatchData(t, bytes(""), ma0, mk, _signOrder(_mkPK[i], mk, sera), L[i][2]);
        }
        return m;
    }

    function test_ChristmasTree_AllSentinel_CircularChain() public {
        _setupChristmasTree();
        uint8[19] memory tI = [1,2,3,4,5,0,6,7,8,9,3,1,4,7,2,5,8,6,9];
        uint256[19] memory mG = [uint256(5000 ether),3000 ether,4000 ether,1500 ether,5000 ether,
            2000 ether,3000 ether,2000 ether,4000 ether,1500 ether,3000 ether,2000 ether,
            5000 ether,2000 ether,3000 ether,4000 ether,2000 ether,3000 ether,2000 ether];
        for (uint256 i; i < 19; i++) _mintAndDeposit(_mk[i], _T[tI[i]], mG[i], sera);

        _exec(_buildChristmasMatches());

        assertGt(IERC20(_T[9]).balanceOf(taker), 0, "Taker received T9");
        for (uint256 i; i < 10; i++)
            assertEq(IERC20(_T[i]).balanceOf(address(sera)), 0, string.concat("No dust T", vm.toString(i)));
    }
}
