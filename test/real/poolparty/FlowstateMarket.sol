// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

import "./interface/IOracle.sol";
import "./interface/IFlowstatePool.sol";
import "./interface/IFlowstateBuyFunder.sol";
import "./interface/IInitializableBeaconProxy.sol";
import "./interface/IUpgradeableBeacon.sol";
import "./libraries/FlowstateStructs.sol";
import "./libraries/FlowstateEvents.sol";

/**
 * @title FlowstateMarket
 * @notice Flowstate factory / router / registry. UUPS proxy. Pass-1 rebuild of
 *         PoolPartySwap.sol — Flowstate-only (plan D1: no ownedPool, no vesting,
 *         no twitter reservations, no staking/rewards).
 *
 * @dev Spec: docs/FLOWSTATE_PASS1_IMPLEMENTATION_PLAN_2026-07-16.md §3.1, §3.7.
 *
 * Custody model (plan D2): the factory NEVER holds funds. Pools hold their own
 * inventory, proceeds, and claim ledgers; the factory is the single allowance
 * target (plan D7) and pulls exactly the oracle cost per fill straight into the
 * pool. There is no role that can mint claims — the legacy POOLPARTY_CONTRACT
 * credit-forging surface does not exist here.
 *
 * GOVERNANCE — FOUR LANES (§3.7). Each lane is defined by its delay, and every delay is
 * enforced by the role-admin chain below rather than by convention:
 *   instant  PAUSER_ROLE            multisig + optional hot ops EOA. pause() only —
 *                                   unpause() is DEFAULT_ADMIN_ROLE.
 *   instant  DEFAULT_ADMIN_ROLE     owner multisig, bounded ops only (inventory below).
 *   12h      EMERGENCY_UPGRADER_ROLE emergency upgrade lane, market UUPS + pool beacon.
 *   24h      FREEZE_ADMIN_ROLE      compliance activation (setFreezeEnabled).
 *   48h      UPGRADER_ROLE          normal upgrades, market UUPS + pool beacon.
 *   48h      TIMELOCK_ROLE          protocol wiring (oracle, beacon, template, receiver).
 *
 * ROLE-ADMIN CHAIN (wired in initialize). Without it OpenZeppelin's default applies and
 * DEFAULT_ADMIN_ROLE administers every role, so the multisig could grantRole(
 * UPGRADER_ROLE, itself) and upgrade instantly, making every delay advisory:
 *   UPGRADER_ROLE           admin = TIMELOCK_ROLE      — 48h to add an upgrader
 *   EMERGENCY_UPGRADER_ROLE admin = TIMELOCK_ROLE      — USING the lane costs 12h, but
 *                                                        GRANTING it costs the full 48h
 *   TIMELOCK_ROLE           admin = TIMELOCK_ROLE      — self-administered
 *   FREEZE_ADMIN_ROLE       admin = FREEZE_ADMIN_ROLE  — self-administered
 *   PAUSER_ROLE             admin = DEFAULT_ADMIN_ROLE — UNCHANGED, instant by design
 * Every line is load-bearing. Leaving TIMELOCK_ROLE on the default admin would let the
 * multisig grant itself TIMELOCK_ROLE and re-open every other lane in one transaction;
 * putting EMERGENCY_UPGRADER_ROLE on the default admin would let it grant itself the 12h
 * lane and re-open the bypass through a different door.
 * Deliberate consequence: DEFAULT_ADMIN_ROLE can neither grant nor revoke any of the four
 * delayed roles. Membership of a delayed lane only ever changes through a delayed lane,
 * and a lost timelock is not recoverable by the multisig — the accepted price of a delay
 * that is real rather than documented.
 *
 * NEVER TRAP EXITS — a first-class guarantee, not an implementation detail (D-M2-1).
 * "We can never stop you leaving." withdrawTokens, withdrawQuote, claimQuote, claimTokens
 * and claimMany remain callable in EVERY state the protocol can be put into:
 *   - while the market is paused    — the exit entry points carry no whenNotPaused gate
 *   - while a pool is paused        — poolPaused blocks trading and new deposits only;
 *                                     withdrawTokensFor / withdrawQuoteFor / the claim
 *                                     paths do not test it
 *   - while an address is frozen    — freezeEnabled is read on the four trading entry
 *                                     points (buyFromPool, buyFromPoolExactQuote,
 *                                     buyFromPoolExactOut, sellToPool) and NOWHERE else;
 *                                     FlowstatePool contains no freeze check at all, so a
 *                                     frozen address keeps its exit rights in full
 * There is no role, and no combination of roles, that can withhold a user's own position.
 *
 * ACCEPTED TRADE-OFF (stated deliberately, so it is a decision on record and not a
 * discovery): because the exit paths are never gated, they are the one surface with no
 * kill switch behind them. A defect in exit or claim accounting cannot be contained by
 * pausing or freezing, and would stay exposed for the duration of an emergency upgrade.
 * That is accepted knowingly: gating exits would mean every incident traps every
 * depositor, and the ability to trap funds indefinitely is a worse risk than the bug
 * class the gate would prevent. Reviewer implication: the exit and claim paths deserve
 * disproportionate attention precisely because no operational control backstops them.
 *
 * EMERGENCY MODEL (what actually happens during an incident):
 * containment is PAUSE, never upgrade. pause() needs only PAUSER_ROLE, takes effect
 * instantly, and is explicitly hot-key eligible; unpause() is DEFAULT_ADMIN_ROLE, so a
 * hot key can stop the system but can never restart it. Pausing stops trading and new
 * deposits while leaving every exit open, per the guarantee above. Repair is the 12h emergency
 * lane, which covers BOTH upgradeable surfaces: the market's own UUPS implementation and,
 * via upgradePoolImplementation, the pool beacon that every live pool follows in
 * lock-step (the stuck-funds case — FIFO ledger or claim logic — is pool-side, so a lane
 * that reached only the market would not cover what it was built for). Emergency use of
 * either surface emits EmergencyUpgradeAuthorized on top of ERC-1967's Upgraded, so it is
 * loudly distinguishable from a normal 48h upgrade in the read model and in monitoring.
 * Normal upgrades and protocol wiring wait the full 48h; compliance activation the full
 * 24h. After the role-admin chain above there is no instant path around any of them.
 *
 * ADMIN-SURFACE INVENTORY (scope doc §11 — deliberately minimal, all event-emitting):
 * instant multisig: setFeeBps (hard-capped ≤100), setQuoteAsset, reseller registry
 * (EOA-only, shares sum to 6000), setAnchorBand, setPriceSource (parked), setBuyBack,
 * resetAnchor, setFrozen (single address, block-only), pausePool/unpause;
 * 48h timelock: upgradeToAndCall (UUPS) + upgradePoolImplementation (beacon),
 * setPriceOracle (epoch reseed), setPoolBeacon/template, setBuybackReceiver;
 * 24h timelock: setFreezeEnabled;
 * 12h emergency timelock: upgradeToAndCall + upgradePoolImplementation ONLY — nothing
 * else, and each use is flagged by EmergencyUpgradeAuthorized.
 *
 * What NO role can do — not admin, not timelock, by construction:
 * price or approve an individual trade (oracle + pool math only); raise any fee above
 * 1% (hardcoded cap); change the 40% buyback fraction (remainder of a constant-sum
 * split); move or seize user deposits (pool-local ledgers, no custody role, freeze
 * blocks only the flagged address's own trading); mint claims (the legacy
 * POOLPARTY_CONTRACT credit path does not exist); or block withdrawals (exits work
 * even while paused).
 */
contract FlowstateMarket is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error QuoteAssetNotApproved();
    error PoolAlreadyExists();
    error UnknownPool();
    error NoOracleRate();
    error InvalidBand();
    error FeeExceedsCap();
    error NotEOA();
    error BDWalletRequired();
    error SharesMustSumToPartnerShare();
    error Bd2ShareWithoutWallet();
    error ResellerNotRegistered();
    error InvalidBdSlot();
    error InvalidBeacon();
    error AccountFrozen();
    error NothingReceived();
    error TransferAmountMismatch();
    error ResellerCodeTooLong();
    error FillShortfall();

    // ── constants ────────────────────────────────────────────────────────
    uint256 private constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 100;      // hardcoded 1% ceiling — admin can never raise past it
    uint16 public constant DEFAULT_FEE_BPS = 100;  // long-tail default tier
    uint16 public constant PARTNER_SHARE_BPS = 6000; // reseller + bd1 + bd2, always
    uint16 public constant BUYBACK_SHARE_BPS = 4000; // remainder by construction — untouchable
    uint16 private constant DEFAULT_BAND_BPS = 1000; // 10%
    uint16 private constant MIN_BAND_BPS = 100;
    uint16 private constant MAX_BAND_BPS = 5000;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_UPGRADER_ROLE = keccak256("EMERGENCY_UPGRADER_ROLE");
    bytes32 public constant TIMELOCK_ROLE = keccak256("TIMELOCK_ROLE");
    bytes32 public constant FREEZE_ADMIN_ROLE = keccak256("FREEZE_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ── storage (plan §3.1; OZ bases are ERC-7201 namespaced) ────────────
    address public poolBeacon;                                        // slot 0
    address public beaconProxyTemplate;                               // slot 1
    address public priceOracle;                                       // slot 2
    uint32 public oracleEpoch;                                        // slot 2 (packed)
    address public buybackReceiver;                                   // slot 3
    bool public freezeEnabled;                                        // slot 4
    mapping(address => uint16) public feeBpsOverride;                 // slot 5 (0 ⇒ default)
    mapping(address => bool) public approvedQuoteAssets;              // slot 6
    mapping(string => FlowstateStructs.ResellerConfig) private resellers; // slot 7
    mapping(address => FlowstateStructs.PoolRecord) public poolRecords;   // slot 8
    mapping(address => mapping(address => address)) public poolByPair;    // slot 9
    mapping(address => bool) public frozen;                           // slot 10
    uint256[40] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param timelock48 48h TimelockController — normal upgrades + protocol wiring.
    /// @param freezeTimelock24 24h TimelockController — compliance activation.
    /// @param emergencyTimelock12 12h TimelockController — emergency upgrade lane only
    ///        (market UUPS + pool beacon). It can USE the lane after 12h, but adding
    ///        another holder of that power still costs the full 48h, because
    ///        EMERGENCY_UPGRADER_ROLE is administered by TIMELOCK_ROLE.
    function initialize(
        address poolBeacon_,
        address beaconProxyTemplate_,
        address priceOracle_,
        address buybackReceiver_,
        address adminMultisig,
        address timelock48,
        address freezeTimelock24,
        address emergencyTimelock12
    ) external initializer {
        if (
            poolBeacon_ == address(0) || beaconProxyTemplate_ == address(0) || priceOracle_ == address(0)
                || buybackReceiver_ == address(0) || adminMultisig == address(0) || timelock48 == address(0)
                || freezeTimelock24 == address(0) || emergencyTimelock12 == address(0)
        ) revert ZeroAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        poolBeacon = poolBeacon_;
        beaconProxyTemplate = beaconProxyTemplate_;
        priceOracle = priceOracle_;
        buybackReceiver = buybackReceiver_;
        oracleEpoch = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, adminMultisig);
        _grantRole(PAUSER_ROLE, adminMultisig);
        _grantRole(UPGRADER_ROLE, timelock48);
        _grantRole(TIMELOCK_ROLE, timelock48);
        _grantRole(FREEZE_ADMIN_ROLE, freezeTimelock24);
        _grantRole(EMERGENCY_UPGRADER_ROLE, emergencyTimelock12);

        // Close the role-admin chain so the delayed lanes are enforced, not documented.
        // Order is safe either side of the grants above: _grantRole is the unchecked
        // internal, so it never consults getRoleAdmin — only the external grantRole does.
        // Kept after the grants so the seeded holders read as the starting membership.
        _setRoleAdmin(UPGRADER_ROLE, TIMELOCK_ROLE);
        _setRoleAdmin(EMERGENCY_UPGRADER_ROLE, TIMELOCK_ROLE);
        _setRoleAdmin(TIMELOCK_ROLE, TIMELOCK_ROLE);
        _setRoleAdmin(FREEZE_ADMIN_ROLE, FREEZE_ADMIN_ROLE);
        // PAUSER_ROLE deliberately left on DEFAULT_ADMIN_ROLE: pausing is the emergency
        // containment lever and must stay instantly grantable to a hot ops key.
    }

    /// @dev Two lanes: UPGRADER_ROLE (48h, silent — ERC-1967 Upgraded is the record) or
    ///      EMERGENCY_UPGRADER_ROLE (12h, additionally emits EmergencyUpgradeAuthorized).
    ///      A caller holding neither reverts with AccessControlUnauthorizedAccount naming
    ///      EMERGENCY_UPGRADER_ROLE — the last role checked, not the only one accepted.
    function _authorizeUpgrade(address newImplementation) internal override {
        if (hasRole(UPGRADER_ROLE, msg.sender)) return;
        _checkRole(EMERGENCY_UPGRADER_ROLE);
        emit FlowstateEvents.EmergencyUpgradeAuthorized(newImplementation, msg.sender);
    }

    /// @notice Ship a new FlowstatePool implementation to EVERY live pool in lock-step.
    ///         Normal lane: UPGRADER_ROLE (48h). Emergency lane: EMERGENCY_UPGRADER_ROLE
    ///         (12h), which additionally emits EmergencyUpgradeAuthorized.
    /// @dev Why this function exists: pool clones latch their beacon address into their
    ///      own ERC-1967 beacon slot at initialize, so setPoolBeacon/setBeaconProxyTemplate
    ///      only ever affect FUTURE clones — neither can ship a fix to a live pool. The
    ///      one call that reaches live pools is UpgradeableBeacon.upgradeTo, which is
    ///      owner-gated on the beacon itself. Routing it through the market is what puts
    ///      the pool-logic upgrade path under the same two-lane role model as the market's
    ///      own UUPS upgrade; without it the emergency lane could not reach the FIFO
    ///      ledger or claim logic, which is the stuck-funds case the lane exists for.
    /// @dev DEPLOYMENT REQUIREMENT: the beacon's owner must be this market proxy. If the
    ///      beacon is owned by anything else this call reverts inside the beacon's
    ///      Ownable check — a loud failure, never a silent no-op.
    function upgradePoolImplementation(address newImplementation) external {
        if (newImplementation == address(0)) revert ZeroAddress();
        bool emergency = !hasRole(UPGRADER_ROLE, msg.sender);
        if (emergency) _checkRole(EMERGENCY_UPGRADER_ROLE);

        IUpgradeableBeacon(poolBeacon).upgradeTo(newImplementation);

        emit FlowstateEvents.PoolImplementationUpgraded(newImplementation);
        if (emergency) emit FlowstateEvents.EmergencyUpgradeAuthorized(newImplementation, msg.sender);
    }

    // ────────────────────────────────────────────────────────────────────
    // Pool creation & liquidity
    // ────────────────────────────────────────────────────────────────────

    /// @notice One live pool per (token, quote) pair. The listability oracle read
    ///         doubles as the pool's anchor seed (plan R13).
    /// @dev Fee-on-transfer tokens are unsupported as inventory (review F-M2-2):
    ///      contributions are balance-diff safe, but buyers of a FoT token pay oracle
    ///      price for more than they receive. Listing discretion, not a code check.
    /// @param anchorBandBps 0 ⇒ default 1000 (10%); otherwise bounded [100, 5000].
    function createPool(address token, address quoteAsset, uint256 amount, uint16 anchorBandBps)
        external
        whenNotPaused
        nonReentrant
        returns (address pool)
    {
        if (token == address(0)) revert ZeroAddress();
        if (!approvedQuoteAssets[quoteAsset]) revert QuoteAssetNotApproved();
        if (poolByPair[token][quoteAsset] != address(0)) revert PoolAlreadyExists();

        uint16 band = anchorBandBps == 0 ? DEFAULT_BAND_BPS : anchorBandBps;
        if (band < MIN_BAND_BPS || band > MAX_BAND_BPS) revert InvalidBand();

        // listability rule: a pair is listable iff the aggregator returns a usable
        // direct rate — and that read seeds the anchor for free
        uint256 seedRate = IOracle(priceOracle).getRate(IERC20(token), IERC20(quoteAsset), false);
        if (seedRate == 0 || seedRate > type(uint192).max) revert NoOracleRate();

        pool = Clones.clone(beaconProxyTemplate);
        IInitializableBeaconProxy(pool).initialize(
            poolBeacon,
            abi.encodeCall(
                IFlowstatePool.initialize,
                (token, quoteAsset, address(this), band, uint192(seedRate), oracleEpoch)
            )
        );

        poolRecords[pool] = FlowstateStructs.PoolRecord(token, true, quoteAsset);
        poolByPair[token][quoteAsset] = pool;

        uint256 actual = _pullToPool(token, pool, amount);
        IFlowstatePool(pool).creditTokenContribution(msg.sender, actual);

        emit FlowstateEvents.PoolCreated(
            token, quoteAsset, pool, msg.sender, actual, band, uint192(seedRate)
        );
        emit FlowstateEvents.TokensContributed(pool, msg.sender, actual);
    }

    /// @notice Token-side (exiter) contribution to an existing pool.
    /// @param contributionOwner credited depositor; msg.sender pays. Deliberately no
    ///        auth link between the two: aggregators/APIs list on behalf of users, and
    ///        crediting someone else's address spends the caller's own tokens (gift
    ///        semantics) — "position inflation" is economically self-defeating (R10).
    function contributeTokens(address pool, uint256 amount, address contributionOwner)
        external
        whenNotPaused
        nonReentrant
    {
        FlowstateStructs.PoolRecord memory rec = poolRecords[pool];
        if (!rec.exists) revert UnknownPool();
        if (contributionOwner == address(0)) revert ZeroAddress();

        uint256 actual = _pullToPool(rec.inventoryToken, pool, amount);
        IFlowstatePool(pool).creditTokenContribution(contributionOwner, actual);
        emit FlowstateEvents.TokensContributed(pool, contributionOwner, actual);
    }

    /// @notice Quote-side (cash) contribution — reverts unless the pool's buy-back is
    ///         enabled. Same gift semantics as contributeTokens (R10).
    function contributeQuote(address pool, uint256 amount, address contributionOwner)
        external
        whenNotPaused
        nonReentrant
    {
        FlowstateStructs.PoolRecord memory rec = poolRecords[pool];
        if (!rec.exists) revert UnknownPool();
        if (contributionOwner == address(0)) revert ZeroAddress();

        uint256 actual = _pullToPool(rec.quoteAsset, pool, amount);
        IFlowstatePool(pool).creditQuoteContribution(contributionOwner, actual);
        emit FlowstateEvents.QuoteContributed(pool, contributionOwner, actual);
    }

    /// @notice Withdraw an unsold token-side position. Pass amount = 0 for the full
    ///         position. (Replaces legacy cancelPool; nonReentrant per audit fix.)
    function withdrawTokens(address pool, uint256 amount) external nonReentrant {
        if (!poolRecords[pool].exists) revert UnknownPool();
        (uint256 withdrawn, bool nowEmpty) = IFlowstatePool(pool).withdrawTokensFor(msg.sender, amount);
        emit FlowstateEvents.TokensWithdrawn(pool, msg.sender, withdrawn, nowEmpty);
    }

    /// @notice Withdraw unspent quote-side funds. Pass amount = 0 for the full position.
    function withdrawQuote(address pool, uint256 amount) external nonReentrant {
        if (!poolRecords[pool].exists) revert UnknownPool();
        (uint256 withdrawn, bool cashSideEmpty) = IFlowstatePool(pool).withdrawQuoteFor(msg.sender, amount);
        emit FlowstateEvents.QuoteWithdrawn(pool, msg.sender, withdrawn, cashSideEmpty);
    }

    // ────────────────────────────────────────────────────────────────────
    // Trading (aggregator-facing)
    // ────────────────────────────────────────────────────────────────────

    /// @notice Pull-exact buy: the pool computes the band-checked oracle cost for the
    ///         fillable amount; the factory pulls exactly that from msg.sender into
    ///         the pool; the pool settles ledgers, fees, and token delivery.
    /// @dev Approved quote assets are vetted no-fee-on-transfer (USDC/WETH class);
    ///      the pull amount is credited at face value.
    function buyFromPool(address pool, uint256 amount, string calldata resellerCode, address buyer)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokensFilled, uint256 quotePaid)
    {
        FlowstateStructs.PoolRecord memory rec = poolRecords[pool];
        if (!rec.exists) revert UnknownPool();
        if (buyer == address(0)) revert ZeroAddress();
        _checkCode(resellerCode);
        if (freezeEnabled && (frozen[msg.sender] || frozen[buyer])) revert AccountFrozen();

        uint256 rate;
        (tokensFilled, quotePaid, rate) = IFlowstatePool(pool).priceBuy(amount, priceOracle, oracleEpoch);

        IERC20(rec.quoteAsset).safeTransferFrom(msg.sender, pool, quotePaid);

        IFlowstatePool(pool).settleBuy(
            buyer, tokensFilled, quotePaid, rate, _feeContext(rec.inventoryToken, resellerCode)
        );
    }

    /// @notice Exact-quote-input buy (V4 hook build scope §2.2, additive pair 1/2):
    ///         the caller names the quote spend; the pool inverts to a token amount
    ///         inside its single band-checked oracle read (the view quote path is
    ///         never involved, so no second cold read exists). All-or-nothing: reverts
    ///         with the pool's FillShortfall if inventory cannot cover the full
    ///         inverted amount.
    /// @dev Pull-exact and fee incidence are unchanged: the factory pulls `quotePaid`
    ///      — the exact oracle cost of the tokens delivered, ≤ quoteIn (the inversion
    ///      rounds tokens DOWN against the buyer, so up to one token-wei's worth of
    ///      quote dust can stay with the caller rather than be overcharged) — and the
    ///      30/30/40 fee is carved from the seller leg in settleBuy, so accounting is
    ///      wei-identical to buyFromPool of the same token amount.
    /// @return tokensFilled tokens delivered to `buyer`.
    /// @return quotePaid    quote-asset units pulled from msg.sender (≤ quoteIn).
    function buyFromPoolExactQuote(address pool, uint256 quoteIn, string calldata resellerCode, address buyer)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokensFilled, uint256 quotePaid)
    {
        FlowstateStructs.PoolRecord memory rec = poolRecords[pool];
        if (!rec.exists) revert UnknownPool();
        if (buyer == address(0)) revert ZeroAddress();
        _checkCode(resellerCode);
        if (freezeEnabled && (frozen[msg.sender] || frozen[buyer])) revert AccountFrozen();

        uint256 rate;
        (tokensFilled, quotePaid, rate) =
            IFlowstatePool(pool).priceBuyExactQuote(quoteIn, priceOracle, oracleEpoch);

        IERC20(rec.quoteAsset).safeTransferFrom(msg.sender, pool, quotePaid);

        IFlowstatePool(pool).settleBuy(
            buyer, tokensFilled, quotePaid, rate, _feeContext(rec.inventoryToken, resellerCode)
        );
    }

    /// @notice Exact-output buy with funding callback (V4 hook build scope §2.2,
    ///         additive pair 2/2 — resolves the Phase 0 funding-order finding): prices
    ///         `tokenAmountOut` in the pool's single oracle read, then lets an
    ///         under-funded contract caller fund itself (the V4 hook does
    ///         PoolManager.take inside fundBuy) before the pull-exact transferFrom.
    ///         All-or-nothing: reverts FillShortfall unless the pool can fill exactly
    ///         tokenAmountOut.
    /// @dev Callback rules (additive safety for every existing caller class): fundBuy
    ///      is invoked ONLY when msg.sender has code AND its quote balance or its
    ///      allowance to this factory does not already cover the cost — a pre-funded
    ///      EOA or contract is served with zero behavior change vs buyFromPool and
    ///      need not implement IFlowstateBuyFunder. Reentrancy: the callback runs
    ///      under this function's nonReentrant guard, which every state-changing
    ///      market entry point shares, so the callee cannot re-enter trading or
    ///      liquidity paths; it runs BEFORE the pull and before any ledger mutation —
    ///      the only state already written is the pool's anchor advance from priceBuy,
    ///      exactly the pre-transfer state buyFromPool itself exposes to the quote
    ///      asset's transferFrom. The callee is msg.sender itself, never a third
    ///      party, so no address can be forced into an unexpected call.
    /// @return tokensFilled tokens delivered to `buyer` (== tokenAmountOut).
    /// @return quotePaid    quote-asset units pulled from msg.sender.
    function buyFromPoolExactOut(address pool, uint256 tokenAmountOut, string calldata resellerCode, address buyer)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokensFilled, uint256 quotePaid)
    {
        FlowstateStructs.PoolRecord memory rec = poolRecords[pool];
        if (!rec.exists) revert UnknownPool();
        if (buyer == address(0)) revert ZeroAddress();
        _checkCode(resellerCode);
        if (freezeEnabled && (frozen[msg.sender] || frozen[buyer])) revert AccountFrozen();

        uint256 rate;
        (tokensFilled, quotePaid, rate) =
            IFlowstatePool(pool).priceBuy(tokenAmountOut, priceOracle, oracleEpoch);
        if (tokensFilled != tokenAmountOut) revert FillShortfall();

        IERC20 quote = IERC20(rec.quoteAsset);
        if (
            msg.sender.code.length != 0
                && (
                    quote.balanceOf(msg.sender) < quotePaid
                        || quote.allowance(msg.sender, address(this)) < quotePaid
                )
        ) {
            IFlowstateBuyFunder(msg.sender).fundBuy(rec.quoteAsset, quotePaid);
        }
        quote.safeTransferFrom(msg.sender, pool, quotePaid);

        IFlowstatePool(pool).settleBuy(
            buyer, tokensFilled, quotePaid, rate, _feeContext(rec.inventoryToken, resellerCode)
        );
    }

    /// @notice Sell into the pool's buy-back side (live only where enabled). The pool
    ///         prices the fillable amount first; the factory pulls exactly that many
    ///         inventory tokens; fee-on-transfer inventory is rejected on this path
    ///         (the pool would pay for tokens it did not receive).
    /// @return tokensSold    inventory tokens the pool bought
    /// @return quoteProceeds quote paid to the seller (net of fee)
    function sellToPool(address pool, uint256 amount, string calldata resellerCode, address seller)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokensSold, uint256 quoteProceeds)
    {
        FlowstateStructs.PoolRecord memory rec = poolRecords[pool];
        if (!rec.exists) revert UnknownPool();
        if (seller == address(0)) revert ZeroAddress();
        _checkCode(resellerCode);
        if (freezeEnabled && (frozen[msg.sender] || frozen[seller])) revert AccountFrozen();

        (uint256 fillable, uint256 quoteGross, uint256 rate) =
            IFlowstatePool(pool).priceSell(amount, priceOracle, oracleEpoch);

        uint256 actual = _pullToPool(rec.inventoryToken, pool, fillable);
        if (actual != fillable) revert TransferAmountMismatch();

        quoteProceeds = IFlowstatePool(pool).settleSell(
            seller, fillable, quoteGross, rate, _feeContext(rec.inventoryToken, resellerCode)
        );
        tokensSold = fillable;
    }

    // ────────────────────────────────────────────────────────────────────
    // Quoters (SOR/adapter integration — NEVER revert)
    // ────────────────────────────────────────────────────────────────────

    /// @notice Non-reverting quote for a buy. `quoteAmount` is exactly what
    ///         buyFromPool would pull in the same block with the same args (the
    ///         consistency invariant aggregators route on). `available == false` on
    ///         any non-quotable state: unknown pool, pause, empty, band-out, oracle
    ///         failure. Freeze status is per-caller and deliberately not reflected.
    function quoteBuyFromPool(address pool, uint256 amount)
        external
        view
        returns (FlowstateStructs.Quote memory q)
    {
        FlowstateStructs.PoolRecord memory rec = poolRecords[pool];
        if (!rec.exists || paused()) return q;
        (bool ok, uint256 fillable, uint256 cost) =
            IFlowstatePool(pool).previewBuy(amount, priceOracle, oracleEpoch);
        if (!ok) return q;
        uint16 feeBps = _feeBpsOf(rec.inventoryToken);
        q = FlowstateStructs.Quote({
            available: true,
            fillableAmount: fillable,
            quoteAmount: cost, // buyer pays cost; the fee is carved out of the seller leg
            feeAmount: (cost * feeBps) / 10_000,
            feeBps: feeBps,
            quoteAsset: rec.quoteAsset
        });
    }

    /// @notice Non-reverting quote for a sell. `quoteAmount` is the seller-visible
    ///         NET proceeds (gross − fee), matching sellToPool's return value.
    function quoteSellToPool(address pool, uint256 amount)
        external
        view
        returns (FlowstateStructs.Quote memory q)
    {
        FlowstateStructs.PoolRecord memory rec = poolRecords[pool];
        if (!rec.exists || paused()) return q;
        (bool ok, uint256 fillable, uint256 gross) =
            IFlowstatePool(pool).previewSell(amount, priceOracle, oracleEpoch);
        if (!ok) return q;
        uint16 feeBps = _feeBpsOf(rec.inventoryToken);
        uint256 fee = (gross * feeBps) / 10_000;
        q = FlowstateStructs.Quote({
            available: true,
            fillableAmount: fillable,
            quoteAmount: gross - fee,
            feeAmount: fee,
            feeBps: feeBps,
            quoteAsset: rec.quoteAsset
        });
    }

    // ────────────────────────────────────────────────────────────────────
    // Claims convenience (R5) — pools also expose direct claimQuote()/claimTokens()
    // ────────────────────────────────────────────────────────────────────

    function claimMany(address[] calldata pools, bool alsoTokens) external nonReentrant {
        uint256 length = pools.length;
        for (uint256 i = 0; i < length; ++i) {
            if (!poolRecords[pools[i]].exists) revert UnknownPool();
            IFlowstatePool(pools[i]).claimQuoteFor(msg.sender);
            if (alsoTokens) IFlowstatePool(pools[i]).claimTokensFor(msg.sender);
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // Fee & partner admin (instant multisig lane — §3.7)
    // ────────────────────────────────────────────────────────────────────

    function setFeeBps(address token, uint16 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeBps > MAX_FEE_BPS) revert FeeExceedsCap();
        feeBpsOverride[token] = feeBps; // 0 resets to DEFAULT_FEE_BPS
        emit FlowstateEvents.FeeBpsSet(token, feeBps);
    }

    function setQuoteAsset(address asset, bool approved) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        approvedQuoteAssets[asset] = approved;
        emit FlowstateEvents.QuoteAssetSet(asset, approved);
    }

    function registerReseller(
        string calldata code,
        address payable wallet,
        uint16 resellerShareBps,
        address payable bd1,
        uint16 bd1ShareBps,
        address payable bd2,
        uint16 bd2ShareBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkCode(code);
        _requireEOA(wallet);
        if (bd1 == address(0)) revert BDWalletRequired();
        _requireEOA(bd1);
        if (bd2 == address(0)) {
            if (bd2ShareBps != 0) revert Bd2ShareWithoutWallet();
        } else {
            _requireEOA(bd2);
        }
        _checkShareSum(resellerShareBps, bd1ShareBps, bd2ShareBps);

        resellers[code] = FlowstateStructs.ResellerConfig(
            wallet, resellerShareBps, true, bd1, bd1ShareBps, bd2, bd2ShareBps
        );
        emit FlowstateEvents.ResellerRegistered(
            code, wallet, resellerShareBps, bd1, bd1ShareBps, bd2, bd2ShareBps
        );
    }

    function updateResellerShare(string calldata code, uint16 r, uint16 b1, uint16 b2)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        FlowstateStructs.ResellerConfig storage rc = _registered(code);
        if (rc.bd2 == address(0) && b2 != 0) revert Bd2ShareWithoutWallet();
        _checkShareSum(r, b1, b2);
        rc.resellerShareBps = r;
        rc.bd1ShareBps = b1;
        rc.bd2ShareBps = b2;
        emit FlowstateEvents.ResellerShareUpdated(code, r, b1, b2);
    }

    function updateResellerWallet(string calldata code, address payable newWallet)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        FlowstateStructs.ResellerConfig storage rc = _registered(code);
        _requireEOA(newWallet); // EOA re-check on every update path (R9)
        address old = rc.wallet;
        rc.wallet = newWallet;
        emit FlowstateEvents.ResellerWalletUpdated(code, old, newWallet);
    }

    function updateBdWallet(string calldata code, uint8 slot, address payable newWallet)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        FlowstateStructs.ResellerConfig storage rc = _registered(code);
        address old;
        if (slot == 1) {
            _requireEOA(newWallet); // bd1 is mandatory — cannot be cleared (R9)
            old = rc.bd1;
            rc.bd1 = newWallet;
        } else if (slot == 2) {
            if (newWallet == address(0)) {
                if (rc.bd2ShareBps != 0) revert Bd2ShareWithoutWallet();
            } else {
                _requireEOA(newWallet);
            }
            old = rc.bd2;
            rc.bd2 = newWallet;
        } else {
            revert InvalidBdSlot();
        }
        emit FlowstateEvents.BdWalletUpdated(code, slot, old, newWallet);
    }

    function getReseller(string calldata code)
        external
        view
        returns (FlowstateStructs.ResellerConfig memory)
    {
        return resellers[code];
    }

    // ────────────────────────────────────────────────────────────────────
    // Pool config admin (instant multisig lane — §3.7)
    // ────────────────────────────────────────────────────────────────────

    function setAnchorBand(address pool, uint16 bandBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!poolRecords[pool].exists) revert UnknownPool();
        IFlowstatePool(pool).setAnchorBand(bandBps);
        emit FlowstateEvents.AnchorBandUpdated(pool, bandBps);
    }

    /// @notice PARKED slot (plan): only 0 (AGGREGATOR) is valid in pass 1.
    function setPriceSource(address pool, uint8 source) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!poolRecords[pool].exists) revert UnknownPool();
        IFlowstatePool(pool).setPriceSource(source);
        emit FlowstateEvents.PriceSourceUpdated(pool, source);
    }

    /// @notice Liveness escape hatch for drift beyond the widened band (D3).
    function resetAnchor(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!poolRecords[pool].exists) revert UnknownPool();
        IFlowstatePool(pool).resetAnchor(priceOracle, oracleEpoch);
    }

    /// @notice Per-pool buy-back config (§4 scope): enable flag (ships OFF), buy-side
    ///         spread, and quote-spend window cap.
    function setBuyBack(
        address pool,
        bool enabled,
        uint16 spreadBps,
        uint128 maxQuotePerWindow,
        uint32 windowSeconds
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!poolRecords[pool].exists) revert UnknownPool();
        IFlowstatePool(pool).setBuyBack(enabled, spreadBps, maxQuotePerWindow, windowSeconds);
        emit FlowstateEvents.BuyBackConfigured(pool, enabled, spreadBps, maxQuotePerWindow, windowSeconds);
    }

    /// @notice Emergency stop: pausing needs PAUSER_ROLE (hot-key eligible);
    ///         unpausing is DEFAULT_ADMIN_ROLE only.
    function pausePool(address pool, bool paused) external {
        _checkRole(paused ? PAUSER_ROLE : DEFAULT_ADMIN_ROLE);
        if (!poolRecords[pool].exists) revert UnknownPool();
        IFlowstatePool(pool).setPaused(paused);
        emit FlowstateEvents.PoolPausedSet(pool, paused);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ────────────────────────────────────────────────────────────────────
    // Compliance (dormant behind freezeEnabled — §3.7/R6)
    // ────────────────────────────────────────────────────────────────────

    /// @notice Blocks ONE named address from trading. Cannot move or seize funds,
    ///         cannot batch. Every call is a public event. Meaningful only once
    ///         freezeEnabled is activated through the 24h timelock.
    function setFrozen(address account, bool isFrozen) external onlyRole(DEFAULT_ADMIN_ROLE) {
        frozen[account] = isFrozen;
        if (isFrozen) emit FlowstateEvents.AddressFrozen(account);
        else emit FlowstateEvents.AddressUnfrozen(account);
    }

    function setFreezeEnabled(bool enabled) external onlyRole(FREEZE_ADMIN_ROLE) {
        freezeEnabled = enabled;
        emit FlowstateEvents.FreezeEnabledSet(enabled);
    }

    // ────────────────────────────────────────────────────────────────────
    // Wiring admin (timelocked lane — §3.7)
    // ────────────────────────────────────────────────────────────────────

    /// @notice Timelocked. Bumps oracleEpoch so every pool reseeds its anchor
    ///         band-check-free on its next trade (R3) — no per-pool ops needed.
    function setPriceOracle(address oracle) external onlyRole(TIMELOCK_ROLE) {
        if (oracle == address(0)) revert ZeroAddress();
        address oldOracle = priceOracle;
        priceOracle = oracle;
        uint32 newEpoch = ++oracleEpoch;
        emit FlowstateEvents.PriceOracleUpdated(oldOracle, oracle, newEpoch);
    }

    /// @notice Timelocked. Probes the beacon so an implementation address can never
    ///         be stored where a beacon belongs (legacy setPoolImplementations bug).
    function setPoolBeacon(address beacon) external onlyRole(TIMELOCK_ROLE) {
        if (beacon == address(0)) revert ZeroAddress();
        try IBeacon(beacon).implementation() returns (address impl) {
            if (impl == address(0)) revert InvalidBeacon();
        } catch {
            revert InvalidBeacon();
        }
        poolBeacon = beacon;
        emit FlowstateEvents.PoolBeaconUpdated(beacon);
    }

    function setBeaconProxyTemplate(address template) external onlyRole(TIMELOCK_ROLE) {
        if (template == address(0)) revert ZeroAddress();
        beaconProxyTemplate = template;
        emit FlowstateEvents.BeaconProxyTemplateUpdated(template);
    }

    function setBuybackReceiver(address receiver) external onlyRole(TIMELOCK_ROLE) {
        if (receiver == address(0)) revert ZeroAddress();
        buybackReceiver = receiver;
        emit FlowstateEvents.BuybackReceiverUpdated(receiver);
    }

    // ────────────────────────────────────────────────────────────────────
    // Internals
    // ────────────────────────────────────────────────────────────────────

    /// @dev Balance-diff transfer (fee-on-transfer-safe for inventory tokens).
    function _pullToPool(address token, address pool, uint256 amount) private returns (uint256 actual) {
        uint256 before = IERC20(token).balanceOf(pool);
        IERC20(token).safeTransferFrom(msg.sender, pool, amount);
        actual = IERC20(token).balanceOf(pool) - before;
        if (actual == 0) revert NothingReceived();
    }

    function _feeBpsOf(address token) private view returns (uint16 feeBps) {
        feeBps = feeBpsOverride[token];
        if (feeBps == 0) feeBps = DEFAULT_FEE_BPS;
    }

    /// @dev Unregistered/empty code ⇒ all shares zero ⇒ the whole fee routes to
    ///      buyback via the pool's remainder rule.
    function _feeContext(address token, string calldata resellerCode)
        private
        view
        returns (FlowstateStructs.FeeContext memory ctx)
    {
        ctx.feeBps = _feeBpsOf(token);
        ctx.buybackReceiver = buybackReceiver;
        ctx.resellerCode = resellerCode;

        FlowstateStructs.ResellerConfig storage rc = resellers[resellerCode];
        if (rc.registered) {
            ctx.resellerWallet = rc.wallet;
            ctx.resellerShareBps = rc.resellerShareBps;
            ctx.bd1 = rc.bd1;
            ctx.bd1ShareBps = rc.bd1ShareBps;
            ctx.bd2 = rc.bd2;
            ctx.bd2ShareBps = rc.bd2ShareBps;
        }
    }

    function _registered(string calldata code)
        private
        view
        returns (FlowstateStructs.ResellerConfig storage rc)
    {
        rc = resellers[code];
        if (!rc.registered) revert ResellerNotRegistered();
    }

    /// @dev EOA-only rule: smart wallets are not address-portable across chains;
    ///      fees sent to a non-portable address on another chain are unrecoverable.
    ///      Re-run on EVERY wallet write, not just registration (R9).
    function _requireEOA(address account) private view {
        if (account == address(0)) revert ZeroAddress();
        if (account.code.length != 0) revert NotEOA();
    }

    function _checkShareSum(uint16 r, uint16 b1, uint16 b2) private pure {
        if (uint256(r) + b1 + b2 != PARTNER_SHARE_BPS) revert SharesMustSumToPartnerShare();
    }

    /// @dev Reseller codes are short human-readable identifiers; the cap keeps the
    ///      hot path's calldata/memory/log cost bounded (review F3).
    function _checkCode(string calldata code) private pure {
        if (bytes(code).length > 32) revert ResellerCodeTooLong();
    }
}
