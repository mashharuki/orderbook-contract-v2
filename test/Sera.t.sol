// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts/utils/Pausable.sol";
import "../src/mock/MockStableCoin.sol";
import "../src/Sera.sol";
import "../src/SeraBatcher.sol";
import "../src/SeraSOR.sol";
import "../src/interface/IVault.sol";
import "../src/SeraAdmin.sol";
import {InvalidCostAmount} from "../src/SeraLib.sol";
import {console2} from "forge-std/console2.sol";

import "./TestHelper.sol";

// Exposes internal functions for testing.
contract SeraHarness is Sera {
    constructor(address initialOwner, Vault _vault) Sera(initialOwner, _vault) {}

    function expose_calculateSettlement(
        MatchData calldata _match,
        uint256 executionValue0,
        uint256 executionValue1,
        bytes32 orderHash0,
        bytes32 orderHash1
    ) external returns (Sera.SettlementCalc memory) {
        return _calculateSettlement(_match, executionValue0, executionValue1, _match.matchAmount0, _match.matchAmount1, orderHash0, orderHash1);
    }
}

/**
 * @title SeraTest
 * @dev Core unit tests for Sera intent-based order matching.
 */
contract SeraTest is TestHelper {
    MockStableCoin USDT;
    MockStableCoin SGD;
    Sera orderBook;
    SeraSOR sor_;
    SeraBatcher batcher;

    address owner;
    uint256 ownerPK;

    event MatchFailed(bytes32 indexed orderHash0, bytes32 indexed orderHash1, bytes reason, uint256 indexed batchIndex);

    function setUp() public {
        (owner, ownerPK) = makeAddrAndKey("owner");

        USDT = new MockStableCoin("USDT");
        SGD = new MockStableCoin("SGD");

        // Deploy Sera directly
        orderBook = _deploySera(owner);

        vm.startPrank(owner);
        _whitelistToken(orderBook, address(USDT), true, 1);
        _whitelistToken(orderBook, address(SGD), true, 1);

        // Grant EXECUTOR_ROLE to this test contract so it can match orders
        orderBook.grantRole(orderBook.EXECUTOR_ROLE(), address(this));

        // Deploy execution wrappers
        sor_ = new SeraSOR(address(orderBook));
        batcher = new SeraBatcher(address(orderBook), address(sor_));

        // Allow wrappers to call Sera.matchOrders()
        orderBook.grantRole(orderBook.EXECUTOR_ROLE(), address(batcher));
        vm.stopPrank();
    }

    // ============================================================================
    // HELPERS
    // ============================================================================

    function _hashTypedData(string memory name, string memory version, address verifyingContract, bytes32 structHash)
        internal
        view
        returns (bytes32)
    {
        bytes32 TYPE_HASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

        bytes32 domainSeparator = keccak256(
            abi.encode(TYPE_HASH, keccak256(bytes(name)), keccak256(bytes(version)), block.chainid, verifyingContract)
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _createMakerOrder(
        address user,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 toAmount,
        uint256 salt
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
            uuid: salt
        });
    }

    // ============================================================================
    // TESTS
    // ============================================================================

    function test_matchOrders_FullFill() public {
        (address user1, uint256 user1PK) = makeAddrAndKey("user1");
        (address user2, uint256 user2PK) = makeAddrAndKey("user2");

        _mintAndDeposit(user1, address(USDT), 1000 ether, orderBook);
        _mintAndDeposit(user2, address(SGD), 1000 ether, orderBook);

        Order memory order1 = _createMakerOrder(user1, address(USDT), address(SGD), 1000 ether, 100 ether, 1);
        bytes memory sig1 = _signOrder(user1PK, order1, orderBook);

        Order memory order2 = _createMakerOrder(user2, address(SGD), address(USDT), 100 ether, 1000 ether, 2);
        bytes memory sig2 = _signOrder(user2PK, order2, orderBook);

        MatchData memory matchData = MatchData({
            order0: order1,
            signature0: sig1,
            matchAmount0: 1000 ether,
            order1: order2,
            signature1: sig2,
            matchAmount1: 100 ether
        });

        orderBook.matchOrders(matchData, type(uint256).max);

        assertEq(USDT.balanceOf(user2), 1000 ether);
        assertEq(SGD.balanceOf(user1), 100 ether);
    }

    function test_matchOrders_PartialFill() public {
        (address user1, uint256 user1PK) = makeAddrAndKey("user1");
        (address user2, uint256 user2PK) = makeAddrAndKey("user2");

        _mintAndDeposit(user1, address(USDT), 1000 ether, orderBook);
        _mintAndDeposit(user2, address(SGD), 1000 ether, orderBook);

        Order memory order1 = _createMakerOrder(user1, address(USDT), address(SGD), 1000 ether, 100 ether, 1);
        bytes memory sig1 = _signOrder(user1PK, order1, orderBook);

        Order memory order2 = _createMakerOrder(user2, address(SGD), address(USDT), 50 ether, 500 ether, 2);
        bytes memory sig2 = _signOrder(user2PK, order2, orderBook);

        MatchData memory matchData = MatchData({
            order0: order1,
            signature0: sig1,
            matchAmount0: 500 ether,
            order1: order2,
            signature1: sig2,
            matchAmount1: 50 ether
        });

        orderBook.matchOrders(matchData, type(uint256).max);

        assertEq(USDT.balanceOf(user2), 500 ether);
        assertEq(SGD.balanceOf(user1), 50 ether);

        // Verify state
        bytes32 hash1 = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order1.user,
                order1.expiration,
                order1.feeBps,
                order1.recipient,
                order1.fromToken,
                order1.toToken,
                order1.fromAmount,
                order1.toAmount,
                order1.initialDepositAmount,
                order1.uuid
            )
        );
        assertEq(orderBook.filledAmount(hash1), 500 ether);
    }

    function test_matchOrders_WithFee() public {
        (address user1, uint256 user1PK) = makeAddrAndKey("user1");
        (address user2, uint256 user2PK) = makeAddrAndKey("user2");

        _mintAndDeposit(user1, address(USDT), 1000 ether, orderBook);
        _mintAndDeposit(user2, address(SGD), 1000 ether, orderBook);

        Order memory order1 = _createMakerOrder(user1, address(USDT), address(SGD), 1000 ether, 100 ether, 1);
        order1.feeBps = 10_000_000_000_000; // 10%
        bytes memory sig1 = _signOrder(user1PK, order1, orderBook);

        Order memory order2 = _createMakerOrder(user2, address(SGD), address(USDT), 100 ether, 1000 ether, 2);
        order2.feeBps = 10_000_000_000_000; // 10%
        bytes memory sig2 = _signOrder(user2PK, order2, orderBook);

        MatchData memory matchData = MatchData({
            order0: order1,
            signature0: sig1,
            matchAmount0: 500 ether,
            order1: order2,
            signature1: sig2,
            matchAmount1: 50 ether
        });

        orderBook.matchOrders(matchData, type(uint256).max);

        // User1 receives 50 SGD - 10% = 45 SGD
        // User2 receives 500 USDT - 10% = 450 USDT
        assertEq(SGD.balanceOf(user1), 45 ether);
        assertEq(USDT.balanceOf(user2), 450 ether);

        assertEq(orderBook.vault().balanceOf(address(SGD), owner), 5 ether);
        assertEq(orderBook.vault().balanceOf(address(USDT), owner), 50 ether);
    }

    function test_matchOrders_MakerZeroFee_TakerPaysFee() public {
        (address maker, uint256 makerPK) = makeAddrAndKey("maker");
        (address taker, uint256 takerPK) = makeAddrAndKey("taker");

        _mintAndDeposit(maker, address(USDT), 1000 ether, orderBook);
        _mintAndDeposit(taker, address(SGD), 1000 ether, orderBook);

        // Maker limit order: 0% fee
        Order memory makerOrder = _createMakerOrder(maker, address(USDT), address(SGD), 1000 ether, 100 ether, 1);
        makerOrder.feeBps = 0; // Maker pays ZERO fees
        bytes memory makerSig = _signOrder(makerPK, makerOrder, orderBook);

        // Taker market order: 5% fee (500 bps)
        Order memory takerOrder = _createMakerOrder(taker, address(SGD), address(USDT), 100 ether, 1000 ether, 2);
        takerOrder.feeBps = 5_000_000_000_000; // Taker pays 5% fees
        bytes memory takerSig = _signOrder(takerPK, takerOrder, orderBook);

        MatchData memory matchData = MatchData({
            order0: makerOrder,
            signature0: makerSig,
            matchAmount0: 1000 ether, // full match
            order1: takerOrder,
            signature1: takerSig,
            matchAmount1: 100 ether // full match
        });

        orderBook.matchOrders(matchData, type(uint256).max);

        // Maker receives 100 SGD exactly (no fee deduction)
        assertEq(SGD.balanceOf(maker), 100 ether);

        // Taker receives 1000 USDT minus 5% fee (50 USDT) = 950 USDT
        assertEq(USDT.balanceOf(taker), 950 ether);

        // Treasury receives only the 50 USDT from the taker
        assertEq(orderBook.vault().balanceOf(address(USDT), owner), 50 ether);
        assertEq(orderBook.vault().balanceOf(address(SGD), owner), 0 ether);
    }

    function test_matchOrders_FrozenUser_Reverts() public {
        (address user1, uint256 user1PK) = makeAddrAndKey("user1");
        (address user2, uint256 user2PK) = makeAddrAndKey("user2");

        _mintAndDeposit(user1, address(USDT), 1000 ether, orderBook);

        Vault v = orderBook.vault();
        vm.prank(owner);
        v.setBlacklisted(user1, true);

        Order memory order1 = _createMakerOrder(user1, address(USDT), address(SGD), 1000 ether, 100 ether, 1);
        bytes memory sig1 = _signOrder(user1PK, order1, orderBook);

        Order memory order2 = _createMakerOrder(user2, address(SGD), address(USDT), 100 ether, 1000 ether, 2);
        bytes memory sig2 = _signOrder(user2PK, order2, orderBook);

        MatchData memory matchData = MatchData({
            order0: order1,
            signature0: sig1,
            matchAmount0: 1000 ether,
            order1: order2,
            signature1: sig2,
            matchAmount1: 100 ether
        });

        vm.expectRevert(abi.encodeWithSelector(IVault.BlacklistedUser.selector, user1));
        orderBook.matchOrders(matchData, type(uint256).max);
    }

    function test_matchOrders_OverFill_Reverts() public {
        (address user1, uint256 user1PK) = makeAddrAndKey("user1");
        (address user2, uint256 user2PK) = makeAddrAndKey("user2");

        _mintAndDeposit(user1, address(USDT), 1000 ether, orderBook);
        _mintAndDeposit(user2, address(SGD), 2000 ether, orderBook);

        Order memory order1 = _createMakerOrder(user1, address(USDT), address(SGD), 1000 ether, 100 ether, 1);
        bytes memory sig1 = _signOrder(user1PK, order1, orderBook);

        Order memory order2 = _createMakerOrder(user2, address(SGD), address(USDT), 2000 ether, 20000 ether, 2);
        bytes memory sig2 = _signOrder(user2PK, order2, orderBook);

        MatchData memory matchData = MatchData({
            order0: order1,
            signature0: sig1,
            matchAmount0: 1001 ether,
            order1: order2,
            signature1: sig2,
            matchAmount1: 100.1 ether
        });

        vm.expectRevert(Sera.OrderFilledAmountExceeded.selector);
        orderBook.matchOrders(matchData, type(uint256).max);
    }

    function test_matchOrders_RoundingExploit_Reverts() public {
        (address maker, uint256 makerPK) = makeAddrAndKey("maker");
        (address taker, uint256 takerPK) = makeAddrAndKey("taker");

        _mintAndDeposit(maker, address(USDT), 1000 ether, orderBook);
        _mintAndDeposit(taker, address(SGD), 1000 ether, orderBook);

        // Maker sells 1e9 USDT for 1e6 SGD (Rate: 1000 USDT per 1 SGD)
        Order memory makerOrder = _createMakerOrder(maker, address(USDT), address(SGD), 1_000_000_000, 1_000_000, 1);
        bytes memory makerSig = _signOrder(makerPK, makerOrder, orderBook);

        Order memory takerOrder = _createMakerOrder(taker, address(SGD), address(USDT), 1_000_000, 1_000_000_000, 2);
        bytes memory takerSig = _signOrder(takerPK, takerOrder, orderBook);

        // Attacker asks for 1999 USDT, which would cost 1.999 SGD.
        // Integer division without Ceiling rounding would only charge 1 SGD.
        MatchData memory matchData = MatchData({
            order0: makerOrder,
            signature0: makerSig,
            matchAmount0: 1999, // Requests 1999 USDT
            order1: takerOrder,
            signature1: takerSig,
            matchAmount1: 1 // Only pays 1 SGD
        });

        vm.expectRevert(InvalidCostAmount.selector);
        orderBook.matchOrders(matchData, type(uint256).max);
    }

    function test_matchOrders_DustRounding_Precision() public {
        (address maker, uint256 makerPK) = makeAddrAndKey("maker");
        (address taker, uint256 takerPK) = makeAddrAndKey("taker");

        _mintAndDeposit(maker, address(USDT), 1000 ether, orderBook);
        _mintAndDeposit(taker, address(SGD), 1000 ether, orderBook);

        // Maker sells 100 USDT for 10 SGD
        Order memory makerOrder = _createMakerOrder(maker, address(USDT), address(SGD), 100 ether, 10 ether, 1);
        bytes memory makerSig = _signOrder(makerPK, makerOrder, orderBook);

        // Taker specifically asks for 1 wei of USDT.
        // 1 wei USDT * 10 SGD / 100 USDT = 0 SGD mathematically.
        Order memory takerOrder = _createMakerOrder(taker, address(SGD), address(USDT), 10 ether, 100 ether, 2);
        bytes memory takerSig = _signOrder(takerPK, takerOrder, orderBook);

        MatchData memory matchData = MatchData({
            order0: makerOrder,
            signature0: makerSig,
            matchAmount0: 1, // 1 wei
            order1: takerOrder,
            signature1: takerSig,
            matchAmount1: 1 // Providing 1 wei SGD
        });

        // The system explicitly blocks matches where the calculated cost violates the exchange rate.
        vm.expectRevert(InvalidCostAmount.selector);
        orderBook.matchOrders(matchData, type(uint256).max);
    }

    function test_batchMatchOrders() public {
        (address user1, uint256 user1PK) = makeAddrAndKey("user1");
        (address user2, uint256 user2PK) = makeAddrAndKey("user2");

        _mintAndDeposit(user1, address(USDT), 2000 ether, orderBook);
        _mintAndDeposit(user2, address(SGD), 2000 ether, orderBook);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = _makeFullPair(user1, user1PK, user2, user2PK, 1, 2);
        matches[1] = _makeFullPair(user1, user1PK, user2, user2PK, 3, 4);

        uint256 failedMask = batcher.batchMatchOrders(matches, type(uint256).max);
        assertEq(failedMask, 0);

        assertEq(USDT.balanceOf(user2), 2000 ether);
        assertEq(SGD.balanceOf(user1), 200 ether);
    }

    function _makeFullPair(address user1, uint256 user1PK, address user2, uint256 user2PK, uint256 uuid1, uint256 uuid2)
        internal
        view
        returns (MatchData memory)
    {
        Order memory o1 = _createMakerOrder(user1, address(USDT), address(SGD), 1000 ether, 100 ether, uuid1);
        Order memory o2 = _createMakerOrder(user2, address(SGD), address(USDT), 100 ether, 1000 ether, uuid2);
        return MatchData(
            o1, _signOrder(user1PK, o1, orderBook), 1000 ether, o2, _signOrder(user2PK, o2, orderBook), 100 ether
        );
    }

    function test_withdrawRequestFlow() public {
        (address user,) = makeAddrAndKey("user");
        _mintAndDeposit(user, address(USDT), 100 ether, orderBook);

        vm.prank(user);
        orderBook.emergencyWithdraw(address(USDT), 100 ether);

        vm.roll(block.number + 7201);

        vm.prank(user);
        orderBook.emergencyWithdraw(address(USDT), 100 ether);

        assertEq(USDT.balanceOf(user), 100 ether);
    }

    function test_instantWithdraw_bulk() public {
        (address user, uint256 userPK) = makeAddrAndKey("user");

        _mintAndDeposit(user, address(USDT), 100 ether, orderBook);
        _mintAndDeposit(user, address(SGD), 100 ether, orderBook);

        address[] memory tokens = new address[](2);
        tokens[0] = address(USDT);
        tokens[1] = address(SGD);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50 ether;
        amounts[1] = 50 ether;

        WithdrawIntent memory intent = WithdrawIntent({
            user: user,
            tokens: tokens,
            amounts: amounts,
            recipient: user,
            deadline: block.timestamp + 1 hours,
            uuid: 123
        });

        bytes32[] memory tokenWords = new bytes32[](intent.tokens.length);
        for (uint256 i; i < intent.tokens.length; i++) {
            tokenWords[i] = bytes32(uint256(uint160(intent.tokens[i])));
        }
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "WithdrawIntent(address user,address[] tokens,uint256[] amounts,address recipient,uint256 deadline,uint256 uuid)"
                ),
                intent.user,
                keccak256(abi.encodePacked(tokenWords)),
                keccak256(abi.encodePacked(intent.amounts)),
                intent.recipient,
                intent.deadline,
                intent.uuid
            )
        );
        bytes32 digest = _hashTypedData("Sera", "1", address(orderBook), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPK, digest);
        bytes memory userSig = abi.encodePacked(r, s, v);

        (uint8 ev, bytes32 er, bytes32 es) = vm.sign(ownerPK, digest);
        bytes memory executorSig = abi.encodePacked(er, es, ev);

        orderBook.executeInstantWithdrawDualSig(intent, userSig, owner, executorSig);

        assertEq(USDT.balanceOf(user), 50 ether);
        assertEq(SGD.balanceOf(user), 50 ether);
    }

    function test_vault_deposit_overloaded() public {
        (address user,) = makeAddrAndKey("user");
        Vault vault = orderBook.vault();

        USDT.mint(user, 100 ether);
        vm.prank(user);
        USDT.approve(address(vault), 100 ether);

        vm.prank(address(orderBook));
        vault.deposit(user, address(USDT), 100 ether);

        assertEq(vault.balanceOf(address(USDT), user), 100 ether);
    }

    function test_depositFundWithPermit_PartialDeposit() public {
        (address user, uint256 userPK) = makeAddrAndKey("user");
        uint256 permitAmount = 100 ether;
        uint256 depositAmount = 50 ether;

        USDT.mint(user, permitAmount);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPermit(userPK, address(USDT), address(orderBook.vault()), permitAmount, deadline);

        // Execute strict deposit
        orderBook.depositFundWithPermit(address(USDT), user, permitAmount, depositAmount, deadline, sig);

        // Check Vault balance matches depositAmount (50)
        assertEq(orderBook.vault().balanceOf(address(USDT), user), depositAmount);

        // Check User wallet balance matches remaining (50)
        assertEq(USDT.balanceOf(user), permitAmount - depositAmount);
    }

    function test_depositFundWithPermit_FrontRunDoS_Protection() public {
        (address user, uint256 userPK) = makeAddrAndKey("user");
        uint256 permitAmount = 100 ether;
        uint256 depositAmount = 50 ether;

        USDT.mint(user, permitAmount);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPermit(userPK, address(USDT), address(orderBook.vault()), permitAmount, deadline);

        // Simulate a front-runner extracting the signature and calling `permit` directly
        // This consumes the user's nonce and sets the allowance off-chain from our Sera flow
        uint8 v;
        bytes32 r;
        bytes32 s;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }

        vm.prank(address(0xbad));
        USDT.permit(user, address(orderBook.vault()), permitAmount, deadline, v, r, s);

        // Fast forward to actual deposit execution.
        // The Vault already has the allowance from the front-runner's permit call.
        // The inner `permit` call inside `depositFundWithPermit` will fail because the nonce is used.
        // However, thanks to the Issue 2 fix, the transaction should gracefully continue and succeed!
        orderBook.depositFundWithPermit(address(USDT), user, permitAmount, depositAmount, deadline, sig);

        // Check Vault balance matches depositAmount (50)
        assertEq(orderBook.vault().balanceOf(address(USDT), user), depositAmount);

        // Check User wallet balance matches remaining (50)
        assertEq(USDT.balanceOf(user), permitAmount - depositAmount);
    }

    function test_matchOrders_FrozenUser() public {
        (address user1, uint256 user1PK) = makeAddrAndKey("user1");
        (address user2, uint256 user2PK) = makeAddrAndKey("user2");

        _mintAndDeposit(user1, address(USDT), 1000 ether, orderBook);
        _mintAndDeposit(user2, address(SGD), 1000 ether, orderBook);

        Order memory order1 = _createMakerOrder(user1, address(USDT), address(SGD), 1000 ether, 100 ether, 1);
        bytes memory sig1 = _signOrder(user1PK, order1, orderBook);

        Order memory order2 = _createMakerOrder(user2, address(SGD), address(USDT), 100 ether, 1000 ether, 2);
        bytes memory sig2 = _signOrder(user2PK, order2, orderBook);

        MatchData memory data = MatchData({
            order0: order1,
            signature0: sig1,
            matchAmount0: 1000 ether,
            order1: order2,
            signature1: sig2,
            matchAmount1: 100 ether
        });

        // Freeze maker using new API
        Vault v1 = orderBook.vault();
        vm.prank(owner);
        v1.setBlacklisted(user1, true);

        // Try to match, should fail
        vm.expectRevert(abi.encodeWithSelector(IVault.BlacklistedUser.selector, user1));
        orderBook.matchOrders(data, type(uint256).max);
    }

    function test_batchMatchOrders_EmitsHashOnFailure() public {
        (address user1, uint256 user1PK) = makeAddrAndKey("user1");
        (address user2, uint256 user2PK) = makeAddrAndKey("user2");

        _mintAndDeposit(user1, address(USDT), 1000 ether, orderBook);
        _mintAndDeposit(user2, address(SGD), 1000 ether, orderBook);

        // Order 1: Expired
        Order memory order1 = _createMakerOrder(user1, address(USDT), address(SGD), 1000 ether, 100 ether, 1);
        order1.expiration = uint48(block.timestamp - 1);
        bytes memory sig1 = _signOrder(user1PK, order1, orderBook);

        // Order 2: Valid
        Order memory order2 = _createMakerOrder(user2, address(SGD), address(USDT), 100 ether, 1000 ether, 2);
        bytes memory sig2 = _signOrder(user2PK, order2, orderBook);

        MatchData memory matchData = MatchData({
            order0: order1,
            signature0: sig1,
            matchAmount0: 1000 ether,
            order1: order2,
            signature1: sig2,
            matchAmount1: 100 ether
        });

        MatchData[] memory batch = new MatchData[](1);
        batch[0] = matchData;

        bytes32 h0 = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order1.user,
                order1.expiration,
                order1.feeBps,
                order1.recipient,
                order1.fromToken,
                order1.toToken,
                order1.fromAmount,
                order1.toAmount,
                order1.initialDepositAmount,
                order1.uuid
            )
        );
        bytes32 h1 = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order2.user,
                order2.expiration,
                order2.feeBps,
                order2.recipient,
                order2.fromToken,
                order2.toToken,
                order2.fromAmount,
                order2.toAmount,
                order2.initialDepositAmount,
                order2.uuid
            )
        );

        vm.expectEmit(true, true, false, true, address(batcher));
        emit MatchFailed(h0, h1, abi.encodeWithSelector(Sera.OrderExpired.selector), 0);

        batcher.batchMatchOrders(batch, type(uint256).max);
    }

    function test_calculateSettlement_ExactMath() public {
        // Deploy harness exactly like `orderBook`
        Vault v = new Vault(owner);
        SeraHarness harness = new SeraHarness(owner, v);

        address u1 = address(111);
        address u2 = address(222);

        // Setup mock orders
        // User 0 expects to pay 100 USDT for 100 SGD (Fee: 1000 bps = 10%)
        Order memory o0 = _createMakerOrder(u1, address(USDT), address(SGD), 100 ether, 100 ether, 1);
        o0.feeBps = 10_000_000_000_000;

        // User 1 expects to pay 100 SGD for 100 USDT (Fee: 500 bps = 5%)
        Order memory o1 = _createMakerOrder(u2, address(SGD), address(USDT), 100 ether, 100 ether, 2);
        o1.feeBps = 5_000_000_000_000;

        // Let's set the slippage explicitly as:
        // Treasury: 50%, Maker: 25%, Taker: 25% to verify exactly how it breaks down.
        vm.prank(owner);
        harness.setSlippageShares(2500, 2500, 5000, 10000); // maker: 25%, taker: 25%, protocol: 50%, sum: 100%
        // There is a 5 SGD spread here! User 0 only expected 100 SGD.
        MatchData memory matchData = MatchData({
            order0: o0,
            signature0: "",
            matchAmount0: 100 ether,
            order1: o1,
            signature1: "",
            matchAmount1: 105 ether
        });

        // executionValue0 refers to how much SGD User 0 mathematically EXPECTS
        // executionValue1 refers to how much USDT User 1 mathematically EXPECTS
        uint256 execVal0 = 100 ether;
        uint256 execVal1 = 100 ether;

        bytes32 hash0 = keccak256("hash0");
        bytes32 hash1 = keccak256("hash1");

        // Execute Settlement calculation exactly as Sera would
        Sera.SettlementCalc memory calc =
            harness.expose_calculateSettlement(matchData, execVal0, execVal1, hash0, hash1);

        // Assert 0: executionValue0 (Amount of Token 1 / SGD requested by User 1 / Taker)
        // Base request: 100 SGD.
        // Taker provides 105 SGD (totalSpread1 = 5 SGD surplus).
        // Maker explicitly receives their share of the bonus (makerBonus1 = 25% = 1.25 SGD).
        // ExecutionValue0 = 100 base + 1.25 makerBonus1 = 101.25 SGD.
        assertEq(calc.executionValue0, 101.25 ether);

        // Assert 1: executionValue1 (Amount of Token 0 / USDT requested by User 0 / Maker)
        // Base request: 100 USDT.
        // Maker provides 100 USDT (totalSpread0 = 0 USDT surplus).
        // Taker explicitly receives their share of the bonus (takerBonus0 = 0).
        // ExecutionValue1 = 100 base = 100 USDT.
        assertEq(calc.executionValue1, 100 ether);

        // Assert 2: User 0 pays 10% on their received 100 SGD (executionValue0 base)
        assertEq(calc.protocolFee1, 10 ether);

        // Assert 3: User 1 pays 5% on their received 100 USDT (match.matchAmount0)
        assertEq(calc.protocolFee0, 5 ether);

        // Assert 4: Protocol Take (Treasury Revenue)
        // Token 0 (USDT) Treasury Take = Fee0 (5 USDT) + Spread0 (0 USDT Protocol Share) = 5 USDT
        assertEq(calc.protocolTake0, 5 ether);

        // Token 1 (SGD) Treasury Take = Fee1 (10 SGD) + Spread1 (50% of 5 SGD = 2.5 SGD) = 12.5 SGD
        assertEq(calc.protocolTake1, 12.5 ether);

        // --- Implicit Rebate Verification ---
        // In _collectAndDistribute, the vault pulls from the Taker:
        //   Payout to Maker: calc.executionValue0 - calc.protocolFee1 = 101.25 - 10 = 91.25 SGD
        //   Treasury take:   calc.protocolTake1 = 12.5 SGD
        //   Total pulled:    91.25 + 12.5 = 103.75 SGD (out of 105 SGD max → 1.25 SGD implicit rebate)
        //
        // From the Maker, the vault pulls:
        //   Payout to Taker: calc.executionValue1 - calc.protocolFee0 = 100 - 5 = 95 USDT
        //   Treasury take:   calc.protocolTake0 = 5 USDT
        //   Total pulled:    95 + 5 = 100 USDT (exact, no surplus)

        // Assert 5: Filled amounts recorded
        assertEq(harness.filledAmount(hash0), 100 ether);
        assertEq(harness.filledAmount(hash1), 105 ether);

        // Assert 6: Full fill flags
        assertTrue(calc.order0FullyFilled); // 100 filled == 100 fromAmount
        assertTrue(calc.order1FullyFilled); // 105 filled >= 100 fromAmount
    }

    function test_calculateSettlement_PartialFill_ExactMath() public {
        // Example B from the mathematical outline:
        // Maker Order: Sell 50 ETH, Buy 80,000 USDC. (Fee: 8%)
        // Taker Order: Sell 82,000 USDC, Buy 40 ETH. (Fee: 2%)
        // System Config: Protocol Share: 40%, Maker Share: 30%, Taker Share: 30%.

        Vault v = new Vault(owner);
        SeraHarness harness = new SeraHarness(owner, v);
        address u1 = address(111);
        address u2 = address(222);

        // Maker sells 50 ETH for 80,000 USDC
        Order memory o0 = _createMakerOrder(u1, address(USDT), address(SGD), 50 ether, 80000 ether, 1);
        o0.feeBps = 8_000_000_000_000; // 8%

        // Taker sells 82,000 USDC for 40 ETH
        Order memory o1 = _createMakerOrder(u2, address(SGD), address(USDT), 82000 ether, 40 ether, 2);
        o1.feeBps = 2_000_000_000_000; // 2%

        vm.prank(owner);
        harness.setSlippageShares(3000, 3000, 4000, 10000); // maker: 30%, taker: 30%, protocol: 40%

        // Notice the partial fill amounts: The engine executes exactly what the Taker requested.
        MatchData memory matchData = MatchData({
            order0: o0,
            signature0: "",
            matchAmount0: 40 ether,
            order1: o1,
            signature1: "",
            matchAmount1: 82000 ether
        });

        // execVal0 represents Maker's base expected receipt (scaled for 40 ETH)
        // (40 / 50) * 80,000 = 64,000 USDC (SGD mock token here)
        uint256 execVal0 = 64000 ether;

        // execVal1 represents Taker's base expected receipt (40 ETH)
        // (82000 / 82000) * 40 = 40 (USDT mock token here)
        uint256 execVal1 = 40 ether;

        Sera.SettlementCalc memory calc =
            harness.expose_calculateSettlement(matchData, execVal0, execVal1, bytes32(0), bytes32(0));

        // Let's verify exactly the spread maths expected in Example B:
        // Surplus USDT (Token 0): 0 (Maker sent 40, Taker requested 40)
        // Surplus SGD (Token 1): Taker sent 82000, Maker expected 64000 = 18,000 surplus

        // ExecutionValue0 = Maker's SGD (USDC) payout
        // Base 64000 + Maker Spread (30% of 18000 = 5400) = 69400
        assertEq(calc.executionValue0, 69400 ether);

        // ExecutionValue1 = Taker's USDT (ETH) payout
        // Base 40 + Taker Spread (0) = 40
        assertEq(calc.executionValue1, 40 ether);

        // Protocol Fees (Assessed against Execution Base execution values)
        // Maker Fee: 8% of 64000 = 5120 SGD
        assertEq(calc.protocolFee1, 5120 ether);

        // Taker Fee: 2% of 40 = 0.8 USDT
        assertEq(calc.protocolFee0, 0.8 ether);

        // Protocol Revenue Take
        // Token 0 (USDT/ETH): 0.8 fee + 0 spread = 0.8 USDT
        assertEq(calc.protocolTake0, 0.8 ether);

        // Token 1 (SGD/USDC): 5120 fee + Protocol Spread (40% of 18000 = 7200) = 12,320 SGD
        assertEq(calc.protocolTake1, 12320 ether);

        // --- Implicit Rebate Verification ---
        // In _collectAndDistribute, the vault pulls from the Taker:
        //   Payout to Maker: calc.executionValue0 - calc.protocolFee1 = 69400 - 5120 = 64,280 USDC
        //   Treasury take:   calc.protocolTake1 = 12,320 USDC
        //   Total pulled:    64,280 + 12,320 = 76,600 USDC (out of 82,000 max → 5,400 USDC implicit rebate)
        //
        // From the Maker, the vault pulls:
        //   Payout to Taker: calc.executionValue1 - calc.protocolFee0 = 40 - 0.8 = 39.2 ETH
        //   Treasury take:   calc.protocolTake0 = 0.8 ETH
        //   Total pulled:    39.2 + 0.8 = 40 ETH (exact, no surplus)
    }

    function test_matchOrders_WrongTokens_Reverts() public {
        (address user1, uint256 user1PK) = makeAddrAndKey("user1");
        (address user2, uint256 user2PK) = makeAddrAndKey("user2");

        MockStableCoin EUR = new MockStableCoin("EUR");

        _mintAndDeposit(user1, address(USDT), 1000 ether, orderBook);
        _mintAndDeposit(user2, address(SGD), 1000 ether, orderBook);

        // Maker sells USDT for USDC
        Order memory order1 = _createMakerOrder(user1, address(USDT), address(EUR), 1000 ether, 100 ether, 1);
        bytes memory sig1 = _signOrder(user1PK, order1, orderBook);

        // Taker sells SGD for USDT (Token Mismatch)
        Order memory order2 = _createMakerOrder(user2, address(SGD), address(USDT), 100 ether, 1000 ether, 2);
        bytes memory sig2 = _signOrder(user2PK, order2, orderBook);

        MatchData memory matchData = MatchData({
            order0: order1,
            signature0: sig1,
            matchAmount0: 1000 ether,
            order1: order2,
            signature1: sig2,
            matchAmount1: 100 ether
        });

        vm.expectRevert(Sera.TokenMismatch.selector);
        orderBook.matchOrders(matchData, type(uint256).max);
    }

    function test_matchOrders_PriceExecution_Reverts() public {
        (address maker, uint256 makerPK) = makeAddrAndKey("maker");
        (address taker, uint256 takerPK) = makeAddrAndKey("taker");

        _mintAndDeposit(maker, address(USDT), 1000 ether, orderBook);
        _mintAndDeposit(taker, address(SGD), 1000 ether, orderBook);

        // Maker strictly wants 30 SGD for 100 USDT
        Order memory makerOrder = _createMakerOrder(maker, address(USDT), address(SGD), 100 ether, 30 ether, 1);
        bytes memory makerSig = _signOrder(makerPK, makerOrder, orderBook);

        // Taker gets a match execution submitted offering only 25 SGD
        Order memory takerOrder = _createMakerOrder(taker, address(SGD), address(USDT), 25 ether, 100 ether, 2);
        bytes memory takerSig = _signOrder(takerPK, takerOrder, orderBook);

        MatchData memory matchData = MatchData({
            order0: makerOrder,
            signature0: makerSig,
            matchAmount0: 100 ether,
            order1: takerOrder,
            signature1: takerSig,
            matchAmount1: 25 ether // Malicious executor tries to underpay the Maker
        });

        // The exact match execution validates the physical price constraints
        vm.expectRevert(InvalidCostAmount.selector);
        orderBook.matchOrders(matchData, type(uint256).max);
    }

    function test_fokBatch_RevertsOnAnyFailure() public {
        (address user1, uint256 user1PK) = makeAddrAndKey("fok_user1");
        (address user2, uint256 user2PK) = makeAddrAndKey("fok_user2");

        _mintAndDeposit(user1, address(USDT), 1000 ether, orderBook);
        _mintAndDeposit(user2, address(SGD), 1000 ether, orderBook);

        // Pair 1 valid
        Order memory o1 = _createMakerOrder(user1, address(USDT), address(SGD), 500 ether, 50 ether, 101);
        bytes memory s1 = _signOrder(user1PK, o1, orderBook);
        Order memory o2 = _createMakerOrder(user2, address(SGD), address(USDT), 50 ether, 500 ether, 102);
        bytes memory s2 = _signOrder(user2PK, o2, orderBook);

        // Pair 2 invalid (expired)
        Order memory o3 = _createMakerOrder(user1, address(USDT), address(SGD), 500 ether, 50 ether, 103);
        o3.expiration = uint48(block.timestamp - 1);
        bytes memory s3 = _signOrder(user1PK, o3, orderBook);
        Order memory o4 = _createMakerOrder(user2, address(SGD), address(USDT), 50 ether, 500 ether, 104);
        bytes memory s4 = _signOrder(user2PK, o4, orderBook);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(o1, s1, 500 ether, o2, s2, 50 ether);
        matches[1] = MatchData(o3, s3, 500 ether, o4, s4, 50 ether);

        vm.expectRevert();
        batcher.batchMatchOrdersAtomic(matches, type(uint256).max);

        // Atomicity check: first valid pair should also be reverted
        assertEq(USDT.balanceOf(user2), 0);
        assertEq(SGD.balanceOf(user1), 0);
    }
}
