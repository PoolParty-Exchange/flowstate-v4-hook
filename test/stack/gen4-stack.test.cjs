/* JUP-698 gate 1: the Gen-4 hook against the EXACT pinned PoolParty_Contracts stack.
 *
 * Runs from a checkout of PoolParty_Contracts at the pinned commit (PR #54 head de4464f, which
 * carries PR #56's tokenQueueEnds) with its own hardhat.test.config.js, so the market, the pool
 * (libraries linked), C1ListingRegistry and C1ListingSettlement are the real contracts. The hook,
 * Uniswap's PoolManager and PoolSwapTest are this repo's Foundry build (`forge build`), loaded as
 * artifacts: nothing is mocked on the Flowstate side. See test/stack/README.md for the commands.
 */
const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const { ethers, network } = require(path.resolve(process.cwd(), "node_modules/hardhat"));
const H = require(path.resolve(process.cwd(), "test/unit/flowstate/helpers"));
const S = require(path.resolve(process.cwd(), "test/unit/flowstate/signedHelpers"));
const { deployListings } = require(path.resolve(process.cwd(), "deploy/lib/listings"));

const PINNED = "de4464fb79e67d09212944f00ee64c9fae772bab";
const OUT = process.env.HOOK_OUT || path.resolve(__dirname, "../../out");
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const CREATE2 = "0x4e59b44847b379578588920ca78fbf26c0b4956c"; // the canonical deterministic deployer
const CREATE2_RUNTIME = "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
const HOOK_FLAGS = 0x28ccn; // beforeInitialize | beforeAddLiquidity | beforeSwap | afterSwap | beforeSwapReturnsDelta | afterSwapReturnsDelta
const MIN_SQRT = 4295128739n + 1n;
const MAX_SQRT = 1461446703485210103287273052203988822378723970342n - 1n;
const MAX160 = (1n << 160n) - 1n;
const ZERO_PERMIT = { details: { token: ethers.ZeroAddress, amount: 0n, expiration: 0n, nonce: 0n }, spender: ethers.ZeroAddress, sigDeadline: 0n };
const GAS = { gasLimit: 29_000_000 };
const { TOK } = S;

function artifact(file, name) {
  const a = JSON.parse(fs.readFileSync(path.join(OUT, file, name + ".json"), "utf8"));
  return { abi: a.abi, bytecode: a.bytecode.object };
}

/** Review F2: a flat venue like registerFlatVenue's, but at tick spacing 10 (the registrar's
 *  minimum) with `positions` one-wei positions (2 initialized ticks each) inside the walk window,
 *  which every venue evaluation (maxBuy, price, the pool's own buy) walks tick by tick. */
async function dustyVenue(fx, pool, positions) {
  const Q192 = 1n << 192n, RATE = H.RATE ?? 2_000_000n;
  const isqrt = (n) => { if (n < 2n) return n; let x = 1n << BigInt(Math.ceil(n.toString(2).length / 2)); for (;;) { const y = (x + n / x) >> 1n; if (y >= x) break; x = y; } while (x * x > n) x--; while ((x + 1n) * (x + 1n) <= n) x++; return x; };
  const tokenAddr = await pool.inventoryToken();
  const srcIsToken0 = BigInt(tokenAddr) < BigInt(fx.usdc.target);
  const [t0, t1] = srcIsToken0 ? [tokenAddr, fx.usdc.target] : [fx.usdc.target, tokenAddr];
  const venue = await (await ethers.getContractFactory("MockV3VenueRing")).deploy(t0, t1, 10);
  await venue.increaseObservationCardinalityNext(3600);
  let sq;
  if (srcIsToken0) sq = isqrt((RATE * Q192) / 10n ** 18n);
  else { sq = isqrt((Q192 * 10n ** 18n) / RATE); if (sq * sq < (Q192 * 10n ** 18n) / RATE) sq += 1n; }
  const price = Number(RATE) / 1e18;
  const slotTick = Math.floor(Math.log(srcIsToken0 ? price : 1 / price) / Math.log(1.0001));
  const ringTick = srcIsToken0 ? slotTick : slotTick + 1;
  await venue.setSqrtPrice(sq, ringTick);
  const L = 10n ** 19n;
  await venue.setLiquidity(L);
  const now = (await ethers.provider.getBlock("latest")).timestamp;
  await venue.pushObservation(now - 2100, ringTick, L);
  await venue.pushObservation(now - 1000, ringTick, L);
  await venue.pushObservation(now - 1, ringTick, L);
  const sp = 10, t = ringTick, base = Math.floor(t / sp) * sp, ticks = [];
  for (let i = 1; ticks.length < 2 * positions; i++) ticks.push(srcIsToken0 ? base + i * sp : base - (i - 1) * sp - (t % sp === 0 ? sp : 0));
  for (let k = 0; k < positions; k++) {
    const a = ticks[2 * k], b = ticks[2 * k + 1];
    await venue.setTickLiquidity(Math.min(a, b), 1);
    await venue.setTickLiquidity(Math.max(a, b), -1);
  }
  await fx.market.connect(fx.signers.admin).setRegistrarParams(25_000n * 10n ** 6n, 20_000n * 10n ** 6n, 723, ethers.ZeroAddress);
  if ((await fx.market.quoteReference(fx.usdc.target)) === ethers.ZeroAddress) await fx.market.connect(fx.signers.admin).setQuoteReference(fx.usdc.target, fx.usdc.target);
  await fx.market.connect(fx.signers.admin).registerVenue(pool.target, venue.target);
  return venue;
}

describe(`JUP-698 gate 1: Gen-4 hook on the pinned stack (PoolParty_Contracts ${PINNED.slice(0, 7)})`, function () {
  this.timeout(600_000);

  /** The real stack: market, pool with its seed node, a flat venue, the lane open, listings.
   *  opts: dustTicks (review F2 venue), jarBps (the hook's jar fee, default the production 8),
   *  managerReserve (USDC the PoolManager holds from other pools, default $1M). */
  async function stack(opts = {}) {
    const fx = await S.deploySignedFixture();
    const { admin, timelock48, buyerEOA } = fx.signers;
    await network.provider.send("hardhat_setCode", [PERMIT2, fs.readFileSync(path.resolve(process.cwd(), "test/fixtures/permit2-rh-runtime.hex"), "utf8").trim()]);
    const permit2 = new ethers.Contract(PERMIT2, ["function approve(address token, address spender, uint160 amount, uint48 expiration)"], ethers.provider);
    const pool = opts.dustTicks
      ? await H.createDefaultPool(fx, TOK(100), 0, [fx.usdc], { venue: false })
      : await H.createDefaultPool(fx, TOK(100)); // node 1: alice's seed; flat USDC venue at RATE; lane opened by the timelock
    if (opts.dustTicks) await dustyVenue(fx, pool, opts.dustTicks);
    await fx.market.connect(admin).setMinContribution(fx.usdc.target, 100_000_000n); // $100 = 50 tokens at RATE
    const { settlement, registry } = await deployListings(ethers, fx.market.target, PERMIT2, false);
    const far = BigInt((await ethers.provider.getBlock("latest")).timestamp + 30 * 86400);

    // Uniswap V4: PoolManager and the test router from this repo's Foundry build
    const PM = artifact("PoolManager.sol", "PoolManager"), ST = artifact("PoolSwapTest.sol", "PoolSwapTest"), HK = artifact("FlowstateC1Hook.sol", "FlowstateC1Hook");
    const manager = await new ethers.ContractFactory(PM.abi, PM.bytecode, admin).deploy(admin.address);
    const router = await new ethers.ContractFactory(ST.abi, ST.bytecode, admin).deploy(manager.target);
    const LR = artifact("Gen4LiveDeltaRouter.sol", "Gen4LiveDeltaRouter");
    const live = await new ethers.ContractFactory(LR.abi, LR.bytecode, admin).deploy(manager.target);

    // the hook at a CREATE2 address carrying its permission flags (as MineHookAddress does on chain)
    await network.provider.send("hardhat_setCode", [CREATE2, CREATE2_RUNTIME]);
    const jar = ethers.Wallet.createRandom().address;
    const args = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "address", "address", "address", "uint16", "address", "address"],
      [manager.target, fx.market.target, admin.address, ethers.ZeroAddress, jar, opts.jarBps ?? 8, registry.target, settlement.target]);
    const initCode = HK.bytecode + args.slice(2);
    const initHash = ethers.keccak256(initCode);
    let salt, hookAddr;
    for (let i = 0n; ; i++) {
      salt = ethers.zeroPadValue(ethers.toBeHex(i), 32);
      hookAddr = ethers.getCreate2Address(CREATE2, salt, initHash);
      if ((BigInt(hookAddr) & 0x3fffn) === HOOK_FLAGS) break;
    }
    await (await admin.sendTransaction({ to: CREATE2, data: salt + initCode.slice(2), ...GAS })).wait();
    const hook = new ethers.Contract(hookAddr, HK.abi, admin);
    assert.notEqual(await ethers.provider.getCode(hookAddr), "0x", "hook deployed at the mined address");
    await (await hook.registerPair(fx.usdc.target, fx.token.target, pool.target, 16)).wait();

    const [c0, c1] = BigInt(fx.usdc.target) < BigInt(fx.token.target) ? [fx.usdc.target, fx.token.target] : [fx.token.target, fx.usdc.target];
    const key = { currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: hookAddr };
    await (await manager.initialize(key, 1n << 96n)).wait();
    const zeroForOne = c0 === fx.usdc.target; // buying the token pays in USDC

    // The hook takes the buyer's input from the PoolManager inside beforeSwap, before the router
    // settles it (gen-3's ManagerReservesExceeded rule): the manager must already hold reserves of
    // the quote currency, as the live Robinhood Chain PoolManager does from its other pools.
    await fx.usdc.mint(manager.target, opts.managerReserve ?? 1_000_000n * 10n ** 6n);
    await fx.usdc.mint(buyerEOA.address, 1_000_000n * 10n ** 6n);
    await fx.usdc.connect(buyerEOA).approve(router.target, ethers.MaxUint256);
    await fx.usdc.connect(buyerEOA).approve(live.target, ethers.MaxUint256);

    const sellers = [];
    const seller = async (amount) => {
      const w = ethers.Wallet.createRandom().connect(ethers.provider);
      await network.provider.send("hardhat_setBalance", [w.address, "0x56BC75E2D63100000"]);
      await fx.token.mint(w.address, amount);
      await (await fx.token.connect(w).approve(PERMIT2, ethers.MaxUint256)).wait();
      await (await permit2.connect(w).approve(fx.token.target, settlement.target, MAX160, far)).wait();
      sellers.push(w);
      return w;
    };
    const list = async (w, amount, opts = {}) =>
      registry.connect(w).list(fx.token.target, amount, far - 86400n, ethers.ZeroHash, await H.consentFloors(pool.target), ZERO_PERMIT, "0x", { ...GAS, ...opts });
    const deposit = async (amount, opts = {}) => {
      const w = ethers.Wallet.createRandom().address;
      await fx.market.connect(fx.signers.alice).contributeTokens(pool.target, amount, w, await H.consentFloors(pool.target), { ...GAS, ...opts });
      return w;
    };
    // WSR F5 (27 Sep 2026): exact input fills the whole slice or reverts. `buyAll` sizes the slice the way
    // a splitting aggregator does: an oversized probe reverts ExactInputShortfall(filled, ...), an
    // exact-output quote of `filled` tokens gives the exact price, and that price is sent as exact input.
    const WRAPPED = new ethers.Interface(["error WrappedError(address target, bytes4 selector, bytes reason, bytes details)"]);
    const shortfallOf = (e) => {
      const data = e.data ?? e.error?.data ?? e.info?.error?.data;
      const w = WRAPPED.parseError(data);
      const inner = hook.interface.parseError(w.args.reason);
      assert.equal(inner.name, "ExactInputShortfall", `expected ExactInputShortfall, got ${inner.name}`);
      return { filled: inner.args[0], wanted: inner.args[1], reason: Number(inner.args[2]) };
    };
    const priceAll = async (gas) => {
      const p = { zeroForOne, sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT };
      let filled;
      try { await live.connect(buyerEOA).swap.staticCall(key, { ...p, amountSpecified: -(10n ** 12n) }, gas); assert.fail("an oversized probe must revert"); }
      catch (e) { if (e.code === "ERR_ASSERTION") throw e; filled = shortfallOf(e).filled; }
      const [d0, d1] = await live.connect(buyerEOA).swap.staticCall(key, { ...p, amountSpecified: filled }, gas);
      return { filled, charged: -(zeroForOne ? d0 : d1) };
    };
    const buy = async (params, opts = {}) => {
      const gas = opts.gasLimit ? { gasLimit: opts.gasLimit } : GAS;
      let sized;
      if (opts.buyAll) { sized = await priceAll(GAS); params = { ...params, amountSpecified: -sized.charged }; }
      const p = { zeroForOne, sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT, ...params };
      const usdc0 = await fx.usdc.balanceOf(buyerEOA.address);
      const tx = opts.buyAll || opts.live
        ? await live.connect(buyerEOA).swap(key, p, gas)
        : await router.connect(buyerEOA).swap(key, p, { takeClaims: false, settleUsingBurn: false }, opts.hookData ?? "0x", gas);
      const rc = await tx.wait();
      // money in equals money out: the buyer pays exactly both sources' payments plus the hook's
      // spread, jar fee and dust; on an exact input nothing else is kept (the rest was refunded)
      const paid = usdc0 - (await fx.usdc.balanceOf(buyerEOA.address));
      let sources = 0n, spread = 0n, dust = 0n, jarFee = 0n;
      for (const log of rc.logs) {
        const a = log.address.toLowerCase();
        try {
          if (a === pool.target.toLowerCase()) { const e = pool.interface.parseLog(log); if (e && e.name === "PoolBuy") sources += e.args[4]; }
          else if (a === settlement.target.toLowerCase()) { const e = settlement.interface.parseLog(log); if (e && e.name === "ListingFilled") sources += e.args.quotePaid; }
          else if (a === hookAddr.toLowerCase()) { const e = hook.interface.parseLog(log); if (e && e.name === "BuyExecuted") { spread += e.args[6]; dust += e.args[7]; } if (e && e.name === "ProtocolFeePaid") jarFee += e.args[2]; }
        } catch {}
      }
      assert.equal(paid, sources + spread + jarFee + dust, `paid ${paid} != sources ${sources} + spread ${spread} + jar ${jarFee} + dust ${dust}`);
      if (params.amountSpecified < 0n) assert.equal(paid, -params.amountSpecified, "exact input charges the whole slice, nothing handed back");
      if (sized) rc.sized = sized;
      rc.money = { paid, sources, spread, jarFee, dust };
      return rc;
    };
    return { fx, pool, registry, settlement, manager, router, live, hook, key, jar, seller, list, deposit, buy, priceAll, shortfallOf, zeroForOne };
  }

  /** The fills of one swap, in execution order: pool fills (PoolBuy) and listing sales (ListingFilled). */
  function fills(rc, s) {
    const out = [];
    for (const log of rc.logs) {
      if (log.address.toLowerCase() === s.pool.target.toLowerCase()) {
        try { const e = s.pool.interface.parseLog(log); if (e && e.name === "PoolBuy") out.push({ src: "pool", amount: e.args[3] }); } catch {}
      } else if (log.address.toLowerCase() === s.settlement.target.toLowerCase()) {
        try { const e = s.settlement.interface.parseLog(log); if (e && e.name === "ListingFilled") out.push({ src: "listing", id: e.args[0], amount: e.args.amount ?? e.args[4] }); } catch {}
      }
    }
    return out;
  }
  const queueOf = async (s) => (await s.pool.queue(100)).map((n) => [n.index, n.amount]);

  // -- helpers for the tests ported from the retired forge fork suite (29 Sep 2026) --------------
  const USD = (n) => BigInt(n) * 10n ** 6n;
  const ceilBps = (amount, bps) => (amount * BigInt(bps) + 9_999n) / 10_000n; // the hook's _ceilBps
  const SETTINGS = { takeClaims: false, settleUsingBurn: false };
  const WRAPPED_ERR = new ethers.Interface(["error WrappedError(address target, bytes4 selector, bytes reason, bytes details)"]);
  const QUOTER_ERR = new ethers.Interface(["error UnexpectedRevertBytes(bytes revertData)"]);
  const revertData = (e) => e.data ?? e.error?.data ?? e.info?.error?.data;
  /** The hook's own error inside a swap's revert (the PoolManager wraps a hook revert in WrappedError). */
  const hookErrorOf = (s, data) => {
    const w = WRAPPED_ERR.parseError(data);
    assert.equal(w.args.target.toLowerCase(), s.hook.target.toLowerCase(), "the revert comes from the hook");
    return s.hook.interface.parseError(w.args.reason);
  };
  const errKey = (err) => `${err.name}(${err.args.map((a) => a.toString()).join(",")})`;
  /** The hook error a swap would revert with, or null when it would go through. */
  const swapError = async (s, amountSpecified) => {
    const p = { zeroForOne: s.zeroForOne, sqrtPriceLimitX96: s.zeroForOne ? MIN_SQRT : MAX_SQRT, amountSpecified };
    try { await s.router.connect(s.fx.signers.buyerEOA).swap.staticCall(s.key, p, SETTINGS, "0x", GAS); return null; }
    catch (e) { return hookErrorOf(s, revertData(e)); }
  };
  const hookEvents = (rc, s) => rc.logs.filter((l) => l.address.toLowerCase() === s.hook.target.toLowerCase()).map((l) => s.hook.interface.parseLog(l));
  const poolIdOf = (key) => ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "uint24", "int24", "address"], [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]));
  /** Uniswap's V4Quoter (v4-periphery, unmodified; compiled via test/stack/StackV4Quoter.sol) on the stack's PoolManager. */
  const deployQuoter = async (s) => {
    const Q = artifact("V4Quoter.sol", "V4Quoter");
    const quoter = await new ethers.ContractFactory(Q.abi, Q.bytecode, s.fx.signers.admin).deploy(s.manager.target);
    const params = (exactAmount) => ({ poolKey: s.key, zeroForOne: s.zeroForOne, exactAmount, hookData: "0x" });
    const from = (who) => quoter.connect(who ?? s.fx.signers.buyerEOA);
    return {
      quoter,
      exactIn: async (amount, who) => (await from(who).quoteExactInputSingle.staticCall(params(amount), GAS))[0],
      exactOut: async (amount, who) => (await from(who).quoteExactOutputSingle.staticCall(params(amount), GAS))[0],
      /** The hook error a quote reverts with (the quoter wraps the swap's revert in UnexpectedRevertBytes). */
      exactInError: async (amount) => {
        try { await from().quoteExactInputSingle.staticCall(params(amount), GAS); return null; }
        catch (e) { return hookErrorOf(s, QUOTER_ERR.parseError(revertData(e)).args.revertData); }
      },
    };
  };
  /** Everything one buy did to the hook's books, the jar and the PoolManager, asserted conserved. */
  const measuredBuy = async (s, params, opts = {}) => {
    const { usdc, token, signers } = s.fx;
    const buyer = signers.buyerEOA.address;
    const at = async () => ({
      jar: await usdc.balanceOf(s.jar), tok: await token.balanceOf(buyer),
      margin: await s.hook.accruedSpreadMargin(usdc.target), dust: await s.hook.accruedDust(usdc.target),
      mgrUsdc: await usdc.balanceOf(s.manager.target), mgrTok: await token.balanceOf(s.manager.target),
    });
    const b = await at();
    const rc = await s.buy(params, opts);
    const a = await at();
    const ev = hookEvents(rc, s);
    const fees = ev.filter((e) => e.name === "ProtocolFeePaid"), buys = ev.filter((e) => e.name === "BuyExecuted");
    assert.equal(buys.length, 1, "one BuyExecuted per swap");
    const out = {
      rc, cost: rc.money.sources, paid: rc.money.paid, got: a.tok - b.tok, jar: a.jar - b.jar, fees,
      retained: buys[0].args.spreadAccrued, dust: buys[0].args.dustAccrued, srcs: fills(rc, s).map((x) => x.src + (x.id ? x.id : "")),
    };
    // the hook's books move by exactly what the swap reported, the manager nets zero on both currencies,
    // and outside the swap the hook holds nothing but its booked margin and dust (scope §8 custody rule)
    assert.equal(a.margin - b.margin, out.retained, "accruedSpreadMargin grew by the reported spread");
    assert.equal(a.dust - b.dust, out.dust, "accruedDust grew by the reported dust");
    assert.equal(a.mgrUsdc, b.mgrUsdc, "PoolManager USDC nets zero");
    assert.equal(a.mgrTok, b.mgrTok, "PoolManager token nets zero");
    assert.equal(await usdc.balanceOf(s.hook.target), a.margin + a.dust, "the hook holds exactly its margin + dust");
    assert.equal(await token.balanceOf(s.hook.target), 0n, "the hook holds no inventory token");
    return out;
  };

  it("pool-only fill: the pool's own buy, jar fee and spread as gen-3 charges them", async () => {
    const s = await stack();
    const { usdc, token, signers } = s.fx;
    const jar0 = await usdc.balanceOf(s.jar), buyer0 = await usdc.balanceOf(signers.buyerEOA.address), tok0 = await token.balanceOf(signers.buyerEOA.address);
    const rc = await s.buy({ amountSpecified: -(20n * 10n ** 6n) }); // $20 exact input
    const f = fills(rc, s);
    assert.equal(f.length, 1); assert.equal(f[0].src, "pool");
    const got = (await token.balanceOf(signers.buyerEOA.address)) - tok0;
    assert.equal(got, f[0].amount);
    const paid = buyer0 - (await usdc.balanceOf(signers.buyerEOA.address));
    assert.equal(paid, 20n * 10n ** 6n);
    const ev = rc.logs.map((l) => { try { return s.hook.interface.parseLog(l); } catch { return null; } }).filter(Boolean);
    const fee = ev.find((e) => e.name === "ProtocolFeePaid"), buy = ev.find((e) => e.name === "BuyExecuted");
    assert.ok(fee && buy, "hook events");
    assert.equal((await usdc.balanceOf(s.jar)) - jar0, fee.args[2]);
    console.log(`      gas: pool-only exact-input swap ${rc.gasUsed}`);
  });

  it("interleaved queue: seed, L1, deposit, L2 are sold in exactly that order in one swap", async () => {
    const s = await stack();
    const a = await s.seller(TOK(60)), b = await s.seller(TOK(60));
    await (await s.list(a, TOK(60))).wait(); // L1: poolTail = 1 (the seed)
    await s.deposit(TOK(50));                // node 2, after L1
    await (await s.list(b, TOK(60))).wait(); // L2: poolTail = 2
    assert.equal((await s.registry.listing(1)).poolTail, 1n);
    assert.equal((await s.registry.listing(2)).poolTail, 2n);
    const rc = await s.buy({ amountSpecified: -(2_000n * 10n ** 6n) }, { buyAll: true }); // more than everything listed and deposited
    const f = fills(rc, s);
    const order = f.map((x) => x.src + (x.id ? x.id : ""));
    console.log(`      order: ${order.join(" > ")}; gas ${rc.gasUsed}`);
    // the seed first, then L1, then node 2, then L2 (the pool's own floor may keep a remainder)
    assert.deepEqual(order.slice(0, 4), ["pool", "listing1", "pool", "listing2"]);
    assert.equal(f[1].amount, TOK(60)); assert.equal(f[3].amount, TOK(60));
  });

  it("the dead L1, pool P, live L2 case: L1 is retired, P is sold before L2, nothing skipped", async () => {
    const s = await stack();
    const a = await s.seller(TOK(60)), b = await s.seller(TOK(60));
    await (await s.list(a, TOK(60))).wait();
    await s.deposit(TOK(50));
    await (await s.list(b, TOK(60))).wait();
    // L1 dies: its seller moves the tokens away
    await (await s.fx.token.connect(a).transfer(s.fx.signers.alice.address, TOK(60))).wait();
    const rc = await s.buy({ amountSpecified: -(2_000n * 10n ** 6n) }, { buyAll: true });
    const f = fills(rc, s), order = f.map((x) => x.src + (x.id ? x.id : ""));
    console.log(`      order: ${order.join(" > ")}; gas ${rc.gasUsed}`);
    assert.ok(!order.includes("listing1"), "the dead listing sold nothing");
    const iP = order.indexOf("pool", 1), iL2 = order.indexOf("listing2");
    assert.ok(iP > 0 && iL2 > iP, `node 2 before L2: ${order}`);
    assert.equal((await s.registry.listing(1)).status, 3n, "L1 retired");
  });

  it("one block: deposit, listing, deposit are ordered by the snapshot, not by the block", async () => {
    const s = await stack();
    const a = await s.seller(TOK(60));
    const floors = await H.consentFloors(s.pool.target);
    await network.provider.send("evm_setAutomine", [false]);
    try {
      await s.fx.market.connect(s.fx.signers.alice).contributeTokens(s.pool.target, TOK(50), ethers.Wallet.createRandom().address, floors, GAS);
      await s.list(a, TOK(60));
      await s.fx.market.connect(s.fx.signers.alice).contributeTokens(s.pool.target, TOK(50), ethers.Wallet.createRandom().address, floors, GAS);
      await network.provider.send("evm_mine", []);
    } finally { await network.provider.send("evm_setAutomine", [true]); }
    assert.equal((await s.registry.listing(1)).poolTail, 2n); // the first deposit (node 2) came before the listing
    const rc = await s.buy({ amountSpecified: -(2_000n * 10n ** 6n) }, { buyAll: true });
    const order = fills(rc, s).map((x) => x.src + (x.id ? x.id : ""));
    console.log(`      order: ${order.join(" > ")}`);
    // seed and node 2 (one pool leg, both at or below the snapshot), then the listing, then node 3
    assert.deepEqual(order.slice(0, 3), ["pool", "listing1", "pool"]);
  });

  it("a pinned head is skipped: the listing behind it goes before a deposit made after the listing", async () => {
    const s = await stack();
    const a = await s.seller(TOK(60));
    await (await s.list(a, TOK(60))).wait(); // poolTail = 1
    await s.deposit(TOK(50));                // node 2
    // a firm-quote hold pins ALL of node 1 (the seed): the first executable node is node 2 > poolTail
    const q = await S.makeQuote(s.fx, s.pool, { tokenAmount: TOK(100), nonce: 9 });
    await S.placeHold(s.fx, q);
    assert.equal((await s.pool.queue(10))[0].pinned, TOK(100));
    const rc = await s.buy({ amountSpecified: -(2_000n * 10n ** 6n) }, { buyAll: true });
    const order = fills(rc, s).map((x) => x.src + (x.id ? x.id : ""));
    console.log(`      order: ${order.join(" > ")}`);
    assert.deepEqual(order.slice(0, 2), ["listing1", "pool"]);
    const q1 = await queueOf(s);
    assert.equal(q1[0][0], 1n); assert.equal(q1[0][1], TOK(100)); // the pinned seed untouched
  });

  it("exact output across both sources delivers exactly the target, in queue order", async () => {
    const s = await stack();
    const a = await s.seller(TOK(60));
    await (await s.list(a, TOK(60))).wait();
    await s.deposit(TOK(50));
    const tok0 = await s.fx.token.balanceOf(s.fx.signers.buyerEOA.address);
    const target = TOK(130); // the seed's sellable part and part of L1, or more
    const rc = await s.buy({ amountSpecified: target });
    const f = fills(rc, s), order = f.map((x) => x.src + (x.id ? x.id : ""));
    console.log(`      order: ${order.join(" > ")}; amounts ${f.map((x) => x.amount).join(", ")}; gas ${rc.gasUsed}`);
    assert.equal((await s.fx.token.balanceOf(s.fx.signers.buyerEOA.address)) - tok0, target);
    // the seed (at or below L1's snapshot) first, then L1 for the rest; node 2 (after L1) untouched
    assert.deepEqual(order, ["pool", "listing1"]);
    assert.equal(f[0].amount + f[1].amount, target);
    const q = await queueOf(s);
    assert.ok(q.some(([index, amount]) => index === 2n && amount === TOK(50)), `node 2 untouched: ${q}`);
  });

  it("F1 (accepted, Hamish 26 Sep): a top-up made after a listing keeps the depositor's place, so it sells before the listing", async () => {
    const s = await stack();
    const d = await s.deposit(TOK(50));                 // node 2
    const a = await s.seller(TOK(60));
    await (await s.list(a, TOK(60))).wait();             // poolTail = 2
    await s.fx.market.connect(s.fx.signers.alice).contributeTokens(s.pool.target, TOK(100), d, await H.consentFloors(s.pool.target), GAS);
    const node2 = (await s.pool.queue(10)).find((n) => n.index === 2n);
    assert.equal(node2.amount, TOK(150), "the top-up merged into node 2, which keeps its number");
    const rc = await s.buy({ amountSpecified: -(2_000n * 10n ** 6n) }, { buyAll: true });
    const f = fills(rc, s);
    assert.deepEqual(f.map((x) => x.src + (x.id ? x.id : "")), ["pool", "listing1"]);
    assert.equal(f[0].amount, TOK(250), "the seed and all of node 2, top-up included, before the listing");
  });

  it("a closed swap route (lane closed by the timelock) reverts with its reason and charges nothing", async () => {
    const s = await stack();
    const a = await s.seller(TOK(60));
    await (await s.list(a, TOK(60))).wait();
    await (await s.fx.market.connect(s.fx.signers.timelock48).closePassiveLane(s.pool.target)).wait();
    const buyer = s.fx.signers.buyerEOA, usdc0 = await s.fx.usdc.balanceOf(buyer.address);
    const p = { zeroForOne: s.zeroForOne, sqrtPriceLimitX96: s.zeroForOne ? MIN_SQRT : MAX_SQRT, amountSpecified: -(20n * 10n ** 6n) };
    let reason;
    try { await s.live.connect(buyer).swap.staticCall(s.key, p, GAS); assert.fail("a closed route must revert"); }
    catch (e) { if (e.code === "ERR_ASSERTION") throw e; reason = s.shortfallOf(e).reason; }
    assert.equal(reason, 6, "STOP_CLOSED");
    assert.equal(await s.fx.usdc.balanceOf(buyer.address), usdc0, "nothing charged");
    assert.equal((await s.registry.listing(1)).remaining, TOK(60), "the listing untouched");
  });

  // ---------------------------------------------------------------------------------------------
  // Ported from the forge fork suite (29 Sep 2026): its swap tests ran the deleted Gen-3 path
  // against an older vendored market with no listings. These carry the Gen-4-relevant properties
  // onto the real stack. Expected numbers are pinned where they can be derived by hand at the
  // fixture's flat rate (RATE = 2e6: $2 per token), so any change in the hook's arithmetic fails.
  // ---------------------------------------------------------------------------------------------

  describe("ported from the forge fork suite", () => {
    it("TokenJar fee: every fill pays the jar exactly ceil(cost x 8 / 10,000) out of the spread; the buyer is charged what a jar-free hook charges", async () => {
      // two stacks identical but for the hook's jar fee (8 bps, the production value, and 0): every buy
      // runs on both, and the buyer must be charged and served identically on both
      const J = await stack(), Z = await stack({ jarBps: 0 });
      assert.equal(await J.hook.jarFeeBps(), 8n); assert.equal(await Z.hook.jarFeeBps(), 0n);
      const both = async (params, opts) => [await measuredBuy(J, params, opts), await measuredBuy(Z, params, opts)];
      const check = (label, j, z, exactInput) => {
        assert.equal(j.cost, z.cost, `${label}: the sources charged the same`);
        assert.equal(j.got, z.got, `${label}: the buyer received the same tokens`);
        assert.equal(j.paid, z.paid, `${label}: the buyer paid the same (the jar changes nothing for the buyer)`);
        assert.equal(j.dust, z.dust, `${label}: same dust`);
        const spread = ceilBps(j.cost, 16); // the pair's 16 bps, no rungs
        const fee = ceilBps(j.cost, 8);
        assert.ok(fee > 0n && fee <= spread, `${label}: 0 < jar fee <= spread`);
        assert.equal(j.fees.length, 1, `${label}: one ProtocolFeePaid per fill`);
        assert.equal(j.fees[0].args.amount, fee, `${label}: ProtocolFeePaid = ceil(cost x 8 / 10,000)`);
        assert.equal(j.fees[0].args.poolId, poolIdOf(J.key), `${label}: ProtocolFeePaid names the V4 pool`);
        assert.equal(j.fees[0].args.asset, J.fx.usdc.target, `${label}: paid in the quote asset`);
        assert.equal(j.jar, fee, `${label}: the jar received exactly the fee, in the same transaction`);
        assert.equal(j.retained + j.jar, spread, `${label}: jar + kept margin = the whole spread`);
        assert.equal(z.retained, spread, `${label}: the jar-free hook keeps the whole spread`);
        assert.equal(z.fees.length, 0, `${label}: no jar fee, no event`); assert.equal(z.jar, 0n);
        if (exactInput) assert.equal(j.paid, j.cost + spread + j.dust, `${label}: exact input charge = cost + spread + dust`);
        else assert.equal(j.paid, j.cost + spread, `${label}: exact output charge = cost + spread`);
        console.log(`      ${label}: cost ${j.cost}, spread ${spread} = jar ${j.jar} + kept ${j.retained}, dust ${j.dust}, sources ${j.srcs.join(" > ")}`);
      };

      // pool only, exact input $20 at 16 bps: budget floor(20e6 x 10,000 / 10,016) = 19,968,051 buys
      // 9.9840255 tokens; spread ceil(19,968,051 x 16 / 10,000) = 31,949, jar ceil(x 8) = 15,975
      let [j, z] = await both({ amountSpecified: -USD(20) });
      check("pool-only exact input $20", j, z, true);
      assert.equal(j.cost, 19_968_051n); assert.equal(j.got, 9_984_025_500_000_000_000n);
      assert.equal(j.jar, 15_975n); assert.equal(j.retained, 15_974n); assert.equal(j.dust, 0n);

      // pool only, exact output 10 tokens: cost $20, spread 32,000, jar 16,000, charge 20,032,000
      [j, z] = await both({ amountSpecified: TOK(10) });
      check("pool-only exact output 10 tokens", j, z, false);
      assert.equal(j.cost, USD(20)); assert.equal(j.jar, 16_000n); assert.equal(j.retained, 16_000n); assert.equal(j.paid, 20_032_000n);

      // the lowest legal spread is the jar fee itself: then the jar takes all of it and the hook keeps 0
      const [usdc, token] = [J.fx.usdc.target, J.fx.token.target];
      let snap = await network.provider.send("evm_snapshot", []);
      await assert.rejects(J.hook.setBaseSpread(usdc, token, 7), (e) => J.hook.interface.parseError(revertData(e)).name === "SpreadOutOfRange");
      await (await J.hook.setBaseSpread(usdc, token, 8)).wait();
      j = await measuredBuy(J, { amountSpecified: TOK(5) }); // cost $10: spread = jar = 8,000
      assert.equal(j.cost, USD(10)); assert.equal(j.jar, 8_000n); assert.equal(j.retained, 0n, "spread = jar fee: the hook keeps nothing");
      assert.equal(j.paid, USD(10) + 8_000n, "and the buyer pays cost + the 8 bps spread");
      await network.provider.send("evm_revert", [snap]);

      // a listing behind the seed: fills that mix the pool and the listing
      for (const s of [J, Z]) await (await s.list(await s.seller(TOK(60)), TOK(60))).wait();
      snap = await network.provider.send("evm_snapshot", []);
      [j, z] = await both({ amountSpecified: -USD(200) });
      check("pool + listing exact input $200", j, z, true);
      assert.deepEqual(j.srcs, ["pool", "listing1"], "the fill mixed the pool and the listing");
      await network.provider.send("evm_revert", [snap]);
      [j, z] = await both({ amountSpecified: TOK(100) });
      check("pool + listing exact output 100 tokens", j, z, false);
      assert.deepEqual(j.srcs, ["pool", "listing1"], "the fill mixed the pool and the listing");
    });

    it("quote parity: Uniswap's V4Quoter returns exactly what the swap delivers or charges (pool only, pool + listing, both directions), from any sender, and declines identically", async () => {
      const s = await stack();
      const q = await deployQuoter(s);
      const other = s.fx.signers.bob;

      // pool only, exact input $20: the same quote from any sender, and exactly what the swap delivers
      let quoted = await q.exactIn(USD(20));
      assert.equal(await q.exactIn(USD(20), other), quoted, "the quote does not depend on the sender");
      assert.equal(quoted, 9_984_025_500_000_000_000n, "the hand-derived amount at $2 and 16 bps");
      let m = await measuredBuy(s, { amountSpecified: -USD(20) });
      assert.equal(m.got, quoted, "exact input: delivered == quoted");

      // pool only, exact output 10 tokens: the quoted input is exactly the charge
      quoted = await q.exactOut(TOK(10));
      assert.equal(await q.exactOut(TOK(10), other), quoted, "the quote does not depend on the sender");
      assert.equal(quoted, 20_032_000n, "cost $20 + ceil(16 bps) spread");
      m = await measuredBuy(s, { amountSpecified: TOK(10) });
      assert.equal(m.paid, quoted, "exact output: charged == quoted");

      // pool + listing, both directions (the listing sits behind the seed)
      await (await s.list(await s.seller(TOK(60)), TOK(60))).wait();
      const snap = await network.provider.send("evm_snapshot", []);
      quoted = await q.exactIn(USD(200));
      m = await measuredBuy(s, { amountSpecified: -USD(200) });
      assert.deepEqual(m.srcs, ["pool", "listing1"]);
      assert.equal(m.got, quoted, "pool + listing exact input: delivered == quoted");
      await network.provider.send("evm_revert", [snap]);
      quoted = await q.exactOut(TOK(100));
      m = await measuredBuy(s, { amountSpecified: TOK(100) });
      assert.deepEqual(m.srcs, ["pool", "listing1"]);
      assert.equal(m.paid, quoted, "pool + listing exact output: charged == quoted");
      console.log(`      pool + listing: exact output 100 tokens quoted and charged ${quoted}`);

      // declines: the quote reverts with exactly the hook error the swap reverts with
      const declines = async (label, amount) => {
        const fromQuote = await q.exactInError(amount), fromSwap = await swapError(s, -amount);
        assert.ok(fromQuote && fromSwap, `${label}: both decline`);
        assert.equal(errKey(fromQuote), errKey(fromSwap), `${label}: identical hook error`);
        console.log(`      ${label}: quoter and swap both revert ${errKey(fromSwap)}`);
        return fromSwap;
      };
      const big = await declines("a slice larger than the stock", USD(100_000));
      assert.equal(big.name, "ExactInputShortfall"); assert.equal(big.args.reason, 5n, "STOP_STOCK");
      const tiny = await declines("one raw unit (below the spread carve)", 1n);
      assert.equal(errKey(tiny), "TradeTooSmallForSpread(1,16)");
      await (await s.fx.market.connect(s.fx.signers.timelock48).closePassiveLane(s.pool.target)).wait();
      const closed = await declines("a closed swap route", USD(20));
      assert.equal(errKey(closed), "ExactInputShortfall(0,0,6)", "STOP_CLOSED");
    });

    it("spread rungs: each buy pays baseSpread + its rung's extraBps (first ceiling >= notional, open-ended top), spread = ceil(cost x bps / 10,000)", async () => {
      const s = await stack();
      const [usdc, token] = [s.fx.usdc.target, s.fx.token.target];
      await s.deposit(TOK(2_000)); // node 2: stock for the large buys
      // setSizeRungs rejects anything but strictly ascending ceilings with non-decreasing extraBps
      await assert.rejects(s.hook.setSizeRungs(usdc, [{ notionalCeiling: USD(500), extraBps: 7 }, { notionalCeiling: USD(50), extraBps: 9 }]),
        (e) => s.hook.interface.parseError(revertData(e)).name === "RungScheduleInvalid");
      const rungs = [{ notionalCeiling: USD(50), extraBps: 0 }, { notionalCeiling: USD(500), extraBps: 7 }, { notionalCeiling: USD(1_000), extraBps: 20 }];
      await (await s.hook.setSizeRungs(usdc, rungs)).wait();
      // base 16 (the fixture) + rung: exact input measures the committed input, exact output the cost
      const cases = [
        { label: "small exact input $50 (at the first ceiling: +0)", params: { amountSpecified: -USD(50) }, notional: USD(50), bps: 16,
          cost: 49_920_127n, spread: 79_873n, got: 24_960_063_500_000_000_000n },
        { label: "exact input $50 + 1 raw unit (one over: +7)", params: { amountSpecified: -(USD(50) + 1n) }, notional: USD(50) + 1n, bps: 23,
          cost: 49_885_264n, spread: 114_737n, got: 24_942_632_000_000_000_000n },
        { label: "large exact input $1,500 (above the top ceiling: top rung +20)", params: { amountSpecified: -USD(1_500) }, notional: USD(1_500), bps: 36,
          cost: 1_494_619_370n, spread: 5_380_630n, got: 747_309_685_000_000_000_000n },
        { label: "small exact output 10 tokens (cost $20: +0)", params: { amountSpecified: TOK(10) }, notional: USD(20), bps: 16,
          cost: USD(20), spread: 32_000n, got: TOK(10) },
        { label: "large exact output 300 tokens (cost $600: +20)", params: { amountSpecified: TOK(300) }, notional: USD(600), bps: 36,
          cost: USD(600), spread: 2_160_000n, got: TOK(300) },
      ];
      for (const c of cases) {
        assert.equal(await s.hook.spreadBpsFor(usdc, token, c.notional), BigInt(c.bps), `${c.label}: spreadBpsFor`);
        const m = await measuredBuy(s, c.params);
        const spread = m.retained + m.jar;
        console.log(`      ${c.label}: ${c.bps} bps, cost ${m.cost}, spread ${spread}, tokens ${m.got}, paid ${m.paid}`);
        assert.equal(m.cost, c.cost, `${c.label}: cost`);
        assert.equal(spread, ceilBps(m.cost, c.bps), `${c.label}: spread = ceil(cost x bps / 10,000)`);
        assert.equal(spread, c.spread, `${c.label}: spread (pinned)`);
        assert.equal(m.got, c.got, `${c.label}: tokens delivered`);
        assert.equal(m.jar, ceilBps(m.cost, 8), `${c.label}: jar fee unaffected by the rung`);
        if (c.params.amountSpecified < 0n) {
          assert.equal(m.paid, -c.params.amountSpecified, `${c.label}: exact input charges the committed input`);
          assert.equal(m.dust, m.paid - m.cost - spread, `${c.label}: the rest is dust`);
        } else assert.equal(m.paid, m.cost + spread, `${c.label}: exact output charges cost + spread`);
      }
    });

    it("PoolManager reserves: a ticket above the manager's quote balance reverts ManagerReservesExceeded; exactly the balance fills and the manager nets zero", async () => {
      // the hook takes the buyer's input from the PoolManager inside beforeSwap, before the router pays
      // it in (_takeChecked), so the largest ticket is what the manager holds from its other pools
      const s = await stack({ managerReserve: 0n });
      const [usdc, mgr] = [s.fx.usdc, s.manager.target];
      const expectReserves = async (label, amountSpecified, requested, available) => {
        const err = await swapError(s, amountSpecified);
        assert.ok(err, `${label}: reverts`);
        assert.equal(errKey(err), `ManagerReservesExceeded(${usdc.target},${requested},${available})`, label);
      };

      // exact input: the take is the whole committed input
      await usdc.mint(mgr, USD(20));
      await expectReserves("exact input one raw unit above the reserve", -(USD(20) + 1n), USD(20) + 1n, USD(20));
      const m = await measuredBuy(s, { amountSpecified: -USD(20) }); // exactly the reserve
      assert.equal(m.got, 9_984_025_500_000_000_000n, "the full-reserve ticket fills");
      assert.equal(await usdc.balanceOf(mgr), USD(20), "and the manager nets zero at the ceiling");

      // exact output: each leg's pre-funding is taken, then the spread, all before the router pays in,
      // so 10 tokens (cost $20, spread 32,000) needs the manager to hold 20,032,000
      await expectReserves("exact output with the reserve covering only the cost", TOK(10), 32_000n, 0n);
      await usdc.mint(mgr, 31_999n);
      await expectReserves("exact output one raw unit short", TOK(10), 32_000n, 31_999n);
      await usdc.mint(mgr, 1n);
      const o = await measuredBuy(s, { amountSpecified: TOK(10) });
      assert.equal(o.paid, 20_032_000n, "exactly cost + spread in reserve fills");
      assert.equal(await usdc.balanceOf(mgr), 20_032_000n, "and the manager nets zero");
    });

    it("the 1-wei visibility beacon: one dust add per pool, from anyone, and it never changes a quote or a fill", async () => {
      const s = await stack();
      const q = await deployQuoter(s);
      const before = [await q.exactIn(USD(20)), await q.exactOut(TOK(10))];
      const LT = artifact("PoolModifyLiquidityTest.sol", "PoolModifyLiquidityTest");
      const lp = await new ethers.ContractFactory(LT.abi, LT.bytecode, s.fx.signers.admin).deploy(s.manager.target);
      const anyone = s.fx.signers.bob;
      await s.fx.usdc.mint(anyone.address, USD(1));
      await s.fx.usdc.connect(anyone).approve(lp.target, ethers.MaxUint256);
      await s.fx.token.connect(anyone).approve(lp.target, ethers.MaxUint256);
      const add = (delta, salt) => lp.connect(anyone)["modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)"](
        s.key, { tickLower: -600, tickUpper: 600, liquidityDelta: delta, salt }, "0x", GAS);
      const poolId = poolIdOf(s.key);
      assert.equal(await s.hook.beaconSeeded(poolId), false);
      await assert.rejects(add(2, ethers.ZeroHash), (e) => hookErrorOf(s, revertData(e)).name === "LiquidityNotAllowed", "a real-size add is refused");
      await (await add(1, ethers.ZeroHash)).wait();
      assert.equal(await s.hook.beaconSeeded(poolId), true, "the beacon is lit");
      await assert.rejects(add(1, ethers.zeroPadValue("0x01", 32)), (e) => hookErrorOf(s, revertData(e)).name === "LiquidityNotAllowed", "and closed after one add");
      assert.deepEqual([await q.exactIn(USD(20)), await q.exactOut(TOK(10))], before, "the dust changed no quote");
      const m = await measuredBuy(s, { amountSpecified: -USD(20) });
      assert.equal(m.got, before[0], "nor the fill");
    });

    it("hookData is never read: the same buys with junk hookData deliver, charge and accrue identically", async () => {
      const s = await stack();
      await (await s.list(await s.seller(TOK(60)), TOK(60))).wait();
      for (const params of [{ amountSpecified: -USD(250) }, { amountSpecified: TOK(130) }]) { // past the seed's 100 tokens
        const runs = [];
        for (const hookData of ["0x", "0xdeadbeef0102030405ffffffffffffffffffffffffffffffff00"]) {
          const snap = await network.provider.send("evm_snapshot", []);
          const m = await measuredBuy(s, params, { hookData });
          runs.push([m.got, m.paid, m.cost, m.retained, m.jar, m.dust, m.srcs.join(">")].map(String));
          await network.provider.send("evm_revert", [snap]);
        }
        assert.deepEqual(runs[1], runs[0], `hookData changed the outcome of ${params.amountSpecified}`);
        assert.equal(runs[0][6], "pool>listing1");
      }
    });

    it("margin custody and sweep: the hook holds exactly its booked margin + dust; the owner's sweep takes it all, with the split, and accrual resumes", async () => {
      const s = await stack();
      const [usdc, token] = [s.fx.usdc, s.fx.token];
      const sweepTo = ethers.Wallet.createRandom().address;
      await (await s.list(await s.seller(TOK(60)), TOK(60))).wait();
      // several fill shapes, including an exact output while margin already sits on the hook
      // (the Gen-4 walk pre-funds each leg from the PoolManager, so the margin is never working capital)
      let spread = 0n, dust = 0n;
      // 21,000,423 is an exact input that leaves 1 raw unit of dust at 16 bps (budget 20,966,875, spread 33,547)
      for (const params of [{ amountSpecified: -21_000_423n }, { amountSpecified: TOK(10) }, { amountSpecified: -USD(33) }, { amountSpecified: TOK(100) }]) {
        const m = await measuredBuy(s, params); // asserts the custody invariant after every fill
        spread += m.retained; dust += m.dust;
      }
      assert.ok(spread > 0n && dust > 0n, "margin and dust accrued");
      assert.equal(await s.hook.accruedSpreadMargin(usdc.target), spread, "the counter is the sum of the fills' kept spread");
      assert.equal(await s.hook.accruedDust(usdc.target), dust);
      assert.equal(await s.hook.accruedSpreadMargin(token.target), 0n, "an unrelated asset accrues nothing");
      assert.equal(await ethers.provider.getBalance(s.hook.target), 0n, "no native on the hook");

      await assert.rejects(s.hook.sweepMargin(usdc.target), (e) => s.hook.interface.parseError(revertData(e)).name === "SweepDestinationNotSet");
      await assert.rejects(s.hook.connect(s.fx.signers.bob).sweepMargin(usdc.target), (e) => s.hook.interface.parseError(revertData(e)).name === "OwnableUnauthorizedAccount");
      await assert.rejects(s.hook.setSweepDestination(ethers.ZeroAddress), (e) => s.hook.interface.parseError(revertData(e)).name === "ZeroAddress");
      await (await s.hook.setSweepDestination(sweepTo)).wait();
      await assert.rejects(s.hook.connect(s.fx.signers.bob).sweepMargin(usdc.target), (e) => s.hook.interface.parseError(revertData(e)).name === "OwnableUnauthorizedAccount");
      const donation = 1_234_567n; // force-sent: recovered by the same sweep, reported as the excess over the split
      await usdc.mint(s.hook.target, donation);
      const rc = await (await s.hook.sweepMargin(usdc.target)).wait();
      const swept = hookEvents(rc, s).find((e) => e.name === "MarginSwept");
      assert.equal(swept.args.asset, usdc.target); assert.equal(swept.args.to, sweepTo);
      assert.equal(swept.args.spreadPortion, spread); assert.equal(swept.args.dustPortion, dust);
      assert.equal(swept.args.swept, spread + dust + donation);
      assert.equal(await usdc.balanceOf(sweepTo), spread + dust + donation, "the destination received everything");
      assert.equal(await usdc.balanceOf(s.hook.target), 0n, "the hook is empty");
      assert.equal(await s.hook.accruedSpreadMargin(usdc.target), 0n); assert.equal(await s.hook.accruedDust(usdc.target), 0n);

      // restock: the seed is sold out, and the listing's 23-token remainder is below the pool's minimum
      // (the fixture's $100 minContribution = 50 tokens), so the registry reports it dead (peek)
      await s.deposit(TOK(100));
      const again = await measuredBuy(s, { amountSpecified: -USD(20) });
      assert.ok(again.retained > 0n, "accrual resumes after a sweep");
      assert.equal(await s.hook.accruedSpreadMargin(usdc.target), again.retained);
    });

    it("a paused market, a paused pool and a frozen hook: quote and swap decline with the same typed error, and service resumes when lifted", async () => {
      const s = await stack();
      const q = await deployQuoter(s);
      const { market, signers } = s.fx;
      const declinesAlike = async (label) => {
        const fromQuote = await q.exactInError(USD(20)), fromSwap = await swapError(s, -USD(20));
        assert.ok(fromQuote && fromSwap, `${label}: both decline`);
        assert.equal(errKey(fromQuote), errKey(fromSwap), `${label}: identical hook error`);
        console.log(`      ${label}: quoter and swap both revert ${errKey(fromSwap)}`);
        return errKey(fromSwap);
      };
      const fillsAgain = async (label) => assert.equal((await measuredBuy(s, { amountSpecified: -USD(20) })).got, 9_984_025_500_000_000_000n, `${label}: fills again`);
      const wanted = 9_984_025_500_000_000_000n; // $20 at 16 bps and $2

      // the settlement's price() reports a paused market (why 2) and a paused pool (why 4) as closed
      await (await market.connect(signers.admin).pause()).wait();
      assert.equal(await declinesAlike("market paused"), "ExactInputShortfall(0,0,6)");
      await (await market.connect(signers.admin).unpause()).wait();
      await fillsAgain("market unpaused");
      await (await market.connect(signers.admin).pausePool(s.pool.target, true)).wait();
      assert.equal(await declinesAlike("pool paused"), "ExactInputShortfall(0,0,6)");
      await (await market.connect(signers.admin).pausePool(s.pool.target, false)).wait();
      await fillsAgain("pool unpaused");

      // the market's freeze tests the pool leg's msg.sender and buyer, both the hook: freezing the
      // swapper changes nothing, freezing the hook stops every pool leg (the runbook's "never freeze
      // the hook address"); the price stays open, so the walk stops on the failed leg (STOP_POOL_LEG)
      await (await market.connect(signers.freeze24).setFreezeEnabled(true)).wait();
      await (await market.connect(signers.admin).setFrozen(signers.buyerEOA.address, true)).wait();
      await fillsAgain("the swapper frozen");
      await (await market.connect(signers.admin).setFrozen(s.hook.target, true)).wait();
      assert.equal(await declinesAlike("the hook frozen"), `ExactInputShortfall(0,${wanted},3)`);
      await (await market.connect(signers.admin).setFrozen(s.hook.target, false)).wait();
      await fillsAgain("the hook unfrozen");
    });

    it("the reseller code reaches both legs verbatim; an unregistered code still trades", async () => {
      const codesOf = (s, rc) => {
        const out = [];
        for (const log of rc.logs) {
          const a = log.address.toLowerCase();
          try {
            if (a === s.pool.target.toLowerCase()) { const e = s.pool.interface.parseLog(log); if (e && e.name === "PoolBuy") out.push(["pool", e.args.resellerCode]); }
            else if (a === s.settlement.target.toLowerCase()) { const e = s.settlement.interface.parseLog(log); if (e && e.name === "ListingFeeDistributed") out.push(["listing", e.args.resellerCode]); }
          } catch {}
        }
        return out;
      };
      for (const code of ["KYBER", "not-registered-anywhere"]) { // KYBER is the fixture's registered reseller
        const s = await stack();
        await (await s.list(await s.seller(TOK(60)), TOK(60))).wait();
        await (await s.hook.setResellerCode(code)).wait();
        const m = await measuredBuy(s, { amountSpecified: TOK(130) }); // the seed's 100, then 30 from the listing
        assert.equal(m.got, TOK(130), `${code}: the buy fills`);
        assert.deepEqual(m.srcs, ["pool", "listing1"]);
        assert.deepEqual(codesOf(s, m.rc), [["pool", code], ["listing", code]], `${code}: forwarded verbatim to both legs`);
      }
    });
  });

  // Gas matrix (WSR F5 build, 27-28 Sep 2026): gas used, eth_estimateGas and the LOWEST gas limit that
  // fills, per case. Run with GAS_MATRIX=1. Each case sizes its slice to the whole stock, as a splitting
  // aggregator would; under all-or-nothing a limit either fills completely or reverts.
  (process.env.GAS_MATRIX ? describe : describe.skip)("gas matrix", () => {
    const measure = async (s, label) => {
      const { charged } = await s.priceAll(GAS);
      const p = { zeroForOne: s.zeroForOne, sqrtPriceLimitX96: s.zeroForOne ? MIN_SQRT : MAX_SQRT, amountSpecified: -charged };
      const buyer = s.fx.signers.buyerEOA;
      const est = await s.live.connect(buyer).swap.estimateGas(s.key, p);
      const at = async (gasLimit) => {
        const snap = await network.provider.send("evm_snapshot", []);
        try { const rc = await (await s.live.connect(buyer).swap(s.key, p, { gasLimit })).wait(); return { ok: true, used: rc.gasUsed }; }
        catch { return { ok: false }; }
        finally { await network.provider.send("evm_revert", [snap]); }
      };
      const full = await at(30_000_000);
      assert.ok(full.ok, `${label}: fills at 30M`);
      let lo = 300_000, hi = 30_000_000;
      while (hi - lo > 25_000) { const mid = Math.floor((lo + hi) / 2); if ((await at(mid)).ok) hi = mid; else lo = mid; }
      const used = Number(full.used);
      console.log(`      ${label}: used ${used}, estimate ${est} (${(Number(est) / used).toFixed(2)}x), lowest limit that fills ${hi} (${(hi / used).toFixed(2)}x used)`);
    };
    it("matrix", async () => {
      { const s = await stack(); await measure(s, "pool only, 1 node (seed)"); }
      { const s = await stack(); for (let i = 0; i < 19; i++) await s.deposit(TOK(50)); await measure(s, "pool only, 20 nodes"); }
      { const s = await stack(); for (let i = 0; i < 49; i++) await s.deposit(TOK(50)); await measure(s, "pool only, 50 nodes"); }
      { const s = await stack(); const a = await s.seller(TOK(60)); await (await s.list(a, TOK(60))).wait(); await measure(s, "seed + 1 listing"); }
      { const s = await stack(); const a = await s.seller(TOK(60)), b = await s.seller(TOK(60)); await (await s.list(a, TOK(60))).wait(); await (await s.list(b, TOK(60))).wait(); await measure(s, "seed + 2 listings"); }
      { const s = await stack(); const a = await s.seller(TOK(60)), b = await s.seller(TOK(60)); await (await s.list(a, TOK(60))).wait(); await (await s.list(b, TOK(60))).wait();
        await (await s.fx.token.connect(a).transfer(s.fx.signers.alice.address, TOK(60))).wait(); await measure(s, "seed + 1 dead + 1 live listing"); }
      { const s = await stack({ dustTicks: 36 }); const a = await s.seller(TOK(60)); await (await s.list(a, TOK(60))).wait(); await measure(s, "dusty venue (72 ticks), seed + 1 listing"); }
    });
  });

  describe("gate 2: gas on the pinned stack", () => {
    it("a 50-deposit queue ahead of a listing: one swap takes all 50 nodes then the listing", async () => {
      const s = await stack();
      for (let i = 0; i < 49; i++) await s.deposit(TOK(50)); // nodes 2..50 behind the seed
      const a = await s.seller(TOK(60));
      await (await s.list(a, TOK(60))).wait(); // poolTail = 50
      assert.equal((await s.pool.queue(100)).length, 50);
      const rc = await s.buy({ amountSpecified: -(20_000n * 10n ** 6n) }, { buyAll: true });
      const f = fills(rc, s), order = f.map((x) => x.src + (x.id ? x.id : ""));
      console.log(`      50 nodes + 1 listing: order ${order.join(" > ")}; pool tokens ${f.filter((x) => x.src === "pool").reduce((t, x) => t + x.amount, 0n)}; gas ${rc.gasUsed}`);
      assert.equal(order[order.length - 1], "listing1", "the listing only after the whole queue ahead of it");
    });

    it("17 dead listings ahead of stock (Wilko, 29 Sep): one swap retires them on the way and fills", async () => {
      const s = await stack();
      const sellers = [];
      for (let i = 0; i < 17; i++) { const w = await s.seller(TOK(60)); await (await s.list(w, TOK(60))).wait(); sellers.push(w); }
      await s.deposit(TOK(50)); // node 2, behind all 17 listings
      for (const w of sellers) await (await s.fx.token.connect(w).transfer(s.fx.signers.alice.address, TOK(60))).wait(); // all 17 die
      const rc = await s.buy({}, { buyAll: true });
      const f = fills(rc, s);
      assert.equal(f.reduce((t, x) => t + x.amount, 0n), TOK(150), "the seed and node 2, past 17 dead listings");
      for (let id = 1n; id <= 17n; id++) assert.equal((await s.registry.listing(id)).status, 3n, `L${id} retired by the swap`);
      console.log(`      17 dead listings: one swap retired them and filled ${f.reduce((t, x) => t + x.amount, 0n)}; gas ${rc.gasUsed}`);
    });

    it("33 dead listings ahead of stock: a buy past them reverts at the dead-listing cap; an independent prune clears the queue and the buy fills", async () => {
      const s = await stack();
      const sellers = [];
      for (let i = 0; i < 33; i++) { const w = await s.seller(TOK(60)); await (await s.list(w, TOK(60))).wait(); sellers.push(w); }
      await s.deposit(TOK(50));
      for (const w of sellers) await (await s.fx.token.connect(w).transfer(s.fx.signers.alice.address, TOK(60))).wait();
      const buyer = s.fx.signers.buyerEOA;
      const p = { zeroForOne: s.zeroForOne, sqrtPriceLimitX96: s.zeroForOne ? MIN_SQRT : MAX_SQRT };
      const seedOnly = await s.priceAll(GAS);
      let wall;
      try { await s.live.connect(buyer).swap.staticCall(s.key, { ...p, amountSpecified: -(seedOnly.charged * 2n) }, GAS); assert.fail("must revert"); }
      catch (e) { if (e.code === "ERR_ASSERTION") throw e; wall = s.shortfallOf(e); }
      console.log(`      33 dead listings: a buy past them reverts reason ${wall.reason} with ${wall.filled} filled (the seed)`);
      assert.equal(wall.reason, 7, "the attempt cap (32 retirements)");
      const keeper = s.fx.signers.alice;
      for (let id = 1n; id <= 33n; id++) await (await s.registry.connect(keeper).prune(id, GAS)).wait();
      const rc = await s.buy({}, { buyAll: true });
      const f = fills(rc, s);
      assert.equal(f.reduce((t, x) => t + x.amount, 0n), TOK(150), "the buy past the cleared queue fills completely");
    });

    it("a 50-deposit buy under tight gas limits either fills completely or reverts, never fills part", async () => {
      const s = await stack();
      for (let i = 0; i < 49; i++) await s.deposit(TOK(50));
      const full = TOK(100) + 49n * TOK(50);
      const { charged } = await s.priceAll(GAS);
      const rows = [];
      for (const gasLimit of [2_000_000, 3_000_000, 4_000_000, 5_000_000, 8_000_000]) {
        const snap = await network.provider.send("evm_snapshot", []);
        try {
          const rc = await s.buy({ amountSpecified: -charged }, { live: true, gasLimit });
          const got = fills(rc, s).reduce((t, x) => t + x.amount, 0n);
          rows.push({ gasLimit, got, gasUsed: rc.gasUsed, reverted: false });
        } catch (e) { rows.push({ gasLimit, reverted: true }); }
        finally { await network.provider.send("evm_revert", [snap]); }
      }
      console.log("      " + rows.map((r) => `${r.gasLimit}: ${r.reverted ? "REVERTED" : `${r.got / 10n ** 18n} of ${full / 10n ** 18n} tokens, gas ${r.gasUsed}`}`).join("; "));
      for (const r of rows) assert.ok(r.reverted || r.got === full, `filled part (${r.got}) at ${r.gasLimit}`);
      assert.equal(rows[rows.length - 1].got, full, "enough gas fills everything");
    });

    it("review F2: 72 dust ticks in a spacing-10 venue raise the reads above 1M but cannot stop swaps", async () => {
      const s = await stack({ dustTicks: 36 });
      const from = s.fx.signers.buyerEOA.address;
      const g = async (c, name, args) => (await ethers.provider.estimateGas({ from, to: c.target, data: c.interface.encodeFunctionData(name, args) })) - 21000n;
      const maxBuyGas = await g(s.fx.market, "maxBuy", [s.pool.target, s.fx.usdc.target]);
      const priceGas = await g(s.settlement, "price", [s.fx.token.target, s.fx.usdc.target]);
      const ev = await s.fx.market.evaluateVenue(s.pool.target);
      assert.ok(maxBuyGas > 1_000_000n, `maxBuy costs ${maxBuyGas}: above the old fixed 1M read cap`);
      const a = await s.seller(TOK(60));
      await (await s.list(a, TOK(60))).wait();
      const rc = await s.buy({ amountSpecified: -(2_000n * 10n ** 6n) }, { buyAll: true });
      const order = fills(rc, s).map((x) => x.src + (x.id ? x.id : ""));
      console.log(`      dusty venue: maxBuy ${maxBuyGas}, price ${priceGas} (tier ${ev.tier}, depthOk ${ev.depthOk}); swap order ${order.join(" > ")}; gas ${rc.gasUsed}`);
      assert.deepEqual(order, ["pool", "listing1"]);
    });

    it("the lowest gas limit at which a pool-only swap fills (routers must send at least this)", async () => {
      const s = await stack();
      const at = async (gasLimit) => {
        const snap = await network.provider.send("evm_snapshot", []);
        try {
          const rc = await s.buy({ amountSpecified: -(20n * 10n ** 6n) }, { gasLimit });
          return { filled: fills(rc, s).length > 0, gasUsed: rc.gasUsed };
        } catch { return { filled: false, reverted: true }; }
        finally { await network.provider.send("evm_revert", [snap]); }
      };
      let lo = 500_000, hi = 12_000_000;
      assert.ok((await at(hi)).filled, "fills with 12M");
      while (hi - lo > 50_000) { const mid = Math.floor((lo + hi) / 2); if ((await at(mid)).filled) hi = mid; else lo = mid; }
      const r = await at(hi), below = await at(lo);
      console.log(`      pool-only $20 swap: fills from gas limit ~${hi} (gas used ${r.gasUsed}); at ${lo}: ${below.reverted ? "reverts" : "succeeds with NO fill"}`);
      assert.ok(below.reverted, "below the limit it reverts, never succeeds empty");
    });
  });
});
