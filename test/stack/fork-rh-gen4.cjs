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
const [SWAP_EXACT_IN_SINGLE, SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL] = [0x06, 0x08, 0x0c, 0x0f];

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
  ok(`hook ${hookAddr} (flags 0x28cc) via CREATE2; pairs CASHCAT/aeWETH and CASHCAT/ETH registered and initialised on the live PoolManager`);

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
  const budget = ((lot * 10n) * rate) / 10n ** 18n * 2n; // twice the value of everything queued and listed here
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
  if (paid1 >= budget) fail("no refund on an over-sized budget");
  if ((await weth.balanceOf(TOKEN_JAR)) - jar0 !== h1.jar || h1.jar === 0n) fail("TokenJar fee not received as reported");
  if ((await weth.balanceOf(UNIVERSAL_ROUTER)) !== urW0 || (await cash.balanceOf(UNIVERSAL_ROUTER)) !== urC0) fail("the router kept a balance");
  if ((await weth.balanceOf(hookAddr)) - hk0 !== h1.spread + h1.dust || (await cash.balanceOf(hookAddr)) !== 0n) fail("the hook holds more than its spread and dust");
  gasTable.push(["UR exact input, live nodes + L1 + deposit + L2", rc1.gasUsed]);
  ok(`sold ${ethers.formatUnits(got1, 18)} CASHCAT for ${ethers.formatUnits(paid1, 18)} WETH of a ${ethers.formatUnits(budget, 18)} budget (rest refunded); pool never sold past a listing's snapshot; jar ${h1.jar}, spread ${h1.spread}, dust ${h1.dust}; router and hook keep nothing else`);

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

  console.log("\ngas (execution on the fork; Robinhood Chain adds an L1 data component the fork does not model):");
  for (const [k, v] of gasTable) console.log(`   ${String(v).padStart(10)}  ${k}`);
  console.log("\nJUP-698 GATE 3 (Robinhood Chain fork): every check passed.");
}
main().catch((e) => { console.error(e); process.exit(1); });
