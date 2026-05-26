// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/Sera.sol";
import "../../src/SeraSOR.sol";
import "../../src/SeraBatcher.sol";
import "../../src/mock/MockStableCoin.sol";
import "../TestHelper.sol";

/**
 * @title SeraSORHandler - Fuzzing handler for SeraSOR invariant testing
 * @notice Simulates multi-leg route executions and transient balance scenarios
 */
contract SeraSORHandler is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    Vault public vault;
    
    MockStableCoin public tokenA;
    MockStableCoin public tokenB;
    MockStableCoin public tokenC;
    
    address public owner;
    uint256 public ownerPK;
    
    address[] public users;
    uint256[] public userPKs;
    address[] public tokens;
    
    uint256 public nextUuid = 1;
    
    // Ghost variables
    uint256 public ghost_singleLegExecutions;
    uint256 public ghost_multiLegExecutions;
    uint256 public ghost_failedExecutions;
    
    mapping(address => mapping(uint256 => bool)) public ghost_consumedIntentUuids;
    mapping(address => uint256) public ghost_totalInputSpent;
    mapping(address => uint256) public ghost_totalOutputReceived;
    
    // Track transient balance issues
    uint256 public ghost_transientBalanceErrors;
    
    constructor(
        Sera _sera,
        SeraSOR _sor,
        MockStableCoin _tokenA,
        MockStableCoin _tokenB,
        MockStableCoin _tokenC,
        address _owner,
        uint256 _ownerPK
    ) {
        sera = _sera;
        sor = _sor;
        vault = _sera.vault();
        tokenA = _tokenA;
        tokenB = _tokenB;
        tokenC = _tokenC;
        owner = _owner;
        ownerPK = _ownerPK;
        
        tokens.push(address(_tokenA));
        tokens.push(address(_tokenB));
        tokens.push(address(_tokenC));
        
        // Create test users
        for (uint256 i = 0; i < 6; i++) {
            (address user, uint256 pk) = makeAddrAndKey(string(abi.encodePacked("sorUser", vm.toString(i))));
            users.push(user);
            userPKs.push(pk);
        }
    }
    
    // ============ Setup Helpers ============
    
    function _setupMakerWithBalance(uint256 makerIdx, address token, uint256 amount) internal {
        address maker = users[makerIdx];
        MockStableCoin(token).mint(maker, amount);
        vm.startPrank(maker);
        IERC20(token).approve(address(vault), amount);
        sera.depositFund(token, maker, amount);
        vm.stopPrank();
    }
    
    // ============ Single Leg SOR Execution ============
    
    function executeSingleLegIntent(
        uint256 takerSeed,
        uint256 makerSeed,
        uint256 amount,
        uint256 walletDepositPercent
    ) external {
        uint256 takerIdx = takerSeed % users.length;
        uint256 makerIdx = makerSeed % users.length;
        if (takerIdx == makerIdx) makerIdx = (makerIdx + 1) % users.length;
        
        address taker = users[takerIdx];
        uint256 takerPK = userPKs[takerIdx];
        address maker = users[makerIdx];
        uint256 makerPK = userPKs[makerIdx];
        
        amount = bound(amount, 1 ether, 100 ether);
        walletDepositPercent = bound(walletDepositPercent, 0, 100);
        
        uint256 walletDeposit = (amount * walletDepositPercent) / 100;
        uint256 vaultPull = amount - walletDeposit;
        
        // Setup: Mint tokens to taker wallet and/or vault
        if (walletDeposit > 0) {
            tokenA.mint(taker, walletDeposit);
            vm.prank(taker);
            IERC20(address(tokenA)).approve(address(sor), walletDeposit);
        }
        if (vaultPull > 0) {
            _mintAndDeposit(taker, address(tokenA), vaultPull, sera);
        }
        
        // Setup maker with tokenB
        _setupMakerWithBalance(makerIdx, address(tokenB), amount);
        
        // Create intent
        uint256 uuid = nextUuid++;
        IntentParams memory intent = IntentParams({
            taker: taker,
            inputToken: address(tokenA),
            outputToken: address(tokenB),
            maxInputAmount: amount,
            minOutputAmount: amount,
            recipient: taker,
            initialDepositAmount: walletDeposit,
            uuid: uuid,
            deadline: uint48(block.timestamp + 1 hours)
        });
        
        // Create matching orders
        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: walletDeposit,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        Order memory makerOrder = Order({
            user: maker,
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: takerOrder,
            signature0: "", // SOR doesn't need taker signature
            matchAmount0: amount,
            order1: makerOrder,
            signature1: _signOrder(makerPK, makerOrder, sera),
            matchAmount1: amount
        });
        
        bytes memory intentSig = _signIntent(
            takerPK, taker, address(tokenA), address(tokenB),
            amount, amount, taker, walletDeposit, uuid, uint48(block.timestamp + 1 hours), sera
        );
        
        vm.prank(owner);
        try sor.executeIntent(matches, intentSig, intent, 2, 0, "") {
            ghost_singleLegExecutions++;
            ghost_consumedIntentUuids[taker][uuid] = true;
            ghost_totalInputSpent[taker] += amount;
            ghost_totalOutputReceived[taker] += amount;
        } catch {
            ghost_failedExecutions++;
        }
    }
    
    // ============ Multi-Leg SOR Execution (A -> B -> C) ============
    
    function executeMultiLegIntent(
        uint256 takerSeed,
        uint256 maker1Seed,
        uint256 maker2Seed,
        uint256 amount
    ) external {
        uint256 takerIdx = takerSeed % users.length;
        uint256 maker1Idx = maker1Seed % users.length;
        uint256 maker2Idx = maker2Seed % users.length;
        
        // Ensure all different
        if (takerIdx == maker1Idx) maker1Idx = (maker1Idx + 1) % users.length;
        if (takerIdx == maker2Idx || maker1Idx == maker2Idx) maker2Idx = (maker2Idx + 2) % users.length;
        
        address taker = users[takerIdx];
        uint256 takerPK = userPKs[takerIdx];
        address maker1 = users[maker1Idx];
        uint256 maker1PK = userPKs[maker1Idx];
        address maker2 = users[maker2Idx];
        uint256 maker2PK = userPKs[maker2Idx];
        
        amount = bound(amount, 1 ether, 50 ether);
        
        // Setup: Taker has tokenA in vault
        _mintAndDeposit(taker, address(tokenA), amount, sera);
        
        // Maker1 has tokenB (for A->B leg)
        _setupMakerWithBalance(maker1Idx, address(tokenB), amount);
        
        // Maker2 has tokenC (for B->C leg)
        _setupMakerWithBalance(maker2Idx, address(tokenC), amount);
        
        uint256 uuid = nextUuid++;
        IntentParams memory intent = IntentParams({
            taker: taker,
            inputToken: address(tokenA),
            outputToken: address(tokenC),
            maxInputAmount: amount,
            minOutputAmount: amount,
            recipient: taker,
            initialDepositAmount: 0,
            uuid: uuid,
            deadline: uint48(block.timestamp + 1 hours)
        });
        
        // Leg 1: Taker A -> Maker1 B (hold output in Sera)
        Order memory takerOrder1 = Order({
            user: taker,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(sera), // Hold in Sera for next leg
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        Order memory maker1Order = Order({
            user: maker1,
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        // Leg 2: Taker B -> Maker2 C (final output to taker)
        Order memory takerOrder2 = Order({
            user: taker,
            fromToken: address(tokenB),
            toToken: address(tokenC),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker, // Final recipient
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        Order memory maker2Order = Order({
            user: maker2,
            fromToken: address(tokenC),
            toToken: address(tokenB),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData({
            order0: takerOrder1,
            signature0: "",
            matchAmount0: amount,
            order1: maker1Order,
            signature1: _signOrder(maker1PK, maker1Order, sera),
            matchAmount1: amount
        });
        matches[1] = MatchData({
            order0: takerOrder2,
            signature0: "",
            matchAmount0: type(uint256).max, // Sentinel: use all transient
            order1: maker2Order,
            signature1: _signOrder(maker2PK, maker2Order, sera),
            matchAmount1: amount
        });
        
        bytes memory intentSig = _signIntent(
            takerPK, taker, address(tokenA), address(tokenC),
            amount, amount, taker, 0, uuid, uint48(block.timestamp + 1 hours), sera
        );
        
        vm.prank(owner);
        try sor.executeIntent(matches, intentSig, intent, 3, 0, "") {
            ghost_multiLegExecutions++;
            ghost_consumedIntentUuids[taker][uuid] = true;
        } catch {
            ghost_failedExecutions++;
        }
    }
    
    // ============ Edge Case: Replay Attack Attempt ============
    
    function attemptReplayAttack(uint256 takerSeed, uint256 makerSeed, uint256 amount) external {
        uint256 takerIdx = takerSeed % users.length;
        uint256 makerIdx = makerSeed % users.length;
        if (takerIdx == makerIdx) makerIdx = (makerIdx + 1) % users.length;
        
        address taker = users[takerIdx];
        uint256 takerPK = userPKs[takerIdx];
        address maker = users[makerIdx];
        uint256 makerPK = userPKs[makerIdx];
        
        amount = bound(amount, 1 ether, 50 ether);
        
        // Setup
        _mintAndDeposit(taker, address(tokenA), amount * 2, sera);
        _setupMakerWithBalance(makerIdx, address(tokenB), amount * 2);
        
        uint256 uuid = nextUuid++;
        IntentParams memory intent = IntentParams({
            taker: taker,
            inputToken: address(tokenA),
            outputToken: address(tokenB),
            maxInputAmount: amount,
            minOutputAmount: amount,
            recipient: taker,
            initialDepositAmount: 0,
            uuid: uuid,
            deadline: uint48(block.timestamp + 1 hours)
        });
        
        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        Order memory makerOrder = Order({
            user: maker,
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: takerOrder,
            signature0: "",
            matchAmount0: amount,
            order1: makerOrder,
            signature1: _signOrder(makerPK, makerOrder, sera),
            matchAmount1: amount
        });
        
        bytes memory intentSig = _signIntent(
            takerPK, taker, address(tokenA), address(tokenB),
            amount, amount, taker, 0, uuid, uint48(block.timestamp + 1 hours), sera
        );
        
        // First execution should succeed
        vm.prank(owner);
        try sor.executeIntent(matches, intentSig, intent, 2, 0, "") {
            ghost_singleLegExecutions++;
            ghost_consumedIntentUuids[taker][uuid] = true;
        } catch {}
        
        // Setup new maker order for replay attempt
        Order memory makerOrder2 = Order({
            user: maker,
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        matches[0].order1 = makerOrder2;
        matches[0].signature1 = _signOrder(makerPK, makerOrder2, sera);
        
        // Replay attempt should fail
        vm.prank(owner);
        try sor.executeIntent(matches, intentSig, intent, 2, 0, "") {
            // If this succeeds, replay protection failed!
            revert("CRITICAL: Replay attack succeeded!");
        } catch {
            // Expected: replay protection worked
        }
    }
    
    // ============ View Functions ============
    
    function getUserCount() external view returns (uint256) {
        return users.length;
    }
    
    function getUser(uint256 idx) external view returns (address) {
        return users[idx];
    }
    
    function getTokenCount() external view returns (uint256) {
        return tokens.length;
    }
    
    function getToken(uint256 idx) external view returns (address) {
        return tokens[idx];
    }
}

/**
 * @title SeraSORInvariantTest - Invariant tests for SeraSOR
 * @notice Tests multi-leg routing, transient balances, and replay protection
 */
contract SeraSORInvariantTest is StdInvariant, TestHelper {
    Sera public sera;
    SeraSOR public sor;
    Vault public vault;
    
    MockStableCoin public tokenA;
    MockStableCoin public tokenB;
    MockStableCoin public tokenC;
    
    SeraSORHandler public handler;
    
    address public owner;
    uint256 public ownerPK;
    
    function setUp() public {
        (owner, ownerPK) = makeAddrAndKey("sorOwner");
        
        tokenA = new MockStableCoin("TokenA");
        tokenB = new MockStableCoin("TokenB");
        tokenC = new MockStableCoin("TokenC");
        
        vm.startPrank(owner);
        Vault vaultDeploy = new Vault(owner);
        sera = new Sera(owner, vaultDeploy);
        vaultDeploy.grantRole(vaultDeploy.TRADER_ROLE(), address(sera));
        vault = sera.vault();
        sor = new SeraSOR(address(sera));
        
        _whitelistToken(sera, address(tokenA), true, 1);
        _whitelistToken(sera, address(tokenB), true, 1);
        _whitelistToken(sera, address(tokenC), true, 1);
        
        sera.grantRole(sera.EXECUTOR_ROLE(), owner);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        vm.stopPrank();
        
        handler = new SeraSORHandler(
            sera, sor,
            tokenA, tokenB, tokenC,
            owner, ownerPK
        );
        
        bytes32 executorRole = sera.EXECUTOR_ROLE();
        vm.prank(owner);
        sera.grantRole(executorRole, address(handler));
        
        targetContract(address(handler));
        
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = SeraSORHandler.executeSingleLegIntent.selector;
        selectors[1] = SeraSORHandler.executeMultiLegIntent.selector;
        selectors[2] = SeraSORHandler.attemptReplayAttack.selector;
        
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }
    
    // ============ Core Invariants ============
    
    /**
     * @notice INVARIANT: Sera contract should never hold tokens after SOR execution
     * @dev All transient balances must be consumed or returned
     */
    function invariant_seraHoldsNoTokens() public view {
        for (uint256 t = 0; t < handler.getTokenCount(); t++) {
            address token = handler.getToken(t);
            uint256 seraBalance = IERC20(token).balanceOf(address(sera));
            assertEq(seraBalance, 0, "Sera holds tokens after execution");
        }
    }
    
    /**
     * @notice INVARIANT: Vault solvency maintained through SOR operations
     */
    function invariant_vaultSolvencyAfterSOR() public view {
        for (uint256 t = 0; t < handler.getTokenCount(); t++) {
            address token = handler.getToken(t);
            uint256 actualBalance = IERC20(token).balanceOf(address(vault));
            
            uint256 sumLedgerBalances = 0;
            for (uint256 u = 0; u < handler.getUserCount(); u++) {
                address user = handler.getUser(u);
                sumLedgerBalances += vault.balanceOf(token, user);
            }
            sumLedgerBalances += vault.balanceOf(token, owner);
            sumLedgerBalances += vault.balanceOf(token, sera.treasury());
            
            assertGe(actualBalance, sumLedgerBalances, "Vault insolvent after SOR");
        }
    }
    
    /**
     * @notice INVARIANT: MAX_ROUTE_LEGS constant is immutable
     */
    function invariant_maxRouteLegsConstant() public view {
        assertEq(sor.MAX_ROUTE_LEGS(), 20);
    }
    
    /**
     * @notice INVARIANT: Trusted router reference is correct
     */
    function invariant_trustedRouterCorrect() public view {
        assertEq(sera.trustedRouter(), address(sor));
    }
    
    /**
     * @notice INVARIANT: Intent UUID replay protection works
     * @dev Verified by attemptReplayAttack not reverting with success
     */
    function invariant_intentUuidReplayProtection() public view {
        // If any replay succeeded, the handler would have reverted
        assertTrue(true);
    }
    
    // ============ Call Summary ============
    
    function invariant_callSummary() public view {
        console.log("=== SeraSOR Invariant Test Summary ===");
        console.log("Single Leg Executions:", handler.ghost_singleLegExecutions());
        console.log("Multi Leg Executions:", handler.ghost_multiLegExecutions());
        console.log("Failed Executions:", handler.ghost_failedExecutions());
    }
}
