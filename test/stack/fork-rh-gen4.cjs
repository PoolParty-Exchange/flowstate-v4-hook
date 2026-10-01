/* JUP-698 gate 3: the Gen-4 hook on a fork of Robinhood Chain, with the LIVE Uniswap PoolManager and
 * Universal Router, the live FlowState market upgraded to the pinned build, and the live CASHCAT pool.
 *
 * Run from a PoolParty_Contracts checkout at the pinned commit (de4464f), against a local fork:
 *   npx hardhat node --config hardhat.test.config.js --fork $RH_RPC_URL --port 8546
 *   MANIFEST=build-b STOP_BEFORE_DRILLS=1 NODES=10 npx hardhat run deploy/rehearse-build-a.js --network rhfork --config hardhat.test.config.js
 *   HOOK_OUT=<hook repo>/out npx hardhat run --network rhfork --config hardhat.test.config.js <hook repo>/test/stack/fork-rh-gen4.cjs
 * Fork-only: the Safe's and the timelock's calls are made by impersonation; buyers, sellers and
 * depositors are throwaways funded from the live venues' balances. Nothing here touches a real chain.
 */
const path = require("node:path");
const fs = require("node:fs");
const { ethers, network } = require(path.resolve(process.cwd(), "node_modules/hardhat"));
const { deployListings } = require(path.resolve(process.cwd(), "deploy/lib/listings"));

if (network.name !== "rhfork") { console.error(`REFUSED: --network rhfork only (got ${network.name})`); process.exit(1); }
const OUT = process.env.HOOK_OUT;
if (!OUT) { console.error("REFUSED: set HOOK_OUT to the hook repo's forge out/ directory"); process.exit(1); }

const CASHCAT = "0x020bfc650a365f8bb26819deaabf3e21291018b4";
const ROBINCAT = "0xded852De9fe9bA9b6f27f39e8e81CF851A5C79cc";
const CASHCAT_WETH_V3 = "0xd42A491087a15E5afd51FEb3606066Cc152d2b09";
const ROBINCAT_WETH_V3 = "0xee0ba443f8871ea3f98b820410025a13213a1635";
const WETH_USDG_V3 = "0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca";
const V3_FACTORY = "0x1f7d7550B1b028f7571E69A784071F0205FD2EfA";
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const POOL_MANAGER = "0x8366a39CC670B4001A1121B8F6A443A643e40951";
const UNIVERSAL_ROUTER = "0x8876789976dEcBfCbBbe364623C63652db8C0904";
const TOKEN_JAR = "0x2aC03e14Cfe755426DaAEe0a4994184Ce81482F8";
const CREATE2 = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
const HOOK_FLAGS = 0x28ccn;
const MAX160 = (1n << 160n) - 1n;
const ZERO_PERMIT = { details: { token: ethers.ZeroAddress, amount: 0n, expiration: 0n, nonce: 0n }, spender: ethers.ZeroAddress, sigDeadline: 0n };
const ERC20 = ["function balanceOf(address) view returns (uint256)", "function transfer(address,uint256) returns (bool)", "function approve(address,uint256) returns (bool)"];
const V3_ABI = ["function increaseObservationCardinalityNext(uint16)", "function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)"];
const UR_ABI = ["function execute(bytes commands, bytes[] inputs, uint256 deadline) payable"];
const G = { gasLimit: 8_000_000 };
const SWAP_GAS = { gasLimit: 30_000_000 };
const V4_SWAP = "0x10";
const [SWAP_EXACT_IN_SINGLE, SWAP_EXACT_OUT_SINGLE, SETTLE, SETTLE_ALL, TAKE_ALL] = [0x06, 0x08, 0x0b, 0x0c, 0x0f];
const [V3_SWAP_EXACT_IN, SWEEP, WRAP_ETH, EXECUTE_SUB_PLAN, ALLOW_REVERT] = [0x00, 0x04, 0x0b, 0x21, 0x80];
const ADDRESS_THIS = "0x0000000000000000000000000000000000000002";
const MIN_SQRT = 4295128740n, MAX_SQRT = 1461446703485210103287273052203988822378723970341n;
const HOODRAT = "0x8e62F281f282686fCa6dCB39288069a93fC23F1c", TENDIES = "0x45242320DBB855EeA8Fd36804C6487E10E97FCF9";
const GEN3_HOOK = "0x1C74A4CA5cfD8C550E54be091aBda476Acffa8CC";

const send = (m, p) => network.provider.send(m, p);
const fail = (m) => { console.error(`\nABORT: ${m}`); process.exit(1); };
const ok = (m) => console.log(`   ✓ ${m}`);
const gasTable = [];
async function impersonate(addr) { await send("hardhat_impersonateAccount", [addr]); await send("hardhat_setBalance", [addr, "0x56BC75E2D63100000"]); return ethers.getSigner(addr); }
async function throwaway() { const w = ethers.Wallet.createRandom().connect(ethers.provider); await send("hardhat_setBalance", [w.address, "0x56BC75E2D63100000"]); return w; }
const now = async () => (await ethers.provider.getBlock("latest")).timestamp;
const artifact = (file, name) => { const a = JSON.parse(fs.readFileSync(path.join(OUT, file, name + ".json"), "utf8")); return { abi: a.abi, bytecode: a.bytecode.object }; };
const sortKey = (a, b) => (BigInt(a) < BigInt(b) ? [a, b] : [b, a]);
const coder = ethers.AbiCoder.defaultAbiCoder();
const KEY_T = "tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";

async function main() {
  const book = JSON.parse(fs.readFileSync(path.resolve(process.cwd(), "deploy/out.rh.json"), "utf8"));
  const m = await ethers.getContractAt("FlowstateMarket", book.market);
  try { await m.supplierRegistry(); } catch { fail("the fork does not carry the build; run rehearse-build-a.js with MANIFEST=build-b STOP_BEFORE_DRILLS=1 first"); }
  if (await m.paused()) fail("the market is paused");
  const admin = await impersonate(book.admin), tl48 = await impersonate(book.tl48);
  const [USDG, WETH] = book.quoteAssets;
  const weth = new ethers.Contract(WETH, ERC20, ethers.provider), cash = new ethers.Contract(CASHCAT, ERC20, ethers.provider), robin = new ethers.Contract(ROBINCAT, ERC20, ethers.provider);
  const permit2 = new ethers.Contract(PERMIT2, ["function approve(address token, address spender, uint160 amount, uint48 expiration)"], ethers.provider);
  const ur = new ethers.Contract(UNIVERSAL_ROUTER, UR_ABI, ethers.provider);
  const cashPoolAddr = await m.poolByToken(CASHCAT);
  const pool = await ethers.getContractAt("FlowstatePool", cashPoolAddr);
  console.log(`[0] fork block ${await ethers.provider.getBlockNumber()}; market ${book.market}; CASHCAT pool ${cashPoolAddr}; PoolManager ${POOL_MANAGER}; Universal Router ${UNIVERSAL_ROUTER}`);
  if ((await ethers.provider.getCode(CREATE2)) === "0x") fail("no CREATE2 deployer at the canonical address on this fork");
  await send("evm_increaseTime", [300]); await send("evm_mine", []);

  // ── setup: attribution ON (production intent), listings, the CASHCAT venue and lane ────────────
  const supplier = await (await ethers.getContractFactory("FlowstateSupplierRegistry", admin)).deploy(book.market, book.admin, true);
  await (await m.connect(tl48).setSupplierRegistry(supplier.target)).wait();
  const { settlement, registry } = await deployListings(ethers, book.market, PERMIT2, true, admin);
  await (await supplier.connect(admin).setPayer(settlement.target, true)).wait();
  await (await m.connect(admin).setRegistrarParams(25_000_000_000n, 20_000_000_000n, 723, V3_FACTORY)).wait();
  await (await m.connect(admin).setQuoteReference(USDG, USDG)).wait();
  await (await m.connect(admin).setQuoteReference(WETH, WETH_USDG_V3)).wait();
  await (await m.connect(admin).registerVenue(cashPoolAddr, CASHCAT_WETH_V3, { gasLimit: 20_000_000 })).wait();
  await (await m.connect(tl48).openPassiveLane(cashPoolAddr)).wait();
  const [why, rate] = await settlement.price(CASHCAT, WETH);
  if (why !== 0n) fail(`CASHCAT not sellable on the fork (why ${why})`);
  ok(`listings ${registry.target} / ${settlement.target}; supplier registry ${supplier.target} on; CASHCAT/WETH venue registered, lane open, rate ${rate}`);

  // ── the hook: live PoolManager, aeWETH as the native wrapper, the live TokenJar ────────────────
  const HK = artifact("FlowstateC1Hook.sol", "FlowstateC1Hook"), PM = artifact("PoolManager.sol", "PoolManager");
  const args = coder.encode(["address", "address", "address", "address", "address", "uint16", "address", "address"],
    [POOL_MANAGER, book.market, book.admin, WETH, TOKEN_JAR, 8, registry.target, settlement.target]);
  const initCode = HK.bytecode + args.slice(2), initHash = ethers.keccak256(initCode);
  let salt, hookAddr;
  for (let i = 0n; ; i++) { salt = ethers.zeroPadValue(ethers.toBeHex(i), 32); hookAddr = ethers.getCreate2Address(CREATE2, salt, initHash); if ((BigInt(hookAddr) & 0x3fffn) === HOOK_FLAGS && (await ethers.provider.getCode(hookAddr)) === "0x") break; }
  const deployer = await throwaway();
  await (await deployer.sendTransaction({ to: CREATE2, data: salt + initCode.slice(2), gasLimit: 29_000_000 })).wait();
  if ((await ethers.provider.getCode(hookAddr)) === "0x") fail("hook not deployed");
  const hook = new ethers.Contract(hookAddr, HK.abi, admin);
  const manager = new ethers.Contract(POOL_MANAGER, PM.abi, admin);
  await (await hook.registerPair(WETH, CASHCAT, cashPoolAddr, 16)).wait();
  await (await hook.registerPair(ethers.ZeroAddress, CASHCAT, cashPoolAddr, 16)).wait();
  const sweepTo = (await throwaway()).address;
  await (await hook.setSweepDestination(sweepTo)).wait();
  const keyOf = (a, b) => { const [c0, c1] = sortKey(a, b); return { currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: hookAddr }; };
  const cashKey = keyOf(WETH, CASHCAT), nativeKey = { currency0: ethers.ZeroAddress, currency1: CASHCAT, fee: 0, tickSpacing: 60, hooks: hookAddr };
  await (await manager.initialize(cashKey, 1n << 96n, G)).wait();
  await (await manager.initialize(nativeKey, 1n << 96n, G)).wait();
  // two-door shares (28 Sep 2026): while both ETH pairs are registered each sells only its share of the stock.
  // Sections 1-9 size one pair to the WHOLE stock, so the native-ETH pair is registered only for [4] and [10].
  await (await hook.unregisterPair(ethers.ZeroAddress, CASHCAT)).wait();
  ok(`hook ${hookAddr} (flags 0x28cc) via CREATE2; pairs CASHCAT/aeWETH and CASHCAT/ETH registered and initialised on the live PoolManager (CASHCAT/ETH unregistered outside [4] and [10])`);

  // ── Universal Router encoding (the live router's V4Router; struct shape detected by simulation) ─
  let withMinHop = true;
  const exactInParams = (key, zeroForOne, amountIn, minOut) => withMinHop
    ? coder.encode([`tuple(${KEY_T} poolKey,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,uint256 minHopPriceX36,bytes hookData)`], [[key, zeroForOne, amountIn, minOut, 0, "0x"]])
    : coder.encode([`tuple(${KEY_T} poolKey,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,bytes hookData)`], [[key, zeroForOne, amountIn, minOut, "0x"]]);
  const exactOutParams = (key, zeroForOne, amountOut, maxIn) => withMinHop
    ? coder.encode([`tuple(${KEY_T} poolKey,bool zeroForOne,uint128 amountOut,uint128 amountInMaximum,uint256 minHopPriceX36,bytes hookData)`], [[key, zeroForOne, amountOut, maxIn, 0, "0x"]])
    : coder.encode([`tuple(${KEY_T} poolKey,bool zeroForOne,uint128 amountOut,uint128 amountInMaximum,bytes hookData)`], [[key, zeroForOne, amountOut, maxIn, "0x"]]);
  const urCall = async (signer, key, inC, outC, kind, amount, bound, value = 0n, gas = SWAP_GAS) => {
    const zeroForOne = BigInt(inC) === BigInt(key.currency0);
    const actions = ethers.solidityPacked(["uint8", "uint8", "uint8"], [kind === "in" ? SWAP_EXACT_IN_SINGLE : SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL]);
    const p0 = kind === "in" ? exactInParams(key, zeroForOne, amount, bound) : exactOutParams(key, zeroForOne, amount, bound);
    const settleMax = kind === "in" ? amount : bound, takeMin = kind === "in" ? bound : amount;
    const inputs = [coder.encode(["bytes", "bytes[]"], [actions, [p0, coder.encode(["address", "uint256"], [inC, settleMax]), coder.encode(["address", "uint256"], [outC, takeMin])]])];
    const deadline = (await now()) + 600;
    return { run: () => ur.connect(signer).execute(V4_SWAP, inputs, deadline, { ...gas, value }), sim: () => ur.connect(signer).execute.staticCall(V4_SWAP, inputs, deadline, { ...gas, value }), est: () => ur.connect(signer).execute.estimateGas(V4_SWAP, inputs, deadline, { value }) };
  };

  // funding
  const cashSrc = await impersonate(CASHCAT_WETH_V3);
  const buyer = await throwaway();
  await (await weth.connect(cashSrc).transfer(buyer.address, 5n * 10n ** 18n)).wait();
  await (await weth.connect(buyer).approve(PERMIT2, ethers.MaxUint256)).wait();
  const far = BigInt((await now()) + 30 * 86400);
  await (await permit2.connect(buyer).approve(WETH, UNIVERSAL_ROUTER, MAX160, far)).wait();
  // WSR F5 (27 Sep 2026): exact input fills the whole slice or reverts. A slice is sized the way a
  // splitting aggregator sizes it: an oversized probe reverts ExactInputShortfall(filled, ...), then an
  // exact-output quote of `filled` tokens gives the exact price (the test-only live-delta router returns it).
  const LR = artifact("Gen4LiveDeltaRouter.sol", "Gen4LiveDeltaRouter");
  const live = await new ethers.ContractFactory(LR.abi, LR.bytecode, admin).deploy(POOL_MANAGER);
  await (await weth.connect(buyer).approve(live.target, ethers.MaxUint256)).wait();
  const WRAPPED = new ethers.Interface(["error WrappedError(address target, bytes4 selector, bytes reason, bytes details)"]);
  const shortfallOf = (e) => {
    let data = e.data ?? e.error?.data ?? e.info?.error?.data;
    if (data && typeof data === "object") data = data.data; // over the fork's JSON-RPC the revert data is nested once more
    const w = WRAPPED.parseError(data), inner = hook.interface.parseError(w.args.reason);
    return { name: inner.name, filled: inner.args[0], wanted: inner.args[1], reason: Number(inner.args[2]) };
  };
  const sizeAll = async (who, key, inC) => {
    const zfo = BigInt(inC) === BigInt(key.currency0), p = { zeroForOne: zfo, sqrtPriceLimitX96: zfo ? MIN_SQRT : MAX_SQRT };
    let filled;
    try { await live.connect(who).swap.staticCall(key, { ...p, amountSpecified: -(10n ** 20n) }, SWAP_GAS); fail("an oversized probe filled"); }
    catch (e) { if (e.code === undefined && String(e).includes("ABORT")) throw e; const sf = shortfallOf(e); if (sf.name !== "ExactInputShortfall") fail(`probe reverted ${sf.name}`); filled = sf.filled; }
    const [d0, d1] = await live.connect(who).swap.staticCall(key, { ...p, amountSpecified: filled }, SWAP_GAS);
    return { filled, charged: -(zfo ? d0 : d1) };
  };

  // detect the router's ExactInputSingleParams shape with a harmless simulation
  try { await (await urCall(buyer, cashKey, WETH, CASHCAT, "in", 1_000_000_000n, 0n)).sim(); }
  catch (e) { withMinHop = false; try { await (await urCall(buyer, cashKey, WETH, CASHCAT, "in", 1_000_000_000n, 0n)).sim(); withMinHop = false; } catch { withMinHop = true; } }
  console.log(`   Universal Router params: ${withMinHop ? "with" : "without"} minHopPriceX36`);

  const consentFloors = async (p) => { const out = []; for (const a of await p.seededAssets()) { const [r] = await p.anchorOf(a); out.push({ asset: a, minRate: r }); } return out; };
  const [anchorW] = await pool.anchorOf(WETH), [anchorU] = await pool.anchorOf(USDG);
  const minFor = async (asset, anchor) => { const f = await m.inventoryFloor(asset), c = await m.minContribution(asset); const need = f > c ? f : c; return (need * 10n ** 18n + anchor - 1n) / anchor; };
  const minTok = [await minFor(USDG, anchorU), await minFor(WETH, anchorW)].reduce((a, b) => (a < b ? a : b));
  const lot = minTok * 3n;
  const payer = await throwaway();
  await (await cash.connect(cashSrc).transfer(payer.address, lot * 20n)).wait();
  await (await cash.connect(payer).approve(book.market, ethers.MaxUint256)).wait();
  const deposit = async (amount) => { const owner = (await throwaway()).address; await (await m.connect(payer).contributeTokens(cashPoolAddr, amount, owner, await consentFloors(pool), G)).wait(); return owner; };
  const seller = async (token, src, amount) => { const s = await throwaway(); await (await new ethers.Contract(token, ERC20, src).transfer(s.address, amount)).wait(); await (await new ethers.Contract(token, ERC20, s).approve(PERMIT2, ethers.MaxUint256)).wait(); await (await permit2.connect(s).approve(token, settlement.target, MAX160, far)).wait(); return s; };
  const floorsW = [{ asset: USDG, minRate: (anchorU * 9n) / 10n }, { asset: WETH, minRate: (anchorW * 9n) / 10n }];
  const list = async (s, amount, token = CASHCAT, fl = floorsW) => { const rc = await (await registry.connect(s).list(token, amount, far - 86400n, ethers.ZeroHash, fl, ZERO_PERMIT, "0x", G)).wait(); return registry.interface.parseLog(rc.logs.find((l) => l.address.toLowerCase() === registry.target.toLowerCase() && registry.interface.parseLog(l)?.name === "Listed")).args.id; };

  const fills = (rc, p) => { const out = []; for (const log of rc.logs) { const a = log.address.toLowerCase(); try { if (a === p.target.toLowerCase()) { const e = p.interface.parseLog(log); if (e?.name === "PoolBuy") out.push({ src: "pool", amount: e.args[3], quote: e.args[4] }); } else if (a === settlement.target.toLowerCase()) { const e = settlement.interface.parseLog(log); if (e?.name === "ListingFilled") out.push({ src: "L" + e.args.id, amount: e.args.amount, quote: e.args.quotePaid }); } } catch {} } return out; };
  const hookEvents = (rc) => { let spread = 0n, dust = 0n, jar = 0n; for (const log of rc.logs) { if (log.address.toLowerCase() !== hookAddr.toLowerCase()) continue; try { const e = hook.interface.parseLog(log); if (e?.name === "BuyExecuted") { spread += e.args[6]; dust += e.args[7]; } if (e?.name === "ProtocolFeePaid") jar += e.args[2]; } catch {} } return { spread, dust, jar }; };
  /** executable inventory of the live queue's nodes at or below a snapshot */
  const boundedInventory = async (p, tail) => (await p.queue(50)).filter((n) => n.index <= tail).reduce((t, n) => t + (n.amount - n.pinned), 0n);

  // ── [1] one swap across live nodes, L1, a new deposit, L2 (exact input, WETH in) ───────────────
  console.log("\n[1] exact input through the Universal Router: live nodes > L1 > deposit > L2");
  const q0 = await pool.queue(50);
  console.log(`   live CASHCAT queue: ${q0.length} nodes (${q0.length ? q0[0].index + ".." + q0[q0.length - 1].index : "empty"}), maxBuy ${(await m.maxBuy(cashPoolAddr, WETH))[0]}`);
  await deposit(lot * 2n); // executable pool inventory ahead of L1 even if the live nodes sit under the floor
  const s1 = await seller(CASHCAT, cashSrc, lot), s2 = await seller(CASHCAT, cashSrc, lot);
  const L1 = await list(s1, lot);
  const bound1 = await boundedInventory(pool, (await registry.listing(L1)).poolTail);
  await deposit(lot * 2n);
  const L2 = await list(s2, lot);
  const bound2 = await boundedInventory(pool, (await registry.listing(L2)).poolTail);
  const jar0 = await weth.balanceOf(TOKEN_JAR), b0 = await weth.balanceOf(buyer.address), c0 = await cash.balanceOf(buyer.address);
  const urW0 = await weth.balanceOf(UNIVERSAL_ROUTER), urC0 = await cash.balanceOf(UNIVERSAL_ROUTER), hk0 = await weth.balanceOf(hookAddr);
  const sized1 = await sizeAll(buyer, cashKey, WETH); // the whole stock, sized as an aggregator would
  const budget = sized1.charged;
  const call1 = await urCall(buyer, cashKey, WETH, CASHCAT, "in", budget, 1n);
  const rc1 = await (await call1.run()).wait();
  const f1 = fills(rc1, pool), h1 = hookEvents(rc1);
  const order1 = f1.map((x) => x.src);
  console.log(`   order: ${order1.join(" > ")}; gas ${rc1.gasUsed}`);
  const iL1 = order1.indexOf("L" + L1), iL2 = order1.indexOf("L" + L2);
  if (iL1 < 0 || iL2 < 0 || iL2 < iL1) fail(`L1 then L2 expected: ${order1}`);
  const poolBefore = (i) => f1.slice(0, i).filter((x) => x.src === "pool").reduce((t, x) => t + x.amount, 0n);
  if (poolBefore(iL1) > bound1) fail(`pool sold ${poolBefore(iL1)} before L1, more than the ${bound1} queued ahead of it`);
  if (poolBefore(iL2) > bound2) fail(`pool sold ${poolBefore(iL2)} before L2, more than the ${bound2} queued ahead of it`);
  const paid1 = b0 - (await weth.balanceOf(buyer.address)), got1 = (await cash.balanceOf(buyer.address)) - c0;
  const sources1 = f1.reduce((t, x) => t + x.quote, 0n);
  if (got1 !== f1.reduce((t, x) => t + x.amount, 0n)) fail("buyer's CASHCAT differs from the fills");
  if (paid1 !== sources1 + h1.spread + h1.jar + h1.dust) fail(`conservation: paid ${paid1} vs ${sources1} + ${h1.spread} + ${h1.jar} + ${h1.dust}`);
  if (paid1 !== budget) fail(`exact input must charge the whole slice: paid ${paid1} of ${budget}`);
  if (got1 !== sized1.filled) fail(`the slice was not filled completely: ${got1} of ${sized1.filled}`);
  if ((await weth.balanceOf(TOKEN_JAR)) - jar0 !== h1.jar || h1.jar === 0n) fail("TokenJar fee not received as reported");
  if ((await weth.balanceOf(UNIVERSAL_ROUTER)) !== urW0 || (await cash.balanceOf(UNIVERSAL_ROUTER)) !== urC0) fail("the router kept a balance");
  if ((await weth.balanceOf(hookAddr)) - hk0 !== h1.spread + h1.dust || (await cash.balanceOf(hookAddr)) !== 0n) fail("the hook holds more than its spread and dust");
  gasTable.push(["UR exact input, live nodes + L1 + deposit + L2", rc1.gasUsed]);
  ok(`sold ${ethers.formatUnits(got1, 18)} CASHCAT for ${ethers.formatUnits(paid1, 18)} WETH (the slice sized to the whole stock, filled completely); pool never sold past a listing's snapshot; jar ${h1.jar}, spread ${h1.spread}, dust ${h1.dust}; router and hook keep nothing else`);

  // ── [2] minimum output: the router refuses and nothing changes ─────────────────────────────────
  console.log("\n[2] minimum output");
  const s3 = await seller(CASHCAT, cashSrc, lot); const L3 = await list(s3, lot);
  const qBefore = JSON.stringify((await pool.queue(50)).map((n) => [n.index.toString(), n.amount.toString()])), lBefore = (await registry.listing(L3)).remaining;
  const call2 = await urCall(buyer, cashKey, WETH, CASHCAT, "in", 10n ** 16n, 10n ** 30n);
  let refused = false; try { await (await call2.run()).wait(); } catch { refused = true; }
  if (!refused) fail("a swap below its minimum output went through");
  if (JSON.stringify((await pool.queue(50)).map((n) => [n.index.toString(), n.amount.toString()])) !== qBefore || (await registry.listing(L3)).remaining !== lBefore) fail("state changed on a refused swap");
  ok("a swap below its minimum output reverts at the router; queue and listing unchanged");

  // ── [3] exact output across a listing and a deposit ────────────────────────────────────────────
  console.log("\n[3] exact output through the Universal Router");
  await deposit(lot);
  const target = lot + lot / 2n; // all of L3 (ahead) and part of the deposit behind it, or pool inventory first
  const cBefore = await cash.balanceOf(buyer.address), wBefore = await weth.balanceOf(buyer.address);
  const call3 = await urCall(buyer, cashKey, WETH, CASHCAT, "out", target, 10n ** 19n);
  const rc3 = await (await call3.run()).wait();
  const f3 = fills(rc3, pool), h3 = hookEvents(rc3);
  const got3 = (await cash.balanceOf(buyer.address)) - cBefore, paid3 = wBefore - (await weth.balanceOf(buyer.address));
  console.log(`   order: ${f3.map((x) => x.src).join(" > ")}; gas ${rc3.gasUsed}`);
  if (got3 !== target) fail(`exact output delivered ${got3}, not ${target}`);
  if (paid3 !== f3.reduce((t, x) => t + x.quote, 0n) + h3.spread + h3.jar + h3.dust) fail("exact output conservation");
  gasTable.push(["UR exact output across sources", rc3.gasUsed]);
  ok(`delivered exactly ${ethers.formatUnits(target, 18)} CASHCAT for ${ethers.formatUnits(paid3, 18)} WETH`);

  // ── [4] native ETH in (the hook wraps into aeWETH) ─────────────────────────────────────────────
  console.log("\n[4] native ETH exact input");
  await (await hook.registerPair(ethers.ZeroAddress, CASHCAT, cashPoolAddr, 16)).wait(); // both ETH pairs: native 80% (the default)
  const s4 = await seller(CASHCAT, cashSrc, lot); await list(s4, lot);
  const ethIn = ((lot / 2n) * rate) / 10n ** 18n; // well inside what is queued: a full fill
  const cN = await cash.balanceOf(buyer.address), hkW = await weth.balanceOf(hookAddr);
  const call4 = await urCall(buyer, nativeKey, ethers.ZeroAddress, CASHCAT, "in", ethIn, 1n, ethIn);
  const rc4 = await (await call4.run()).wait();
  const f4 = fills(rc4, pool), h4 = hookEvents(rc4), gotN = (await cash.balanceOf(buyer.address)) - cN;
  console.log(`   order: ${f4.map((x) => x.src).join(" > ")}; gas ${rc4.gasUsed}`);
  if (gotN === 0n || gotN !== f4.reduce((t, x) => t + x.amount, 0n)) fail("native swap delivered nothing or not the fills");
  if (ethIn !== f4.reduce((t, x) => t + x.quote, 0n) + h4.spread + h4.jar + h4.dust) fail("native conservation");
  if ((await ethers.provider.getBalance(hookAddr)) !== 0n) fail("the hook holds native ETH");
  await (await hook.unregisterPair(ethers.ZeroAddress, CASHCAT)).wait();
  if ((await weth.balanceOf(hookAddr)) - hkW !== h4.spread + h4.dust) fail("native: hook's aeWETH moved by more than spread and dust");
  gasTable.push(["UR native ETH exact input", rc4.gasUsed]);
  ok(`${ethers.formatUnits(ethIn, 18)} ETH bought ${ethers.formatUnits(gotN, 18)} CASHCAT; margin held in aeWETH, no native left on the hook`);

  // ── [5] the other V4 ordering: ROBINCAT (WETH is currency0) with a seeded pool and a listing ──
  console.log("\n[5] ROBINCAT: WETH is currency0 (zeroForOne), seed first then the listing");
  if ((await m.poolByToken(ROBINCAT)) !== ethers.ZeroAddress) fail("ROBINCAT already has a pool on this fork");
  const robinSrc = await impersonate(ROBINCAT_WETH_V3);
  const oracle = await ethers.getContractAt(["function getRate(address,address,bool) view returns (uint256)"], book.oracle);
  const rU = await oracle.getRate(ROBINCAT, USDG, false), rW = await oracle.getRate(ROBINCAT, WETH, false);
  const fU = (await m.inventoryFloor(USDG)) > (await m.minContribution(USDG)) ? await m.inventoryFloor(USDG) : await m.minContribution(USDG);
  const minR = (fU * 10n ** 18n + rU - 1n) / rU;
  const seeder = await seller(ROBINCAT, robinSrc, minR * 8n);
  const rFloors = [{ asset: USDG, minRate: (rU * 9n) / 10n }, { asset: WETH, minRate: (rW * 9n) / 10n }];
  await (await registry.connect(seeder).listAndSeed(ROBINCAT, minR * 2n, minR * 4n, far - 86400n, ethers.ZeroHash, rFloors, ZERO_PERMIT, "0x", G)).wait();
  const rPoolAddr = await m.poolByToken(ROBINCAT), rPool = await ethers.getContractAt("FlowstatePool", rPoolAddr);
  const rv = new ethers.Contract(ROBINCAT_WETH_V3, V3_ABI, admin);
  const [, , , , cardNext] = await rv.slot0();
  for (let n = Number(cardNext) + 100; n <= 3600; n += 100) await (await rv.increaseObservationCardinalityNext(Math.min(n, 3600), { gasLimit: 5_000_000 })).wait();
  if (Number((await rv.slot0())[4]) < 3600) await (await rv.increaseObservationCardinalityNext(3600, { gasLimit: 5_000_000 })).wait();
  // Depth floors for this section only: $100 to open, $80 to stay (fork fixture). The live ROBINCAT/WETH
  // venue is thin (0.101 WETH of depth at block 72,839,953, 0.325 at 72,856,778), and this section tests the hook with WETH as
  // currency0, not venue qualification. The measured depth is printed below.
  await (await m.connect(admin).setRegistrarParams(100_000_000n, 80_000_000n, 723, V3_FACTORY)).wait();
  await (await m.connect(admin).registerVenue(rPoolAddr, ROBINCAT_WETH_V3, { gasLimit: 20_000_000 })).wait();
  const rVenue = await m.evaluateVenue(rPoolAddr);
  console.log(`   venue depth ${ethers.formatUnits(rVenue.depthQuote, 18)} WETH; depthOk ${rVenue.depthOk} (fork floors $100 open / $80 stay)`);
  await (await m.connect(tl48).openPassiveLane(rPoolAddr)).wait();
  const [rWhy, rRate] = await settlement.price(ROBINCAT, WETH);
  if (rWhy !== 0n) {
    fail(`ROBINCAT not sellable on this fork (why ${rWhy}): the WETH-as-currency0 case was not exercised`);
  } else {
    await (await hook.registerPair(WETH, ROBINCAT, rPoolAddr, 16)).wait();
    const rKey = keyOf(WETH, ROBINCAT);
    if (BigInt(rKey.currency0) !== BigInt(WETH)) fail("expected WETH as currency0 for ROBINCAT");
    await (await manager.initialize(rKey, 1n << 96n, G)).wait();
    const rB = await robin.balanceOf(buyer.address);
    const rIn = (minR * 5n * rRate) / 10n ** 18n; // more than the seed: reaches into the listing
    const call5 = await urCall(buyer, rKey, WETH, ROBINCAT, "in", rIn, 1n);
    const rc5 = await (await call5.run()).wait();
    const f5 = fills(rc5, rPool), order5 = f5.map((x) => x.src);
    console.log(`   order: ${order5.join(" > ")}; gas ${rc5.gasUsed}`);
    if (order5[0] !== "pool" || !order5.some((x) => x.startsWith("L"))) fail(`seed first then the listing expected: ${order5}`);
    if ((await robin.balanceOf(buyer.address)) - rB !== f5.reduce((t, x) => t + x.amount, 0n)) fail("ROBINCAT delivery");
    gasTable.push(["UR exact input, ROBINCAT (WETH currency0)", rc5.gasUsed]);
    ok(`bought ${ethers.formatUnits((await robin.balanceOf(buyer.address)) - rB, 18)} ROBINCAT: the seed, then the listing`);
  }

  // ── [6] gas estimate against use, and the owner's sweep ────────────────────────────────────────
  console.log("\n[6] gas estimate and sweep");
  const small = await urCall(buyer, cashKey, WETH, CASHCAT, "in", ((minTok / 4n) * rate) / 10n ** 18n, 1n);
  const est = await small.est();
  const rc6 = await (await small.run()).wait();
  gasTable.push(["UR small exact input (estimate " + est + ")", rc6.gasUsed]);
  ok(`eth_estimateGas ${est} for a small buy that used ${rc6.gasUsed} (${(Number(est) / Number(rc6.gasUsed)).toFixed(2)}x)`);
  const margin = await weth.balanceOf(hookAddr);
  await (await hook.sweepMargin(WETH)).wait();
  if ((await weth.balanceOf(sweepTo)) !== margin || (await weth.balanceOf(hookAddr)) !== 0n) fail("sweep");
  ok(`owner swept ${ethers.formatUnits(margin, 18)} aeWETH of margin; the hook holds nothing`);

  // ── [7] Wilko's router plans: the router holds the input (WRAP_ETH, and USDG -> WETH on V3 first) ─────
  console.log("\n[7] router-held input through the live Universal Router: exact, oversized, allow-revert with and without SWEEP");
  const zfoW = BigInt(WETH) === BigInt(cashKey.currency0);
  const ethOf = (a) => ethers.provider.getBalance(a);
  const urState = async () => ({ eth: await ethOf(UNIVERSAL_ROUTER), weth: await weth.balanceOf(UNIVERSAL_ROUTER), usdg: await usdg.balanceOf(UNIVERSAL_ROUTER), cash: await cash.balanceOf(UNIVERSAL_ROUTER) });
  const sameUr = (a, b) => a.eth === b.eth && a.weth === b.weth && a.usdg === b.usdg && a.cash === b.cash;
  const usdg = new ethers.Contract(USDG, ERC20, ethers.provider);
  const strangerSweep = async () => {
    const st = await throwaway(), w0 = await weth.balanceOf(st.address), e0 = await ethOf(st.address);
    const ins = [coder.encode(["address", "address", "uint256"], [WETH, st.address, 0n]), coder.encode(["address", "address", "uint256"], [ethers.ZeroAddress, st.address, 0n])];
    const rc = await (await ur.connect(st).execute(ethers.solidityPacked(["uint8", "uint8"], [SWEEP, SWEEP]), ins, (await now()) + 600, { gasLimit: 400_000 })).wait();
    return { weth: (await weth.balanceOf(st.address)) - w0, eth: (await ethOf(st.address)) - e0 + rc.gasUsed * rc.gasPrice };
  };
  const v4RouterPays = (amount) => coder.encode(["bytes", "bytes[]"], [ethers.solidityPacked(["uint8", "uint8", "uint8"], [SETTLE, SWAP_EXACT_IN_SINGLE, TAKE_ALL]),
    [coder.encode(["address", "uint256", "bool"], [WETH, amount, false]), exactInParams(cashKey, zfoW, amount, 1n), coder.encode(["address", "uint256"], [CASHCAT, 1n])]]);
  const subPlan = (v4Input) => coder.encode(["bytes", "bytes[]"], [ethers.solidityPacked(["uint8"], [0x10]), [v4Input]]);
  const sweepBack = (to) => coder.encode(["address", "address", "uint256"], [WETH, to, 0n]);
  const plan = async (who, cmds, inputs, value) => (await ur.connect(who).execute(ethers.solidityPacked(cmds.map(() => "uint8"), cmds), inputs, (await now()) + 600, { ...SWAP_GAS, value })).wait();
  // a USDG payer for the multi-step route
  const usdgSrc = await impersonate(WETH_USDG_V3);
  const payerU = await throwaway();
  await (await usdg.connect(usdgSrc).transfer(payerU.address, 50_000n * 10n ** 6n)).wait();
  await (await usdg.connect(payerU).approve(PERMIT2, ethers.MaxUint256)).wait();
  await (await permit2.connect(payerU).approve(USDG, UNIVERSAL_ROUTER, MAX160, far)).wait();
  const [sqrtWU] = await new ethers.Contract(WETH_USDG_V3, V3_ABI, ethers.provider).slot0(); // token0 aeWETH, token1 USDG
  const usdgPerWeth = (sqrtWU * sqrtWU * 10n ** 18n) / (1n << 192n); // USDG raw per 1 WETH
  // this router build's V3_SWAP_EXACT_IN takes a per-hop price floor array after payerIsUser (empty = none)
  const v3In = (usdgAmount, recipient) => coder.encode(["address", "uint256", "uint256", "bytes", "bool", "uint256[]"],
    [recipient, usdgAmount, 0n, ethers.solidityPacked(["address", "uint24", "address"], [USDG, 100, WETH]), true, []]);
  const v4AfterV3 = coder.encode(["bytes", "bytes[]"], [ethers.solidityPacked(["uint8", "uint8", "uint8"], [SETTLE, SWAP_EXACT_IN_SINGLE, TAKE_ALL]),
    [coder.encode(["address", "uint256", "bool"], [WETH, 1n << 255n, false]), exactInParams(cashKey, zfoW, 0n, 1n), coder.encode(["address", "uint256"], [CASHCAT, 1n])]]);
  const rows7 = [];
  const case7 = async (label, fn) => { const r = await fn(); rows7.push([label, r]); console.log(`   ${label}: ${r}`); };
  const freshStock = async () => { const sx = await seller(CASHCAT, cashSrc, lot); await list(sx, lot); return sizeAll(buyer, cashKey, WETH); };

  await case7("a. WRAP_ETH, slice = our stock", async () => {
    const st = await freshStock(), u0 = await urState(), b = await throwaway(), c0 = await cash.balanceOf(b.address);
    await plan(b, [WRAP_ETH, 0x10], [coder.encode(["address", "uint256"], [ADDRESS_THIS, st.charged]), v4RouterPays(st.charged)], st.charged);
    const got = (await cash.balanceOf(b.address)) - c0;
    if (got !== st.filled) fail("7a: slice not filled completely"); if (!sameUr(u0, await urState())) fail("7a: the router kept a balance");
    return `filled ${ethers.formatUnits(got, 18)} CASHCAT completely; router unchanged`;
  });
  await case7("b. WRAP_ETH 10 ETH, oversized, no allow-revert", async () => {
    await freshStock(); const u0 = await urState(), b = await throwaway(), e0 = await ethOf(b.address);
    let reverted = false; try { await plan(b, [WRAP_ETH, 0x10], [coder.encode(["address", "uint256"], [ADDRESS_THIS, 10n ** 19n]), v4RouterPays(10n ** 19n)], 10n ** 19n); } catch { reverted = true; }
    if (!reverted) fail("7b: an oversized slice went through"); if (!sameUr(u0, await urState())) fail("7b: the router kept a balance");
    return `whole transaction reverted; buyer's 10 ETH never left (balance change ${ethers.formatUnits((await ethOf(b.address)) - e0, 18)} ETH, gas only); router unchanged`;
  });
  await case7("c0. WRAP_ETH 10 ETH, oversized, allow-revert flag set directly on V4_SWAP", async () => {
    const u0 = await urState(), b = await throwaway();
    let reverted = false; try { await plan(b, [WRAP_ETH, 0x10 | ALLOW_REVERT], [coder.encode(["address", "uint256"], [ADDRESS_THIS, 10n ** 19n]), v4RouterPays(10n ** 19n)], 10n ** 19n); } catch { reverted = true; }
    if (!sameUr(u0, await urState())) fail("7c0: the router kept a balance");
    return reverted ? "the flag does not catch V4_SWAP on this router: the whole transaction reverted; router unchanged" : "the flag caught it (unexpected)";
  });
  await case7("c. WRAP_ETH 10 ETH, oversized, our swap inside a sub-plan allowed to fail, NO sweep", async () => {
    const u0 = await urState(), b = await throwaway();
    await plan(b, [WRAP_ETH, EXECUTE_SUB_PLAN | ALLOW_REVERT], [coder.encode(["address", "uint256"], [ADDRESS_THIS, 10n ** 19n]), subPlan(v4RouterPays(10n ** 19n))], 10n ** 19n);
    const u1 = await urState(), left = u1.weth - u0.weth, sw = await strangerSweep();
    return `transaction succeeded, our swap reverted inside it; ${ethers.formatUnits(left, 18)} aeWETH left in the router by the PLAN; a stranger's SWEEP took ${ethers.formatUnits(sw.weth, 18)} aeWETH`;
  });
  await case7("d. same as c, plus SWEEP of aeWETH back to the buyer", async () => {
    const u0 = await urState(), b = await throwaway(), w0 = await weth.balanceOf(b.address);
    await plan(b, [WRAP_ETH, EXECUTE_SUB_PLAN | ALLOW_REVERT, SWEEP], [coder.encode(["address", "uint256"], [ADDRESS_THIS, 10n ** 19n]), subPlan(v4RouterPays(10n ** 19n)), sweepBack(b.address)], 10n ** 19n);
    const back = (await weth.balanceOf(b.address)) - w0, sw = await strangerSweep();
    if (!sameUr(u0, await urState())) fail("7d: the router kept a balance");
    return `buyer's own sweep returned ${ethers.formatUnits(back, 18)} aeWETH; router unchanged; a stranger's SWEEP took ${ethers.formatUnits(sw.weth, 18)}`;
  });
  await case7("e. USDG -> WETH on V3 to the router, then our pool, slice inside our stock", async () => {
    const st = await freshStock(), u0 = await urState(), c0 = await cash.balanceOf(payerU.address), usd0 = await usdg.balanceOf(payerU.address);
    const usdgIn = (st.charged / 2n) * usdgPerWeth / 10n ** 18n; // about half the stock's value: the V3 output stays inside it
    await plan(payerU, [V3_SWAP_EXACT_IN, 0x10], [v3In(usdgIn, ADDRESS_THIS), v4AfterV3], 0n);
    const got = (await cash.balanceOf(payerU.address)) - c0;
    if (got === 0n) fail("7e: nothing bought"); if (!sameUr(u0, await urState())) fail("7e: the router kept a balance");
    return `${ethers.formatUnits(usd0 - (await usdg.balanceOf(payerU.address)), 6)} USDG -> ${ethers.formatUnits(got, 18)} CASHCAT; router unchanged`;
  });
  await case7("f. USDG -> WETH -> our pool, oversized, no allow-revert", async () => {
    await freshStock(); const u0 = await urState(), usd0 = await usdg.balanceOf(payerU.address);
    let reverted = false; try { await plan(payerU, [V3_SWAP_EXACT_IN, 0x10], [v3In(20_000n * 10n ** 6n, ADDRESS_THIS), v4AfterV3], 0n); } catch { reverted = true; }
    if (!reverted) fail("7f: an oversized multi-step went through"); if (!sameUr(u0, await urState()) || (await usdg.balanceOf(payerU.address)) !== usd0) fail("7f: funds moved");
    return "whole transaction reverted; buyer's USDG unchanged; router unchanged";
  });
  await case7("g. same as f, our swap inside a sub-plan allowed to fail, NO sweep", async () => {
    const u0 = await urState();
    await plan(payerU, [V3_SWAP_EXACT_IN, EXECUTE_SUB_PLAN | ALLOW_REVERT], [v3In(20_000n * 10n ** 6n, ADDRESS_THIS), subPlan(v4AfterV3)], 0n);
    const left = (await weth.balanceOf(UNIVERSAL_ROUTER)) - u0.weth, sw = await strangerSweep();
    return `V3 leg ran, our swap reverted; ${ethers.formatUnits(left, 18)} aeWETH left in the router by the PLAN; a stranger's SWEEP took ${ethers.formatUnits(sw.weth, 18)}`;
  });
  await case7("h. same as g, plus SWEEP of aeWETH back to the buyer", async () => {
    const u0 = await urState(), w0 = await weth.balanceOf(payerU.address);
    await plan(payerU, [V3_SWAP_EXACT_IN, EXECUTE_SUB_PLAN | ALLOW_REVERT, SWEEP], [v3In(20_000n * 10n ** 6n, ADDRESS_THIS), subPlan(v4AfterV3), sweepBack(payerU.address)], 0n);
    const back = (await weth.balanceOf(payerU.address)) - w0, sw = await strangerSweep();
    if (!sameUr(u0, await urState())) fail("7h: the router kept a balance");
    return `buyer's own sweep returned ${ethers.formatUnits(back, 18)} aeWETH; router unchanged; a stranger's SWEEP took ${ethers.formatUnits(sw.weth, 18)}`;
  });
  ok("router-held input: an exact slice fills; an oversized slice reverts the whole transaction; only a plan that wraps our swap in an allowed-to-fail sub-plan AND omits a sweep leaves its own funds in the router");

  // ── [8] Gen-3 pairs on the deployed gen-3 hook (must all be unregistered before any passive lane reopens) ──
  console.log("\n[8] gen-3 pairs on " + GEN3_HOOK);
  const g3 = new ethers.Contract(GEN3_HOOK, ["function pairs(bytes32) view returns (address marketPool, bool quoteIsCurrency0, bool registered, uint16 baseSpreadBps, address marketAsset)"], ethers.provider);
  const pk = (a, b) => { const [c0, c1] = sortKey(a, b); return ethers.keccak256(coder.encode(["address", "address"], [c0, c1])); };
  const g3pairs = [["CASHCAT/WETH", CASHCAT, WETH], ["CASHCAT/USDG", CASHCAT, USDG], ["HOODRAT/WETH", HOODRAT, WETH], ["HOODRAT/USDG", HOODRAT, USDG], ["TENDIES/USDG", TENDIES, USDG], ["TENDIES/WETH", TENDIES, WETH]];
  let stillRegistered = 0;
  for (const [label, a, b] of g3pairs) { const r = await g3.pairs(pk(a, b)); if (r.registered) stillRegistered++; console.log(`   ${label}: registered ${r.registered}`); }
  if (process.env.PREOPEN && stillRegistered) fail(`${stillRegistered} gen-3 pairs still registered: unregister all six before any passive lane reopens`);
  ok(`${stillRegistered} of 6 gen-3 pairs registered on this fork (the live state; the cutover unregisters all six before a passive lane reopens; PREOPEN=1 makes this a hard gate)`);

  // ── [9] gas matrix through the live Universal Router: gas used, estimate, lowest limit that fills ──
  console.log("\n[9] gas matrix (each case sized to the whole stock; under all-or-nothing a limit fills completely or reverts)");
  const matrix = [];
  // GAS_MARKS=1 with a measurement-only hook build that emits GasMark(tag, gasleft()) around every part of a
  // swap (never the production hook): prints what each part cost inside this matrix case.
  const MARK = ethers.id("GasMark(uint8,uint256)");
  const gasMarks = async (label, amount) => {
    const sn = await send("evm_snapshot", []);
    try {
      const c = await urCall(buyer, cashKey, WETH, CASHCAT, "in", amount, 1n, 0n, { gasLimit: 30_000_000 });
      const rc = await (await c.run()).wait();
      const marks = rc.logs.filter((l) => l.address.toLowerCase() === hookAddr.toLowerCase() && l.topics[0] === MARK).map((l) => coder.decode(["uint8", "uint256"], l.data)).map(([t, g]) => [Number(t), Number(g)]);
      const out = { attemptReads: [], poolLegs: [], listingLegs: [] };
      for (let i = 0; i < marks.length; i++) {
        const [t, g] = marks[i], next = marks[i + 1];
        if (t === 1 && next && (next[0] === 2 || next[0] === 4)) out.attemptReads.push(g - next[1]);
        if (t === 2 && next && next[0] === 3) out.poolLegs.push(g - next[1]);
        if (t === 4 && next && next[0] === 5) out.listingLegs.push(g - next[1]);
        if (t === 0) out.hookEntry = g;
        if (t === 6) out.loopEnd = g;
        if (t === 8) out.hookExit = g;
      }
      out.finalisation = out.loopEnd - out.hookExit;
      out.hookTotal = out.hookEntry - out.hookExit;
      out.outsideHook = Number(rc.gasUsed) - out.hookTotal;
      console.log(`     marks ${label}: ${JSON.stringify(out)}`);
    } finally { await send("evm_revert", [sn]); }
  };
  const measure = async (label, setup) => {
    const snap = await send("evm_snapshot", []);
    try {
      await setup();
      const st = await sizeAll(buyer, cashKey, WETH);
      const call = await urCall(buyer, cashKey, WETH, CASHCAT, "in", st.charged, 1n);
      const est = await call.est();
      const at = async (gasLimit) => {
        const sn = await send("evm_snapshot", []);
        try { const c = await urCall(buyer, cashKey, WETH, CASHCAT, "in", st.charged, 1n, 0n, { gasLimit }); const rc = await (await c.run()).wait(); return { ok: rc.status === 1, used: rc.gasUsed }; }
        catch { return { ok: false }; }
        finally { await send("evm_revert", [sn]); }
      };
      const full = await at(30_000_000);
      if (!full.ok) fail(`${label}: does not fill at 30M`);
      let lo = 300_000, hi = 30_000_000;
      while (hi - lo > 25_000) { const mid = Math.floor((lo + hi) / 2); if ((await at(mid)).ok) hi = mid; else lo = mid; }
      const used = Number(full.used);
      if (process.env.GAS_MARKS) await gasMarks(label, st.charged);
      matrix.push([label, used, Number(est), hi]);
      console.log(`   ${label}: used ${used}, estimate ${est} (${(Number(est) / used).toFixed(2)}x), lowest limit that fills ${hi} (${(hi / used).toFixed(2)}x used)`);
    } finally { await send("evm_revert", [snap]); }
  };
  await measure("pool only (1 deposit)", async () => { await deposit(lot * 2n); });
  await measure("pool (1 deposit) + 1 listing", async () => { await deposit(lot * 2n); const a = await seller(CASHCAT, cashSrc, lot); await list(a, lot); });
  await measure("pool (1 deposit) + 2 listings", async () => { await deposit(lot * 2n); const a = await seller(CASHCAT, cashSrc, lot), b = await seller(CASHCAT, cashSrc, lot); await list(a, lot); await list(b, lot); });
  await measure("pool (1 deposit) + 1 dead + 1 live listing", async () => {
    await deposit(lot * 2n); const a = await seller(CASHCAT, cashSrc, lot), b = await seller(CASHCAT, cashSrc, lot); await list(a, lot); await list(b, lot);
    await (await cash.connect(a).transfer(cashSrc.address, lot)).wait(); // the first listing dies
  });
  await measure("pool (5 deposits)", async () => { for (let i = 0; i < 5; i++) await deposit(lot); });

  // ── [10] design E: two ETH Uniswap pools on one C1 pool (native main door at 60%, aeWETH second door) ──
  console.log("\n[10] design E: ETH/CASHCAT (main door, 60%) and aeWETH/CASHCAT (second door) on one C1 pool");
  {
    await (await hook.registerPair(ethers.ZeroAddress, CASHCAT, cashPoolAddr, 16)).wait(); // both pools were initialised at setup, so both are open
    await (await hook.setNativeShare(cashPoolAddr, 6000)).wait();
    await deposit(lot * 4n);
    const L10 = await seller(CASHCAT, cashSrc, lot); await list(L10, lot);
    const maxIn = async (key, inC) => {
      const value = (a) => (inC === ethers.ZeroAddress ? a : 0n);
      let lo = 0n, hi = 10n ** 19n;
      while (hi - lo > 10n ** 9n) {
        const mid = (lo + hi) / 2n;
        try { await (await urCall(buyer, key, inC, CASHCAT, "in", mid, 1n, value(mid))).sim(); lo = mid; } catch { hi = mid; }
      }
      return lo;
    };
    const tokensAt = async (key, inC, amount) => { const c0 = await cash.balanceOf(buyer.address); const sn = await send("evm_snapshot", []); try { await (await (await urCall(buyer, key, inC, CASHCAT, "in", amount, 1n, inC === ethers.ZeroAddress ? amount : 0n)).run()).wait(); return (await cash.balanceOf(buyer.address)) - c0; } finally { await send("evm_revert", [sn]); } };
    // expected second-door budget from the rule: K = one inventory floor in tokens; second = 40% of (deposits - K), less K
    const [, rate10] = await settlement.price(CASHCAT, WETH);
    const floorW = await m.inventoryFloor(WETH);
    const K = (floorW * 10n ** 18n + rate10 - 1n) / rate10;
    const [deposits] = await m.maxBuy(cashPoolAddr, WETH);
    const shareable = deposits > K ? deposits - K : 0n;
    const secondRaw = (shareable * 4000n) / 10000n, second = secondRaw > K ? secondRaw - K : 0n, mainDeposits = shareable - second;
    const nIn = await maxIn(nativeKey, ethers.ZeroAddress), wIn = await maxIn(cashKey, WETH);
    const nTok = await tokensAt(nativeKey, ethers.ZeroAddress, nIn), wTok = await tokensAt(cashKey, WETH, wIn);
    console.log(`   deposits ${ethers.formatUnits(deposits, 18)} CASHCAT, K ${ethers.formatUnits(K, 18)}: second-door budget ${ethers.formatUnits(second, 18)}, main-door deposit budget ${ethers.formatUnits(mainDeposits, 18)}`);
    console.log(`   largest slice: ETH/CASHCAT (main) ${ethers.formatUnits(nTok, 18)} CASHCAT, aeWETH/CASHCAT (second) ${ethers.formatUnits(wTok, 18)} CASHCAT`);
    const off = wTok > second ? wTok - second : second - wTok;
    if (second === 0n ? wTok !== 0n : off * 1000n > second) fail(`10: second door ${wTok} is not its budget ${second}`);
    if (nTok <= mainDeposits) fail(`10: main door ${nTok} did not add listings to its deposit budget ${mainDeposits}`);
    const both = (first) => {
      const sw = [[nativeKey, true, nIn], [cashKey, BigInt(WETH) === BigInt(cashKey.currency0), wIn]];
      const ord = first === "main" ? sw : [sw[1], sw[0]];
      const actions = ethers.solidityPacked(["uint8", "uint8", "uint8", "uint8", "uint8"], [SWAP_EXACT_IN_SINGLE, SWAP_EXACT_IN_SINGLE, SETTLE_ALL, SETTLE_ALL, TAKE_ALL]);
      return [coder.encode(["bytes", "bytes[]"], [actions, [exactInParams(ord[0][0], ord[0][1], ord[0][2], 1n), exactInParams(ord[1][0], ord[1][1], ord[1][2], 1n),
        coder.encode(["address", "uint256"], [ethers.ZeroAddress, nIn]), coder.encode(["address", "uint256"], [WETH, wIn]), coder.encode(["address", "uint256"], [CASHCAT, 1n])]])];
    };
    for (const first of ["main", "second"]) {
      const sn = await send("evm_snapshot", []);
      try {
        const c0 = await cash.balanceOf(buyer.address);
        const rc = await plan(buyer, [V4_SWAP], both(first), nIn);
        const got = (await cash.balanceOf(buyer.address)) - c0, want = nTok + wTok, diff = got > want ? got - want : want - got;
        if (diff * 10n ** 12n > want) fail(`10 (${first} first): got ${got}, expected ${want}`);
        console.log(`   ${first} door first: one transaction bought ${ethers.formatUnits(got, 18)} CASHCAT through both pools (gas ${rc.gasUsed})`);
      } finally { await send("evm_revert", [sn]); }
    }
    {
      const c0 = await cash.balanceOf(buyer.address), w0 = await weth.balanceOf(buyer.address);
      const over = (wIn * 3n) / 2n + 10n ** 12n;
      let reverted = false;
      try { await plan(buyer, [V4_SWAP], [coder.encode(["bytes", "bytes[]"], [ethers.solidityPacked(["uint8", "uint8", "uint8", "uint8", "uint8"], [SWAP_EXACT_IN_SINGLE, SWAP_EXACT_IN_SINGLE, SETTLE_ALL, SETTLE_ALL, TAKE_ALL]), [
        exactInParams(nativeKey, true, nIn, 1n), exactInParams(cashKey, BigInt(WETH) === BigInt(cashKey.currency0), over, 1n),
        coder.encode(["address", "uint256"], [ethers.ZeroAddress, nIn]), coder.encode(["address", "uint256"], [WETH, over]), coder.encode(["address", "uint256"], [CASHCAT, 1n])]])], nIn); } catch { reverted = true; }
      if (!reverted) fail("10: a second-door slice above its budget went through");
      if ((await cash.balanceOf(buyer.address)) !== c0 || (await weth.balanceOf(buyer.address)) !== w0) fail("10: funds moved on the refused plan");
      console.log("   second-door slice above its budget: the whole plan reverted, nothing moved (its own quote shows the limit)");
    }
    {
      const sn = await send("evm_snapshot", []);
      try {
        const half = wIn / 2n;
        await (await (await urCall(buyer, cashKey, WETH, CASHCAT, "in", half, 1n)).run()).wait();
        const wIn2 = await maxIn(cashKey, WETH), wTok2 = await tokensAt(cashKey, WETH, wIn2);
        console.log(`   next transaction after a second-door buy: its budget is recomputed from what is left (${ethers.formatUnits(wTok2, 18)} CASHCAT)`);
        if (wTok2 === 0n && second > K * 4n) fail("10: the second door did not get a fresh budget in the next transaction");
      } finally { await send("evm_revert", [sn]); }
    }
    await (await hook.unregisterPair(ethers.ZeroAddress, CASHCAT)).wait();
    ok("design E: the second door quotes only its deposit budget, the main door adds listings, both fill in one transaction in either order, an over-budget slice is refused whole, and budgets reset every transaction");
  }

  console.log("\ngas (execution on the fork; Robinhood Chain adds an L1 data component the fork does not model):");
  for (const [k, v] of gasTable) console.log(`   ${String(v).padStart(10)}  ${k}`);
  console.log("\nJUP-698 GATE 3 (Robinhood Chain fork): every check passed.");
}
main().catch((e) => { console.error(e); process.exit(1); });
