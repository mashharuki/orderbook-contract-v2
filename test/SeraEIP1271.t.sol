// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

/**
 * @title MockERC1271Wallet
 * @notice Minimal smart contract wallet that validates signatures via an owner EOA.
 *         Used to test EIP-1271 support in Sera and SeraSOR.
 */
contract MockERC1271Wallet is IERC1271 {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s) = _parseSignature(signature);
        address recovered = ecrecover(hash, v, r, s);
        if (recovered == owner) {
            return IERC1271.isValidSignature.selector; // 0x1626ba7e
        }
        return 0xffffffff;
    }

    function _parseSignature(bytes memory sig) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        require(sig.length == 65, "bad sig len");
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
    }
}

/**
 * @title MockERC1271WalletRejector
 * @notice Always rejects signatures. Used to test invalid ERC-1271 signatures.
 */
contract MockERC1271WalletRejector is IERC1271 {
    function isValidSignature(bytes32, bytes memory) external pure override returns (bytes4) {
        return 0xffffffff;
    }
}

/**
 * @title SeraEIP1271Test
 * @notice Tests EIP-1271 smart contract wallet signature support for:
 *         - Maker orders in matchOrders (Sera._validateSignature)
 *         - User signatures in executeInstantWithdrawDualSig
 *         - SOR taker signatures in SeraSOR.executeIntent
 */
contract SeraEIP1271Test is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    MockStableCoin public usdc;
    MockStableCoin public eth;

    address public owner;
    address public executor;
    uint256 public executorPK;

    // EOA that controls the smart wallet
    address public walletOwnerEOA;
    uint256 public walletOwnerPK;
    MockERC1271Wallet public smartWallet;

    // Regular EOA counterparty
    address public counterparty;
    uint256 public counterpartyPK;

    function setUp() public {
        owner = makeAddr("owner");
        (executor, executorPK) = makeAddrAndKey("executor");
        (walletOwnerEOA, walletOwnerPK) = makeAddrAndKey("walletOwner");
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

        // Deploy smart contract wallet owned by walletOwnerEOA
        smartWallet = new MockERC1271Wallet(walletOwnerEOA);
    }

    // ============ Helper: sign order with EOA key for smart wallet ============

    function _signOrderForWallet(uint256 pk, Order memory p) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                p.user, p.expiration, p.feeBps, p.recipient,
                p.fromToken, p.toToken, p.fromAmount, p.toAmount,
                p.initialDepositAmount, p.uuid
            )
        );
        bytes32 domainSeparator = sera.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _mintAndDepositForWallet(address token, uint256 amount) internal {
        Vault v = sera.vault();
        MockStableCoin(token).mint(address(smartWallet), amount);
        // Smart wallet needs to approve vault and call deposit
        // For testing, we directly deal tokens to vault and credit ledger
        vm.startPrank(address(smartWallet));
        IERC20(token).approve(address(v), amount);
        sera.depositFund(token, address(smartWallet), amount);
        vm.stopPrank();
    }

    // ============ matchOrders: smart wallet as maker ============

    function test_matchOrders_SmartWalletMaker() public {
        // Smart wallet is maker (order1), EOA is counterparty (order0)
        _mintAndDepositForWallet(address(eth), 10 ether);
        _mintAndDeposit(counterparty, address(usdc), 1000 ether, sera);

        Order memory order0 = Order({
            user: counterparty,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: counterparty,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0,
            uuid: 1
        });

        Order memory order1 = Order({
            user: address(smartWallet),
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: address(0), // internal ledger
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            uuid: 2
        });

        bytes memory sig0 = _signOrder(counterpartyPK, order0, sera);
        // Smart wallet's order signed by its EOA owner — validated via ERC-1271
        bytes memory sig1 = _signOrderForWallet(walletOwnerPK, order1);

        MatchData memory m = MatchData(order0, sig0, 1000 ether, order1, sig1, 10 ether);

        vm.prank(executor);
        sera.matchOrders(m, type(uint256).max);

        // Verify settlement: counterparty got ETH to wallet (non-zero recipient), smart wallet got USDC in vault (zero recipient)
        assertEq(IERC20(address(eth)).balanceOf(counterparty), 10 ether);
        assertEq(sera.vault().balanceOf(address(usdc), address(smartWallet)), 1000 ether);
    }

    function test_matchOrders_SmartWalletBothSides() public {
        // Both order0 and order1 are from smart wallets
        MockERC1271Wallet smartWallet2 = new MockERC1271Wallet(counterparty);

        _mintAndDepositForWallet(address(usdc), 1000 ether);

        // Deposit for wallet2
        Vault v = sera.vault();
        MockStableCoin(address(eth)).mint(address(smartWallet2), 10 ether);
        vm.startPrank(address(smartWallet2));
        IERC20(address(eth)).approve(address(v), 10 ether);
        sera.depositFund(address(eth), address(smartWallet2), 10 ether);
        vm.stopPrank();

        Order memory order0 = Order({
            user: address(smartWallet),
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: address(0),
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0,
            uuid: 10
        });

        Order memory order1 = Order({
            user: address(smartWallet2),
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: address(0),
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            uuid: 11
        });

        bytes memory sig0 = _signOrderForWallet(walletOwnerPK, order0);
        bytes memory sig1 = _signOrderForWallet(counterpartyPK, order1);

        MatchData memory m = MatchData(order0, sig0, 1000 ether, order1, sig1, 10 ether);

        vm.prank(executor);
        sera.matchOrders(m, type(uint256).max);

        assertEq(sera.vault().balanceOf(address(eth), address(smartWallet)), 10 ether);
        assertEq(sera.vault().balanceOf(address(usdc), address(smartWallet2)), 1000 ether);
    }

    function test_matchOrders_RejectsInvalidSmartWalletSig() public {
        MockERC1271WalletRejector rejector = new MockERC1271WalletRejector();

        // Fund the rejector wallet
        Vault v = sera.vault();
        MockStableCoin(address(eth)).mint(address(rejector), 10 ether);
        vm.startPrank(address(rejector));
        IERC20(address(eth)).approve(address(v), 10 ether);
        sera.depositFund(address(eth), address(rejector), 10 ether);
        vm.stopPrank();

        _mintAndDeposit(counterparty, address(usdc), 1000 ether, sera);

        Order memory order0 = Order({
            user: counterparty,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: counterparty,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0,
            uuid: 20
        });

        Order memory order1 = Order({
            user: address(rejector),
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: address(0),
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            uuid: 21
        });

        bytes memory sig0 = _signOrder(counterpartyPK, order0, sera);
        // Sign with any key — rejector always returns invalid
        bytes memory sig1 = _signOrderForWallet(walletOwnerPK, order1);

        MatchData memory m = MatchData(order0, sig0, 1000 ether, order1, sig1, 10 ether);

        vm.prank(executor);
        vm.expectRevert(Sera.InvalidSignature.selector);
        sera.matchOrders(m, type(uint256).max);
    }

    // ============ SOR: smart wallet as taker ============

    function test_SOR_SmartWalletTaker_SingleLeg() public {
        // Smart wallet is the SOR taker
        _mintAndDepositForWallet(address(usdc), 1000 ether);
        _mintAndDeposit(counterparty, address(eth), 10 ether, sera);

        Order memory takerOrder = Order({
            user: address(smartWallet),
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: address(smartWallet),
            initialDepositAmount: 0,
            uuid: 30
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
            uuid: 31
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

        // Sign the SOR intent with the wallet owner's EOA key
        bytes memory sorSig = _signIntent(
            walletOwnerPK,
            address(smartWallet), // taker = smart wallet address
            address(usdc), address(eth),
            0, 0,
            address(smartWallet),
            0,
            block.timestamp,
            uint48(block.timestamp + 1 days),
            sera
        );

        vm.prank(executor);
        sor.executeIntent(
            matches,
            sorSig,
            IntentParams(address(smartWallet), address(usdc), address(eth), 0, 0, address(smartWallet), 0, block.timestamp, uint48(block.timestamp + 1 days)),
            3,
            0,
            bytes("")
        );

        // Taker (smart wallet) received ETH to their wallet
        assertEq(IERC20(address(eth)).balanceOf(address(smartWallet)), 10 ether);
    }

    function test_SOR_RejectsWrongSmartWalletSig() public {
        _mintAndDepositForWallet(address(usdc), 1000 ether);
        _mintAndDeposit(counterparty, address(eth), 10 ether, sera);

        Order memory takerOrder = Order({
            user: address(smartWallet),
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            expiration: uint48(block.timestamp + 1 days),
            feeBps: 0,
            recipient: address(smartWallet),
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

        // Sign with wrong key (counterparty instead of walletOwner)
        bytes memory badSig = _signIntent(
            counterpartyPK,
            address(smartWallet),
            address(usdc), address(eth),
            0, 0,
            address(smartWallet),
            0,
            block.timestamp,
            uint48(block.timestamp + 1 days),
            sera
        );

        vm.prank(executor);
        vm.expectRevert(Sera.InvalidSignature.selector);
        sor.executeIntent(
            matches,
            badSig,
            IntentParams(address(smartWallet), address(usdc), address(eth), 0, 0, address(smartWallet), 0, block.timestamp, uint48(block.timestamp + 1 days)),
            3,
            0,
            bytes("")
        );
    }

    // ============ Instant Withdraw: smart wallet as user ============

    function test_instantWithdraw_SmartWalletUser() public {
        _mintAndDepositForWallet(address(usdc), 500 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500 ether;

        WithdrawIntent memory intent = WithdrawIntent({
            user: address(smartWallet),
            tokens: tokens,
            amounts: amounts,
            recipient: address(smartWallet),
            deadline: block.timestamp + 1 days,
            uuid: 50
        });

        // User signature (from wallet owner EOA, validated via ERC-1271)
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
        bytes32 domainSeparator = sera.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletOwnerPK, digest);
        bytes memory userSig = abi.encodePacked(r, s, v);

        // Executor signature (standard EOA)
        (uint8 ev, bytes32 er, bytes32 es) = vm.sign(executorPK, digest);
        bytes memory execSig = abi.encodePacked(er, es, ev);

        sera.executeInstantWithdrawDualSig(intent, userSig, executor, execSig);

        assertEq(IERC20(address(usdc)).balanceOf(address(smartWallet)), 500 ether);
    }
}
