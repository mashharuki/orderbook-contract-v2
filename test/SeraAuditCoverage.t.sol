// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "./TestHelper.sol";
import "../src/SeraBatcher.sol";
import "../src/SeraSOR.sol";

contract SeraAuditCoverageTest is TestHelper {
    Sera public sera;
    Vault public vault;
    SeraSOR sor_;
    SeraBatcher public batcher;

    MockStableCoin public usdt;
    MockStableCoin public sgd;

    address public owner;
    uint256 public ownerPK;
    address public maker;
    uint256 public makerPK;
    address public taker;
    uint256 public takerPK;

    function setUp() public {
        (owner, ownerPK) = makeAddrAndKey("owner");
        (taker, takerPK) = makeAddrAndKey("taker");
        (maker, makerPK) = makeAddrAndKey("maker");
        
        sera = _deploySera(owner);
        vault = sera.vault();
        sor_ = new SeraSOR(address(sera));
        batcher = new SeraBatcher(address(sera), address(sor_));

        usdt = new MockStableCoin("USDT");
        sgd = new MockStableCoin("SGD");

        vm.startPrank(owner);
        _whitelistToken(sera, address(usdt), true, 100);
        _whitelistToken(sera, address(sgd), true, 100);
        
        sera.grantRole(sera.EXECUTOR_ROLE(), owner);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(batcher));
        sera.grantRole(sera.EXECUTOR_ROLE(), address(this));
        
        vm.stopPrank();
        
        _mintAndDeposit(taker, address(usdt), 1000 ether, sera);
        _mintAndDeposit(maker, address(sgd), 1000 ether, sera);
    }

    // Vault line 41: if (blacklisted[user]) revert BlacklistedUser(user);
    // Vault line 42: if (amount == 0) revert ZeroAmount();
    function test_Vault_Reverts() public {
        vm.prank(owner);
        vault.setBlacklisted(taker, true);

        vm.prank(address(sera));
        vm.expectRevert(abi.encodeWithSelector(IVault.BlacklistedUser.selector, taker));
        vault.deposit(taker, address(usdt), 100);

        vm.prank(owner);
        vault.setBlacklisted(taker, false);

        vm.prank(address(sera));
        vm.expectRevert(IVault.ZeroAmount.selector);
        vault.deposit(taker, address(usdt), 0);
    }

    // SeraAdmin lines 62-64: setTreasury
    function test_Admin_setTreasury() public {
        vm.startPrank(owner);
        sera.setTreasury(address(999));
        assertEq(sera.treasury(), address(999));

        vm.expectRevert(SeraAdmin.InvalidAddress.selector);
        sera.setTreasury(address(0));
        vm.stopPrank();
    }

    // SeraAdmin lines 109-114: batchModifyWhitelistedTokens
    function test_Admin_batchModify() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(555);
        tokens[1] = address(666);
        uint256[] memory mins = new uint256[](2);
        mins[0] = 10;
        mins[1] = 20;

        vm.prank(owner);
        sera.batchModifyWhitelistedTokens(tokens, true, mins);

        (bool w1, uint256 m1) = sera.tokenConfigs(address(555));
        assertTrue(w1);
        assertEq(m1, 10);

        uint256[] memory minsBad = new uint256[](1);
        minsBad[0] = 10;
        vm.prank(owner);
        vm.expectRevert(SeraAdmin.InvalidAmount.selector);
        sera.batchModifyWhitelistedTokens(tokens, true, minsBad);
    }

    // SeraBatcher lines 113-115: try this.batchMatchOrdersAtomic success
    function _makeOrder(address user, address fromToken, address toToken, uint256 fromAmt, uint256 toAmt, uint256 uuid) internal view returns (Order memory) {
        return Order({
            user: user,
            expiration: uint48(block.timestamp + 1000),
            feeBps: 0,
            recipient: address(0),
            fromToken: fromToken,
            toToken: toToken,
            fromAmount: fromAmt,
            toAmount: toAmt,
            initialDepositAmount: 0,
            uuid: uint256(keccak256(abi.encode(uuid)))
        });
    }

    function test_Batcher_BatchMatchMixed_TrySuccess() public {
        // Create a valid match
        Order memory takerOrder = _makeOrder(taker, address(usdt), address(sgd), 100 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker, address(sgd), address(usdt), 10 ether, 100 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: takerOrder,
            signature0: _signOrder(takerPK, takerOrder, sera),
            matchAmount0: 100 ether,
            order1: makerOrder,
            signature1: _signOrder(makerPK, makerOrder, sera),
            matchAmount1: 10 ether
        });

        SeraBatcher.AtomicBatch[] memory atomics = new SeraBatcher.AtomicBatch[](1);
        atomics[0] = SeraBatcher.AtomicBatch(matches);

        MatchData[] memory st = new MatchData[](0);

        SeraBatcher.IntentExecution[] memory intents = new SeraBatcher.IntentExecution[](0);

        vm.prank(owner);
        batcher.batchMatchMixed(atomics, st, intents, uint48(block.timestamp + 100));
        
        assertEq(vault.balanceOf(address(usdt), taker), 900 ether); 
    }
}
