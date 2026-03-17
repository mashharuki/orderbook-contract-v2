// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "./TestHelper.sol";
import "../src/SeraBatcher.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";

contract FakeSeraString {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    function hasRole(bytes32 role, address) external pure returns (bool) {
        return role == EXECUTOR_ROLE;
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function matchOrders(MatchData calldata) external pure {
        revert("oops");
    }

    function getOrderHash(Order calldata order) external pure returns (bytes32) {
        return keccak256(abi.encode(order.user, order.uuid));
    }

    function depositFundWithPermit(address, address, uint256, uint256, uint256, bytes calldata) external pure {}
}

contract SeraCoverageExtrasTest is TestHelper {
    Sera public sera;
    SeraBatcher public batcher;
    SeraSOR public sor;

    MockStableCoin public usdt;
    MockStableCoin public sgd;
    MockStableCoin public btc;

    address public owner;
    uint256 public ownerPK;
    address public executor;
    address public maker;
    uint256 public makerPK;
    address public taker;
    uint256 public takerPK;

    function setUp() public {
        (owner, ownerPK) = makeAddrAndKey("owner");
        executor = makeAddr("executor");
        (maker, makerPK) = makeAddrAndKey("maker");
        (taker, takerPK) = makeAddrAndKey("taker");

        usdt = new MockStableCoin("USDT");
        sgd = new MockStableCoin("SGD");
        btc = new MockStableCoin("BTC");

        sera = _deploySera(owner);
        batcher = new SeraBatcher(address(sera));
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(usdt), true, 1);
        _whitelistToken(sera, address(sgd), true, 1);
        _whitelistToken(sera, address(btc), true, 1);

        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(this));
        sera.grantRole(sera.EXECUTOR_ROLE(), address(batcher));
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        vm.stopPrank();

        _mintAndDeposit(taker, address(usdt), 2_000 ether, sera);
        _mintAndDeposit(maker, address(sgd), 400 ether, sera);
    }

    function test_coverage_sera_admin_paths() public {
        vm.startPrank(owner);
        vm.expectRevert(SeraAdmin.InvalidAddress.selector);
        sera.rescueToken(address(0), address(usdt));

        vm.expectRevert(abi.encodeWithSelector(SeraAdmin.InvalidToken.selector, address(0)));
        sera.rescueToken(owner, address(0));

        vm.expectRevert(SeraAdmin.NoBalance.selector);
        sera.rescueToken(owner, address(usdt));

        sera.pause();
        sera.unpause();
        vm.stopPrank();

        usdt.mint(address(sera), 5 ether);
        vm.prank(owner);
        sera.rescueToken(owner, address(usdt));
        assertEq(usdt.balanceOf(owner), 5 ether);

        bytes32 randomHash = keccak256("x");
        assertEq(sera.filledAmount(randomHash), 0);
    }

    function test_coverage_instantWithdraw_uuid_replay() public {
        (address user, uint256 userPK) = makeAddrAndKey("withdrawUser");
        _mintAndDeposit(user, address(usdt), 100 ether, sera);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdt);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        WithdrawIntent memory intent = WithdrawIntent({user: user, tokens: tokens, amounts: amounts, recipient: address(0), deadline: block.timestamp + 1 hours, uuid: 999});

        bytes32 structHash = keccak256(abi.encode(keccak256("WithdrawIntent(address user,address[] tokens,uint256[] amounts,address recipient,uint256 deadline,uint256 uuid)"), intent.user, keccak256(abi.encodePacked(intent.tokens)), keccak256(abi.encodePacked(intent.amounts)), intent.recipient, intent.deadline, intent.uuid));
        bytes32 typeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 domainSeparator = keccak256(abi.encode(typeHash, keccak256(bytes(sera.NAME())), keccak256(bytes(sera.VERSION())), block.chainid, address(sera)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // User Sig
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPK, digest);
        bytes memory userSig = abi.encodePacked(r, s, v);

        // Executor Sig
        (uint8 ev, bytes32 er, bytes32 es) = vm.sign(ownerPK, digest);
        bytes memory executorSig = abi.encodePacked(er, es, ev);

        sera.executeInstantWithdrawDualSig(intent, userSig, executorSig);

        vm.expectRevert(Sera.UuidAlreadyUsed.selector);
        sera.executeInstantWithdrawDualSig(intent, userSig, executorSig);
    }

    function test_coverage_payout_or_deposit_branch() public {
        (address user1, uint256 user1PK) = makeAddrAndKey("u1");
        (address user2, uint256 user2PK) = makeAddrAndKey("u2");

        _mintAndDeposit(user1, address(usdt), 1000 ether, sera);
        _mintAndDeposit(user2, address(sgd), 100 ether, sera);

        Order memory o0 = Order({user: user1, fromToken: address(usdt), toToken: address(sgd), fromAmount: 1000 ether, toAmount: 100 ether, initialDepositAmount: 0, feeBps: 0, recipient: user1, expiration: uint48(block.timestamp + 1 days), uuid: 10, routeHash: bytes32(0)});
        Order memory o1 = Order({user: user2, fromToken: address(sgd), toToken: address(usdt), fromAmount: 100 ether, toAmount: 1000 ether, initialDepositAmount: 0, feeBps: 0, recipient: address(0), expiration: uint48(block.timestamp + 1 days), uuid: 11, routeHash: bytes32(0)});

        MatchData memory m = MatchData({order0: o0, signature0: _signOrder(user1PK, o0, sera), matchAmount0: 1000 ether, order1: o1, signature1: _signOrder(user2PK, o1, sera), matchAmount1: 100 ether});

        uint256 beforeVaultCredit = sera.vault().balanceOf(address(usdt), user2);
        sera.matchOrders(m);
        uint256 afterVaultCredit = sera.vault().balanceOf(address(usdt), user2);

        assertEq(afterVaultCredit - beforeVaultCredit, 1000 ether);
        assertEq(usdt.balanceOf(user2), 0);
    }

    function test_coverage_vault_overloads_and_rescue() public {
        Vault v = sera.vault();

        (address user,) = makeAddrAndKey("vaultUser");
        _mintAndDeposit(user, address(usdt), 50 ether, sera);

        vm.prank(owner);
        v.setBlacklisted(user, true);

        vm.prank(address(sera));
        vm.expectRevert(abi.encodeWithSelector(IVault.BlacklistedUser.selector, user));
        v.creditLedger(user, address(usdt), 1);

        vm.prank(owner);
        v.setBlacklisted(user, false);

        vm.prank(address(sera));
        v.withdraw(user, address(usdt), 10 ether, user);
        assertEq(usdt.balanceOf(user), 10 ether);

        uint256 totalInVault = v.balanceOf(address(usdt));
        assertGe(totalInVault, 40 ether);

        vm.prank(owner);
        vm.expectRevert(IVault.ZeroAddress.selector);
        v.rescueToken(address(usdt), address(0), 1);

        vm.prank(owner);
        vm.expectRevert(IVault.CannotRescueTrackedFunds.selector);
        v.rescueToken(address(usdt), owner, 1);

        usdt.mint(address(v), 7 ether);
        vm.prank(owner);
        v.rescueToken(address(usdt), owner, 7 ether);
        assertEq(usdt.balanceOf(owner), 7 ether);
    }

    function test_coverage_batcher_error_string_catch() public {
        FakeSeraString fake = new FakeSeraString();
        SeraBatcher fakeBatcher = new SeraBatcher(address(fake));

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({order0: Order({user: address(0), fromToken: address(0), toToken: address(0), fromAmount: 0, toAmount: 0, initialDepositAmount: 0, feeBps: 0, recipient: address(0), expiration: 0, uuid: 0, routeHash: bytes32(0)}), signature0: hex"", matchAmount0: 1, order1: Order({user: address(0), fromToken: address(0), toToken: address(0), fromAmount: 0, toAmount: 0, initialDepositAmount: 0, feeBps: 0, recipient: address(0), expiration: 0, uuid: 0, routeHash: bytes32(0)}), signature1: hex"", matchAmount1: 1});

        uint256 failedMask = fakeBatcher.batchMatchOrders(matches);
        assertEq(failedMask, 1);
    }

    function test_coverage_sor_collision_wrap_branch() public {
        uint256 tableSize = 5;
        uint256 targetMod = uint256(uint160(address(sgd))) % tableSize;

        MockStableCoin colliding = _findCollidingToken(targetMod, tableSize);
        vm.prank(owner);
        _whitelistToken(sera, address(colliding), true, 1);

        (address mk2, uint256 mk2PK) = makeAddrAndKey("mk2");

        // Maker1 provides colliding token for leg1
        _mintAndDeposit(maker, address(colliding), 50 ether, sera);
        // Maker2 provides BTC for leg2
        _mintAndDeposit(mk2, address(btc), 1 ether, sera);

        // Leg 1: taker sells USDT, gets colliding token (held transient in Sera)
        Order memory takerLeg1 = Order({user: taker, fromToken: address(usdt), toToken: address(colliding), fromAmount: 1000 ether, toAmount: 50 ether, initialDepositAmount: 0, feeBps: 0, recipient: address(sera), expiration: uint48(block.timestamp + 1 days), uuid: 21, routeHash: bytes32(0)});
        Order memory makerLeg1 = Order({user: maker, fromToken: address(colliding), toToken: address(usdt), fromAmount: 50 ether, toAmount: 1000 ether, initialDepositAmount: 0, feeBps: 0, recipient: maker, expiration: uint48(block.timestamp + 1 days), uuid: 22, routeHash: bytes32(0)});

        Order memory takerLeg2 = Order({user: taker, fromToken: address(colliding), toToken: address(btc), fromAmount: 50 ether, toAmount: 1 ether, initialDepositAmount: 0, feeBps: 0, recipient: taker, expiration: uint48(block.timestamp + 1 days), uuid: 23, routeHash: bytes32(0)});
        Order memory makerLeg2 = Order({user: mk2, fromToken: address(btc), toToken: address(colliding), fromAmount: 1 ether, toAmount: 50 ether, initialDepositAmount: 0, feeBps: 0, recipient: mk2, expiration: uint48(block.timestamp + 1 days), uuid: 24, routeHash: bytes32(0)});

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(takerLeg1, "", 1000 ether, makerLeg1, _signOrder(makerPK, makerLeg1, sera), 50 ether);
        matches[1] = MatchData(takerLeg2, "", 50 ether, makerLeg2, _signOrder(mk2PK, makerLeg2, sera), 1 ether);

        bytes32 routeHash = _routeHash(matches);
        matches[0].order0.routeHash = routeHash;
        matches[1].order0.routeHash = routeHash;

        vm.prank(executor);
        sor.executeRoute(matches, _signRoute(takerPK, routeHash, sera));

        assertEq(btc.balanceOf(taker), 1 ether);
    }

    function _findCollidingToken(uint256 modValue, uint256 tableSize) internal returns (MockStableCoin) {
        for (uint256 i = 0; i < 40; i++) {
            MockStableCoin t = new MockStableCoin(string(abi.encodePacked("C", vm.toString(i))));
            if (uint256(uint160(address(t))) % tableSize == modValue && address(t) != address(sgd)) return t;
        }
        revert("no-collision-token");
    }

    function _routeHash(MatchData[] memory matches) internal pure returns (bytes32) {
        bytes memory packed;
        for (uint256 i = 0; i < matches.length; i++) {
            Order memory o = matches[i].order0;
            o.routeHash = bytes32(0);
            bytes32 h = keccak256(abi.encode(ORDER_TYPEHASH, o.user, o.expiration, o.feeBps, o.recipient, o.fromToken, o.toToken, o.fromAmount, o.toAmount, o.initialDepositAmount, bytes32(0), o.uuid));
            packed = bytes.concat(packed, abi.encodePacked(h));
        }
        return keccak256(packed);
    }
}
