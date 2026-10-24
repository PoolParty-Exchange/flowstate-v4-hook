/* Gen-6 end-to-end on a fork of Robinhood Chain (24 Oct 2026, Hamish's ask): the JUP-771 contracts upgrade already applied to
 * the fork by deploy/rehearse-build-a.js (MANIFEST=jup-771 STOP_BEFORE_DRILLS=1), then the Gen-6 listing contracts (PR 62
 * settlement), the opener and the Gen-6 hook at a mined CREATE2 address, the eight pair registrations from the (impersonated)
 * owner Safe, the trusted-hook switch from the (impersonated) 48h timelock, Gen-5's pairs retired, then buys through the LIVE
 * Universal Router with first-fill and second-fill gas ratios (estimate / used, the Hooklist bar is 1.30), the USDG door, an
 * aeWETH payer reaching the native door through the router's own unwrap, and the USDG + ETH split route that must revert whole.
 * Also: a new token (ROBINCAT) created through createPool gets its two doors with no operator call.
 *
 * Run from a PoolParty_Contracts checkout carrying jup-771 (the worktree PoolParty_Contracts-jup770), against the fork:
 *   npx hardhat node --config hardhat.test.config.js --fork $RH_RPC_URL --port 8546
 *   STOP_BEFORE_DRILLS=1 NODES=5 npx hardhat run deploy/rehearse-build-a.js --network rhfork --config hardhat.test.config.js
 *   HOOK_OUT=<hook repo>/out OUT_DIR=<dir> npx hardhat run --network rhfork --config hardhat.test.config.js <hook repo>/test/stack/gen6-fork-e2e.cjs
 * Fork-only: the Safe's and the timelock's calls are impersonated; buyers are throwaways funded from live venues. Nothing live.
 */
const path = require("node:path");
const fs = require("node:fs");
const { ethers, network } = require(path.resolve(process.cwd(), "node_modules/hardhat"));
const { deployListings } = require(path.resolve(process.cwd(), "deploy/lib/listings"));
if (network.name !== "rhfork") { console.error(`REFUSED: --network rhfork only (got ${network.name})`); process.exit(1); }
const OUT = process.env.HOOK_OUT; if (!OUT) { console.error("REFUSED: set HOOK_OUT"); process.exit(1); }
const OUT_DIR = process.env.OUT_DIR || path.resolve(process.cwd(), "gen6_e2e_out"); fs.mkdirSync(OUT_DIR, { recursive: true });
const CASHCAT = "0x020bfC650A365f8BB26819deAAbF3E21291018b4", HOODRAT = "0x8e62F281f282686fCa6dCB39288069a93fC23F1c", TENDIES = "0x45242320DBB855EeA8Fd36804C6487E10E97FCF9", V4TOKEN = "0xC60bA256B44334A0Cd2C7242E98B88f031abB006";
const ROBINCAT = "0xded852De9fe9bA9b6f27f39e8e81CF851A5C79cc", ROBINCAT_WETH_V3 = "0xee0ba443f8871ea3f98b820410025a13213a1635";
const CASHCAT_WETH_V3 = "0xd42A491087a15E5afd51FEb3606066Cc152d2b09", USDG_V3_POOL = "0x4B0c312fFbB068F6a0bEa128759E35d94B94D0E1", REF_AEWETH_USDG = "0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a";
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3", POOL_MANAGER = "0x8366a39CC670B4001A1121B8F6A443A643e40951", UNIVERSAL_ROUTER = "0x8876789976dEcBfCbBbe364623C63652db8C0904", TOKEN_JAR = "0x2aC03e14Cfe755426DaAEe0a4994184Ce81482F8";
const CREATE2 = "0x4e59b44847b379578588920cA78FbF26c0B4956C", HOOK5 = "0x44Ca381B2264d0F0173F817d42ab2a8489f968cC", HOOK_FLAGS = 0x28ccn, MAX160 = (1n << 160n) - 1n;
const ERC20 = ["function balanceOf(address) view returns (uint256)", "function transfer(address,uint256) returns (bool)", "function approve(address,uint256) returns (bool)"];
const UR_ABI = ["function execute(bytes commands, bytes[] inputs, uint256 deadline) payable"];
const G = { gasLimit: 8_000_000 }, SWAP_GAS = { gasLimit: 3_000_000 };
const [SWAP_EXACT_IN_SINGLE, SWAP_EXACT_OUT_SINGLE, SETTLE, SETTLE_ALL, TAKE_ALL] = [0x06, 0x08, 0x0b, 0x0c, 0x0f];
const [V4_SWAP_CMD, PERMIT2_TRANSFER_FROM, SWEEP, UNWRAP_WETH] = [0x10, 0x02, 0x04, 0x0c];
const ADDRESS_THIS = "0x0000000000000000000000000000000000000002";
const MIN_SQRT = 4295128740n, MAX_SQRT = 1461446703485210103287273052203988822378723970341n;
const send = (m, p) => network.provider.send(m, p);
const fail = (m) => { console.error(`\nABORT: ${m}`); process.exit(1); };
const ok = (m) => console.log(`   ✓ ${m}`);
async function impersonate(addr) { await send("hardhat_impersonateAccount", [addr]); await send("hardhat_setBalance", [addr, "0x56BC75E2D63100000"]); return ethers.getSigner(addr); }
async function throwaway() { const w = ethers.Wallet.createRandom().connect(ethers.provider); await send("hardhat_setBalance", [w.address, "0x56BC75E2D63100000"]); return w; }
const now = async () => (await ethers.provider.getBlock("latest")).timestamp;
const artifact = (file, name) => { const a = JSON.parse(fs.readFileSync(path.join(OUT, file, name + ".json"), "utf8")); return { abi: a.abi, bytecode: a.bytecode.object }; };
const sortKey = (a, b) => (BigInt(a) < BigInt(b) ? [a, b] : [b, a]);
const coder = ethers.AbiCoder.defaultAbiCoder();
const KEY_T = "tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";
const record = { startedAt: new Date().toISOString(), steps: {}, canaries: [], checks: [] };
const save = () => fs.writeFileSync(path.join(OUT_DIR, "gen6_fork_e2e.json"), JSON.stringify(record, (k, v) => (typeof v === "bigint" ? v.toString() : v), 1));
const check = (name, cond, detail = "") => { record.checks.push({ name, pass: !!cond, detail: String(detail) }); console.log(`${cond ? "PASS" : "FAIL"} ${name}${detail ? "  [" + detail + "]" : ""}`); save(); if (!cond) record.failed = true; };

async function main() {
  const book = JSON.parse(fs.readFileSync(path.resolve(process.cwd(), "deploy/out.rh.json"), "utf8"));
  const m = await ethers.getContractAt("FlowstateMarket", book.market);
  const admin = await impersonate(book.admin), tl48 = await impersonate(book.tl48), safe = await impersonate(book.adminSafe);
  const [USDG, WETH] = book.quoteAssets;
  const weth = new ethers.Contract(WETH, ERC20, ethers.provider), usdg = new ethers.Contract(USDG, ERC20, ethers.provider), cash = new ethers.Contract(CASHCAT, ERC20, ethers.provider);
  const permit2 = new ethers.Contract(PERMIT2, ["function approve(address token, address spender, uint160 amount, uint48 expiration)"], ethers.provider);
  const ur = new ethers.Contract(UNIVERSAL_ROUTER, UR_ABI, ethers.provider);
  const pmRead = new ethers.Contract(POOL_MANAGER, ["function extsload(bytes32) view returns (bytes32)"], ethers.provider);
  const poolIdOf = (k) => ethers.keccak256(coder.encode(["address", "address", "uint24", "int24", "address"], [k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks]));
  const slot0Of = async (k) => BigInt(await pmRead.extsload(ethers.keccak256(coder.encode(["bytes32", "uint256"], [poolIdOf(k), 6n])))) & ((1n << 160n) - 1n);
  const positionLiquidity = async (k, owner, lower, upper) => { const posKey = ethers.keccak256(ethers.solidityPacked(["address", "int24", "int24", "bytes32"], [owner, lower, upper, ethers.ZeroHash])); const stateSlot = ethers.keccak256(coder.encode(["bytes32", "uint256"], [poolIdOf(k), 6n])); const positionsSlot = BigInt(stateSlot) + 6n; const slot = ethers.keccak256(coder.encode(["bytes32", "uint256"], [posKey, positionsSlot])); return BigInt(await pmRead.extsload(slot)) & ((1n << 128n) - 1n); };

  // ── [0] the fork carries jup-771 ───────────────────────────────────────────────────────────────
  const cashPoolAddr = await m.poolByToken(CASHCAT); const pool = await ethers.getContractAt("FlowstatePool", cashPoolAddr);
  let has771 = false; try { await pool.laneForceClosed(); await pool.conversionFor(USDG); has771 = true; } catch {}
  console.log(`[0] fork block ${await ethers.provider.getBlockNumber()} | market ${book.market} | CASHCAT pool ${cashPoolAddr} | jup-771 pool surface: ${has771}`);
  if (!has771) fail("the fork does not carry jup-771 (laneForceClosed / conversionFor missing): run rehearse-build-a.js first");
  if ((await ethers.provider.getCode(CREATE2)) === "0x") fail("no CREATE2 deployer on this fork");
  record.steps.fork = { block: await ethers.provider.getBlockNumber(), market: book.market, cashPool: cashPoolAddr, trustedHookBefore: await m.trustedHook() };

  // ── [1] Gen-6 listing contracts (PR 62 settlement) and the JUP-770 references ───────────────────
  const { settlement, registry } = await deployListings(ethers, book.market, PERMIT2, true, admin);
  const regBound = (await registry.settlement()).toLowerCase() === settlement.target.toLowerCase() && (await settlement.registry()).toLowerCase() === registry.target.toLowerCase();
  check("[1] Gen-6 listing registry and settlement deployed and bound to each other and the market", regBound && (await settlement.market()).toLowerCase() === book.market.toLowerCase(), `${registry.target} / ${settlement.target}`);
  await (await m.connect(safe).setQuoteReference(USDG, USDG)).wait();
  await (await m.connect(safe).setQuoteReference(WETH, REF_AEWETH_USDG)).wait();
  if (await pool.poolPaused()) await (await m.connect(admin).pausePool(cashPoolAddr, false)).wait();
  await send("evm_increaseTime", [1900]); await send("evm_mine", []); // past the lane notice and the reference's 30-minute window
  const conv = await pool.conversionFor(USDG);
  check("[1] CASHCAT prices in USDG through the conversion leg (JUP-770 live on the fork)", conv[0], `reason ${conv[1]} factor ${conv[2]}`);
  record.steps.listings = { registry: registry.target, settlement: settlement.target, conversionForUSDG: { ok: conv[0], reason: Number(conv[1]), factor: conv[2].toString() } };

  // ── [2] opener and Gen-6 hook: CREATE from a fresh deployer at nonce 0, then CREATE2 ────────────
  const HK = artifact("FlowstateC1Hook.sol", "FlowstateC1Hook"), OP = artifact("FlowstatePoolOpener.sol", "FlowstatePoolOpener");
  const deployer = await throwaway();
  const openerAddr = ethers.getCreateAddress({ from: deployer.address, nonce: 0 });
  const args = coder.encode(["address", "address", "address", "address", "address", "uint16", "address", "address", "address"], [POOL_MANAGER, book.market, book.adminSafe, WETH, TOKEN_JAR, 8, registry.target, settlement.target, openerAddr]);
  const initCode = HK.bytecode + args.slice(2), initHash = ethers.keccak256(initCode);
  let salt, hookAddr;
  for (let i = 0n; ; i++) { salt = ethers.zeroPadValue(ethers.toBeHex(i), 32); hookAddr = ethers.getCreate2Address(CREATE2, salt, initHash); if ((BigInt(hookAddr) & 0x3fffn) === HOOK_FLAGS && (await ethers.provider.getCode(hookAddr)) === "0x") break; }
  const opener = await new ethers.ContractFactory(OP.abi, OP.bytecode, deployer).deploy(POOL_MANAGER, hookAddr, WETH);
  check("[2] opener deployed at the predicted CREATE address, bound to the mined hook", opener.target.toLowerCase() === openerAddr.toLowerCase() && (await opener.hook()).toLowerCase() === hookAddr.toLowerCase(), opener.target);
  const rcDeploy = await (await deployer.sendTransaction({ to: CREATE2, data: salt + initCode.slice(2), gasLimit: 29_000_000 })).wait();
  const hook = new ethers.Contract(hookAddr, HK.abi, ethers.provider);
  check("[2] Gen-6 hook at the mined CREATE2 address (flags 0x28cc), owner = the Safe, opener wired", (await ethers.provider.getCode(hookAddr)) !== "0x" && (await hook.owner()).toLowerCase() === book.adminSafe.toLowerCase() && (await hook.opener()).toLowerCase() === openerAddr.toLowerCase(), `${hookAddr} deploy gas ${rcDeploy.gasUsed}`);
  record.steps.hook = { hook: hookAddr, salt, opener: opener.target, deployGas: rcDeploy.gasUsed.toString(), runtimeBytes: ((await ethers.provider.getCode(hookAddr)).length - 2) / 2 };

  // ── [3] Safe A: eight registerPair (native ETH, USDG per token) + setResellerCode; each initialises its pool ──
  const TOKENS = [["CASHCAT", CASHCAT], ["HOODRAT", HOODRAT], ["TENDIES", TENDIES], ["V4", V4TOKEN]];
  const keyFor = (q, t) => { const [c0, c1] = sortKey(q, t); return { currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: hookAddr }; };
  const regs = [];
  for (const [tn, t] of TOKENS) { const p = await m.poolByToken(t); for (const [qn, q] of [["native", ethers.ZeroAddress], ["USDG", USDG]]) { const rc = await (await hook.connect(safe).registerPair(q, t, p, 16, G)).wait(); const k = keyFor(q, t); const price = await slot0Of(k); regs.push({ pair: `${tn}/${qn}`, pool: p, gas: rc.gasUsed.toString(), poolId: poolIdOf(k), sqrtPriceX96: price.toString(), initialised: price !== 0n, ready: await hook.isPairReady(q, t) }); } }
  await (await hook.connect(safe).setResellerCode("v4hook")).wait();
  check("[3] eight pairs registered by the Safe, eight pools initialised by the registrations (no init sends), all ready", regs.every(r => r.initialised && r.ready) && regs.length === 8, regs.map(r => `${r.pair} ${r.gas}`).join(", "));
  for (const [tn, t] of TOKENS) check(`[3] no aeWETH-keyed pool for ${tn} (one ETH door)`, (await slot0Of(keyFor(WETH, t))) === 0n && !(await hook.isPairRegistered(WETH, t)));
  record.steps.safeA = regs;

  // ── [4] Safe B: the trusted-hook switch from the 48h timelock; Safe C: Gen-5's pairs retired ─────
  await (await m.connect(tl48).setTrustedHook(hookAddr)).wait();
  check("[4] market.trustedHook = Gen-6", (await m.trustedHook()).toLowerCase() === hookAddr.toLowerCase());
  const hook5 = new ethers.Contract(HOOK5, HK.abi, ethers.provider); let retired = 0;
  for (const [, t] of TOKENS) for (const q of [ethers.ZeroAddress, WETH, USDG]) if (await hook5.isPairRegistered(q, t)) { await (await hook5.connect(safe).unregisterPair(q, t)).wait(); retired++; }
  check("[4] Gen-5 pairs retired by the Safe (expected eight)", retired === 8, String(retired));
  record.steps.switch = { trustedHook: await m.trustedHook(), gen5PairsRetired: retired };

  // ── [5] canaries through the LIVE Universal Router on CASHCAT ──────────────────────────────────
  const nativeKey = keyFor(ethers.ZeroAddress, CASHCAT), usdgKey = keyFor(USDG, CASHCAT);
  const cashSrc = await impersonate(CASHCAT_WETH_V3), usdgSrc = await impersonate(USDG_V3_POOL);
  const buyer = await throwaway(); const far = BigInt((await now()) + 30 * 86400);
  await (await weth.connect(cashSrc).transfer(buyer.address, 2n * 10n ** 18n)).wait();
  await (await usdg.connect(usdgSrc).transfer(buyer.address, 5_000n * 10n ** 6n)).wait();
  for (const tkn of [WETH, USDG]) { await (await new ethers.Contract(tkn, ERC20, buyer).approve(PERMIT2, ethers.MaxUint256)).wait(); await (await permit2.connect(buyer).approve(tkn, UNIVERSAL_ROUTER, MAX160, far)).wait(); }
  let withMinHop = true;
  const exactInParams = (key, zeroForOne, amountIn, minOut) => withMinHop
    ? coder.encode([`tuple(${KEY_T} poolKey,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,uint256 minHopPriceX36,bytes hookData)`], [[key, zeroForOne, amountIn, minOut, 0, "0x"]])
    : coder.encode([`tuple(${KEY_T} poolKey,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,bytes hookData)`], [[key, zeroForOne, amountIn, minOut, "0x"]]);
  const exactOutParams = (key, zeroForOne, amountOut, maxIn) => withMinHop
    ? coder.encode([`tuple(${KEY_T} poolKey,bool zeroForOne,uint128 amountOut,uint128 amountInMaximum,uint256 minHopPriceX36,bytes hookData)`], [[key, zeroForOne, amountOut, maxIn, 0, "0x"]])
    : coder.encode([`tuple(${KEY_T} poolKey,bool zeroForOne,uint128 amountOut,uint128 amountInMaximum,bytes hookData)`], [[key, zeroForOne, amountOut, maxIn, "0x"]]);
  const v4Input = (key, inC, outC, kind, amount, bound) => { const zfo = BigInt(inC) === BigInt(key.currency0); const actions = ethers.solidityPacked(["uint8", "uint8", "uint8"], [kind === "in" ? SWAP_EXACT_IN_SINGLE : SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL]); const p0 = kind === "in" ? exactInParams(key, zfo, amount, bound) : exactOutParams(key, zfo, amount, bound); const settleMax = kind === "in" ? amount : bound, takeMin = kind === "in" ? bound : amount; return coder.encode(["bytes", "bytes[]"], [actions, [p0, coder.encode(["address", "uint256"], [inC, settleMax]), coder.encode(["address", "uint256"], [outC, takeMin])]]); };
  const urExec = async (who, cmds, inputs, value, gas = SWAP_GAS) => ur.connect(who).execute(ethers.solidityPacked(cmds.map(() => "uint8"), cmds), inputs, (await now()) + 600, { ...gas, value });
  const urEst = async (who, cmds, inputs, value) => ur.connect(who).execute.estimateGas(ethers.solidityPacked(cmds.map(() => "uint8"), cmds), inputs, (await now()) + 600, { value });
  // shape detection
  try { await ur.connect(buyer).execute.staticCall(ethers.solidityPacked(["uint8"], [V4_SWAP_CMD]), [v4Input(usdgKey, USDG, CASHCAT, "in", 1_000_000n, 1n)], (await now()) + 600, SWAP_GAS); } catch { withMinHop = false; try { await ur.connect(buyer).execute.staticCall(ethers.solidityPacked(["uint8"], [V4_SWAP_CMD]), [v4Input(usdgKey, USDG, CASHCAT, "in", 1_000_000n, 1n)], (await now()) + 600, SWAP_GAS); } catch { withMinHop = true; } }
  console.log(`   Universal Router params: ${withMinHop ? "with" : "without"} minHopPriceX36`);
  const [okW, rateW] = await m.previewHookRate(cashPoolAddr, WETH), [okU, rateU] = await m.previewHookRate(cashPoolAddr, USDG);
  const [maxTokW] = await m.maxBuy(cashPoolAddr, WETH), [maxTokU] = await m.maxBuy(cashPoolAddr, USDG);
  console.log(`   CASHCAT hook rate: ${okW ? rateW : "n/a"} aeWETH wei per 1e18 (maxBuy ${ethers.formatEther(maxTokW)}), ${okU ? rateU : "n/a"} USDG raw per 1e18 (maxBuy ${ethers.formatEther(maxTokU)})`);
  if (!okW || !okU) fail("CASHCAT does not quote in both aeWETH and USDG on the fork");
  const hookEvents = (rc) => { const e = { spread: 0n, dust: 0n, jar: 0n, beacons: [] }; for (const log of rc.logs) { if (log.address.toLowerCase() !== hookAddr.toLowerCase()) continue; try { const x = hook.interface.parseLog(log); if (x?.name === "BuyExecuted") { e.spread += x.args[6]; e.dust += x.args[7]; } if (x?.name === "ProtocolFeePaid") e.jar += x.args[2]; if (x?.name === "BeaconSeeded") e.beacons.push(x.args[0]); } catch {} } return e; };
  const canary = async (label, cmds, inputs, value, outToken, expectBeacon) => {
    const before = { out: await new ethers.Contract(outToken, ERC20, ethers.provider).balanceOf(buyer.address), hookEth: await ethers.provider.getBalance(hookAddr), openerEth: await ethers.provider.getBalance(opener.target) };
    let est = null, estErr = null; try { est = await urEst(buyer, cmds, inputs, value); } catch (e) { estErr = (e.shortMessage || e.message).slice(0, 120); }
    const rc = await (await urExec(buyer, cmds, inputs, value)).wait();
    const got = (await new ethers.Contract(outToken, ERC20, ethers.provider).balanceOf(buyer.address)) - before.out; const ev = hookEvents(rc);
    const ratio = est ? Number(est) / Number(rc.gasUsed) : null;
    const row = { label, gasUsed: rc.gasUsed.toString(), estimate: est ? est.toString() : estErr, ratio: ratio ? Number(ratio.toFixed(3)) : null, got: got.toString(), spread: ev.spread.toString(), jar: ev.jar.toString(), dust: ev.dust.toString(), beacons: ev.beacons.length, hookEthAfter: (await ethers.provider.getBalance(hookAddr)).toString(), openerEthAfter: (await ethers.provider.getBalance(opener.target)).toString() };
    record.canaries.push(row); save();
    console.log(`   ${label}: used ${row.gasUsed}, estimate ${row.estimate}, ratio ${row.ratio}, got ${ethers.formatEther(got)}, spread ${ev.spread}, jar ${ev.jar}, beacons ${ev.beacons.length}`);
    check(`[5] ${label}: filled`, got > 0n);
    check(`[5] ${label}: limit-to-used ratio under 1.30`, ratio !== null && ratio < 1.3, String(row.ratio));
    check(`[5] ${label}: beacon ${expectBeacon ? "lit on this first fill" : "not lit again"}`, ev.beacons.length === (expectBeacon ? 1 : 0));
    check(`[5] ${label}: hook and opener hold no native`, row.hookEthAfter === "0" && row.openerEthAfter === "0");
    return row;
  };
  const ethIn = 5n * 10n ** 14n; // 0.0005 ETH (the Gen-5 canary size)
  const r1 = await canary("native exact-in 0.0005 ETH, FIRST fill (beacon)", [V4_SWAP_CMD], [v4Input(nativeKey, ethers.ZeroAddress, CASHCAT, "in", ethIn, 1n)], ethIn, CASHCAT, true);
  check("[5] native pool beacon: one unit of liquidity owned by the opener on the quote side", (await (async () => { const tick = Number(BigInt.asIntN(24, (BigInt(await pmRead.extsload(ethers.keccak256(coder.encode(["bytes32", "uint256"], [poolIdOf(nativeKey), 6n])))) >> 160n) & 0xffffffn)); const lower = (Math.floor(tick / 60) + 1) * 60, upper = lower + 60; return positionLiquidity(nativeKey, opener.target, lower, upper); })()) === 1n);
  const r2 = await canary("native exact-in 0.0005 ETH, SECOND fill", [V4_SWAP_CMD], [v4Input(nativeKey, ethers.ZeroAddress, CASHCAT, "in", ethIn, 1n)], ethIn, CASHCAT, false);
  const usdgIn = 1_200_000n; // 1.2 USDG
  const r3 = await canary("USDG exact-in 1.2 USDG, FIRST fill (beacon in USDG)", [V4_SWAP_CMD], [v4Input(usdgKey, USDG, CASHCAT, "in", usdgIn, 1n)], 0n, CASHCAT, true);
  const tokensOut = 5n * 10n ** 18n; const maxIn = ((tokensOut * rateW + 10n ** 18n - 1n) / 10n ** 18n) * 10_100n / 10_000n;
  const r4 = await canary("native exact-out 5 CASHCAT (+SWEEP of the unused value)", [V4_SWAP_CMD, SWEEP], [v4Input(nativeKey, ethers.ZeroAddress, CASHCAT, "out", tokensOut, maxIn), coder.encode(["address", "address", "uint256"], [ethers.ZeroAddress, "0x0000000000000000000000000000000000000001", 0])], maxIn, CASHCAT, false);
  // an aeWETH payer reaching the NATIVE door through the router's own unwrap: PERMIT2_TRANSFER_FROM -> UNWRAP_WETH -> V4 swap with the router paying (SETTLE, payerIsUser = false)
  const aeIn = 5n * 10n ** 14n;
  const routerPays = coder.encode(["bytes", "bytes[]"], [ethers.solidityPacked(["uint8", "uint8", "uint8"], [SETTLE, SWAP_EXACT_IN_SINGLE, TAKE_ALL]), [coder.encode(["address", "uint256", "bool"], [ethers.ZeroAddress, aeIn, false]), exactInParams(nativeKey, true, aeIn, 1n), coder.encode(["address", "uint256"], [CASHCAT, 1n])]]);
  const r5 = await canary("aeWETH payer 0.0005 aeWETH, router unwraps into the NATIVE door", [PERMIT2_TRANSFER_FROM, UNWRAP_WETH, V4_SWAP_CMD], [coder.encode(["address", "address", "uint160"], [WETH, ADDRESS_THIS, aeIn]), coder.encode(["address", "uint256"], [ADDRESS_THIS, aeIn]), routerPays], 0n, CASHCAT, false);
  record.steps.canaries = { r1, r2, r3, r4, r5 };

  // ── [6] the split route: USDG door + native door in one router call, together above the stock ──
  const [maxU] = await m.maxBuy(cashPoolAddr, USDG), [maxW] = await m.maxBuy(cashPoolAddr, WETH);
  const stock = maxU < maxW ? maxU : maxW; // the same deposits seen through either door
  const legTokU = (stock * 60n) / 100n, legTokW = (stock * 60n) / 100n; // 60% + 60% = 120% of the stock
  const costU = ((legTokU * rateU + 10n ** 18n - 1n) / 10n ** 18n) * 10_100n / 10_000n, costW = ((legTokW * rateW + 10n ** 18n - 1n) / 10n ** 18n) * 10_100n / 10_000n;
  await (await usdg.connect(usdgSrc).transfer(buyer.address, costU * 2n)).wait(); await send("hardhat_setBalance", [buyer.address, "0x" + (costW * 3n + 10n ** 18n).toString(16)]);
  const splitInputs = [v4Input(usdgKey, USDG, CASHCAT, "out", legTokU, costU), v4Input(nativeKey, ethers.ZeroAddress, CASHCAT, "out", legTokW, costW)];
  const bal = async () => ({ cash: await cash.balanceOf(buyer.address), usdg: await usdg.balanceOf(buyer.address), eth: await ethers.provider.getBalance(buyer.address), poolTok: await cash.balanceOf(cashPoolAddr), hookUsdg: await usdg.balanceOf(hookAddr), hookWeth: await weth.balanceOf(hookAddr) });
  const b0 = await bal(); let splitEst = null, splitEstErr = null; try { splitEst = await urEst(buyer, [V4_SWAP_CMD, V4_SWAP_CMD], splitInputs, costW); } catch (e) { splitEstErr = (e.shortMessage || e.message).slice(0, 140); }
  let splitStatus = null, splitGas = null; try { const rc = await (await urExec(buyer, [V4_SWAP_CMD, V4_SWAP_CMD], splitInputs, costW, { gasLimit: 4_000_000 })).wait(); splitStatus = rc.status; splitGas = rc.gasUsed; } catch (e) { splitStatus = 0; splitGas = e.receipt ? e.receipt.gasUsed : null; }
  const b1 = await bal(); const gasPaid = b0.eth - b1.eth;
  const unchanged = b0.cash === b1.cash && b0.usdg === b1.usdg && b0.poolTok === b1.poolTok && b0.hookUsdg === b1.hookUsdg && b0.hookWeth === b1.hookWeth && gasPaid < 10n ** 16n;
  check("[6] a USDG + ETH split route that promises 120% of the stock reverts as a whole (estimate refused, transaction status 0)", splitStatus === 0 && splitEst === null, `estimate: ${splitEstErr}; status ${splitStatus}; gas ${splitGas}`);
  check("[6] after the failed split nothing moved but gas", unchanged, `tokens ${b1.cash - b0.cash}, usdg ${b1.usdg - b0.usdg}, pool ${b1.poolTok - b0.poolTok}`);
  // and a split inside the stock (40% + 40%) fills both legs
  const legOk = (stock * 40n) / 100n; const costUo = ((legOk * rateU + 10n ** 18n - 1n) / 10n ** 18n) * 10_100n / 10_000n, costWo = ((legOk * rateW + 10n ** 18n - 1n) / 10n ** 18n) * 10_100n / 10_000n;
  const okInputs = [v4Input(usdgKey, USDG, CASHCAT, "out", legOk, costUo), v4Input(nativeKey, ethers.ZeroAddress, CASHCAT, "out", legOk, costWo)];
  const c0 = await cash.balanceOf(buyer.address); const rcOk = await (await urExec(buyer, [V4_SWAP_CMD, V4_SWAP_CMD, SWEEP], [...okInputs, coder.encode(["address", "address", "uint256"], [ethers.ZeroAddress, "0x0000000000000000000000000000000000000001", 0])], costWo, { gasLimit: 4_000_000 })).wait();
  check("[6] the same split inside the stock fills both doors in one transaction", rcOk.status === 1 && (await cash.balanceOf(buyer.address)) - c0 === legOk * 2n, `gas ${rcOk.gasUsed}`);
  record.steps.split = { stock: stock.toString(), over: { legTokU: legTokU.toString(), legTokW: legTokW.toString(), estimateError: splitEstErr, status: splitStatus, gas: splitGas ? splitGas.toString() : null, unchanged }, within: { leg: legOk.toString(), status: rcOk.status, gas: rcOk.gasUsed.toString() } };

  // ── [7] a new token through createPool: two doors, no operator ─────────────────────────────────
  let robinPool = await m.poolByToken(ROBINCAT);
  if (robinPool === ethers.ZeroAddress) {
    const robin = new ethers.Contract(ROBINCAT, ERC20, ethers.provider); const rSrc = await impersonate(ROBINCAT_WETH_V3); const lister = await throwaway();
    const amount = (await robin.balanceOf(ROBINCAT_WETH_V3)) / 20n; await (await robin.connect(rSrc).transfer(lister.address, amount)).wait(); await (await robin.connect(lister).approve(book.market, ethers.MaxUint256)).wait();
    const oracle = new ethers.Contract(book.oracle, ["function getRate(address,address,bool) view returns (uint256)"], ethers.provider);
    const floors = []; for (const a of [USDG, WETH]) { try { const r = await oracle.getRate(ROBINCAT, a, false); if (r > 0n) floors.push({ asset: a, minRate: r }); } catch {} }
    if (floors.length) {
      const rc = await (await m.connect(lister).createPool(ROBINCAT, amount, 0, floors, { gasLimit: 6_000_000 })).wait(); robinPool = await m.poolByToken(ROBINCAT);
      const nk = keyFor(ethers.ZeroAddress, ROBINCAT), uk = keyFor(USDG, ROBINCAT), wk = keyFor(WETH, ROBINCAT);
      check("[7] createPool(ROBINCAT) opened the native and USDG doors by itself: two pairs ready, two pools initialised, no aeWETH-keyed pool, no operator call", (await hook.isPairReady(ethers.ZeroAddress, ROBINCAT)) && (await hook.isPairReady(USDG, ROBINCAT)) && (await slot0Of(nk)) !== 0n && (await slot0Of(uk)) !== 0n && (await slot0Of(wk)) === 0n && !(await hook.isPairRegistered(WETH, ROBINCAT)), `createPool gas ${rc.gasUsed}`);
      record.steps.newToken = { token: ROBINCAT, pool: robinPool, createPoolGas: rc.gasUsed.toString(), floors: floors.map(f => ({ asset: f.asset, minRate: f.minRate.toString() })) };
    } else { console.log("   [7] skipped: the live oracle has no rate for ROBINCAT in USDG or aeWETH"); record.steps.newToken = { skipped: "no oracle rate" }; }
  } else { console.log(`   [7] ROBINCAT already has a pool live (${robinPool}); the createPool path was shown by the fork suite instead`); record.steps.newToken = { skipped: "pool exists live", pool: robinPool }; }

  record.finishedAt = new Date().toISOString(); save();
  const fails = record.checks.filter(c => !c.pass).length;
  console.log(`\nGEN-6 FORK E2E: ${record.checks.length - fails} of ${record.checks.length} checks pass${fails ? " - " + fails + " FAILED" : ""}; record ${path.join(OUT_DIR, "gen6_fork_e2e.json")}`);
  process.exit(fails ? 1 : 0);
}
main().catch((e) => { console.error("ERR", e.shortMessage || e.message, e.stack ? e.stack.split("\n").slice(1, 4).join(" | ") : ""); record.error = e.shortMessage || e.message; save(); process.exit(1); });
