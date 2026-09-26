/* JUP-698 gate 2: gas of each read the Gen-4 hook makes before every attempt, measured COLD
 * (eth_estimateGas of a direct call, 21,000 base included) on the pinned stack. */
const path = require("node:path");
const fs = require("node:fs");
const { ethers, network } = require(path.resolve(process.cwd(), "node_modules/hardhat"));
const H = require(path.resolve(process.cwd(), "test/unit/flowstate/helpers"));
const S = require(path.resolve(process.cwd(), "test/unit/flowstate/signedHelpers"));
const { deployListings } = require(path.resolve(process.cwd(), "deploy/lib/listings"));
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
describe("gate 2: read gas per Gen-4 attempt", function () {
  this.timeout(600000);
  for (const n of [1, 50, 100]) it(`${n}-node queue with a listing`, async () => {
    const fx = await S.deploySignedFixture();
    await network.provider.send("hardhat_setCode", [PERMIT2, fs.readFileSync(path.resolve(process.cwd(), "test/fixtures/permit2-rh-runtime.hex"), "utf8").trim()]);
    const pool = await H.createDefaultPool(fx, S.TOK(100));
    await fx.market.connect(fx.signers.admin).setMinContribution(fx.usdc.target, 100_000_000n);
    for (let i = 1; i < n; i++) await fx.market.connect(fx.signers.alice).contributeTokens(pool.target, S.TOK(50), ethers.Wallet.createRandom().address, await H.consentFloors(pool.target));
    const { settlement, registry } = await deployListings(ethers, fx.market.target, PERMIT2, false);
    const w = ethers.Wallet.createRandom().connect(ethers.provider);
    await network.provider.send("hardhat_setBalance", [w.address, "0x56BC75E2D63100000"]);
    await fx.token.mint(w.address, S.TOK(60));
    await (await fx.token.connect(w).approve(PERMIT2, ethers.MaxUint256)).wait();
    const permit2 = new ethers.Contract(PERMIT2, ["function approve(address,address,uint160,uint48)"], w);
    await (await permit2.approve(fx.token.target, settlement.target, (1n << 160n) - 1n, BigInt((await ethers.provider.getBlock("latest")).timestamp + 30 * 86400))).wait();
    const far = BigInt((await ethers.provider.getBlock("latest")).timestamp + 29 * 86400);
    await (await registry.connect(w).list(fx.token.target, S.TOK(60), far, ethers.ZeroHash, await H.consentFloors(pool.target), { details: { token: ethers.ZeroAddress, amount: 0n, expiration: 0n, nonce: 0n }, spender: ethers.ZeroAddress, sigDeadline: 0n }, "0x", { gasLimit: 8_000_000 })).wait();
    const from = fx.signers.buyerEOA.address;
    const g = async (c, name, args) => (await ethers.provider.estimateGas({ from, to: c.target, data: c.interface.encodeFunctionData(name, args) })) - 21000n;
    const r = {
      peek: await g(registry, "peek", [fx.token.target]),
      tokenQueueEnds: await g(pool, "tokenQueueEnds", []),
      queue50: await g(pool, "queue", [50]),
      maxBuy: await g(fx.market, "maxBuy", [pool.target, fx.usdc.target]),
      price: await g(settlement, "price", [fx.token.target, fx.usdc.target]),
    };
    const total = Object.values(r).reduce((a, b) => a + b, 0n);
    console.log(`      ${n} nodes: ${Object.entries(r).map(([k, v]) => `${k} ${v}`).join(", ")}; total ${total}`);
  });
});
