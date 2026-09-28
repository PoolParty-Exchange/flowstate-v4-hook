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

contract FlowstateC1HookGen3Harness is FlowstateC1Hook {
    constructor(address manager, address market, address owner, address weth)
        FlowstateC1Hook(manager, market, owner, weth, address(0xBEEF), 0, address(0), address(0))
    {}

    function runGen3ExactInput(address pool, address input, address output, uint256 quoteIn)
        external
        returns (uint256 tokens, uint256 dust)
    {
        Fill memory f = _buyExactInput(PairConfig(pool, false, true, 0, input), Currency.wrap(input), Currency.wrap(output), -int256(quoteIn));
        return (f.tokensOut, f.dustAccrued);
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

    // ---- Two ETH pairs on one stock (two-door shares, 28 Sep 2026) ----
    // Foundry runs a test function as one transaction, so two runs below are two pairs hit in the same
    // transaction, the case a router split across both pairs creates.

    function _twoEthPairs(uint128 stock) internal {
        pool.setNode(1, stock, 0);
        token.mint(address(pool), stock);
        hook.registerPair(Currency.wrap(address(0)), Currency.wrap(address(token)), address(pool), 0);
        hook.registerPair(Currency.wrap(address(weth)), Currency.wrap(address(token)), address(pool), 0);
        vm.deal(address(this), 2_000e18);
        weth.deposit{value: 2_000e18}();
        weth.transfer(address(manager), 2_000e18);
    }

    function _buyNative(uint256 amount) internal returns (uint256 tokens) {
        (tokens,,,) = hook.runExactInput(address(pool), address(0), address(weth), address(token), amount, address(this));
    }

    function _buyWrapped(uint256 amount) internal returns (uint256 tokens) {
        (tokens,,,) = hook.runExactInput(address(pool), address(weth), address(weth), address(token), amount, address(this));
    }

    function test_TwoEthPairsSellTheWholeStockBetweenThem_NativeFirst() public {
        _twoEthPairs(1_000e18);
        assertEq(_buyNative(800e18), 800e18, "native pair: its 80%");
        assertEq(_buyWrapped(200e18), 200e18, "aeWETH pair: the other 20%, in the same transaction");
        assertEq(pool.available(), 0);
    }

    function test_TwoEthPairsSellTheWholeStockBetweenThem_WrappedFirst() public {
        _twoEthPairs(1_000e18);
        assertEq(_buyWrapped(200e18), 200e18);
        assertEq(_buyNative(800e18), 800e18);
        assertEq(pool.available(), 0);
    }

    function test_SliceAbovePairShareRevertsBeforeSellingAnything() public {
        _twoEthPairs(1_000e18);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 801e18, uint8(8)));
        _buyNative(801e18);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 201e18, uint8(8)));
        _buyWrapped(201e18);
        assertEq(pool.available(), 1_000e18, "nothing sold");
        assertEq(recorder.length(), 0, "no leg was called");
    }

    // the fade this prevents: 600 + 600 on a 1,000 stock. With shares the second slice is refused up front
    // (a quote shows it), instead of coming up short mid-route.
    function test_SplitAcrossBothPairsAboveStockIsRefusedByShareNotStock() public {
        _twoEthPairs(1_000e18);
        hook.setNativeShare(address(pool), 6_000);
        assertEq(_buyNative(600e18), 600e18);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 600e18, uint8(8)));
        _buyWrapped(600e18);
        assertEq(_buyWrapped(400e18), 400e18, "the aeWETH pair's own 40% is still there");
    }

    function test_OnePairHitTwiceCountsBothSlices() public {
        _twoEthPairs(1_000e18);
        assertEq(_buyNative(500e18), 500e18);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 301e18, uint8(8)));
        _buyNative(301e18);
        assertEq(_buyNative(300e18), 300e18);
    }

    function test_OnlyOneEthPairRegisteredSellsTheWholeStock() public {
        pool.setNode(1, 1_000e18, 0);
        token.mint(address(pool), 1_000e18);
        hook.registerPair(Currency.wrap(address(0)), Currency.wrap(address(token)), address(pool), 0);
        assertEq(_buyNative(1_000e18), 1_000e18);
    }

    function test_UnregisteringTheSiblingRestoresTheWholeStock() public {
        _twoEthPairs(1_000e18);
        hook.unregisterPair(Currency.wrap(address(weth)), Currency.wrap(address(token)));
        assertEq(_buyNative(1_000e18), 1_000e18);
    }

    function test_NonEthPairIsNeverCapped() public {
        _twoEthPairs(1_000e18);
        (uint256 tokens,,,) = hook.runExactInput(address(pool), address(quote), address(quote), address(token), 1_000e18, address(this));
        assertEq(tokens, 1_000e18);
    }

    function test_StrandComesOffTheSmallerShareOnly() public {
        _twoEthPairs(1_000e18);
        // strand = floor 30 + 1.25 x max(floor 30, minimum 40) = 80 tokens at rate 1, off the aeWETH pair (20%)
        market.setFloors(address(weth), 30e18, 40e18);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 121e18, uint8(8)));
        _buyWrapped(121e18);
        assertEq(_buyWrapped(120e18), 120e18, "aeWETH: 200 less the 80 strand");
        assertEq(_buyNative(800e18), 800e18, "native keeps its full 80%");
    }

    function test_StrandMovesToWhicheverPairHasTheSmallerShare() public {
        _twoEthPairs(1_000e18);
        market.setFloors(address(weth), 30e18, 40e18);
        hook.setNativeShare(address(pool), 3_000);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 221e18, uint8(8)));
        _buyNative(221e18);
        assertEq(_buyNative(220e18), 220e18, "native now the smaller pair: 300 less 80");
        assertEq(_buyWrapped(700e18), 700e18, "aeWETH keeps its full 70%");
    }

    function test_StrandLargerThanTheSmallShareSpillsOntoTheBigShare() public {
        _twoEthPairs(1_000e18);
        market.setFloors(address(weth), 100e18, 100e18); // strand 225 > the aeWETH pair's 200
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 1e18, uint8(8)));
        _buyWrapped(1e18);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 776e18, uint8(8)));
        _buyNative(776e18);
        assertEq(_buyNative(775e18), 775e18, "800 less the 25 of strand the aeWETH pair could not carry");
    }

    // Robin pass 63 #2: stock 100, floor = minimum = 40 -> strand 90. Before the fix the native pair kept 80
    // and could strand the pool below its floor across two of its own slices (65 + 15).
    function test_RepeatedSlicesOfOnePairStayOutsideTheStrand() public {
        _twoEthPairs(100e18);
        market.setFloors(address(weth), 40e18, 40e18);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 11e18, uint8(8)));
        _buyNative(11e18);
        assertEq(_buyNative(6e18), 6e18);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 0, 5e18, uint8(8)));
        _buyNative(5e18);
        assertEq(_buyNative(4e18), 4e18, "the pairs together never pass stock 100 less strand 90");
    }

    // Robin pass 63 #1: the Gen-3 exact-input path accepted a short fill whose leftover is exactly one token's price
    function test_Gen3ShortFillByOneTokenReverts() public {
        bytes memory args = abi.encode(address(manager), address(market), address(this), address(weth));
        (, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(FlowstateC1HookGen3Harness).creationCode, args);
        FlowstateC1HookGen3Harness g3 =
            new FlowstateC1HookGen3Harness{salt: salt}(address(manager), address(market), address(this), address(weth));
        g3.registerPair(Currency.wrap(address(quote)), Currency.wrap(address(token)), address(pool), 0);
        // raw units at one quote-wei per token-wei: 99 wei of stock, a 100 wei budget, 1 wei left = one token-wei's price
        pool.setNode(1, 99, 0);
        token.mint(address(pool), 99);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 99, 100, uint8(5)));
        g3.runGen3ExactInput(address(pool), address(quote), address(token), 100);
        (uint256 tokens, uint256 dust) = g3.runGen3ExactInput(address(pool), address(quote), address(token), 99);
        assertEq(tokens, 99, "a complete fill still passes");
        assertEq(dust, 0);
    }

    function test_HeadListingCountsInTheNote() public {
        _twoEthPairs(500e18);
        token.mint(address(settlement), 500e18);
        registry.push(Gen4MockRegistry.Candidate(1, 1, 500e18, 1, 1));
        hook.setNativeShare(address(pool), 5_000);
        // without the listing the note would be 500 and each pair could sell only 250
        assertEq(_buyNative(500e18), 500e18, "note = pool 500 + listing 500; native 50% takes the pool");
        assertEq(_buyWrapped(500e18), 500e18, "aeWETH 50% takes the listing");
    }

    function test_ExactOutputAbovePairShareReverts() public {
        _twoEthPairs(1_000e18);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.Gen4FillShortfall.selector, 0, 801e18));
        hook.runExactOutput(address(pool), address(0), address(weth), address(token), 801e18, address(this));
        (uint256 tokens,,) = hook.runExactOutput(address(pool), address(0), address(weth), address(token), 800e18, address(this));
        assertEq(tokens, 800e18);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.Gen4FillShortfall.selector, 0, 201e18));
        hook.runExactOutput(address(pool), address(weth), address(weth), address(token), 201e18, address(this));
    }

    function test_NativeShareSetterBoundsAndOwner() public {
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.InvalidShare.selector, uint16(10_000)));
        hook.setNativeShare(address(pool), 10_000);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        hook.setNativeShare(address(pool), 5_000);
        hook.setNativeShare(address(pool), 1);
        assertEq(hook.nativeShareBps(address(pool)), 1);
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
