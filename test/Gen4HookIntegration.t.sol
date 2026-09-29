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

/// @dev A deposit queue in index order; a sold-out entry leaves the queue, as in the real pool.
contract Gen4MockPool {
    MockInventoryToken public immutable token;
    IGen4Pool.QueueNode[] internal _nodes;

    constructor(MockInventoryToken token_) { token = token_; }

    /// @dev Resets the queue to one entry (none when amount_ is 0).
    function setNode(uint64 index_, uint128 amount_, uint128 pinned_) external {
        delete _nodes;
        if (amount_ != 0) _nodes.push(IGen4Pool.QueueNode(index_, address(0xA11CE), amount_, pinned_, pinned_ == 0 ? 0 : 1));
    }

    /// @dev Queues another entry behind the others.
    function addNode(uint64 index_, uint128 amount_) external {
        _nodes.push(IGen4Pool.QueueNode(index_, address(0xA11CE), amount_, 0, 0));
    }

    bool public buyBackEnabled;
    address public buybackAsset;
    function setBuyBack(bool enabled, address asset) external { buyBackEnabled = enabled; buybackAsset = asset; }

    function amount() external view returns (uint256 total) {
        for (uint256 i; i < _nodes.length; ++i) total += _nodes[i].amount;
    }

    function available() public view returns (uint256 total) {
        for (uint256 i; i < _nodes.length; ++i) total += uint256(_nodes[i].amount) - uint256(_nodes[i].pinned);
    }

    function tokenQueueEnds() external view returns (uint64 head, uint64 tail) {
        uint256 n = _nodes.length;
        for (uint256 i; i < n; ++i) {
            if (_nodes[i].amount != 0) return (_nodes[i].index, _nodes[n - 1].index);
        }
    }

    /// @dev Pins stock on entry `i` (a signed-lane hold), as a hold landing inside a transaction would.
    function pin(uint256 i, uint128 pinned_) external {
        _nodes[i].pinned = pinned_;
    }

    function queue(uint256 limit) external view returns (IGen4Pool.QueueNode[] memory nodes) {
        uint256 live;
        for (uint256 i; i < _nodes.length; ++i) if (_nodes[i].amount != 0) ++live;
        if (live > limit) live = limit;
        nodes = new IGen4Pool.QueueNode[](live);
        uint256 j;
        for (uint256 i; i < _nodes.length && j < live; ++i) if (_nodes[i].amount != 0) nodes[j++] = _nodes[i];
    }

    /// @dev Sells in queue order, as the market does; it does not see listings.
    function fill(uint256 requested, address buyer) external returns (uint256 filled) {
        for (uint256 i; i < _nodes.length && filled < requested; ++i) {
            uint256 a = uint256(_nodes[i].amount) - uint256(_nodes[i].pinned);
            uint256 take = requested - filled < a ? requested - filled : a;
            _nodes[i].amount -= uint128(take);
            filled += take;
        }
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
    function setRate(uint256 value) external { rate = value; }
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
    function setRate(uint256 value) external { rate = value; }
    uint256 public executionRate = 1e18;
    mapping(address => bool) public approvedQuoteAssets;
    mapping(address => uint256) public inventoryFloor;
    mapping(address => uint256) public minContribution;
    function setFloors(address asset, uint256 floor, uint256 minimum) external {
        inventoryFloor[asset] = floor;
        minContribution[asset] = minimum;
    }

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
    mapping(address => bool) public otherPools; // more C1 pools of the same token, registration only
    function addPool(address candidate) external { otherPools[candidate] = true; }
    function poolRecords(address candidate) external view returns (address inventoryToken, bool exists) {
        return candidate == address(pool) || otherPools[candidate] ? (address(token), true) : (address(0), false);
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
    address public reenter; // when set, called once during the next pool leg (a nested swap)
    function setReenter(address value) external { reenter = value; }
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
        if (reenter != address(0)) {
            address r = reenter;
            reenter = address(0);
            Gen4Nested(r).nested();
        }
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

interface Gen4Nested {
    function nested() external;
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

    /// @dev What beforeInitialize records when the pool of a registered pair is created.
    function openPair(address a, address b) external {
        (Currency c0, Currency c1) = _sort(Currency.wrap(a), Currency.wrap(b));
        _pairOpened[_pairKey(c0, c1)] = true;
    }

    function runExactInput(
        address pool,
        address input,
        address marketAsset,
        address output,
        uint256 quoteIn,
        address
    ) external returns (uint256 tokens, uint256 cost, uint256 refund, uint256 dust) {
        PairConfig memory cfg = PairConfig(pool, false, true, 0, marketAsset);
        Fill memory f = _buyGen4ExactInput(cfg, Currency.wrap(input), Currency.wrap(output), -int256(quoteIn));
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

    // WSR F5 (27 Sep 2026): a slice fills completely or reverts; nothing is ever handed back
    function test_ExactInputShortFillRevertsAndHandsNothingBack() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        uint256 beforeBalance = quote.balanceOf(address(manager));
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 1e18, 10e18, uint8(5)));
        hook.runExactInput(address(pool), address(quote), address(quote), address(token), 10e18, address(this));
        assertEq(quote.balanceOf(address(manager)), beforeBalance);
        assertEq(quote.balanceOf(address(hook)), 0);
        assertEq(pool.available(), 1e18, "the stock is untouched");
    }

    function test_ExactInputAtExactDepthFillsCompletely() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        uint256 beforeBalance = quote.balanceOf(address(manager));
        (uint256 tokens, uint256 cost, uint256 refund, uint256 dust) = hook.runExactInput(
            address(pool), address(quote), address(quote), address(token), 1e18, address(this)
        );
        assertEq(tokens, 1e18);
        assertEq(cost, 1e18);
        assertEq(refund, 0);
        assertEq(dust, 0);
        assertEq(quote.balanceOf(address(manager)), beforeBalance - 1e18);
        assertEq(quote.balanceOf(address(hook)), 0);
    }

    function test_ExactInputJustAboveDepthReverts() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 1e18, 1e18 + 1, uint8(5)));
        hook.runExactInput(address(pool), address(quote), address(quote), address(token), 1e18 + 1, address(this));
    }

    function test_SubUnitLeftoverIsDustAndTheFillCompletes() public {
        settlement.setRate(3e18);
        market.setRate(3e18);
        market.setExecutionRate(3e18);
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        (uint256 tokens,, uint256 refund, uint256 dust) = hook.runExactInput(
            address(pool), address(quote), address(quote), address(token), 3e18 + 2, address(this)
        );
        assertEq(tokens, 1e18);
        assertEq(refund, 0);
        assertEq(dust, 2, "two wei, less than one token unit at 3, kept as dust");
    }

    function test_BudgetBelowOneTokenUnitRevertsWithNothingFilled() public {
        settlement.setRate(3e18);
        market.setRate(3e18);
        market.setExecutionRate(3e18);
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 0, uint8(5)));
        hook.runExactInput(address(pool), address(quote), address(quote), address(token), 2, address(this));
    }

    function test_FillEndingOnTheSixteenthAttemptSucceeds() public {
        uint256 n = hook.GEN4_MAX_ATTEMPTS();
        for (uint64 i = 1; i <= n + 1; ++i) registry.push(Gen4MockRegistry.Candidate(1, i, 1e17, 1, 0));
        token.mint(address(settlement), (n + 1) * 1e17);
        (uint256 tokens,, uint256 refund,) = hook.runExactInput(
            address(pool), address(quote), address(quote), address(token), n * 1e17, address(this)
        );
        assertEq(tokens, n * 1e17, "sixteen listings, the budget spent on the last");
        assertEq(refund, 0);
        assertEq(recorder.length(), n);
    }

    function enforceMinimumOutput(uint256 minimum) external {
        (uint256 tokens,,,) = hook.runExactInput(
            address(pool), address(quote), address(quote), address(token), 1e18, address(this)
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

    function test_StaleAttemptCapRevertsAndRetainsNothing() public {
        token.mint(address(settlement), 1e18);
        registry.push(Gen4MockRegistry.Candidate(1, 7, 1e18, 1, 0));
        settlement.setAlwaysStale(true);
        uint256 beforeBalance = quote.balanceOf(address(manager));
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 5e18, uint8(7)));
        hook.runExactInput(address(pool), address(quote), address(quote), address(token), 5e18, address(this));
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
        try hook.runExactInput(address(pool), address(quote), address(quote), address(token), 5e18, address(this)) {
            revert("sixteen stale attempts must revert");
        } catch {}
        emit log_named_uint("gen4_16_stale_attempts_gas", beforeGas - gasleft());
    }

    // Failure handling (JUP-698 gate 1 finding, review F3/F5, 26 Sep 2026). A leg that reverts or runs
    // out of gas is rolled back in the callee, and the walk stops. Since WSR F5 (27 Sep 2026) exact input
    // then reverts the whole swap with ExactInputShortfall(filled, wanted, reason), filled or not.
    function test_ZeroFillPoolLegFailureRevertsNothingFilled() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        for (uint8 mode = 1; mode <= 2; ++mode) {
            market.setFailMode(mode);
            vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 10e18, uint8(3)));
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
        // the listing had sold 2e18 before the pool leg failed: the whole swap reverts
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 2e18, 10e18, uint8(3)));
        hook.runExactInput(address(pool), address(quote), address(quote), address(token), 10e18, address(this));
        assertEq(quote.balanceOf(address(manager)), managerBefore, "nothing left the manager");
        assertEq(quote.balanceOf(address(hook)), 0, "hook keeps nothing");
        assertEq(pool.amount(), 1e18, "the pool node untouched");
    }

    function test_RevertingPoolLegAfterAFillRevertsTheSwap() public {
        _listingThenFailingPool(1);
    }

    function test_OutOfGasPoolLegAfterAFillRevertsTheSwap() public {
        _listingThenFailingPool(2);
    }

    function test_RevertingListingLegAfterAFillRevertsTheSwap() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        token.mint(address(settlement), 2e18);
        registry.push(Gen4MockRegistry.Candidate(1, 2, 2e18, 1, 1)); // live listing behind node 1
        settlement.setRevertSettle(true);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 1e18, 10e18, uint8(4)));
        hook.runExactInput(address(pool), address(quote), address(quote), address(token), 10e18, address(this));
        assertEq(quote.balanceOf(address(hook)), 0);
    }

    function test_ZeroFillListingLegFailureRevertsNothingFilled() public {
        token.mint(address(settlement), 2e18);
        registry.push(Gen4MockRegistry.Candidate(1, 2, 2e18, 1, 0));
        settlement.setRevertSettle(true);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 10e18, uint8(4)));
        hook.runExactInput(address(pool), address(quote), address(quote), address(token), 10e18, address(this));
    }

    function test_FailedVenueReadRevertsWithNothingFilled() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        market.setFailMode(3);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 10e18, uint8(2)));
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
        assertEq(ret, abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 10e18, uint8(1)));
        assertEq(recorder.length(), 0, "no leg attempted");
    }

    // The price is read once per swap: a closed swap route sells nothing from either source
    function test_ClosedRouteExactInputRevertsWithItsReasonBeforeTakingInput() public {
        pool.setNode(1, 1e18, 0);
        token.mint(address(pool), 1e18);
        registry.push(Gen4MockRegistry.Candidate(1, 2, 2e18, 1, 1));
        settlement.setClosed(true);
        uint256 managerBefore = quote.balanceOf(address(manager));
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 0, uint8(6)));
        hook.runExactInput(address(pool), address(quote), address(quote), address(token), 10e18, address(this));
        assertEq(quote.balanceOf(address(manager)), managerBefore);
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

    // ---- Design E: two ETH Uniswap pools on one C1 pool (29 Sep 2026) ----
    // Foundry runs a test function as one transaction, so two runs below are two pools hit in the same
    // transaction, the case a router split across both pools creates. Native is the main door (80%).

    function _twoEthPools(uint128 stock, uint256 floor) internal {
        pool.setNode(1, stock, 0);
        token.mint(address(pool), stock);
        hook.registerPair(Currency.wrap(address(0)), Currency.wrap(address(token)), address(pool), 0);
        hook.registerPair(Currency.wrap(address(weth)), Currency.wrap(address(token)), address(pool), 0);
        hook.openPair(address(0), address(token));
        hook.openPair(address(weth), address(token));
        market.setFloors(address(weth), floor, 0); // K = floor tokens at rate 1
        vm.deal(address(this), 4_000e18);
        weth.deposit{value: 4_000e18}();
        weth.transfer(address(manager), 4_000e18);
    }

    function _buyNative(uint256 amount) internal returns (uint256 tokens) {
        (tokens,,,) = hook.runExactInput(address(pool), address(0), address(weth), address(token), amount, address(this));
    }

    function _buyWrapped(uint256 amount) internal returns (uint256 tokens) {
        (tokens,,,) = hook.runExactInput(address(pool), address(weth), address(weth), address(token), amount, address(this));
    }

    function _shortfall(uint256 filled, uint256 wanted) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, filled, wanted, uint8(5));
    }

    function test_E_BothDoorsFillTheirBudgetsInOneTransaction_MainFirst() public {
        _twoEthPools(1_000e18, 0);
        assertEq(_buyNative(800e18), 800e18, "main door: 80% of deposits");
        assertEq(_buyWrapped(200e18), 200e18, "second door: 20%, same transaction");
        assertEq(pool.available(), 0);
    }

    function test_E_BothDoorsFillTheirBudgetsInOneTransaction_SecondFirst() public {
        _twoEthPools(1_000e18, 0);
        assertEq(_buyWrapped(200e18), 200e18);
        assertEq(_buyNative(800e18), 800e18);
    }

    function test_E_SecondDoorOverItsBudgetRevertsAndSellsNothing() public {
        _twoEthPools(1_000e18, 0);
        vm.expectRevert(_shortfall(200e18, 201e18));
        _buyWrapped(201e18);
        assertEq(pool.available(), 1_000e18, "nothing sold");
        assertEq(_buyNative(800e18), 800e18, "the main door's budget is untouched");
    }

    // K = 14: deposits 1,000 -> shareable 986, second = 197.2 - 14 = 183.2, main = 802.8; 14 stay in the pool
    function test_E_OneFloorStaysInThePoolWhileSharing() public {
        _twoEthPools(1_000e18, 14e18);
        assertEq(_buyNative(802.8e18), 802.8e18);
        assertEq(_buyWrapped(183.2e18), 183.2e18);
        assertEq(pool.available(), 14e18, "K left for the next transaction");
        vm.expectRevert(_shortfall(0, 1e18));
        _buyWrapped(1e18);
    }

    // deposits 60, K 14 -> second = 9.2 - 14 < 0 -> sharing off: main uncapped, second sells nothing
    function test_E_SharingSwitchesOffBelowAboutSixFloors() public {
        _twoEthPools(60e18, 14e18);
        vm.expectRevert(_shortfall(0, 1e18));
        _buyWrapped(1e18);
        assertEq(_buyNative(60e18), 60e18, "main door sells everything");
    }

    function test_E_MainDoorManySlicesStayInItsBudget() public {
        _twoEthPools(1_000e18, 0);
        assertEq(_buyNative(500e18), 500e18);
        assertEq(_buyNative(300e18), 300e18);
        vm.expectRevert(_shortfall(0, 1e18));
        _buyNative(1e18);
    }

    function test_E_NoCapUntilTheSiblingPoolIsOpened() public {
        pool.setNode(1, 1_000e18, 0);
        token.mint(address(pool), 1_000e18);
        hook.registerPair(Currency.wrap(address(0)), Currency.wrap(address(token)), address(pool), 0);
        hook.registerPair(Currency.wrap(address(weth)), Currency.wrap(address(token)), address(pool), 0);
        hook.openPair(address(0), address(token)); // the aeWETH pool was never created
        assertEq(_buyNative(1_000e18), 1_000e18);
    }

    function test_E_SiblingBelowTheSpreadFloorDoesNotCount() public {
        _twoEthPools(1_000e18, 0);
        hook.setBaseSpreadFloor(1); // both registered at spread 0: the sibling cannot trade
        assertEq(_buyNative(1_000e18), 1_000e18);
    }

    function test_E_UnregisteringTheSiblingRemovesTheCap() public {
        _twoEthPools(1_000e18, 0);
        hook.unregisterPair(Currency.wrap(address(weth)), Currency.wrap(address(token)));
        assertEq(_buyNative(1_000e18), 1_000e18);
    }

    function test_E_NativeOnlyAtTenThousand() public {
        _twoEthPools(1_000e18, 0);
        hook.setNativeShare(address(pool), 10_000);
        vm.expectRevert(_shortfall(0, 1e18));
        _buyWrapped(1e18);
        assertEq(_buyNative(1_000e18), 1_000e18);
    }

    function test_E_AeWETHIsTheMainDoorBelowFiveThousand() public {
        _twoEthPools(1_000e18, 0);
        hook.setNativeShare(address(pool), 2_000);
        vm.expectRevert(_shortfall(200e18, 201e18));
        _buyNative(201e18);
        assertEq(_buyWrapped(800e18), 800e18);
        assertEq(_buyNative(200e18), 200e18);
    }

    function test_E_NonEthPoolIsNeverCapped() public {
        _twoEthPools(1_000e18, 0);
        (uint256 tokens,,,) = hook.runExactInput(address(pool), address(quote), address(quote), address(token), 1_000e18, address(this));
        assertEq(tokens, 1_000e18);
    }

    // listings are sold only through the main door: deposits 200 (K 0: second 40, main 160) + a listing of 800
    function test_E_MainDoorSellsListingsUncapped() public {
        _twoEthPools(200e18, 0);
        token.mint(address(settlement), 800e18);
        registry.push(Gen4MockRegistry.Candidate(1, 1, 800e18, 1, 0)); // older than the pool node
        assertEq(_buyNative(960e18), 960e18, "800 listed + 160 deposits");
        assertEq(_buyWrapped(40e18), 40e18);
    }

    function test_E_SecondDoorNeverTouchesListings() public {
        _twoEthPools(1_000e18, 0);
        token.mint(address(settlement), 500e18);
        registry.push(Gen4MockRegistry.Candidate(1, 1, 500e18, 1, 0)); // older than the pool node
        assertEq(_buyWrapped(100e18), 100e18);
        assertEq(recorder.length(), 1);
        assertEq(recorder.step(0), 200, "one pool leg, no listing leg");
        assertEq(registry.cursor(), 0, "the listing is untouched");
    }

    function test_E_ExactOutputFollowsTheSameBudgets() public {
        _twoEthPools(1_000e18, 0);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.Gen4FillShortfall.selector, 200e18, 201e18));
        hook.runExactOutput(address(pool), address(weth), address(weth), address(token), 201e18, address(this));
        (uint256 tokens,,) = hook.runExactOutput(address(pool), address(weth), address(weth), address(token), 200e18, address(this));
        assertEq(tokens, 200e18);
        (tokens,,) = hook.runExactOutput(address(pool), address(0), address(weth), address(token), 800e18, address(this));
        assertEq(tokens, 800e18);
    }

    // a swap nested inside the main door's pool leg sees that leg's planned sale
    uint256 internal nestedAmount;
    uint256 internal nestedRuns;
    bool internal nestedFilled;
    function nested() external {
        ++nestedRuns;
        try hook.runExactInput(address(pool), address(0), address(weth), address(token), nestedAmount, address(this)) returns (
            uint256 tokens, uint256, uint256, uint256
        ) {
            nestedFilled = tokens == nestedAmount;
        } catch {
            nestedFilled = false;
        }
    }

    function test_E_NestedSwapDuringAPoolLegSeesThePlannedSale() public {
        _twoEthPools(1_000e18, 0);
        // main door budget 800; the outer leg plans 500 before it runs, so a nested 301 does not fit
        nestedAmount = 301e18;
        market.setReenter(address(this));
        assertEq(_buyNative(500e18), 500e18);
        assertEq(nestedRuns, 1, "the nested swap ran");
        assertFalse(nestedFilled, "a nested 301 would take the main door past 800");
        // outer 1 planned (501 recorded): a nested 299 fits exactly
        nestedAmount = 299e18;
        market.setReenter(address(this));
        assertEq(_buyNative(1e18), 1e18);
        assertEq(nestedRuns, 2);
        assertTrue(nestedFilled, "299 fits beside the planned 501");
        vm.expectRevert(_shortfall(0, 1e18));
        _buyNative(1e18); // 500 + 1 + 299 = 800: the main door is full
    }

    function test_E_NativeShareSetterBoundsAndOwner() public {
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.InvalidShare.selector, uint16(10_001)));
        hook.setNativeShare(address(pool), 10_001);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        hook.setNativeShare(address(pool), 5_000);
        hook.setNativeShare(address(pool), 10_000);
        assertEq(hook.nativeShareBps(address(pool)), 10_000);
    }

    // ---- Robin pass 65: the second door's sale must not push the main door past its own quote ----
    // Queue: a deposit of 188 (entry 1), 17 listings of 20 queued after it, a deposit of 812 (entry 2).
    // K = 10 -> shareable 990, second door 198 - 10 = 188, main door 802.
    function _robin65Queue() internal {
        _twoEthPools(188e18, 10e18);
        pool.addNode(2, 812e18);
        token.mint(address(pool), 812e18);
        token.mint(address(settlement), 340e18);
        for (uint64 id = 1; id <= 17; ++id) registry.push(Gen4MockRegistry.Candidate(1, id, 20e18, 1, 1));
    }

    function _mainExactOutput(uint256 target) internal returns (uint256 tokens) {
        (tokens,,) = hook.runExactOutput(address(pool), address(0), address(weth), address(token), target, address(this));
    }

    /// @dev Steps recorded from entry `from` on: 200 = a pool leg, 100 + id = a listing.
    function _assertSteps(uint256 from, uint256[] memory expected) internal view {
        assertEq(recorder.length() - from, expected.length, "number of steps");
        for (uint256 i; i < expected.length; ++i) assertEq(recorder.step(from + i), expected[i]);
    }

    function _robin65MainSteps() internal pure returns (uint256[] memory s) {
        s = new uint256[](9);
        s[0] = 200; // 188 of deposits
        for (uint256 i = 1; i < 9; ++i) s[i] = 100 + i; // listings 1 to 8 (the 8th sells 12 of 20)
    }

    function test_E_Robin65_MainQuoteAloneTakesNineSteps() public {
        _robin65Queue();
        assertEq(_mainExactOutput(340e18), 340e18);
        _assertSteps(0, _robin65MainSteps());
    }

    function test_E_Robin65_SecondDoorFirstLeavesTheMainDoorItsQuotedSteps() public {
        _robin65Queue();
        assertEq(_buyWrapped(188e18), 188e18, "second door: the first deposit");
        uint256 from = recorder.length();
        assertEq(_mainExactOutput(340e18), 340e18, "main door: 9 steps, not 17");
        _assertSteps(from, _robin65MainSteps());
        assertEq(pool.available(), 624e18, "188 + 188 of deposits sold");
        assertEq(registry.cursor(), 8, "listings 1 to 8 sold");
    }

    function test_E_Robin65_MainDoorFirstSellsTheSameStock() public {
        _robin65Queue();
        assertEq(_mainExactOutput(340e18), 340e18);
        assertEq(_buyWrapped(188e18), 188e18);
        assertEq(pool.available(), 624e18, "the same deposits as the other order");
        assertEq(registry.cursor(), 8, "the same listings as the other order");
    }

    function test_E_Robin65_ExactInputSecondDoorFirst() public {
        _robin65Queue();
        assertEq(_buyWrapped(188e18), 188e18);
        uint256 from = recorder.length();
        assertEq(_buyNative(340e18), 340e18);
        _assertSteps(from, _robin65MainSteps());
        assertEq(pool.available(), 624e18);
        assertEq(registry.cursor(), 8);
    }

    // Deposits between listings: entry 1 = 100, listing 1 (10), entry 2 = 100, listings 2 to 20 (10 each),
    // entry 3 = 1,000; K = 0 -> second door 240, main door 960. The main door's view must remember how
    // far along the queue each listing sits: a plain "second door sold 100" credit would be spent on
    // entry 2, which the main door reaches anyway, and leave it more listings than its quote.
    function _betweenQueue() internal {
        _twoEthPools(100e18, 0);
        pool.addNode(2, 100e18);
        pool.addNode(3, 1_000e18);
        token.mint(address(pool), 1_100e18);
        token.mint(address(settlement), 200e18);
        registry.push(Gen4MockRegistry.Candidate(1, 1, 10e18, 1, 1));
        for (uint64 id = 2; id <= 20; ++id) registry.push(Gen4MockRegistry.Candidate(1, id, 10e18, 1, 2));
    }

    function _betweenMainSteps() internal pure returns (uint256[] memory s) {
        s = new uint256[](6);
        (s[0], s[1], s[2], s[3], s[4], s[5]) = (200, 101, 200, 102, 103, 104);
    }

    function test_E_DepositsBetweenListings_SecondDoorFirst() public {
        _betweenQueue();
        assertEq(_buyWrapped(100e18), 100e18);
        uint256 from = recorder.length();
        assertEq(_mainExactOutput(240e18), 240e18);
        _assertSteps(from, _betweenMainSteps());
        assertEq(pool.available(), 900e18);
        assertEq(registry.cursor(), 4);
    }

    function test_E_DepositsBetweenListings_MainDoorFirst() public {
        _betweenQueue();
        assertEq(_mainExactOutput(240e18), 240e18);
        _assertSteps(0, _betweenMainSteps());
        assertEq(_buyWrapped(100e18), 100e18);
        assertEq(pool.available(), 900e18, "the same deposits as the other order");
        assertEq(registry.cursor(), 4, "the same listings as the other order");
    }

    // Robin pass 66: only the second door's sales count. Entry 1 = 100, a listing of 10 queued after it,
    // entry 2 = 900; K = 0 -> second door 200, main door 800.
    function _oneListingQueue() internal {
        _twoEthPools(100e18, 0);
        pool.addNode(2, 900e18);
        token.mint(address(pool), 900e18);
        token.mint(address(settlement), 10e18);
        registry.push(Gen4MockRegistry.Candidate(1, 1, 10e18, 1, 1));
    }

    // a USDG slice takes entry 1 after the note: the main door may pass the listing by the second
    // door's 1 token only, then the listing sells in its turn
    function test_E_AnotherPoolsSaleDoesNotLetTheMainDoorPassAListing() public {
        _oneListingQueue();
        assertEq(_buyWrapped(1e18), 1e18, "second door: 1 from entry 1 (the note is taken)");
        (uint256 usdg,,,) = hook.runExactInput(address(pool), address(quote), address(quote), address(token), 99e18, address(this));
        assertEq(usdg, 99e18, "the USDG pool takes the rest of entry 1");
        uint256 from = recorder.length();
        assertEq(_mainExactOutput(20e18), 20e18);
        uint256[] memory s = new uint256[](3);
        (s[0], s[1], s[2]) = (200, 101, 200); // 1 of deposits, the listing, then 9 of deposits
        _assertSteps(from, s);
        assertEq(registry.cursor(), 1, "the listing sold");
    }

    // a hold pins the rest of entry 1 after the main door's first slice: with no second-door sale, the
    // main door's next slice must sell the listing before any later deposit
    function test_E_APinDoesNotLetTheMainDoorPassAListing() public {
        _oneListingQueue();
        assertEq(_mainExactOutput(1e18), 1e18, "main door: 1 from entry 1 (the note is taken)");
        pool.pin(0, 99e18);
        uint256 from = recorder.length();
        assertEq(_mainExactOutput(20e18), 20e18);
        uint256[] memory s = new uint256[](2);
        (s[0], s[1]) = (101, 200); // the listing first, then entry 2
        _assertSteps(from, s);
    }

    // Robin pass 67: the credit used at a listing position is kept per position. Entry 1 = 100, entry
    // 2 = 100, entry 3 = 800; listings X (after entry 1), Y (after entry 2), then Z back at X's position
    // (a listing position the walk returns to). The second door sells 1, a USDG slice the rest of entry
    // 1, and a hold pins entry 2: the main door has 1 of credit at each position, once.
    function test_E_CreditUsedAtAPositionIsNotResetByAnother() public {
        _twoEthPools(100e18, 0);
        pool.addNode(2, 100e18);
        pool.addNode(3, 800e18);
        token.mint(address(pool), 900e18);
        token.mint(address(settlement), 30e18);
        registry.push(Gen4MockRegistry.Candidate(1, 1, 10e18, 1, 1));
        registry.push(Gen4MockRegistry.Candidate(1, 2, 10e18, 1, 2));
        registry.push(Gen4MockRegistry.Candidate(1, 3, 10e18, 1, 1));
        assertEq(_buyWrapped(1e18), 1e18);
        (uint256 usdg,,,) = hook.runExactInput(address(pool), address(quote), address(quote), address(token), 99e18, address(this));
        assertEq(usdg, 99e18);
        pool.pin(1, 100e18);
        uint256 from = recorder.length();
        assertEq(_mainExactOutput(32e18), 32e18);
        uint256[] memory s = new uint256[](5);
        (s[0], s[1], s[2], s[3], s[4]) = (200, 101, 200, 102, 103); // Z sells without a third credit
        _assertSteps(from, s);
    }

    // Robin pass 67: a swap nested inside a credited leg sees that leg's credit as used. After the
    // second door sells 1 and a USDG slice the rest of entry 1, the main door's 1 of credit is taken
    // by the outer leg, so the nested main-door swap sells the listing instead of a second credit.
    function test_E_NestedSwapDuringACreditedLegSeesTheCreditUsed() public {
        _oneListingQueue();
        assertEq(_buyWrapped(1e18), 1e18);
        (uint256 usdg,,,) = hook.runExactInput(address(pool), address(quote), address(quote), address(token), 99e18, address(this));
        assertEq(usdg, 99e18);
        nestedAmount = 1e18;
        market.setReenter(address(this));
        uint256 from = recorder.length();
        assertEq(_buyNative(1e18), 1e18);
        assertEq(nestedRuns, 1, "the nested swap ran");
        assertTrue(nestedFilled);
        assertEq(recorder.step(from), 200, "outer: the credited leg");
        assertEq(recorder.step(from + 1), 101, "nested: the listing, not a second credited leg");
    }

    // Robin pass 65: an owner call between two swaps of one transaction cannot lift a cap or swap roles
    function test_E_SpreadFloorRaisedMidTransactionKeepsTheCap() public {
        _twoEthPools(1_000e18, 10e18); // second 188, main 802
        assertEq(_buyWrapped(188e18), 188e18);
        hook.setBaseSpreadFloor(1); // the sibling now sits below the floor
        vm.expectRevert(_shortfall(802e18, 803e18));
        _buyNative(803e18);
        assertEq(_buyNative(802e18), 802e18);
        assertEq(pool.available(), 10e18, "K stays");
    }

    function test_E_UnregisteringMidTransactionKeepsTheCap() public {
        _twoEthPools(1_000e18, 10e18);
        assertEq(_buyWrapped(188e18), 188e18);
        hook.unregisterPair(Currency.wrap(address(weth)), Currency.wrap(address(token)));
        vm.expectRevert(_shortfall(802e18, 803e18));
        _buyNative(803e18);
        assertEq(_buyNative(802e18), 802e18);
    }

    function test_E_ShareChangeMidTransactionKeepsTheRoles() public {
        _twoEthPools(1_000e18, 10e18);
        assertEq(_buyNative(802e18), 802e18);
        hook.setNativeShare(address(pool), 2_000); // would make aeWETH the main door
        assertEq(_buyWrapped(188e18), 188e18);
        vm.expectRevert(_shortfall(0, 1e18));
        _buyWrapped(1e18);
        assertEq(pool.available(), 10e18, "K stays");
    }

    function test_E_EthPoolsOnDifferentC1PoolsAreNotShared() public {
        Gen4MockPool other = new Gen4MockPool(token);
        market.addPool(address(other));
        pool.setNode(1, 1_000e18, 0);
        token.mint(address(pool), 1_000e18);
        hook.registerPair(Currency.wrap(address(0)), Currency.wrap(address(token)), address(pool), 0);
        hook.registerPair(Currency.wrap(address(weth)), Currency.wrap(address(token)), address(other), 0);
        hook.openPair(address(0), address(token));
        hook.openPair(address(weth), address(token));
        assertEq(_buyNative(1_000e18), 1_000e18, "no share cap across two C1 pools");
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

    // WSR F5 pass (27 Sep 2026): one V4 pool per registered pair. A second pool of the same pair at any
    // other tick spacing would sell the same stock and let a route count it twice.
    function test_OnlyTheCanonicalTickSpacingCanBeInitialised() public {
        PoolKey memory second = PoolKey({
            currency0: key.currency0, currency1: key.currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        bytes memory inner = abi.encodeWithSelector(FlowstateC1Hook.TickSpacingNotCanonical.selector, int24(10));
        try manager.initialize(second, uint160(1 << 96)) {
            revert("a second pool of a registered pair must not initialise");
        } catch (bytes memory ret) {
            assertTrue(_contains(ret, inner), "the hook refused it for its tick spacing");
        }
        assertEq(hook.CANONICAL_TICK_SPACING(), key.tickSpacing, "the live pool uses the canonical spacing");
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool hit = true;
            for (uint256 j; j < needle.length; ++j) if (hay[i + j] != needle[j]) { hit = false; break; }
            if (hit) return true;
        }
        return false;
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
