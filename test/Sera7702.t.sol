// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

// EIP-7702 delegate that accepts signatures ecrecovering to the wallet's own
// address. Because `address(this)` under a 7702 delegation equals the EOA
// address, this authorizes signatures produced by the EOA's root private key.
contract Delegate7702Self is IERC1271 {
    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s) = _parse(signature);
        if (ecrecover(hash, v, r, s) == address(this)) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }

    function _parse(bytes memory sig) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        require(sig.length == 65, "bad sig len");
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
    }
}

// EIP-7702 delegate that authorizes an immutable session key rather than the
// EOA's root key. Mirrors the common wallet pattern where users delegate
// signing authority to a hot key while their root key stays cold.
contract Delegate7702Session is IERC1271 {
    address public immutable sessionKey;

    constructor(address _sessionKey) {
        sessionKey = _sessionKey;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s) = _parse(signature);
        if (ecrecover(hash, v, r, s) == sessionKey) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }

    function _parse(bytes memory sig) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        require(sig.length == 65, "bad sig len");
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
    }
}

// EIP-7702 delegate that rejects everything. Used to prove that once an EOA
// is delegated, the delegate's 1271 verdict is authoritative — even a valid
// ECDSA signature from the EOA's root key no longer rescues the call.
contract Delegate7702Rejector is IERC1271 {
    function isValidSignature(bytes32, bytes memory) external pure override returns (bytes4) {
        return 0xffffffff;
    }
}

/**
 * @title Sera7702Test
 * @notice Tests EIP-7702 wallet support in Sera and SeraSOR.
 *
 *         Under EIP-7702, an EOA can install contract code at its own address
 *         by submitting a signed authorization. Post-authorization the EOA
 *         retains its private key but also has bytecode — so for the signer
 *         `signer.code.length > 0`. OpenZeppelin's SignatureChecker (used by
 *         Sera via `_validateSignature` and SeraSOR.executeIntent) branches on
 *         that length: if code is present, it ONLY consults ERC-1271 and
 *         skips ECDSA. That means a 7702 EOA's orders are only accepted
 *         insofar as its delegate validates them via `isValidSignature`.
 *
 *         These tests exercise that flow end-to-end using `vm.etch` to write
 *         the delegate's runtime bytecode at the EOA's address — the
 *         observable end-state of a 7702 delegation.
 */
contract Sera7702Test is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    MockStableCoin public usdc;
    MockStableCoin public eth;

    address public owner;
    address public executor;
    uint256 public executorPK;

    // The 7702-enabled address: has both a private key and contract code.
    address public eoa;
    uint256 public eoaPK;

    // Separate signing key used in session-key scenarios.
    address public sessionKey;
    uint256 public sessionPK;

    // Plain-EOA counterparty.
    address public counterparty;
    uint256 public counterpartyPK;

    Delegate7702Self public selfDelegate;
    Delegate7702Session public sessionDelegate;
    Delegate7702Rejector public rejectorDelegate;

    function setUp() public {
        owner = makeAddr("owner");
        (executor, executorPK) = makeAddrAndKey("executor");
        (eoa, eoaPK) = makeAddrAndKey("eoa7702");
        (sessionKey, sessionPK) = makeAddrAndKey("sessionKey");
        (counterparty, counterpartyPK) = makeAddrAndKey("counterparty");

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
        vm.stopPrank();

        selfDelegate = new Delegate7702Self();
        sessionDelegate = new Delegate7702Session(sessionKey);
        rejectorDelegate = new Delegate7702Rejector();
    }

    // ---------- helpers ----------

    // Installs the delegate's runtime bytecode at the EOA's address — the
    // observable end-state of an EIP-7702 authorization from Sera's
    // perspective (code present + private key intact).
    function _delegateEOATo(address impl) internal {
        vm.etch(eoa, impl.code);
    }

    function _mintAndDepositAsEOA(address token, uint256 amount) internal {
        MockStableCoin(token).mint(eoa, amount);
        vm.startPrank(eoa);
        IERC20(token).approve(address(sera.vault()), amount);
        sera.depositFund(token, eoa, amount);
        vm.stopPrank();
    }

    function _makerOrderFromEOA(uint256 uuid, address from, address to, uint256 fromAmt, uint256 toAmt)
        internal
        view
        returns (Order memory)
    {
        return Order({
            user: eoa,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: address(0),
            fromToken: from,
            toToken: to,
            fromAmount: fromAmt,
            toAmount: toAmt,
            initialDepositAmount: 0,
            uuid: uuid
        });
    }

    function _takerOrderFromCounterparty(uint256 uuid, address from, address to, uint256 fromAmt, uint256 toAmt)
        internal
        view
        returns (Order memory)
    {
        return Order({
            user: counterparty,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: counterparty,
            fromToken: from,
            toToken: to,
            fromAmount: fromAmt,
            toAmount: toAmt,
            initialDepositAmount: 0,
            uuid: uuid
        });
    }

    // ---------- matchOrders: 7702 EOA as maker ----------

    // Happy path: EOA delegates to a 1271 impl that authorizes its own root
    // key. User signs orders with the EOA key they've always had; the
    // delegate's isValidSignature confirms it.
    function test_7702_Maker_SelfDelegate_ValidatesEOAKey() public {
        _mintAndDepositAsEOA(address(eth), 10 ether);
        _delegateEOATo(address(selfDelegate));
        assertGt(eoa.code.length, 0);

        _mintAndDeposit(counterparty, address(usdc), 1000 ether, sera);

        Order memory takerOrder = _takerOrderFromCounterparty(1, address(usdc), address(eth), 1000 ether, 10 ether);
        Order memory eoaOrder = _makerOrderFromEOA(2, address(eth), address(usdc), 10 ether, 1000 ether);

        bytes memory takerSig = _signOrder(counterpartyPK, takerOrder, sera);
        bytes memory eoaSig = _signOrder(eoaPK, eoaOrder, sera);

        MatchData memory m = MatchData(takerOrder, takerSig, 1000 ether, eoaOrder, eoaSig, 10 ether);

        vm.prank(executor);
        sera.matchOrders(m, type(uint256).max);

        assertEq(IERC20(address(eth)).balanceOf(counterparty), 10 ether);
        assertEq(sera.vault().balanceOf(address(usdc), eoa), 1000 ether);
    }

    // Session-key pattern: delegate authorizes an immutable hot key distinct
    // from the EOA's root key. Order is signed by the session key and still
    // accepted under `order.user = eoa`.
    function test_7702_Maker_SessionKey_ValidatesViaDelegate() public {
        _mintAndDepositAsEOA(address(eth), 10 ether);
        _delegateEOATo(address(sessionDelegate));

        _mintAndDeposit(counterparty, address(usdc), 1000 ether, sera);

        Order memory takerOrder = _takerOrderFromCounterparty(10, address(usdc), address(eth), 1000 ether, 10 ether);
        Order memory eoaOrder = _makerOrderFromEOA(11, address(eth), address(usdc), 10 ether, 1000 ether);

        bytes memory takerSig = _signOrder(counterpartyPK, takerOrder, sera);
        bytes memory sessionSig = _signOrder(sessionPK, eoaOrder, sera);

        MatchData memory m = MatchData(takerOrder, takerSig, 1000 ether, eoaOrder, sessionSig, 10 ether);

        vm.prank(executor);
        sera.matchOrders(m, type(uint256).max);

        assertEq(IERC20(address(eth)).balanceOf(counterparty), 10 ether);
        assertEq(sera.vault().balanceOf(address(usdc), eoa), 1000 ether);
    }

    // Documents the critical ECDSA-bypass behavior: once `eoa.code.length > 0`,
    // SignatureChecker stops consulting ecrecover and defers fully to the
    // delegate. A signature that would have been valid on a plain EOA is
    // rejected here because the delegate refuses it. This is why 7702 wallets
    // MUST install a delegate that correctly implements ERC-1271.
    function test_7702_Maker_ECDSA_SkippedWhenDelegateRejects() public {
        _mintAndDepositAsEOA(address(eth), 10 ether);
        _delegateEOATo(address(rejectorDelegate));

        _mintAndDeposit(counterparty, address(usdc), 1000 ether, sera);

        Order memory takerOrder = _takerOrderFromCounterparty(20, address(usdc), address(eth), 1000 ether, 10 ether);
        Order memory eoaOrder = _makerOrderFromEOA(21, address(eth), address(usdc), 10 ether, 1000 ether);

        bytes memory takerSig = _signOrder(counterpartyPK, takerOrder, sera);
        bytes memory eoaSig = _signOrder(eoaPK, eoaOrder, sera);

        MatchData memory m = MatchData(takerOrder, takerSig, 1000 ether, eoaOrder, eoaSig, 10 ether);

        vm.prank(executor);
        vm.expectRevert(Sera.InvalidSignature.selector);
        sera.matchOrders(m, type(uint256).max);
    }

    // Delegate authorizes only the session key; signing with the EOA's root
    // key yields a sig the delegate rejects.
    function test_7702_Maker_WrongSigner_Reverts() public {
        _mintAndDepositAsEOA(address(eth), 10 ether);
        _delegateEOATo(address(sessionDelegate));

        _mintAndDeposit(counterparty, address(usdc), 1000 ether, sera);

        Order memory takerOrder = _takerOrderFromCounterparty(30, address(usdc), address(eth), 1000 ether, 10 ether);
        Order memory eoaOrder = _makerOrderFromEOA(31, address(eth), address(usdc), 10 ether, 1000 ether);

        bytes memory takerSig = _signOrder(counterpartyPK, takerOrder, sera);
        bytes memory eoaSig = _signOrder(eoaPK, eoaOrder, sera);

        MatchData memory m = MatchData(takerOrder, takerSig, 1000 ether, eoaOrder, eoaSig, 10 ether);

        vm.prank(executor);
        vm.expectRevert(Sera.InvalidSignature.selector);
        sera.matchOrders(m, type(uint256).max);
    }

    // ---------- SOR: 7702 EOA as taker ----------

    function test_7702_SOR_Taker_SelfDelegate() public {
        _mintAndDepositAsEOA(address(usdc), 1000 ether);
        _delegateEOATo(address(selfDelegate));

        _mintAndDeposit(counterparty, address(eth), 10 ether, sera);

        Order memory takerOrder = Order({
            user: eoa,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: eoa,
            initialDepositAmount: 0,
            uuid: 40
        });
        Order memory makerOrder = Order({
            user: counterparty,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: address(0),
            initialDepositAmount: 0,
            uuid: 41
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: takerOrder,
            signature0: bytes(""),
            matchAmount0: 1000 ether,
            order1: makerOrder,
            signature1: _signOrder(counterpartyPK, makerOrder, sera),
            matchAmount1: 10 ether
        });

        bytes memory sorSig = _signIntent(
            eoaPK, eoa, address(usdc), address(eth), type(uint256).max, 1, eoa, 0, block.timestamp, uint48(block.timestamp + 1 days), sera
        );

        vm.prank(executor);
        sor.executeIntent(
            matches,
            sorSig,
            IntentParams(eoa, address(usdc), address(eth), type(uint256).max, 1, eoa, 0, block.timestamp, uint48(block.timestamp + 1 days)),
            3,
            0,
            bytes("")
        );

        assertEq(IERC20(address(eth)).balanceOf(eoa), 10 ether);
    }

    function test_7702_SOR_Taker_SessionKey() public {
        _mintAndDepositAsEOA(address(usdc), 1000 ether);
        _delegateEOATo(address(sessionDelegate));

        _mintAndDeposit(counterparty, address(eth), 10 ether, sera);

        Order memory takerOrder = Order({
            user: eoa,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: eoa,
            initialDepositAmount: 0,
            uuid: 50
        });
        Order memory makerOrder = Order({
            user: counterparty,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: address(0),
            initialDepositAmount: 0,
            uuid: 51
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: takerOrder,
            signature0: bytes(""),
            matchAmount0: 1000 ether,
            order1: makerOrder,
            signature1: _signOrder(counterpartyPK, makerOrder, sera),
            matchAmount1: 10 ether
        });

        bytes memory sorSig = _signIntent(
            sessionPK, eoa, address(usdc), address(eth), type(uint256).max, 1, eoa, 0, block.timestamp, uint48(block.timestamp + 1 days), sera
        );

        vm.prank(executor);
        sor.executeIntent(
            matches,
            sorSig,
            IntentParams(eoa, address(usdc), address(eth), type(uint256).max, 1, eoa, 0, block.timestamp, uint48(block.timestamp + 1 days)),
            3,
            0,
            bytes("")
        );

        assertEq(IERC20(address(eth)).balanceOf(eoa), 10 ether);
    }

    // ---------- Instant withdraw: 7702 EOA as user ----------

    function test_7702_InstantWithdraw_SelfDelegate() public {
        _mintAndDepositAsEOA(address(usdc), 500 ether);
        _delegateEOATo(address(selfDelegate));

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500 ether;

        WithdrawIntent memory intent = WithdrawIntent({
            user: eoa,
            tokens: tokens,
            amounts: amounts,
            recipient: eoa,
            deadline: block.timestamp + 1 days,
            uuid: 60
        });

        bytes32[] memory tokenWords = new bytes32[](1);
        tokenWords[0] = bytes32(uint256(uint160(intent.tokens[0])));
        bytes32 structHash = keccak256(
            abi.encode(
                WITHDRAW_INTENT_TYPEHASH,
                intent.user,
                keccak256(abi.encodePacked(tokenWords)),
                keccak256(abi.encodePacked(intent.amounts)),
                intent.recipient,
                intent.deadline,
                intent.uuid
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", sera.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPK, digest);
        bytes memory userSig = abi.encodePacked(r, s, v);

        (uint8 ev, bytes32 er, bytes32 es) = vm.sign(executorPK, digest);
        bytes memory execSig = abi.encodePacked(er, es, ev);

        sera.executeInstantWithdrawDualSig(intent, userSig, executor, execSig);

        assertEq(IERC20(address(usdc)).balanceOf(eoa), 500 ether);
    }

    // ---------- Instant withdraw: 7702 EOA as EXECUTOR ----------

    // The executor arg passes through the same signature helper as the user,
    // so a 7702-delegated EOA holding EXECUTOR_ROLE can co-sign withdraws.
    // Its root-key ECDSA signature is routed through the delegate's 1271.
    function test_7702_InstantWithdraw_7702Executor() public {
        (address execEOA, uint256 execEOAPK) = makeAddrAndKey("executor7702");
        vm.etch(execEOA, address(selfDelegate).code);
        bytes32 execRole = sera.EXECUTOR_ROLE();
        vm.prank(owner);
        sera.grantRole(execRole, execEOA);

        _mintAndDeposit(counterparty, address(usdc), 500 ether, sera);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500 ether;

        WithdrawIntent memory intent = WithdrawIntent({
            user: counterparty,
            tokens: tokens,
            amounts: amounts,
            recipient: counterparty,
            deadline: block.timestamp + 1 days,
            uuid: 61
        });

        bytes32[] memory tokenWords = new bytes32[](1);
        tokenWords[0] = bytes32(uint256(uint160(intent.tokens[0])));
        bytes32 structHash = keccak256(
            abi.encode(
                WITHDRAW_INTENT_TYPEHASH,
                intent.user,
                keccak256(abi.encodePacked(tokenWords)),
                keccak256(abi.encodePacked(intent.amounts)),
                intent.recipient,
                intent.deadline,
                intent.uuid
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", sera.DOMAIN_SEPARATOR(), structHash));

        (uint8 uv, bytes32 ur, bytes32 us) = vm.sign(counterpartyPK, digest);
        bytes memory userSig = abi.encodePacked(ur, us, uv);

        // Signed by the 7702 executor's root key; self-delegate authorizes
        // because ecrecover == address(this) under 7702.
        (uint8 ev, bytes32 er, bytes32 es) = vm.sign(execEOAPK, digest);
        bytes memory execSig = abi.encodePacked(er, es, ev);

        sera.executeInstantWithdrawDualSig(intent, userSig, execEOA, execSig);

        assertEq(IERC20(address(usdc)).balanceOf(counterparty), 500 ether);
    }

    // Once the executor EOA has code (via 7702), SignatureChecker skips
    // ECDSA entirely. A rejecting delegate makes even a valid root-key sig
    // fail — mirroring the user-side behavior.
    function test_7702_InstantWithdraw_7702Executor_DelegateRejects_Reverts() public {
        (address execEOA, uint256 execEOAPK) = makeAddrAndKey("executor7702Rejector");
        vm.etch(execEOA, address(rejectorDelegate).code);
        bytes32 execRole = sera.EXECUTOR_ROLE();
        vm.prank(owner);
        sera.grantRole(execRole, execEOA);

        _mintAndDeposit(counterparty, address(usdc), 500 ether, sera);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500 ether;

        WithdrawIntent memory intent = WithdrawIntent({
            user: counterparty,
            tokens: tokens,
            amounts: amounts,
            recipient: counterparty,
            deadline: block.timestamp + 1 days,
            uuid: 62
        });

        bytes32[] memory tokenWords = new bytes32[](1);
        tokenWords[0] = bytes32(uint256(uint160(intent.tokens[0])));
        bytes32 structHash = keccak256(
            abi.encode(
                WITHDRAW_INTENT_TYPEHASH,
                intent.user,
                keccak256(abi.encodePacked(tokenWords)),
                keccak256(abi.encodePacked(intent.amounts)),
                intent.recipient,
                intent.deadline,
                intent.uuid
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", sera.DOMAIN_SEPARATOR(), structHash));

        (uint8 uv, bytes32 ur, bytes32 us) = vm.sign(counterpartyPK, digest);
        bytes memory userSig = abi.encodePacked(ur, us, uv);

        (uint8 ev, bytes32 er, bytes32 es) = vm.sign(execEOAPK, digest);
        bytes memory execSig = abi.encodePacked(er, es, ev);

        vm.expectRevert(Sera.InvalidSignature.selector);
        sera.executeInstantWithdrawDualSig(intent, userSig, execEOA, execSig);
    }
}
