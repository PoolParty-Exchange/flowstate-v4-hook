/* Gen-6 gas-ratio probe on the fork AFTER gen6-fork-e2e.cjs has run (hook deployed, trusted, beacons lit). For each compiled
 * constant variant of the hook (runtime hex-patched with the deployed immutables and hot-swapped at the hook address with
 * hardhat_setCode), measure estimateGas / gasUsed through the LIVE Universal Router on the steady-state shapes Uniswap's
 * allowlist judges (bar: 1.30): native exact-in, native exact-out, USDG exact-in, an aeWETH payer unwrapped by the router into
 * the native door, and a deposits-plus-listing fill. Every measurement runs in a snapshot and is reverted. Nothing live.
 *   HOOK_OUT=<hook>/out E2E=<gen6_fork_e2e.json> VARIANTS=<dir of variant artifacts> OUT_DIR=<dir> \
 *   npx hardhat run --network rhfork --config hardhat.test.config.js <hook repo>/test/stack/gen6-ratio-probe.cjs
 */
const path = require("node:path"); const fs = require("node:fs");
const { ethers, network } = require(path.resolve(process.cwd(), "node_modules/hardhat"));
if (network.name !== "rhfork") { console.error("REFUSED: rhfork only"); process.exit(1); }
const E2E = JSON.parse(fs.readFileSync(process.env.E2E, "utf8")); const VDIR = process.env.VARIANTS; const OUT_DIR = process.env.OUT_DIR || VDIR;
const CASHCAT = "0x020bfC650A365f8BB26819deAAbF3E21291018b4", CASHCAT_WETH_V3 = "0xd42A491087a15E5afd51FEb3606066Cc152d2b09", USDG_V3_POOL = "0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca" // the aeWETH/USDG v3 pool holding 3.6M USDG on the fork;
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3", POOL_MANAGER = "0x8366a39CC670B4001A1121B8F6A443A643e40951", UNIVERSAL_ROUTER = "0x8876789976dEcBfCbBbe364623C63652db8C0904", TOKEN_JAR = "0x2aC03e14Cfe755426DaAEe0a4994184Ce81482F8";
const MAX160 = (1n << 160n) - 1n, ZERO_PERMIT = { details: { token: ethers.ZeroAddress, amount: 0n, expiration: 0n, nonce: 0n }, spender: ethers.ZeroAddress, sigDeadline: 0n };
const ERC20 = ["function balanceOf(address) view returns (uint256)", "function transfer(address,uint256) returns (bool)", "function approve(address,uint256) returns (bool)"];
const [SWAP_EXACT_IN_SINGLE, SWAP_EXACT_OUT_SINGLE, SETTLE, SETTLE_ALL, TAKE_ALL] = [0x06, 0x08, 0x0b, 0x0c, 0x0f];
const [V4_SWAP_CMD, PERMIT2_TRANSFER_FROM, SWEEP, UNWRAP_WETH] = [0x10, 0x02, 0x04, 0x0c]; const ADDRESS_THIS = "0x0000000000000000000000000000000000000002", MSG_SENDER = "0x0000000000000000000000000000000000000001";
const send = (m, p) => network.provider.send(m, p); const now = async () => (await ethers.provider.getBlock("latest")).timestamp;
async function impersonate(a) { await send("hardhat_impersonateAccount", [a]); await send("hardhat_setBalance", [a, "0x56BC75E2D63100000"]); return ethers.getSigner(a); }
async function throwaway() { const w = ethers.Wallet.createRandom().connect(ethers.provider); await send("hardhat_setBalance", [w.address, "0x56BC75E2D63100000"]); return w; }
const coder = ethers.AbiCoder.defaultAbiCoder(); const KEY_T = "tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";
const word = (v) => ethers.zeroPadValue(typeof v === "number" ? ethers.toBeHex(v) : v, 32).slice(2);
function patched(art, values) { const refs = art.deployedBytecode.immutableReferences; const ids = Object.keys(refs).map(Number).sort((a, b) => a - b); if (ids.length !== values.length) throw new Error("immutables " + ids.length); let code = art.deployedBytecode.object.slice(2); ids.forEach((id, k) => { for (const r of refs[id]) { const s = r.start * 2; code = code.slice(0, s) + values[k] + code.slice(s + 64); } }); return "0x" + code; }

async function main() {
  const book = JSON.parse(fs.readFileSync(path.resolve(process.cwd(), "deploy/out.rh.json"), "utf8")); const [USDG, WETH] = book.quoteAssets;
  const hookAddr = ethers.getAddress(E2E.steps.hook.hook), opener = ethers.getAddress(E2E.steps.hook.opener), registryAddr = E2E.steps.listings.registry, settlementAddr = E2E.steps.listings.settlement;
  const m = await ethers.getContractAt("FlowstateMarket", book.market); const cashPoolAddr = await m.poolByToken(CASHCAT); const pool = await ethers.getContractAt("FlowstatePool", cashPoolAddr);
  if ((await m.trustedHook()).toLowerCase() !== hookAddr.toLowerCase()) throw new Error("the fork is not in the post-e2e state (trustedHook != Gen-6)");
  const liveCode = await ethers.provider.getCode(hookAddr);
  const immutables = [POOL_MANAGER, book.market, WETH, TOKEN_JAR, 8, registryAddr, settlementAddr, opener].map(word);
  const HK = JSON.parse(fs.readFileSync(path.join(process.env.HOOK_OUT, "FlowstateC1Hook.sol", "FlowstateC1Hook.json"), "utf8")); const hook = new ethers.Contract(hookAddr, HK.abi, ethers.provider);
  const ur = new ethers.Contract(UNIVERSAL_ROUTER, ["function execute(bytes commands, bytes[] inputs, uint256 deadline) payable"], ethers.provider);
  const weth = new ethers.Contract(WETH, ERC20, ethers.provider), usdg = new ethers.Contract(USDG, ERC20, ethers.provider), cash = new ethers.Contract(CASHCAT, ERC20, ethers.provider);
  const permit2 = new ethers.Contract(PERMIT2, ["function approve(address token, address spender, uint160 amount, uint48 expiration)"], ethers.provider);
  const registry = await ethers.getContractAt("C1ListingRegistry", registryAddr);
  // buyer and a listing behind the deposits (once, before the snapshots)
  const cashSrc = await impersonate(CASHCAT_WETH_V3), usdgSrc = await impersonate(USDG_V3_POOL); const buyer = await throwaway(); const far = BigInt((await now()) + 30 * 86400);
  await (await weth.connect(cashSrc).transfer(buyer.address, 2n * 10n ** 18n)).wait(); await (await usdg.connect(usdgSrc).transfer(buyer.address, 20_000n * 10n ** 6n)).wait(); await send("hardhat_setBalance", [buyer.address, "0x" + (50n * 10n ** 18n).toString(16)]);
  for (const t of [WETH, USDG]) { await (await new ethers.Contract(t, ERC20, buyer).approve(PERMIT2, ethers.MaxUint256)).wait(); await (await permit2.connect(buyer).approve(t, UNIVERSAL_ROUTER, MAX160, far)).wait(); }
  const seller = await throwaway(); const lot = 1_200n * 10n ** 18n; await (await cash.connect(cashSrc).transfer(seller.address, lot)).wait(); await (await cash.connect(seller).approve(PERMIT2, ethers.MaxUint256)).wait(); await (await permit2.connect(seller).approve(CASHCAT, settlementAddr, MAX160, far)).wait();
  const floors = []; for (const a of await pool.seededAssets()) { const [r] = await pool.anchorOf(a); floors.push({ asset: a, minRate: (r * 9n) / 10n }); }
  await (await registry.connect(seller).list(CASHCAT, lot, far - 86400n, ethers.ZeroHash, floors, ZERO_PERMIT, "0x", { gasLimit: 3_000_000 })).wait();
  const [, rateW] = await m.previewHookRate(cashPoolAddr, WETH), [, rateU] = await m.previewHookRate(cashPoolAddr, USDG); const [maxTokW] = await m.maxBuy(cashPoolAddr, WETH);
  const peek = await registry.peek(CASHCAT); console.log(`deposits executable ${ethers.formatEther(maxTokW)} CASHCAT; listing state ${peek[0]} id ${peek[1]} available ${ethers.formatEther(peek[3])}; rate ${rateW} wei/token`);
  const keyFor = (q) => { const [c0, c1] = BigInt(q) < BigInt(CASHCAT) ? [q, CASHCAT] : [CASHCAT, q]; return { currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: hookAddr }; };
  const nativeKey = keyFor(ethers.ZeroAddress), usdgKey = keyFor(USDG);
  const exactIn = (key, zfo, a, min) => coder.encode([`tuple(${KEY_T} poolKey,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,uint256 minHopPriceX36,bytes hookData)`], [[key, zfo, a, min, 0, "0x"]]);
  const exactOut = (key, zfo, a, max) => coder.encode([`tuple(${KEY_T} poolKey,bool zeroForOne,uint128 amountOut,uint128 amountInMaximum,uint256 minHopPriceX36,bytes hookData)`], [[key, zfo, a, max, 0, "0x"]]);
  const v4 = (key, inC, outC, kind, amount, bound) => { const zfo = BigInt(inC) === BigInt(key.currency0); const acts = ethers.solidityPacked(["uint8", "uint8", "uint8"], [kind === "in" ? SWAP_EXACT_IN_SINGLE : SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL]); const p0 = kind === "in" ? exactIn(key, zfo, amount, bound) : exactOut(key, zfo, amount, bound); return coder.encode(["bytes", "bytes[]"], [acts, [p0, coder.encode(["address", "uint256"], [inC, kind === "in" ? amount : bound]), coder.encode(["address", "uint256"], [outC, kind === "in" ? bound : amount])]]); };
  const ethIn = 5n * 10n ** 14n, usdgIn = 1_200_000n, tokOut = 5n * 10n ** 18n, maxIn = ((tokOut * rateW + 10n ** 18n - 1n) / 10n ** 18n) * 10_100n / 10_000n;
  const crossing = ((maxTokW + 20n * 10n ** 18n) * rateW + 10n ** 18n - 1n) / 10n ** 18n; // all deposits plus 20 tokens of the listing
  const unwrapPlan = coder.encode(["bytes", "bytes[]"], [ethers.solidityPacked(["uint8", "uint8", "uint8"], [SETTLE, SWAP_EXACT_IN_SINGLE, TAKE_ALL]), [coder.encode(["address", "uint256", "bool"], [ethers.ZeroAddress, ethIn, false]), exactIn(nativeKey, true, ethIn, 1n), coder.encode(["address", "uint256"], [CASHCAT, 1n])]]);
  const shapes = [
    { label: "native exact-in 0.0005 ETH", cmds: [V4_SWAP_CMD], inputs: [v4(nativeKey, ethers.ZeroAddress, CASHCAT, "in", ethIn, 1n)], value: ethIn },
    { label: "native exact-out 5 CASHCAT + SWEEP", cmds: [V4_SWAP_CMD, SWEEP], inputs: [v4(nativeKey, ethers.ZeroAddress, CASHCAT, "out", tokOut, maxIn), coder.encode(["address", "address", "uint256"], [ethers.ZeroAddress, MSG_SENDER, 0])], value: maxIn },
    { label: "USDG exact-in 1.2 USDG", cmds: [V4_SWAP_CMD], inputs: [v4(usdgKey, USDG, CASHCAT, "in", usdgIn, 1n)], value: 0n },
    { label: "aeWETH payer, router unwraps into the native door", cmds: [PERMIT2_TRANSFER_FROM, UNWRAP_WETH, V4_SWAP_CMD], inputs: [coder.encode(["address", "address", "uint160"], [WETH, ADDRESS_THIS, ethIn]), coder.encode(["address", "uint256"], [ADDRESS_THIS, ethIn]), unwrapPlan], value: 0n },
    { label: `native exact-in crossing all deposits into the listing (${ethers.formatEther(crossing)} ETH)`, cmds: [V4_SWAP_CMD], inputs: [v4(nativeKey, ethers.ZeroAddress, CASHCAT, "in", crossing, 1n)], value: crossing },
  ];
  const measure = async (sh) => { const sn = await send("evm_snapshot", []); try { const deadline = (await now()) + 600; const cmds = ethers.solidityPacked(sh.cmds.map(() => "uint8"), sh.cmds); let est = null, err = null; try { est = await ur.connect(buyer).execute.estimateGas(cmds, sh.inputs, deadline, { value: sh.value }); } catch (e) { err = (e.shortMessage || e.message).slice(0, 100); } const c0 = await cash.balanceOf(buyer.address); const rc = await (await ur.connect(buyer).execute(cmds, sh.inputs, deadline, { value: sh.value, gasLimit: 3_000_000 })).wait(); const got = (await cash.balanceOf(buyer.address)) - c0; let atEst = null; if (est) { const sn2 = await send("evm_snapshot", []); try { const r2 = await (await ur.connect(buyer).execute(cmds, sh.inputs, deadline, { value: sh.value, gasLimit: est })).wait(); atEst = r2.status === 1; } catch { atEst = false; } finally { await send("evm_revert", [sn2]); } } return { used: rc.gasUsed.toString(), estimate: est ? est.toString() : err, ratio: est ? Number((Number(est) / Number(rc.gasUsed)).toFixed(3)) : null, got: ethers.formatEther(got), fillsAtEstimate: atEst }; } catch (e) { return { error: (e.shortMessage || e.message).slice(0, 120) }; } finally { await send("evm_revert", [sn]); } };
  const variants = fs.readdirSync(VDIR).filter((f) => /^V\d.*\.json$/.test(f)).sort(); const results = {};
  for (const vf of variants) {
    const art = JSON.parse(fs.readFileSync(path.join(VDIR, vf), "utf8")); const code = patched(art, immutables); const name = vf.replace(".json", "");
    const sn = await send("evm_snapshot", []);
    try {
      await send("hardhat_setCode", [hookAddr, code]);
      const consts = { attempt: String(await hook.GEN4_MIN_ATTEMPT_GAS()), legBase: String(await hook.GEN4_POOL_LEG_BASE_GAS()), reserve: String(await hook.GEN4_FINALIZATION_GAS_RESERVE()), listing: String(await hook.GEN4_LISTING_LEG_MIN_GAS()) };
      console.log(`\n== ${name}: ${JSON.stringify(consts)} (runtime ${(code.length - 2) / 2} bytes${name.startsWith("V0") ? ", baseline = deployed: " + (code.toLowerCase() === liveCode.toLowerCase()) : ""})`);
      results[name] = { constants: consts, shapes: {} };
      for (const sh of shapes) { const r = await measure(sh); results[name].shapes[sh.label] = r; console.log(`   ${sh.label}: ${r.error ? "ERROR " + r.error : `used ${r.used}, estimate ${r.estimate}, ratio ${r.ratio}, got ${r.got}, fills at the estimate ${r.fillsAtEstimate}`}`); }
    } finally { await send("evm_revert", [sn]); }
    fs.writeFileSync(path.join(OUT_DIR, "gen6_ratio_probe.json"), JSON.stringify(results, null, 1));
  }
  console.log("\nwritten", path.join(OUT_DIR, "gen6_ratio_probe.json"));
}
main().catch((e) => { console.error("ERR", e.shortMessage || e.message); process.exit(1); });
