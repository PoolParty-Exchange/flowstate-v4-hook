/* JUP-698 review F5: EXECUTION gas (eth_estimateGas: what a call needs before end-of-transaction
 * refunds) of the market's bounded buy across N nodes, plain and with recycled proceeds
 * (buy-back on in the traded asset, every owner opted in). Receipt gasUsed understates it. */
const path = require("node:path");
const { ethers, network } = require(path.resolve(process.cwd(), "node_modules/hardhat"));
const H = require(path.resolve(process.cwd(), "test/unit/flowstate/helpers"));
const S = require(path.resolve(process.cwd(), "test/unit/flowstate/signedHelpers"));
describe("F5: execution gas of the pool's bounded buy", function () {
  this.timeout(600000);
  const rows = {};
  for (const recycled of [false, true]) for (const n of [10, 50]) it(`${recycled ? "recycled" : "plain"} ${n} nodes`, async () => {
    const fx = await S.deploySignedFixture();
    const pool = await H.createDefaultPool(fx, S.TOK(100));
    if (recycled) await fx.market.connect(fx.signers.admin).setBuyBack(pool.target, fx.usdc.target, true, 50, 0, 0);
    for (let i = 1; i < n; i++) {
      const w = ethers.Wallet.createRandom().connect(ethers.provider);
      await network.provider.send("hardhat_setBalance", [w.address, "0x56BC75E2D63100000"]);
      if (recycled) await (await pool.connect(w).setRecycleOptIn(true)).wait();
      await fx.market.connect(fx.signers.alice).contributeTokens(pool.target, S.TOK(50), w.address, await H.consentFloors(pool.target));
    }
    if (recycled) await (await pool.connect(fx.signers.alice).setRecycleOptIn(true)).wait();
    const [maxTokens] = await fx.market.maxBuy(pool.target, fx.usdc.target);
    await fx.usdc.mint(fx.signers.buyerEOA.address, 10n ** 12n);
    await fx.usdc.connect(fx.signers.buyerEOA).approve(fx.market.target, ethers.MaxUint256);
    const data = fx.market.interface.encodeFunctionData("buyFromPoolBounded", [pool.target, fx.usdc.target, maxTokens, "", fx.signers.buyerEOA.address, 10n ** 12n, 0, 0]);
    const est = (await ethers.provider.estimateGas({ from: fx.signers.buyerEOA.address, to: fx.market.target, data })) - 21000n;
    const rc = await (await fx.signers.buyerEOA.sendTransaction({ to: fx.market.target, data, gasLimit: 29_000_000 })).wait();
    rows[`${recycled}-${n}`] = est;
    console.log(`      ${recycled ? "recycled" : "plain"} ${n} nodes: execution ${est}, receipt ${rc.gasUsed - 21000n}`);
    if (n === 50) { const per = (est - rows[`${recycled}-10`]) / 40n; console.log(`      => ${recycled ? "recycled" : "plain"} per node (execution): ${per}; base ${rows[`${recycled}-10`] - 10n * per}`); }
  });
});
