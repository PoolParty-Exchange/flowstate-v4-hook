const path = require("node:path");
const { ethers } = require(path.resolve(process.cwd(), "node_modules/hardhat"));
const H = require(path.resolve(process.cwd(), "test/unit/flowstate/helpers"));
const S = require(path.resolve(process.cwd(), "test/unit/flowstate/signedHelpers"));
describe("probe: gas of the pool's own bounded buy across N nodes", function () {
  this.timeout(600000);
  for (const n of [10, 25, 50]) it(`${n} nodes`, async () => {
    const fx = await S.deploySignedFixture();
    const pool = await H.createDefaultPool(fx, S.TOK(100));
    for (let i = 1; i < n; i++) await fx.market.connect(fx.signers.alice).contributeTokens(pool.target, S.TOK(50), ethers.Wallet.createRandom().address, await H.consentFloors(pool.target));
    const [maxTokens] = await fx.market.maxBuy(pool.target, fx.usdc.target);
    await fx.usdc.mint(fx.signers.buyerEOA.address, 10n ** 12n);
    await fx.usdc.connect(fx.signers.buyerEOA).approve(fx.market.target, ethers.MaxUint256);
    const rc = await (await fx.market.connect(fx.signers.buyerEOA).buyFromPoolBounded(pool.target, fx.usdc.target, maxTokens, "", fx.signers.buyerEOA.address, 10n ** 12n, 0, 0, { gasLimit: 29_000_000 })).wait();
    console.log(`      ${n} nodes (${(await pool.queue(100)).length} left): maxBuy ${maxTokens}; bounded buy gas ${rc.gasUsed}`);
  });
});
