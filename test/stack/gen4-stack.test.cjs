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

  /** The real stack: market, pool with its seed node, a flat venue, the lane open, listings. */
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
      [manager.target, fx.market.target, admin.address, ethers.ZeroAddress, jar, 8, registry.target, settlement.target]);
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
    await fx.usdc.mint(manager.target, 1_000_000n * 10n ** 6n);
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
        : await router.connect(buyerEOA).swap(key, p, { takeClaims: false, settleUsingBurn: false }, "0x", gas);
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

    it("16 dead listings ahead of stock: a buy that needs it reverts; an independent prune clears the queue and the buy fills", async () => {
      const s = await stack();
      const sellers = [];
      for (let i = 0; i < 16; i++) { const w = await s.seller(TOK(60)); await (await s.list(w, TOK(60))).wait(); sellers.push(w); }
      await s.deposit(TOK(50)); // node 2, behind all 16 listings
      for (const w of sellers) await (await s.fx.token.connect(w).transfer(s.fx.signers.alice.address, TOK(60))).wait(); // all 16 die
      const buyer = s.fx.signers.buyerEOA;
      const p = { zeroForOne: s.zeroForOne, sqrtPriceLimitX96: s.zeroForOne ? MIN_SQRT : MAX_SQRT };
      // the seed (node 1) is at or below every snapshot and sells first; node 2 sits behind the 16 dead listings
      const seedOnly = await s.priceAll(GAS);
      let wall;
      try { await s.live.connect(buyer).swap.staticCall(s.key, { ...p, amountSpecified: -(seedOnly.charged * 2n) }, GAS); assert.fail("must revert"); }
      catch (e) { if (e.code === "ERR_ASSERTION") throw e; wall = s.shortfallOf(e); }
      console.log(`      16 dead listings: a buy past them reverts reason ${wall.reason} with ${wall.filled} filled (the seed)`);
      assert.equal(wall.reason, 7, "the attempt cap");
      // independent cleanup, in its own transactions, by anyone
      const keeper = s.fx.signers.alice;
      for (let id = 1n; id <= 16n; id++) await (await s.registry.connect(keeper).prune(id, GAS)).wait();
      for (let id = 1n; id <= 16n; id++) assert.equal((await s.registry.listing(id)).status, 3n, `L${id} retired by prune`);
      const all = await s.priceAll(GAS);
      assert.equal(all.filled, TOK(100) + TOK(50), "the seed and node 2 are now reachable");
      const rc = await s.buy({}, { buyAll: true });
      const f = fills(rc, s);
      assert.equal(f.reduce((t, x) => t + x.amount, 0n), TOK(150), "the buy past the cleared queue fills completely");
      console.log(`      after prune: filled ${f.reduce((t, x) => t + x.amount, 0n)}; gas ${rc.gasUsed}`);
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
