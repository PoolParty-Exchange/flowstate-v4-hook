/* Gen-7 source stack: real Market/Pool/listing V2 contracts, Uniswap V4
 * PoolManager and the hook. Run from the candidate PoolParty_Contracts checkout.
 * All addresses and commercial values below are disposable local fixtures. */
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { ethers, network, artifacts } = require(path.resolve(process.cwd(), "node_modules/hardhat"));
const H = require(path.resolve(process.cwd(), "test/unit/flowstate/helpers"));

const OUT = process.env.HOOK_OUT || path.resolve(__dirname, "../../out");
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const CREATE2 = "0x4e59b44847b379578588920ca78fbf26c0b4956c";
const CREATE2_RUNTIME = "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
const HOOK_FLAGS = 0x28ccn;
const MAX160 = (1n << 160n) - 1n;
const TOK = (n) => ethers.parseUnits(String(n), 18);
const CODE = ethers.encodeBytes32String("SYNTHETIC");
const ZERO_PERMIT = { details: { token: ethers.ZeroAddress, amount: 0n, expiration: 0n, nonce: 0n }, spender: ethers.ZeroAddress, sigDeadline: 0n };
const GAS = { gasLimit: 29_000_000 };

function artifact(file, name) {
  const a = JSON.parse(fs.readFileSync(path.join(OUT, file, `${name}.json`), "utf8"));
  return { abi: a.abi, bytecode: a.bytecode.object };
}

function poolIdOf(key) {
  return ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "uint24", "int24", "address"],
    [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]
  ));
}

function events(receipt, source, iface, name) {
  return receipt.logs.filter((log) => log.address.toLowerCase() === source.toLowerCase()).map((log) => {
    try { return iface.parseLog(log); } catch { return null; }
  }).filter((event) => event?.name === name);
}

describe("Gen-7 V4 hook on the current PoolParty contract stack", function () {
  this.timeout(600_000);

  async function stack() {
    const fx = await H.deployFlowstateFixture();
    const { admin, timelock48, bob, buyerEOA, bd2W } = fx.signers;
    const permit2Runtime = fs.readFileSync(path.resolve(process.cwd(), "test/fixtures/permit2-rh-runtime.hex"), "utf8").trim();
    await network.provider.send("hardhat_setCode", [PERMIT2, permit2Runtime]);
    const permit2 = new ethers.Contract(PERMIT2,
      ["function approve(address token,address spender,uint160 amount,uint48 expiration)"], ethers.provider);
    const supplier = await (await ethers.getContractFactory("FlowstateSupplierRegistryV2"))
      .deploy(fx.market.target, admin.address, false);
    await supplier.connect(admin).createCode(CODE, bob.address, 2000, bd2W.address, 500);
    await fx.market.connect(timelock48).setSupplierRegistry(supplier.target);
    const pool = await H.createDefaultPool(fx, TOK(100));

    const Settlement = await ethers.getContractFactory("C1ListingSettlementV2", admin);
    const Registry = await ethers.getContractFactory("C1ListingRegistryV2", admin);
    const nonce = await ethers.provider.getTransactionCount(admin.address, "pending");
    const settlementAddress = ethers.getCreateAddress({ from: admin.address, nonce: nonce + 1 });
    const registry = await Registry.deploy(fx.market.target, PERMIT2, settlementAddress, false);
    const settlement = await Settlement.deploy(fx.market.target, PERMIT2, registry.target);
    assert.equal(settlement.target.toLowerCase(), settlementAddress.toLowerCase());
    assert.equal(await registry.settlement(), settlement.target);
    assert.equal(await settlement.registry(), registry.target);
    await supplier.connect(admin).setPayer(settlement.target, true);
    await fx.token.connect(bob).approve(PERMIT2, ethers.MaxUint256);
    const far = BigInt((await ethers.provider.getBlock("latest")).timestamp + 30 * 86400);
    await permit2.connect(bob).approve(fx.token.target, settlement.target, MAX160, far);

    const PM = artifact("PoolManager.sol", "PoolManager");
    const ST = artifact("PoolSwapTest.sol", "PoolSwapTest");
    const HK = artifact("FlowstateC1Hook.sol", "FlowstateC1Hook");
    const OP = artifact("FlowstatePoolOpener.sol", "FlowstatePoolOpener");
    const manager = await new ethers.ContractFactory(PM.abi, PM.bytecode, admin).deploy(admin.address);
    const router = await new ethers.ContractFactory(ST.abi, ST.bytecode, admin).deploy(manager.target);
    await network.provider.send("hardhat_setCode", [CREATE2, CREATE2_RUNTIME]);
    const jar = ethers.Wallet.createRandom().address;
    const openerAddress = ethers.getCreateAddress({ from: admin.address, nonce: await ethers.provider.getTransactionCount(admin.address) });
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "address", "address", "address", "uint16", "address", "address", "address"],
      [manager.target, fx.market.target, admin.address, ethers.ZeroAddress, jar, 8, registry.target, settlement.target, openerAddress]
    );
    const initCode = HK.bytecode + encoded.slice(2);
    const hash = ethers.keccak256(initCode);
    let salt, hookAddress;
    for (let i = 0n; ; i++) {
      salt = ethers.zeroPadValue(ethers.toBeHex(i), 32);
      hookAddress = ethers.getCreate2Address(CREATE2, salt, hash);
      if ((BigInt(hookAddress) & 0x3fffn) === HOOK_FLAGS) break;
    }
    const opener = await new ethers.ContractFactory(OP.abi, OP.bytecode, admin)
      .deploy(manager.target, hookAddress, ethers.ZeroAddress);
    assert.equal(opener.target, openerAddress);
    await (await admin.sendTransaction({ to: CREATE2, data: salt + initCode.slice(2), ...GAS })).wait();
    const hook = new ethers.Contract(hookAddress, HK.abi, admin);
    assert.notEqual(await ethers.provider.getCode(hookAddress), "0x");
    await (await hook.registerPair(fx.usdc.target, fx.token.target, pool.target, 16)).wait();
    const [c0, c1] = BigInt(fx.usdc.target) < BigInt(fx.token.target)
      ? [fx.usdc.target, fx.token.target] : [fx.token.target, fx.usdc.target];
    const key = { currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: hookAddress };
    const slot0 = await manager["extsload(bytes32)"](
      ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "uint256"], [poolIdOf(key), 6n]))
    );
    assert.notEqual(BigInt(slot0) & ((1n << 160n) - 1n), 0n);
    await fx.usdc.mint(manager.target, 1_000_000n * 10n ** 6n);
    await fx.usdc.mint(buyerEOA.address, 1_000_000n * 10n ** 6n);
    await fx.usdc.connect(buyerEOA).approve(router.target, ethers.MaxUint256);

    await registry.connect(bob).list(
      fx.token.target, TOK(60), far - 86400n, CODE,
      await H.consentFloors(pool.target), ZERO_PERMIT, "0x"
    );
    const feeInterface = new ethers.Interface((await artifacts.readArtifact("Gen7ListingFees")).abi);
    return { fx, supplier, pool, registry, settlement, manager, router, hook, key, feeInterface };
  }

  async function swap(x, hookData = "0x") {
    const zeroForOne = x.key.currency0 === x.fx.usdc.target;
    const limit = zeroForOne ? 4295128740n : 1461446703485210103287273052203988822378723970341n;
    return (await x.router.connect(x.fx.signers.buyerEOA).swap(
      x.key, { zeroForOne, sqrtPriceLimitX96: limit, amountSpecified: TOK(130) },
      { takeClaims: false, settleUsingBurn: false }, hookData, GAS
    )).wait();
  }

  function result(x, receipt) {
    const poolBuys = events(receipt, x.pool.target, x.pool.interface, "PoolBuy");
    const listingFills = events(receipt, x.settlement.target, x.settlement.interface, "ListingFilled");
    const poolFees = events(receipt, x.pool.target, x.pool.interface, "Gen7FeeDistributed");
    const listingFees = events(receipt, x.settlement.target, x.feeInterface, "Gen7FeeDistributed");
    const listingPieces = events(receipt, x.settlement.target, x.feeInterface, "Gen7SellPiece");
    const resolved = events(receipt, x.hook.target, x.hook.interface, "V4RouterResolved");
    assert.equal(poolBuys.length, 1);
    assert.equal(listingFills.length, 1);
    assert.equal(poolFees.length, 1);
    assert.equal(listingFees.length, 1);
    assert.equal(listingPieces.length, 1);
    assert.equal(resolved.length, 1);
    return {
      pool: poolBuys[0], listing: listingFills[0], poolFee: poolFees[0],
      listingFee: listingFees[0], listingPiece: listingPieces[0], resolved: resolved[0],
      supplierCredit: x.supplier.claimable(x.fx.usdc.target, CODE),
    };
  }

  it("uses PoolManager-authenticated router fallback, mapping and unmapping in both real legs", async () => {
    const x = await stack();
    const snapshot = await network.provider.send("evm_snapshot", []);
    const fallback = result(x, await swap(x, ethers.hexlify(ethers.toUtf8Bytes("KYBER"))));
    assert.equal(fallback.resolved.args.router, x.router.target);
    assert.equal(fallback.resolved.args.effectiveCode, "v4hook");
    assert.equal(fallback.pool.args.resellerCode, "v4hook");
    assert.equal(fallback.listingFee.args.resellerCode, "v4hook");
    assert.equal(fallback.poolFee.args.resellerCut, 0n);
    assert.equal(fallback.listingFee.args.resellerCut, 0n);
    const fallbackCredit = await fallback.supplierCredit;
    const fallbackEconomics = [fallback.pool.args.tokensFilled, fallback.pool.args.quotePaid,
      fallback.listing.args.amount, fallback.listing.args.quotePaid,
      fallback.poolFee.args.fee, fallback.listingFee.args.fee, fallback.listingPiece.args.supplierCut];

    assert.equal(await network.provider.send("evm_revert", [snapshot]), true);
    await x.fx.market.connect(x.fx.signers.timelock48).setV4RouterReseller(x.router.target, "KYBER");
    assert.equal(await x.fx.market.resolveV4Reseller(x.router.target), "KYBER");
    const mappedSnapshot = await network.provider.send("evm_snapshot", []);
    const mapped = result(x, await swap(x, ethers.hexlify(ethers.toUtf8Bytes("v4hook"))));
    assert.equal(mapped.resolved.args.router, x.router.target);
    assert.equal(mapped.resolved.args.effectiveCode, "KYBER");
    assert.equal(mapped.pool.args.resellerCode, "KYBER");
    assert.equal(mapped.listingFee.args.resellerCode, "KYBER");
    assert.equal(mapped.poolFee.args.resellerCut, mapped.poolFee.args.fee * 1500n / 10000n);
    assert.equal(mapped.listingFee.args.resellerCut, mapped.listingFee.args.fee * 1500n / 10000n);
    assert.deepEqual([mapped.pool.args.tokensFilled, mapped.pool.args.quotePaid,
      mapped.listing.args.amount, mapped.listing.args.quotePaid,
      mapped.poolFee.args.fee, mapped.listingFee.args.fee, mapped.listingPiece.args.supplierCut], fallbackEconomics);
    assert.equal(await mapped.supplierCredit, fallbackCredit);

    assert.equal(await network.provider.send("evm_revert", [mappedSnapshot]), true);
    await x.fx.market.connect(x.fx.signers.timelock48).setV4RouterReseller(x.router.target, "");
    assert.equal(await x.fx.market.resolveV4Reseller(x.router.target), "v4hook");
    const unmapped = result(x, await swap(x, ethers.hexlify(ethers.toUtf8Bytes("KYBER"))));
    assert.equal(unmapped.resolved.args.effectiveCode, "v4hook");
    assert.equal(unmapped.pool.args.resellerCode, "v4hook");
    assert.equal(unmapped.listingFee.args.resellerCode, "v4hook");
    assert.deepEqual([unmapped.pool.args.tokensFilled, unmapped.pool.args.quotePaid,
      unmapped.listing.args.amount, unmapped.listing.args.quotePaid,
      unmapped.poolFee.args.fee, unmapped.listingFee.args.fee, unmapped.listingPiece.args.supplierCut], fallbackEconomics);
    assert.equal(await unmapped.supplierCredit, fallbackCredit);
  });
});
