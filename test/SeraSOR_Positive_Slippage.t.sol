// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "./TestHelper.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";

contract PoC_SOR_Positive_Slippage is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    MockStableCoin public usdc;
    MockStableCoin public eth;
    MockStableCoin public btc;

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
        btc = new MockStableCoin("BTC");

        sera = _deploySera(owner);
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(usdc), true, 1);
        _whitelistToken(sera, address(eth), true, 1);
        _whitelistToken(sera, address(btc), true, 1);
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.grantRole(sera.EXECUTOR_ROLE_CACHED(), address(sor));
        sera.setTrustedRouter(address(sor));

        // Split positive slippage evenly between the protocol and user payouts.
        // Intermediate leftovers that are not consumed by later legs are swept to treasury.
        sera.setSlippageShares(5000, 0, 5000, 10000);
        vm.stopPrank();

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        // Maker1 provides ETH with positive slippage (willing to sell 2 ETH for 100 USDC instead of 1 ETH)
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 10 ether, sera);
    }

    function _finalizeRouteBindings(MatchData[] memory matches) internal pure returns (bytes32) {
        bytes memory packed = new bytes(matches.length * 32);
        for (uint256 i = 0; i < matches.length; i++) {
            Order memory p = matches[i].order0;
            p.routeHash = bytes32(0);
            bytes32 structHash = keccak256(abi.encode(ORDER_TYPEHASH, p.user, p.expiration, p.feeBps, p.recipient, p.fromToken, p.toToken, p.fromAmount, p.toAmount, p.initialDepositAmount, p.routeHash, p.uuid));
            assembly {
                let offset := add(add(packed, 32), mul(i, 32))
                mstore(offset, structHash)
            }
        }
        bytes32 routeHash = keccak256(packed);
        for (uint256 i = 0; i < matches.length; i++) {
            matches[i].order0.routeHash = routeHash;
        }
        return routeHash;
    }

    function test_PoC_SOR_Positive_Slippage_Sweeps_Leftover_Intermediate_Output() public {
        // Taker wants to trade 100 USDC -> 1 ETH -> 0.1 BTC
        // Leg 1: Taker pays 100 USDC for 1 ETH
        // Maker 1 wants to trade 2 ETH for 100 USDC (positive slippage of 1 ETH!)

        Order memory takerLeg1 = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 100 ether,
            toAmount: 1 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(sera), // hold intermediate output
            expiration: uint48(block.timestamp + 1 days),
            uuid: 1,
            routeHash: bytes32(0)
        });

        Order memory makerLeg1 = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 2 ether, // 2 ETH!
            toAmount: 100 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 2,
            routeHash: bytes32(0)
        });

        // Leg 2: Taker uses the 1 ETH to buy 0.1 BTC
        Order memory takerLeg2 = Order({
            user: taker,
            fromToken: address(eth),
            toToken: address(btc),
            fromAmount: 1 ether, // Statically configured based on expected 1 ETH
            toAmount: 0.1 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker, // final payout
            expiration: uint48(block.timestamp + 1 days),
            uuid: 3,
            routeHash: bytes32(0)
        });

        Order memory makerLeg2 = Order({user: maker2, fromToken: address(btc), toToken: address(eth), fromAmount: 0.1 ether, toAmount: 1 ether, initialDepositAmount: 0, feeBps: 0, recipient: maker2, expiration: uint48(block.timestamp + 1 days), uuid: 4, routeHash: bytes32(0)});

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData({
            order0: takerLeg1,
            signature0: bytes(""),
            matchAmount0: 100 ether,
            order1: makerLeg1,
            signature1: _signOrder(maker1PK, makerLeg1, sera),
            matchAmount1: 2 ether // Fill all 2 ETH
        });

        matches[1] = MatchData({order0: takerLeg2, signature0: bytes(""), matchAmount0: 1 ether, order1: makerLeg2, signature1: _signOrder(maker2PK, makerLeg2, sera), matchAmount1: 0.1 ether});

        bytes32 routeHash = _finalizeRouteBindings(matches);
        bytes memory routeSig = _signRoute(takerPK, routeHash, sera);

        // The route executes successfully and sweeps the unconsumed intermediate ETH to the protocol.
        vm.prank(executor);
        sor.executeRoute(matches, routeSig, type(uint256).max);

        // 0.5 ETH is captured during leg 1 settlement and 0.5 ETH remains unconsumed after leg 2.
        assertEq(sera.vault().balanceOf(address(eth), owner), 1 ether, "Protocol should receive positive slippage");
    }

    function test_PoC_SOR_Positive_Slippage_Linear() public {
        MockStableCoin dai = new MockStableCoin("DAI");
        vm.prank(owner);
        _whitelistToken(sera, address(dai), true, 1);

        (address maker3, uint256 maker3PK) = makeAddrAndKey("maker3");

        // Balances
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 10 ether, sera);
        _mintAndDeposit(maker3, address(dai), 1000 ether, sera);

        // Path: USDC -> ETH -> BTC -> DAI

        // Leg 1: 100 USDC -> 1 ETH (Maker gives 1.5 ETH = 0.5 ETH pos slip)
        Order memory t1 = Order({user: taker, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: address(sera), fromToken: address(usdc), toToken: address(eth), fromAmount: 100 ether, toAmount: 1 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 11});
        Order memory m1 = Order({user: maker1, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: maker1, fromToken: address(eth), toToken: address(usdc), fromAmount: 1.5 ether, toAmount: 100 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 12});

        // Leg 2: 1 ETH -> 0.1 BTC (Maker gives 0.12 BTC = 0.02 BTC pos slip)
        Order memory t2 = Order({user: taker, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: address(sera), fromToken: address(eth), toToken: address(btc), fromAmount: 1 ether, toAmount: 0.1 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 13});
        Order memory m2 = Order({user: maker2, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: maker2, fromToken: address(btc), toToken: address(eth), fromAmount: 0.12 ether, toAmount: 1 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 14});

        // Leg 3: 0.1 BTC -> 100 DAI (Maker gives 150 DAI = 50 DAI pos slip)
        Order memory t3 = Order({user: taker, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: taker, fromToken: address(btc), toToken: address(dai), fromAmount: 0.1 ether, toAmount: 100 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 15});
        Order memory m3 = Order({user: maker3, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: maker3, fromToken: address(dai), toToken: address(btc), fromAmount: 150 ether, toAmount: 0.1 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 16});

        MatchData[] memory matches = new MatchData[](3);
        matches[0] = MatchData(t1, bytes(""), 100 ether, m1, _signOrder(maker1PK, m1, sera), 1.5 ether);
        matches[1] = MatchData(t2, bytes(""), 1 ether, m2, _signOrder(maker2PK, m2, sera), 0.12 ether);
        matches[2] = MatchData(t3, bytes(""), 0.1 ether, m3, _signOrder(maker3PK, m3, sera), 150 ether);

        bytes32 routeHash = _finalizeRouteBindings(matches);
        bytes memory routeSig = _signRoute(takerPK, routeHash, sera);

        vm.prank(executor);
        sor.executeRoute(matches, routeSig, type(uint256).max);

        assertEq(dai.balanceOf(taker), 125 ether, "Taker receives final-leg positive slippage share in DAI");
        assertEq(sera.vault().balanceOf(address(eth), owner), 0.5 ether, "Protocol swept 0.5 ETH");
        assertEq(sera.vault().balanceOf(address(btc), owner), 0.02 ether, "Protocol swept 0.02 BTC");
        assertEq(sera.vault().balanceOf(address(dai), owner), 25 ether, "Protocol received its 50% DAI share");
    }

    function test_PoC_SOR_Positive_Slippage_Diamond() public {
        MockStableCoin dai = new MockStableCoin("DAI");
        vm.prank(owner);
        _whitelistToken(sera, address(dai), true, 1);

        (address maker3, uint256 maker3PK) = makeAddrAndKey("maker3");
        (address maker4, uint256 maker4PK) = makeAddrAndKey("maker4");

        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(dai), 1000 ether, sera);
        _mintAndDeposit(maker3, address(btc), 10 ether, sera);
        _mintAndDeposit(maker4, address(btc), 10 ether, sera);

        // Path: 100 USDC
        // Branch 1: 50 USDC -> 0.5 ETH -> 0.05 BTC
        // Branch 2: 50 USDC -> 500 DAI -> 0.05 BTC

        // Leg 1: 50 USDC -> 0.5 ETH (Maker gives 0.8 ETH = 0.3 ETH pos slip)
        Order memory t1 = Order({user: taker, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: address(sera), fromToken: address(usdc), toToken: address(eth), fromAmount: 50 ether, toAmount: 0.5 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 21});
        Order memory m1 = Order({user: maker1, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: maker1, fromToken: address(eth), toToken: address(usdc), fromAmount: 0.8 ether, toAmount: 50 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 22});

        // Leg 2: 50 USDC -> 500 DAI (Maker gives 600 DAI = 100 DAI pos slip)
        Order memory t2 = Order({user: taker, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: address(sera), fromToken: address(usdc), toToken: address(dai), fromAmount: 50 ether, toAmount: 500 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 23});
        Order memory m2 = Order({user: maker2, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: maker2, fromToken: address(dai), toToken: address(usdc), fromAmount: 600 ether, toAmount: 50 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 24});

        // Leg 3: 0.5 ETH -> 0.05 BTC (Maker gives 0.06 BTC = 0.01 BTC pos slip)
        Order memory t3 = Order({user: taker, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: taker, fromToken: address(eth), toToken: address(btc), fromAmount: 0.5 ether, toAmount: 0.05 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 25});
        Order memory m3 = Order({user: maker3, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: maker3, fromToken: address(btc), toToken: address(eth), fromAmount: 0.06 ether, toAmount: 0.5 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 26});

        // Leg 4: 500 DAI -> 0.05 BTC (Maker gives 0.06 BTC = 0.01 BTC pos slip)
        Order memory t4 = Order({user: taker, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: taker, fromToken: address(dai), toToken: address(btc), fromAmount: 500 ether, toAmount: 0.05 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 27});
        Order memory m4 = Order({user: maker4, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: maker4, fromToken: address(btc), toToken: address(dai), fromAmount: 0.06 ether, toAmount: 500 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 28});

        MatchData[] memory matches = new MatchData[](4);
        matches[0] = MatchData(t1, bytes(""), 50 ether, m1, _signOrder(maker1PK, m1, sera), 0.8 ether);
        matches[1] = MatchData(t2, bytes(""), 50 ether, m2, _signOrder(maker2PK, m2, sera), 600 ether);
        matches[2] = MatchData(t3, bytes(""), 0.5 ether, m3, _signOrder(maker3PK, m3, sera), 0.06 ether);
        matches[3] = MatchData(t4, bytes(""), 500 ether, m4, _signOrder(maker4PK, m4, sera), 0.06 ether);

        bytes32 routeHash = _finalizeRouteBindings(matches);
        bytes memory routeSig = _signRoute(takerPK, routeHash, sera);

        vm.prank(executor);
        sor.executeRoute(matches, routeSig, type(uint256).max);

        assertEq(btc.balanceOf(taker), 0.11 ether, "Taker receives both branch outputs plus final-leg positive slippage");
        assertEq(sera.vault().balanceOf(address(eth), owner), 0.3 ether, "Protocol swept 0.3 ETH");
        assertEq(sera.vault().balanceOf(address(dai), owner), 100 ether, "Protocol swept 100 DAI");
        assertEq(sera.vault().balanceOf(address(btc), owner), 0.01 ether, "Protocol received combined BTC share from both final legs");
    }

    function test_PoC_SOR_Positive_Slippage_Tree() public {
        MockStableCoin dai = new MockStableCoin("DAI");
        vm.prank(owner);
        _whitelistToken(sera, address(dai), true, 1);

        // Path: 100 USDC -> 1 ETH
        // Branch 1: 0.5 ETH -> 0.05 BTC
        // Branch 2: 0.5 ETH -> 500 DAI

        (address maker3, uint256 maker3PK) = makeAddrAndKey("maker3");

        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 10 ether, sera);
        _mintAndDeposit(maker3, address(dai), 1000 ether, sera);

        // Leg 1: 100 USDC -> 1 ETH (Maker gives 1.5 ETH = 0.5 ETH pos slip)
        Order memory t1 = Order({user: taker, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: address(sera), fromToken: address(usdc), toToken: address(eth), fromAmount: 100 ether, toAmount: 1 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 31});
        Order memory m1 = Order({user: maker1, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: maker1, fromToken: address(eth), toToken: address(usdc), fromAmount: 1.5 ether, toAmount: 100 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 32});

        // Leg 2: 0.5 ETH -> 0.05 BTC (Maker gives 0.06 BTC = 0.01 BTC pos slip)
        Order memory t2 = Order({user: taker, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: taker, fromToken: address(eth), toToken: address(btc), fromAmount: 0.5 ether, toAmount: 0.05 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 33});
        Order memory m2 = Order({user: maker2, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: maker2, fromToken: address(btc), toToken: address(eth), fromAmount: 0.06 ether, toAmount: 0.5 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 34});

        // Leg 3: 0.5 ETH -> 500 DAI (Maker gives 700 DAI = 200 DAI pos slip)
        Order memory t3 = Order({user: taker, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: taker, fromToken: address(eth), toToken: address(dai), fromAmount: 0.5 ether, toAmount: 500 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 35});
        Order memory m3 = Order({user: maker3, expiration: uint48(block.timestamp + 1 days), feeBps: 0, recipient: maker3, fromToken: address(dai), toToken: address(eth), fromAmount: 700 ether, toAmount: 0.5 ether, initialDepositAmount: 0, routeHash: bytes32(0), uuid: 36});

        MatchData[] memory matches = new MatchData[](3);
        matches[0] = MatchData(t1, bytes(""), 100 ether, m1, _signOrder(maker1PK, m1, sera), 1.5 ether);
        matches[1] = MatchData(t2, bytes(""), 0.5 ether, m2, _signOrder(maker2PK, m2, sera), 0.06 ether);
        matches[2] = MatchData(t3, bytes(""), 0.5 ether, m3, _signOrder(maker3PK, m3, sera), 700 ether);

        bytes32 routeHash = _finalizeRouteBindings(matches);
        bytes memory routeSig = _signRoute(takerPK, routeHash, sera);

        vm.prank(executor);
        sor.executeRoute(matches, routeSig, type(uint256).max);

        assertEq(btc.balanceOf(taker), 0.055 ether, "Taker receives BTC output plus final-leg positive slippage");
        assertEq(dai.balanceOf(taker), 600 ether, "Taker receives DAI output plus final-leg positive slippage");
        assertEq(sera.vault().balanceOf(address(eth), owner), 0.5 ether, "Protocol swept 0.5 ETH");
        assertEq(sera.vault().balanceOf(address(btc), owner), 0.005 ether, "Protocol received its BTC share on the final leg");
        assertEq(sera.vault().balanceOf(address(dai), owner), 100 ether, "Protocol received its DAI share on the final leg");
    }
}
