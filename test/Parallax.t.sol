// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

import { ParallaxToken } from "../src/amm/ParallaxToken.sol";
import { ParallaxPair } from "../src/amm/ParallaxPair.sol";
import { ParallaxReactive } from "../src/ParallaxReactive.sol";
import { ParallaxExecutor } from "../src/ParallaxExecutor.sol";
import { MockSystem } from "./mocks/MockSystem.sol";

/// @notice End-to-end simulation of the full Parallax loop on a single local chain:
///         origin Sync -> react() -> 2 callback requests -> executors swap -> executor events -> react() -> settle.
contract ParallaxTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant PROXY = address(0xC0FFEE);
    uint256 internal constant CHAIN_A = 1301; // Unichain Sepolia
    uint256 internal constant CHAIN_B = 84532; // Base Sepolia

    uint256 internal constant LIQ_BASE = 100 ether;
    uint256 internal constant LIQ_QUOTE = 300_000 ether; // 1 pWETH = 3,000 pUSD

    MockSystem internal sys;
    ParallaxToken internal baseA;
    ParallaxToken internal quoteA;
    ParallaxToken internal baseB;
    ParallaxToken internal quoteB;
    ParallaxPair internal poolA;
    ParallaxPair internal poolB;
    ParallaxReactive internal rx;
    ParallaxExecutor internal exA;
    ParallaxExecutor internal exB;

    function setUp() public {
        vm.warp(1_750_000_000);

        MockSystem impl = new MockSystem();
        vm.etch(SYSTEM_ADDR, address(impl).code);
        sys = MockSystem(payable(SYSTEM_ADDR));

        (baseA, quoteA, poolA) = _market();
        (baseB, quoteB, poolB) = _market();

        rx = new ParallaxReactive(
            CHAIN_A,
            address(poolA),
            true,
            CHAIN_B,
            address(poolB),
            true,
            1 ether, // min profit: 1 pUSD
            100_000 ether, // max trade: 100k pUSD
            100, // 1% slippage
            60, // leg TTL (s)
            120 // lock timeout (s)
        );

        exA = new ParallaxExecutor(
            IPayable(payable(PROXY)), address(rx), address(poolA), address(baseA), address(quoteA), 0
        );
        exB = new ParallaxExecutor(
            IPayable(payable(PROXY)), address(rx), address(poolB), address(baseB), address(quoteB), 0
        );
        rx.configureExecutors(address(exA), address(exB));

        baseA.mint(address(exA), 50 ether);
        quoteA.mint(address(exA), 150_000 ether);
        baseB.mint(address(exB), 50 ether);
        quoteB.mint(address(exB), 150_000 ether);

        // Mirror the starting state of both pools.
        _feedSync(CHAIN_A, poolA);
        _feedSync(CHAIN_B, poolB);
    }

    // ================================================================== setup checks

    function test_subscriptions() public view {
        // 2 Sync subscriptions (constructor) + 4 executor-event subscriptions (configureExecutors)
        assertEq(sys.subscriptionCount(), 6);
        (uint256 c0, address a0, uint256 t0) = sys.subscriptionAt(0);
        assertEq(c0, CHAIN_A);
        assertEq(a0, address(poolA));
        assertEq(t0, rx.SYNC_TOPIC_0());
        (uint256 c1, address a1,) = sys.subscriptionAt(1);
        assertEq(c1, CHAIN_B);
        assertEq(a1, address(poolB));
    }

    function test_syncTopicIsUniswapV2() public view {
        assertEq(rx.SYNC_TOPIC_0(), 0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1);
    }

    function test_mirrorMatchesPools() public view {
        (,,, bool baseIsToken0, uint256 rb, uint256 rq,,) = rx.venueA();
        assertTrue(baseIsToken0);
        assertEq(rb, LIQ_BASE);
        assertEq(rq, LIQ_QUOTE);
        assertEq(rx.currentSpreadBps(), 0);
    }

    // ================================================================== the full loop

    function test_fullLoop_closesSpreadAndBooksProfit() public {
        // A whale dumps 10 pWETH on Base -> Base becomes the cheap venue.
        _whaleDump(baseB, poolB, 10 ether);
        _feedSync(CHAIN_B, poolB);

        uint256 spreadBefore = rx.currentSpreadBps();
        assertGt(spreadBefore, 1500, "dislocation should be > 15%");
        assertEq(sys.callbackCount(), 2, "two legs requested in one reactive tx");
        assertEq(rx.activeArbId(), 1);
        assertTrue(rx.isLocked());

        // Leg 0 -> buy on Base (cheap), leg 1 -> sell on Unichain (rich)
        (uint256 chain0, address to0,,) = sys.callbackAt(0);
        (uint256 chain1, address to1,,) = sys.callbackAt(1);
        assertEq(chain0, CHAIN_B);
        assertEq(to0, address(exB));
        assertEq(chain1, CHAIN_A);
        assertEq(to1, address(exA));

        vm.warp(block.timestamp + 2);
        vm.recordLogs();
        _deliver(0);
        _deliver(1);
        _relay(vm.getRecordedLogs());

        (, uint8 legsMask, uint8 legsFailed, bool settled,,,,, int256 realized,) = rx.arbs(1);
        assertEq(legsMask, 3);
        assertEq(legsFailed, 0);
        assertTrue(settled);
        assertGt(realized, 0, "round trip must be profitable");
        assertEq(rx.arbsFullyFilled(), 1);
        assertEq(rx.cumulativePnlQuote(), realized);
        assertEq(rx.activeArbId(), 0);
        assertFalse(rx.isLocked());

        uint256 spreadAfter = rx.currentSpreadBps();
        assertLt(spreadAfter, 100, "gap closed to inside the fee band");
        assertEq(exA.legsExecuted(), 1);
        assertEq(exB.legsExecuted(), 1);
    }

    function test_smallMoveDoesNotTrade() public {
        _whaleDump(baseB, poolB, 0.05 ether); // ~0.1% move, inside the 0.6% round-trip fee band
        _feedSync(CHAIN_B, poolB);
        assertEq(sys.callbackCount(), 0);
        assertEq(rx.activeArbId(), 0);
    }

    function test_noTradeBeforeExecutorsConfigured() public {
        ParallaxReactive fresh = new ParallaxReactive(
            CHAIN_A, address(poolA), true, CHAIN_B, address(poolB), true, 1 ether, 100_000 ether, 100, 60, 120
        );
        _whaleDump(baseB, poolB, 10 ether);
        _feedSyncTo(fresh, CHAIN_A, poolA);
        _feedSyncTo(fresh, CHAIN_B, poolB);
        assertEq(fresh.activeArbId(), 0);
        assertEq(sys.callbackCount(), 0);
    }

    function test_maxTradeCapIsRespected() public {
        rx.setParams(1 ether, 5_000 ether, 100, 60, 120);
        _whaleDump(baseB, poolB, 10 ether);
        _feedSync(CHAIN_B, poolB);
        (,,,, uint256 quoteIn,,,,,) = rx.arbs(1);
        assertEq(quoteIn, 5_000 ether);
    }

    function test_chainedArbAfterCappedTrade() public {
        rx.setParams(1 ether, 5_000 ether, 100, 60, 120);
        _whaleDump(baseB, poolB, 10 ether);
        _feedSync(CHAIN_B, poolB);
        assertEq(sys.callbackCount(), 2);

        vm.recordLogs();
        _deliver(0);
        _deliver(1);
        _relay(vm.getRecordedLogs());

        // The cap left a gap, so settlement immediately opened arb #2 in the same reactive tx.
        assertEq(rx.activeArbId(), 2);
        assertEq(sys.callbackCount(), 4);
    }

    function test_lockBlocksThenExpires() public {
        _whaleDump(baseB, poolB, 10 ether);
        _feedSync(CHAIN_B, poolB);
        assertEq(sys.callbackCount(), 2);

        // Callbacks never arrive. More dislocation while locked -> no new arb.
        _whaleDump(baseB, poolB, 5 ether);
        _feedSync(CHAIN_B, poolB);
        assertEq(sys.callbackCount(), 2);

        // After lockTimeout the lock expires on the next event and a fresh arb is opened.
        vm.warp(block.timestamp + 121);
        _whaleDump(baseB, poolB, 1 ether);
        _feedSync(CHAIN_B, poolB);
        assertEq(rx.activeArbId(), 2);
        assertEq(sys.callbackCount(), 4);
    }

    function test_skippedLegStillSettlesAndUnlocks() public {
        exA.setPaused(true);
        _whaleDump(baseB, poolB, 10 ether);
        _feedSync(CHAIN_B, poolB);

        vm.recordLogs();
        _deliver(0); // exB executes
        _deliver(1); // exA paused -> LegSkipped
        _relay(vm.getRecordedLogs());

        (,, uint8 legsFailed, bool settled,,,,,,) = rx.arbs(1);
        assertTrue(settled);
        assertEq(legsFailed, 1);
        assertEq(rx.arbsFullyFilled(), 0);
        assertEq(rx.consecutivePartialFills(), 1);
        assertEq(exA.legsSkipped(), 1);
        // One retry is allowed: the gap is still open, so arb #2 fires straight away.
        assertEq(rx.activeArbId(), 2);
        assertFalse(rx.paused());
    }

    function test_circuitBreakerAfterRepeatedPartialFills() public {
        exA.setPaused(true);
        _whaleDump(baseB, poolB, 10 ether);
        _feedSync(CHAIN_B, poolB);

        vm.recordLogs();
        _deliver(0);
        _deliver(1);
        _relay(vm.getRecordedLogs()); // arb #1 partial -> retry opens arb #2

        vm.warp(block.timestamp + 2);
        vm.recordLogs();
        _deliver(2);
        _deliver(3);
        _relay(vm.getRecordedLogs()); // arb #2 partial -> breaker trips

        assertTrue(rx.paused(), "breaker must pause the engine");
        assertEq(rx.activeArbId(), 0);
        assertEq(sys.callbackCount(), 4, "no third arb");

        rx.setPaused(false);
        assertEq(rx.consecutivePartialFills(), 0);
    }

    function test_pausedReactiveDoesNothing() public {
        rx.setPaused(true);
        _whaleDump(baseB, poolB, 10 ether);
        _feedSync(CHAIN_B, poolB);
        assertEq(sys.callbackCount(), 0);
    }

    // ================================================================== access control

    function test_reactOnlySystem() public {
        IReactive.LogRecord memory log_ = _syncLog(CHAIN_A, poolA);
        vm.expectRevert();
        rx.react(log_);
    }

    function test_reactIgnoresUnknownPool() public {
        IReactive.LogRecord memory log_ = _syncLog(CHAIN_A, poolB); // right topic, wrong (chain, pool) pair
        log_.data = abi.encode(uint112(1 ether), uint112(1 ether));
        vm.prank(SYSTEM_ADDR);
        rx.react(log_);
        (,,,, uint256 rb,,,) = rx.venueA();
        assertEq(rb, LIQ_BASE);
    }

    function test_executorRejectsNonProxy() public {
        vm.expectRevert();
        exA.executeLeg(address(rx), 1, true, 1 ether, 0, block.timestamp + 60);
    }

    function test_executorRejectsForeignReactive() public {
        vm.prank(PROXY);
        vm.expectRevert();
        exA.executeLeg(address(0xBAD), 1, true, 1 ether, 0, block.timestamp + 60);
    }

    function test_onlyOwnerConfig() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(ParallaxReactive.NotOwner.selector);
        rx.setPaused(true);

        vm.expectRevert(ParallaxReactive.AlreadyConfigured.selector);
        rx.configureExecutors(address(1), address(2));
    }

    // ================================================================== executor guards

    function test_executorSkipsExpired() public {
        vm.prank(PROXY);
        exA.executeLeg(address(rx), 7, true, 1_000 ether, 0, block.timestamp - 1);
        assertEq(exA.legsSkipped(), 1);
        assertEq(exA.legsExecuted(), 0);
    }

    function test_executorSkipsWhenPriceMoved() public {
        vm.prank(PROXY);
        exA.executeLeg(address(rx), 7, true, 1_000 ether, 1_000 ether, block.timestamp + 60); // absurd minOut
        assertEq(exA.legsSkipped(), 1);
    }

    function test_executorSkipsWithoutInventory() public {
        vm.prank(PROXY);
        exA.executeLeg(address(rx), 7, true, 10_000_000 ether, 0, block.timestamp + 60);
        assertEq(exA.legsSkipped(), 1);
    }

    function test_executorReplayProtection() public {
        vm.startPrank(PROXY);
        exA.executeLeg(address(rx), 7, true, 1_000 ether, 0, block.timestamp + 60);
        exA.executeLeg(address(rx), 7, true, 1_000 ether, 0, block.timestamp + 60);
        vm.stopPrank();
        assertEq(exA.legsExecuted(), 1);
        assertEq(exA.legsSkipped(), 1);
    }

    function test_executorCooldownIsTimestampBased() public {
        exA.setCooldown(10);
        // Explicit times: with via_ir, block.timestamp can be cached inside one test function.
        uint256 t0 = block.timestamp;
        uint256 deadline = t0 + 600;
        vm.startPrank(PROXY);
        exA.executeLeg(address(rx), 1, true, 100 ether, 0, deadline);
        vm.warp(t0 + 5);
        exA.executeLeg(address(rx), 2, true, 100 ether, 0, deadline);
        assertEq(exA.legsSkipped(), 1, "inside cooldown");
        vm.warp(t0 + 11);
        exA.executeLeg(address(rx), 3, true, 100 ether, 0, deadline);
        vm.stopPrank();
        assertEq(exA.legsExecuted(), 2);
    }

    function test_executorEventTopicsMatchReactive() public {
        vm.recordLogs();
        vm.startPrank(PROXY);
        exA.executeLeg(address(rx), 1, true, 100 ether, 0, block.timestamp + 60);
        exA.executeLeg(address(rx), 1, true, 100 ether, 0, block.timestamp + 60); // duplicate -> skip
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawExecuted;
        bool sawSkipped;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(exA)) continue;
            if (uint256(logs[i].topics[0]) == rx.LEG_EXECUTED_TOPIC_0()) sawExecuted = true;
            if (uint256(logs[i].topics[0]) == rx.LEG_SKIPPED_TOPIC_0()) sawSkipped = true;
        }
        assertTrue(sawExecuted);
        assertTrue(sawSkipped);
    }

    // ================================================================== helpers

    function _market() internal returns (ParallaxToken base, ParallaxToken quote, ParallaxPair pool) {
        base = new ParallaxToken("Parallax Wrapped Ether", "pWETH");
        quote = new ParallaxToken("Parallax USD", "pUSD");
        pool = new ParallaxPair(address(base), address(quote));
        base.mint(address(this), LIQ_BASE);
        quote.mint(address(this), LIQ_QUOTE);
        base.approve(address(pool), LIQ_BASE);
        quote.approve(address(pool), LIQ_QUOTE);
        pool.addLiquidity(LIQ_BASE, LIQ_QUOTE);
    }

    function _whaleDump(ParallaxToken base, ParallaxPair pool, uint256 amount) internal {
        base.mint(address(this), amount);
        base.approve(address(pool), amount);
        pool.swapExactIn(address(base), amount, 0, address(this));
    }

    function _syncLog(uint256 chainId, ParallaxPair pool) internal view returns (IReactive.LogRecord memory log_) {
        (uint112 r0, uint112 r1,) = pool.getReserves();
        log_.chainId = chainId;
        log_.contractAddress = address(pool);
        log_.topic0 = rx.SYNC_TOPIC_0();
        log_.data = abi.encode(r0, r1);
        log_.blockNumber = block.number;
        log_.txHash = uint256(keccak256(abi.encode(chainId, r0, r1)));
    }

    function _feedSync(uint256 chainId, ParallaxPair pool) internal {
        _feedSyncTo(rx, chainId, pool);
    }

    function _feedSyncTo(ParallaxReactive target, uint256 chainId, ParallaxPair pool) internal {
        IReactive.LogRecord memory log_ = _syncLog(chainId, pool);
        vm.prank(SYSTEM_ADDR);
        target.react(log_);
    }

    /// @dev Replays callback #i the way the callback proxy would: first argument overwritten with the reactive address.
    function _deliver(uint256 i) internal {
        (, address recipient, uint64 gasLimit, bytes memory payload) = sys.callbackAt(i);
        address sender = address(rx);
        assembly {
            mstore(add(payload, 36), sender) // 32 (length) + 4 (selector) -> first argument word
        }
        vm.prank(PROXY);
        (bool ok,) = recipient.call{ gas: gasLimit }(payload);
        assertTrue(ok, "callback reverted");
    }

    /// @dev Feeds every log Reactive Network would forward (pool Syncs + executor leg events) back into react().
    function _relay(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            uint256 t0 = uint256(l.topics[0]);
            if (t0 != rx.SYNC_TOPIC_0() && t0 != rx.LEG_EXECUTED_TOPIC_0() && t0 != rx.LEG_SKIPPED_TOPIC_0()) continue;

            uint256 chainId;
            if (l.emitter == address(poolA) || l.emitter == address(exA)) chainId = CHAIN_A;
            else if (l.emitter == address(poolB) || l.emitter == address(exB)) chainId = CHAIN_B;
            else continue;

            IReactive.LogRecord memory log_;
            log_.chainId = chainId;
            log_.contractAddress = l.emitter;
            log_.topic0 = t0;
            if (l.topics.length > 1) log_.topic1 = uint256(l.topics[1]);
            log_.data = l.data;
            log_.blockNumber = block.number;
            log_.txHash = uint256(keccak256(abi.encode(i, l.emitter)));

            vm.prank(SYSTEM_ADDR);
            rx.react(log_);
        }
    }
}
