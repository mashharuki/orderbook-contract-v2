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
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
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



}
