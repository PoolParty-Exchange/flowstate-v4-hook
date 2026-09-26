// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {FlowstateC1Hook} from "../src/FlowstateC1Hook.sol";
import {IGen4Pool} from "../src/interfaces/IGen4Inventory.sol";
import {MockInventoryToken} from "./mocks/MockInventoryToken.sol";

contract Gen4Recorder {
    uint256[] internal _steps;
    function record(uint256 value) external { _steps.push(value); }
    function length() external view returns (uint256) { return _steps.length; }
    function step(uint256 i) external view returns (uint256) { return _steps[i]; }
}

contract Gen4MockPool {
    MockInventoryToken public immutable token;
    uint64 public index;
    uint128 public amount;
    uint128 public pinned;

    constructor(MockInventoryToken token_) { token = token_; }

    function setNode(uint64 index_, uint128 amount_, uint128 pinned_) external {
        index = index_;
        amount = amount_;
        pinned = pinned_;
    }

    bool public buyBackEnabled;
    address public buybackAsset;
    function setBuyBack(bool enabled, address asset) external { buyBackEnabled = enabled; buybackAsset = asset; }

    function available() public view returns (uint256) { return uint256(amount) - uint256(pinned); }

    function tokenQueueEnds() external view returns (uint64 head, uint64 tail) {
        if (amount != 0) return (index, index);
    }

    function queue(uint256) external view returns (IGen4Pool.QueueNode[] memory nodes) {
        if (amount == 0) return new IGen4Pool.QueueNode[](0);
        nodes = new IGen4Pool.QueueNode[](1);
        nodes[0] = IGen4Pool.QueueNode(index, address(0xA11CE), amount, pinned, pinned == 0 ? 0 : 1);
    }

    function fill(uint256 requested, address buyer) external returns (uint256 filled) {
        uint256 a = available();
        filled = requested < a ? requested : a;
        amount -= uint128(filled);
        token.transfer(buyer, filled);
    }
}

contract Gen4MockRegistry {
    struct Candidate { uint8 state; uint64 id; uint256 available; uint32 version; uint64 poolTail; }
    Candidate[] internal _candidates;
    uint256 public cursor;
    address public immutable market;

    address public settlement;

    constructor(address market_) { market = market_; }

    function setSettlement(address value) external { settlement = value; }
    function push(Candidate calldata c) external { _candidates.push(c); }
    function advance() external { if (cursor < _candidates.length) ++cursor; }

    function peek(address) external view returns (uint8, uint64, uint64, uint256, uint32, uint64) {
        if (cursor >= _candidates.length) return (0, 0, 0, 0, 0, 0);
        Candidate memory c = _candidates[cursor];
        return (c.state, c.id, 1, c.available, c.version, c.poolTail);
    }
}

contract Gen4MockSettlement {
    uint8 internal constant SOLD = 0;
    uint8 internal constant SKIPPED = 2;
    uint8 internal constant STALE = 3;
    uint8 internal constant CLOSED = 4;

    Gen4MockRegistry public immutable registry;
    MockInventoryToken public immutable token;
    Gen4Recorder public immutable recorder;
    address public immutable market;
    uint256 public rate = 1e18;
    bool public alwaysStale;
    bool public closed;

    constructor(Gen4MockRegistry registry_, MockInventoryToken token_, Gen4Recorder recorder_, address market_) {
        registry = registry_;
        token = token_;
        recorder = recorder_;
        market = market_;
    }

    bool public revertSettle;
    function setAlwaysStale(bool value) external { alwaysStale = value; }
    function setClosed(bool value) external { closed = value; }
    function setRevertSettle(bool value) external { revertSettle = value; }
    function price(address, address) external view returns (uint8 why, uint256 price_) {
        return closed ? (uint8(1), uint256(0)) : (uint8(0), rate);
    }

    function settleHead(
        address,
        uint64 listingId,
        uint32,
        uint256 maxAmount,
        address quoteAsset,
        uint256 maxQuoteIn,
        address recipient,
        string calldata,
        uint256
    ) external returns (uint8 outcome, uint64 id, uint256 filled, uint256 quotePaid) {
        recorder.record(100 + listingId);
        require(!revertSettle, "settlement reverted");
        if (closed) return (CLOSED, listingId, 0, 0);
        if (alwaysStale) return (STALE, listingId, 0, 0);
        (uint8 state, uint64 current,, uint256 available,,) = registry.peek(address(token));
        if (current != listingId) return (STALE, listingId, 0, 0);
        if (state == 2) {
            registry.advance();
            return (SKIPPED, listingId, 0, 0);
        }
        filled = maxAmount < available ? maxAmount : available;
        quotePaid = (filled * rate + 1e18 - 1) / 1e18;
        require(quotePaid <= maxQuoteIn, "over budget");
        IERC20(quoteAsset).transferFrom(msg.sender, address(this), quotePaid);
        token.transfer(recipient, filled);
        registry.advance();
        return (SOLD, listingId, filled, quotePaid);
    }
}

contract Gen4MockMarket {
    Gen4MockPool public immutable pool;
    MockInventoryToken public immutable token;
    Gen4Recorder public immutable recorder;
    uint256 public rate = 1e18;
    uint256 public executionRate = 1e18;
    mapping(address => bool) public approvedQuoteAssets;

    constructor(Gen4MockPool pool_, MockInventoryToken token_, Gen4Recorder recorder_) {
        pool = pool_;
        token = token_;
        recorder = recorder_;
    }

    // 1: the bounded buy reverts; 2: it burns every unit of gas it is given (an out-of-gas leg)
    uint8 public failMode;
    address public supplierRegistry; // zero: sell-side attribution off, as the pinned stack deploys
    function setSupplierRegistry(address value) external { supplierRegistry = value; }
    function approveAsset(address asset) external { approvedQuoteAssets[asset] = true; }
    function setExecutionRate(uint256 value) external { executionRate = value; }
    function setFailMode(uint8 value) external { failMode = value; }
    function poolRecords(address candidate) external view returns (address inventoryToken, bool exists) {
        return candidate == address(pool) ? (address(token), true) : (address(0), false);
    }
    function previewRate(address candidate, address asset) external view returns (bool ok, uint256 rate_) {
        return (candidate == address(pool) && approvedQuoteAssets[asset], rate);
    }
    function maxBuy(address candidate, address asset) external view returns (uint256 maxTokens, uint256 maxQuote) {
        if (failMode == 3) revert("maxBuy reverted");
        if (candidate != address(pool) || !approvedQuoteAssets[asset]) return (0, 0);
        maxTokens = pool.available();
        maxQuote = (maxTokens * rate + 1e18 - 1) / 1e18;
    }
    function buyFromPoolBounded(
        address,
        address asset,
        uint256 amount,
        string calldata,
        address buyer,
        uint256 maxCost,
        uint256,
        uint256
    ) public returns (uint256 tokensFilled, uint256 quotePaid) {
        recorder.record(200);
        if (failMode == 1) revert("pool leg reverted");
        if (failMode == 2) while (true) {} // exhausts the forwarded gas
        tokensFilled = pool.fill(amount, buyer);
        quotePaid = (tokensFilled * executionRate + 1e18 - 1) / 1e18;
        require(quotePaid <= maxCost, "over budget");
        IERC20(asset).transferFrom(msg.sender, address(this), quotePaid);
    }
    function buyFromPool(address p, address a, uint256 n, string calldata c, address b)
        external returns (uint256, uint256)
    { return buyFromPoolBounded(p, a, n, c, b, type(uint256).max, 0, 0); }
    function buyFromPoolExactQuote(address p, address a, uint256 q, string calldata c, address b)
        external returns (uint256, uint256)
    { return buyFromPoolBounded(p, a, q, c, b, q, 0, 0); }
    function buyFromPoolExactOut(address p, address a, uint256 n, string calldata c, address b)
        external returns (uint256, uint256)
    { return buyFromPoolBounded(p, a, n, c, b, type(uint256).max, n, 0); }
}

contract Gen4MockManager {
    receive() external payable {}
    function take(Currency currency, address to, uint256 amount) external {
        address asset = Currency.unwrap(currency);
        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "native take failed");
        } else {
            IERC20(asset).transfer(to, amount);
        }
    }
    function sync(Currency) external {}
    function settle() external payable returns (uint256) { return msg.value; }
    function settleFor(address) external payable returns (uint256) { return msg.value; }
    function currencyDelta(address, Currency) external pure returns (int256) { return 0; }
}

contract Gen4MockWETH is ERC20 {
    constructor() ERC20("Mock WETH", "MWETH") {}
    receive() external payable {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external { _burn(msg.sender, amount); payable(msg.sender).transfer(amount); }
}

contract FlowstateC1HookHarness is FlowstateC1Hook {
    constructor(
        address manager,
        address market,
        address owner,
        address weth,
        address registry,
        address settlement
    ) FlowstateC1Hook(manager, market, owner, weth, address(0xBEEF), 0, registry, settlement) {}

    function runExactInput(
        address pool,
        address input,
        address marketAsset,
        address output,
        uint256 quoteIn,
        address sender
    ) external returns (uint256 tokens, uint256 cost, uint256 refund, uint256 dust) {
        PairConfig memory cfg = PairConfig(pool, false, true, 0, marketAsset);
        Fill memory f = _buyGen4ExactInput(cfg, Currency.wrap(input), Currency.wrap(output), -int256(quoteIn), sender);
        tokens = f.tokensOut;
        cost = f.costBase;
        dust = f.dustAccrued;
        refund = quoteIn - cost - f.spreadAccrued - dust;
    }

    function poolNodeGas(address pool, address marketAsset) external view returns (uint256) {
        return _poolNodeGas(PairConfig(pool, false, true, 0, marketAsset));
    }

    function runExactOutput(
        address pool,
        address input,
        address marketAsset,
        address output,
        uint256 target,
        address
    ) external returns (uint256 tokens, uint256 cost, uint256 charged) {
        PairConfig memory cfg = PairConfig(pool, false, true, 0, marketAsset);
        Fill memory f = _buyGen4ExactOutput(cfg, Currency.wrap(input), Currency.wrap(output), int256(target));
        return (f.tokensOut, f.costBase, f.quoteIn);
    }
}

contract Gen4HookIntegrationTest is Test {
    uint160 internal constant FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    MockInventoryToken token;
    MockInventoryToken quote;
    Gen4MockWETH weth;
    Gen4Recorder recorder;
    Gen4MockPool pool;
    Gen4MockRegistry registry;
    Gen4MockSettlement settlement;
    Gen4MockMarket market;
    Gen4MockManager manager;
    FlowstateC1HookHarness hook;

    function setUp() public {
        token = new MockInventoryToken();
        quote = new MockInventoryToken();
        weth = new Gen4MockWETH();
        recorder = new Gen4Recorder();
        pool = new Gen4MockPool(token);
        market = new Gen4MockMarket(pool, token, recorder);
        registry = new Gen4MockRegistry(address(market));
        settlement = new Gen4MockSettlement(registry, token, recorder, address(market));
        registry.setSettlement(address(settlement));
        manager = new Gen4MockManager();
        market.approveAsset(address(quote));
        market.approveAsset(address(weth));

        bytes memory args = abi.encode(
            address(manager), address(market), address(this), address(weth), address(registry), address(settlement)
        );
        (address expected, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(FlowstateC1HookHarness).creationCode, args);
        hook = new FlowstateC1HookHarness{salt: salt}(
            address(manager), address(market), address(this), address(weth), address(registry), address(settlement)
        );
        assertEq(address(hook), expected);
        hook.registerPair(Currency.wrap(address(quote)), Currency.wrap(address(token)), address(pool), 0);
        quote.mint(address(manager), 1_000e18);
        vm.deal(address(manager), 1_000e18);
    }

    function test_DeadListingThenOlderPoolThenLiveListing() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        token.mint(address(settlement), 2e18);
        registry.push(Gen4MockRegistry.Candidate(2, 1, 0, 1, 0));
        registry.push(Gen4MockRegistry.Candidate(1, 2, 2e18, 1, 1));

        (uint256 tokens, uint256 cost, uint256 charged) = hook.runExactOutput(
            address(pool), address(quote), address(quote), address(token), 3e18, address(this)
        );
        assertEq(tokens, 3e18);
        assertEq(cost, 3e18);
        assertEq(charged, 3e18);
        assertEq(recorder.length(), 3);
        assertEq(recorder.step(0), 101, "dead L1 attempted first");
        assertEq(recorder.step(1), 200, "P1 filled after reinspection");
        assertEq(recorder.step(2), 102, "L2 cannot jump P1");
        assertEq(token.balanceOf(address(manager)), 3e18);
    }

    function test_ExactInputPartialFillRefundsUnspentQuote() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        uint256 beforeBalance = quote.balanceOf(address(manager));
        (uint256 tokens, uint256 cost, uint256 refund, uint256 dust) = hook.runExactInput(
            address(pool), address(quote), address(quote), address(token), 10e18, address(this)
        );
        assertEq(tokens, 1e18);
        assertEq(cost, 1e18);
        assertEq(refund, 9e18);
        assertEq(dust, 0);
        assertEq(quote.balanceOf(address(manager)), beforeBalance - 1e18);
        assertEq(quote.balanceOf(address(hook)), 0);
    }

    function enforceMinimumOutput(uint256 minimum) external {
        (uint256 tokens,,,) = hook.runExactInput(
            address(pool), address(quote), address(quote), address(token), 10e18, address(this)
        );
        require(tokens >= minimum, "minimum output");
    }

    function test_MinimumOutputFailureRollsBackFundsAndInventory() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        uint256 quoteBefore = quote.balanceOf(address(manager));

        vm.expectRevert(bytes("minimum output"));
        this.enforceMinimumOutput(2e18);

        assertEq(quote.balanceOf(address(manager)), quoteBefore);
        assertEq(quote.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(pool.available(), 1e18);
    }

    function test_ExactInputMixedFillUsesActualLegAmounts() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        token.mint(address(settlement), 2e18);
        registry.push(Gen4MockRegistry.Candidate(2, 1, 0, 1, 0));
        registry.push(Gen4MockRegistry.Candidate(1, 2, 2e18, 1, 1));
        (uint256 tokens, uint256 cost, uint256 refund, uint256 dust) = hook.runExactInput(
            address(pool), address(quote), address(quote), address(token), 3e18, address(this)
        );
        assertEq(tokens, 3e18);
        assertEq(cost, 3e18);
        assertEq(refund, 0);
        assertEq(dust, 0);
        assertEq(recorder.step(0), 101);
        assertEq(recorder.step(1), 200);
        assertEq(recorder.step(2), 102);
    }

    function test_StaleAttemptCapRefundsAndRetainsNothing() public {
        token.mint(address(settlement), 1e18);
        registry.push(Gen4MockRegistry.Candidate(1, 7, 1e18, 1, 0));
        settlement.setAlwaysStale(true);
        uint256 beforeBalance = quote.balanceOf(address(manager));
        (uint256 tokens, uint256 cost, uint256 refund, uint256 dust) = hook.runExactInput(
            address(pool), address(quote), address(quote), address(token), 5e18, address(this)
        );
        assertEq(tokens, 0);
        assertEq(cost, 0);
        assertEq(refund, 5e18);
        assertEq(dust, 0);
        assertEq(recorder.length(), hook.GEN4_MAX_ATTEMPTS());
        assertEq(quote.balanceOf(address(manager)), beforeBalance);
        assertEq(quote.balanceOf(address(hook)), 0);
    }

    function test_NativeQuotePoolLegWrapsAndLeavesNoBalance() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        hook.registerPair(Currency.wrap(address(0)), Currency.wrap(address(token)), address(pool), 0);
        (uint256 tokens, uint256 cost, uint256 charged) = hook.runExactOutput(
            address(pool), address(0), address(weth), address(token), 1e18, address(this)
        );
        assertEq(tokens, 1e18);
        assertEq(cost, 1e18);
        assertEq(charged, 1e18);
        assertEq(address(hook).balance, 0);
        assertEq(weth.balanceOf(address(hook)), 0);
    }

    function test_ExactOutputAttemptCapRevertsWithoutStrandingFunds() public {
        registry.push(Gen4MockRegistry.Candidate(1, 11, 1e18, 1, 0));
        settlement.setAlwaysStale(true);
        uint256 managerBefore = quote.balanceOf(address(manager));
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.Gen4AttemptCapExceeded.selector, 16));
        hook.runExactOutput(address(pool), address(quote), address(quote), address(token), 1e18, address(this));
        assertEq(quote.balanceOf(address(manager)), managerBefore);
        assertEq(quote.balanceOf(address(hook)), 0);
    }

    function test_WorstCaseStaleRetryGas() public {
        registry.push(Gen4MockRegistry.Candidate(1, 9, 1e18, 1, 0));
        settlement.setAlwaysStale(true);
        uint256 beforeGas = gasleft();
        hook.runExactInput(address(pool), address(quote), address(quote), address(token), 5e18, address(this));
        emit log_named_uint("gen4_16_stale_attempts_gas", beforeGas - gasleft());
    }

    // Failure handling (JUP-698 gate 1 finding, review F3/F5, 26 Sep 2026). A leg that reverts or runs
    // out of gas is rolled back in the callee. Exact input keeps what already filled and refunds the
    // rest; with nothing filled it reverts Gen4NothingFilled, so gas estimators search upward.
    function test_ZeroFillPoolLegFailureRevertsNothingFilled() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        for (uint8 mode = 1; mode <= 2; ++mode) {
            market.setFailMode(mode);
            vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.Gen4NothingFilled.selector, uint8(3)));
            hook.runExactInput(address(pool), address(quote), address(quote), address(token), 10e18, address(this));
        }
    }

    function _listingThenFailingPool(uint8 mode) internal {
        pool.setNode(5, 1e18, 0);                               // node 5: after the listing's snapshot
        token.mint(address(pool), 1e18);
        token.mint(address(settlement), 2e18);
        registry.push(Gen4MockRegistry.Candidate(1, 2, 2e18, 1, 4)); // listing, poolTail 4: sells first
        market.setFailMode(mode);
        uint256 managerBefore = quote.balanceOf(address(manager));
        (uint256 tokens, uint256 cost, uint256 refund,) = hook.runExactInput(
            address(pool), address(quote), address(quote), address(token), 10e18, address(this)
        );
        assertEq(tokens, 2e18, "the listing sold before the pool leg failed");
        assertEq(cost, 2e18);
        assertEq(refund, 8e18, "the rest refunded");
        assertEq(quote.balanceOf(address(manager)), managerBefore - 2e18, "only the listing's cost left the manager");
        assertEq(quote.balanceOf(address(hook)), 0, "hook keeps nothing");
        assertEq(pool.amount(), 1e18, "the pool node untouched");
    }

    function test_RevertingPoolLegAfterAFillRefundsTheRest() public {
        _listingThenFailingPool(1);
    }

    function test_OutOfGasPoolLegAfterAFillIsCaughtAndRefunds() public {
        _listingThenFailingPool(2);
    }

    function test_RevertingListingLegRefundsAfterEarlierFills() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        token.mint(address(settlement), 2e18);
        registry.push(Gen4MockRegistry.Candidate(1, 2, 2e18, 1, 1)); // live listing behind node 1
        settlement.setRevertSettle(true);
        (uint256 tokens, uint256 cost, uint256 refund,) = hook.runExactInput(
            address(pool), address(quote), address(quote), address(token), 10e18, address(this)
        );
        assertEq(tokens, 1e18, "the pool leg before the listing still delivered");
        assertEq(cost, 1e18);
        assertEq(refund, 9e18, "the rest refunded");
        assertEq(quote.balanceOf(address(hook)), 0);
    }

    function test_ZeroFillListingLegFailureRevertsNothingFilled() public {
        token.mint(address(settlement), 2e18);
        registry.push(Gen4MockRegistry.Candidate(1, 2, 2e18, 1, 0));
        settlement.setRevertSettle(true);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.Gen4NothingFilled.selector, uint8(4)));
        hook.runExactInput(address(pool), address(quote), address(quote), address(token), 10e18, address(this));
    }

    function test_FailedVenueReadRevertsWithNothingFilled() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        market.setFailMode(3);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.Gen4NothingFilled.selector, uint8(2)));
        hook.runExactInput(address(pool), address(quote), address(quote), address(token), 10e18, address(this));
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.CandidateInspectionFailed.selector, uint8(1)));
        hook.runExactOutput(address(pool), address(quote), address(quote), address(token), 1e18, address(this));
    }

    function test_FailedPoolLegOnExactOutputRevertsAsShortfallAndStrandsNothing() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        market.setFailMode(2);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.Gen4FillShortfall.selector, 0, 1e18));
        hook.runExactOutput(address(pool), address(quote), address(quote), address(token), 1e18, address(this));
    }

    function test_BelowMinimumAttemptGasExactInputRevertsNothingFilled() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        uint256 limit = hook.GEN4_FINALIZATION_GAS_RESERVE() + hook.GEN4_MIN_ATTEMPT_GAS() - 1;
        (bool ok, bytes memory ret) = address(hook).call{gas: limit}(
            abi.encodeCall(FlowstateC1HookHarness.runExactInput, (address(pool), address(quote), address(quote), address(token), 10e18, address(this)))
        );
        assertFalse(ok, "reverts rather than succeeding with no output");
        assertEq(ret, abi.encodeWithSelector(FlowstateC1Hook.Gen4NothingFilled.selector, uint8(1)));
        assertEq(recorder.length(), 0, "no leg attempted");
    }

    // The price is read once per swap: a closed swap route sells nothing from either source
    function test_ClosedRouteExactInputRefundsEverythingWithoutAnAttempt() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        registry.push(Gen4MockRegistry.Candidate(1, 2, 2e18, 1, 1));
        settlement.setClosed(true);
        (uint256 tokens, uint256 cost, uint256 refund,) = hook.runExactInput(
            address(pool), address(quote), address(quote), address(token), 10e18, address(this)
        );
        assertEq(tokens, 0);
        assertEq(cost, 0);
        assertEq(refund, 10e18);
        assertEq(recorder.length(), 0, "no leg attempted");
        assertEq(quote.balanceOf(address(hook)), 0);
    }

    function test_ClosedRouteExactOutputRevertsAsShortfall() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        settlement.setClosed(true);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.Gen4FillShortfall.selector, 0, 1e18));
        hook.runExactOutput(address(pool), address(quote), address(quote), address(token), 1e18, address(this));
    }

    // Per-node gas planning (review F5): four cases from the market's registry and the pool's buy-back
    function test_PoolNodeGasFollowsAttributionAndRecycling() public {
        assertEq(hook.poolNodeGas(address(pool), address(quote)), hook.GEN4_POOL_NODE_GAS());
        pool.setBuyBack(true, address(weth)); // buy-back in another asset: no recycling for this swap
        assertEq(hook.poolNodeGas(address(pool), address(quote)), hook.GEN4_POOL_NODE_GAS());
        pool.setBuyBack(true, address(quote));
        assertEq(hook.poolNodeGas(address(pool), address(quote)), hook.GEN4_POOL_NODE_GAS_RECYCLED());
        market.setSupplierRegistry(address(0xBEEF));
        assertEq(hook.poolNodeGas(address(pool), address(quote)), hook.GEN4_POOL_NODE_GAS_ATTRIBUTED_RECYCLED());
        pool.setBuyBack(false, address(quote));
        assertEq(hook.poolNodeGas(address(pool), address(quote)), hook.GEN4_POOL_NODE_GAS_ATTRIBUTED());
        // settings that cannot be read (a contract without the views reverts, caught) count as on
        market.setSupplierRegistry(address(0));
        assertEq(hook.poolNodeGas(address(recorder), address(quote)), hook.GEN4_POOL_NODE_GAS_RECYCLED());
    }

    // Review F6: the settlement the hook approves must be the one the registry is bound to
    function test_ConstructorRefusesASettlementTheRegistryDoesNotName() public {
        registry.setSettlement(address(0xBAD));
        bytes memory args = abi.encode(
            address(manager), address(market), address(this), address(weth), address(registry), address(settlement)
        );
        (, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(FlowstateC1HookHarness).creationCode, args);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ListingWiringMismatch.selector, address(registry), address(settlement)));
        new FlowstateC1HookHarness{salt: salt}(
            address(manager), address(market), address(this), address(weth), address(registry), address(settlement)
        );
    }
}

/// @notice Runs the production beforeSwap path against a real local V4
///         PoolManager. This catches hook/caller delta mistakes that the direct
///         loop harness intentionally cannot model.
contract Gen4PoolManagerIntegrationTest is Test {
    uint160 internal constant FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    MockInventoryToken token;
    MockInventoryToken quote;
    Gen4MockWETH weth;
    Gen4MockPool inventoryPool;
    Gen4MockRegistry registry;
    Gen4MockSettlement settlement;
    Gen4MockMarket market;
    PoolManager manager;
    FlowstateC1Hook hook;
    PoolSwapTest router;
    PoolKey key;
    address swapper = address(0x5157);

    function setUp() public {
        token = new MockInventoryToken();
        quote = new MockInventoryToken();
        weth = new Gen4MockWETH();
        Gen4Recorder recorder = new Gen4Recorder();
        inventoryPool = new Gen4MockPool(token);
        market = new Gen4MockMarket(inventoryPool, token, recorder);
        registry = new Gen4MockRegistry(address(market));
        settlement = new Gen4MockSettlement(registry, token, recorder, address(market));
        registry.setSettlement(address(settlement));
        manager = new PoolManager(address(this));
        market.approveAsset(address(quote));

        bytes memory args = abi.encode(
            address(manager),
            address(market),
            address(this),
            address(weth),
            address(0xBEEF),
            uint16(0),
            address(registry),
            address(settlement)
        );
        (address expected, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(FlowstateC1Hook).creationCode, args);
        hook = new FlowstateC1Hook{salt: salt}(
            address(manager),
            address(market),
            address(this),
            address(weth),
            address(0xBEEF),
            0,
            address(registry),
            address(settlement)
        );
        assertEq(address(hook), expected);
        hook.registerPair(Currency.wrap(address(quote)), Currency.wrap(address(token)), address(inventoryPool), 0);

        (Currency c0, Currency c1) = address(quote) < address(token)
            ? (Currency.wrap(address(quote)), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(address(quote)));
        key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(key, uint160(1 << 96));
        router = new PoolSwapTest(IPoolManager(address(manager)));

        quote.mint(address(manager), 100e18);
        quote.mint(swapper, 100e18);
        vm.prank(swapper);
        quote.approve(address(router), type(uint256).max);
    }

    function test_ExactOutputSurplusPrefundSettlesHookDelta() public {
        inventoryPool.setNode(1, 2e18, 0);
        token.mint(address(inventoryPool), 2e18);
        market.setExecutionRate(5e17); // preview/prefund 2; actual pool charge 1
        uint256 quoteBefore = quote.balanceOf(swapper);

        vm.prank(swapper);
        router.swap(
            key,
            SwapParams({
                zeroForOne: address(quote) < address(token),
                amountSpecified: int256(2e18),
                sqrtPriceLimitX96: address(quote) < address(token)
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(quoteBefore - quote.balanceOf(swapper), 1e18, "swapper charged actual cost only");
        assertEq(token.balanceOf(swapper), 2e18);
        assertEq(quote.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_OppositeCurrencyOrderingUsesProductionBeforeSwap() public {
        bool originalQuoteBelow = address(quote) < address(token);
        MockInventoryToken oppositeQuote;
        for (uint256 i; i < 32; ++i) {
            MockInventoryToken candidate = new MockInventoryToken();
            if ((address(candidate) < address(token)) != originalQuoteBelow) {
                oppositeQuote = candidate;
                break;
            }
        }
        assertTrue(address(oppositeQuote) != address(0), "opposite ordering not found");

        market.approveAsset(address(oppositeQuote));
        hook.registerPair(
            Currency.wrap(address(oppositeQuote)), Currency.wrap(address(token)), address(inventoryPool), 0
        );
        (Currency c0, Currency c1) = address(oppositeQuote) < address(token)
            ? (Currency.wrap(address(oppositeQuote)), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(address(oppositeQuote)));
        PoolKey memory oppositeKey =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(oppositeKey, uint160(1 << 96));

        inventoryPool.setNode(1, 1e18, 0);
        token.mint(address(inventoryPool), 1e18);
        oppositeQuote.mint(address(manager), 10e18);
        oppositeQuote.mint(swapper, 10e18);
        vm.prank(swapper);
        oppositeQuote.approve(address(router), type(uint256).max);

        vm.prank(swapper);
        router.swap(
            oppositeKey,
            SwapParams({
                zeroForOne: address(oppositeQuote) < address(token),
                amountSpecified: int256(1e18),
                sqrtPriceLimitX96: address(oppositeQuote) < address(token)
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token.balanceOf(swapper), 1e18);
        assertEq(oppositeQuote.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }
}
