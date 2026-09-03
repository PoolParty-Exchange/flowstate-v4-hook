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

import "./interface/IFlowstateC1Hook.sol";
import "./interface/IOracle.sol";
import "./interface/IFlowstatePool.sol";
import "./interface/IFlowstateBuyFunder.sol";
import "./interface/IInitializableBeaconProxy.sol";
import "./interface/IUpgradeableBeacon.sol";
import "./libraries/FlowstateStructs.sol";
import "./libraries/FlowstateEvents.sol";
import {Mul512Compare} from "./libraries/Mul512Compare.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
 * (chain-specific recipients, shares sum to 6000), setAnchorBand, setPriceSource (parked), setBuyBack,
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
    // FS-R0-C-01b seller-side consent floors
    error FloorRequired(); // empty list, zero minRate, unapproved asset, or duplicate asset
    error SeedBelowFloor(address asset, uint256 rate, uint256 minRate);
    error AnchorBelowFloor(address asset, uint256 anchorRate, uint256 minRate);
    error FloorMissingForAsset(address asset); // pool carries an anchor the contributor did not consent to
    error FloorForUnseededAsset(address asset); // contributor consented to an asset the pool has no anchor for
    /// @dev JUP-612: a token-side contribution must itself be worth at least the
    ///      inventory floor in at least one floored, seeded asset (valued at that
    ///      asset's durable anchor). `asset` is the first floored seeded asset
    ///      checked, for the error's benefit.
    error ContributionBelowFloor(address asset, uint256 value, uint256 floor); // `floor` = the threshold applied: max(inventoryFloor, minContribution)
    error PoolNotPaused(); // compactDust is a paused-pool maintenance step (Wilko round 3)
    /// @dev Bounded entry points (JUP-544). Each carries the actuals so an
    ///      integrator's revert decode names the miss, not just the fact of one.
    error DeadlineExpired(uint256 deadline, uint256 nowTimestamp);
    error CostAboveBound(uint256 quotePaid, uint256 tokensFilled);
    error FillBelowBound(uint256 filled, uint256 minFilled);
    error ProceedsBelowBound(uint256 quoteProceeds, uint256 tokensSold);

    // ── constants ────────────────────────────────────────────────────────
    uint256 private constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 100;      // hardcoded 1% ceiling — admin can never raise past it
    uint16 public constant DEFAULT_FEE_BPS = 100;  // long-tail default tier
    uint16 public constant PARTNER_SHARE_BPS = 6000; // reseller + bd1 + bd2, always
    uint16 public constant BUYBACK_SHARE_BPS = 4000; // remainder by construction — untouchable
    // 10% — widened from 500 on measured keeper-gas evidence (real CASHCAT 60s series:
    // 1 poke/12h at 1000bps vs 7-9 at 500bps; a poke costs ~824k gas). The accepted
    // cost, stated plainly: an in-band read is believed with NO confirmation, so the
    // band width IS the atomic flash-loan drain size (scenario I measures 4.00% taken
    // in one tx at 500bps, 9.00% at 1000bps). Confirmation guards only moves LARGER
    // than the band.
    uint16 private constant DEFAULT_BAND_BPS = 1000;
    uint16 private constant MIN_BAND_BPS = 100;
    uint16 private constant MAX_BAND_BPS = 5000;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_UPGRADER_ROLE = keccak256("EMERGENCY_UPGRADER_ROLE");
    bytes32 public constant TIMELOCK_ROLE = keccak256("TIMELOCK_ROLE");
    bytes32 public constant FREEZE_ADMIN_ROLE = keccak256("FREEZE_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ── storage (plan §3.1; OZ bases are ERC-7201 namespaced) ────────────
    // Multi-asset change: pools are keyed by inventory token alone (poolByToken
    // replaces the old poolByPair mapping — a legacy-shape poolByPair VIEW remains
    // below for integrators), and the approved quote assets gain an enumeration
    // list so createPool can seed one anchor per priceable asset.
    address public poolBeacon;                                        // slot 0
    address public beaconProxyTemplate;                               // slot 1
    address public priceOracle;                                       // slot 2
    uint32 public oracleEpoch;                                        // slot 2 (packed)
    address public buybackReceiver;                                   // slot 3
    bool public freezeEnabled;                                        // slot 3 (packed after buybackReceiver)
    mapping(address => uint16) public feeBpsOverride;                 // slot 4 (0 ⇒ default)
    mapping(address => bool) public approvedQuoteAssets;              // slot 5
    mapping(string => FlowstateStructs.ResellerConfig) private resellers; // slot 6
    mapping(address => FlowstateStructs.PoolRecord) public poolRecords;   // slot 7
    mapping(address => address) public poolByToken;                   // slot 8
    mapping(address => bool) public frozen;                           // slot 9
    address[] private quoteAssetList;                                 // slot 10 (ever-approved, dedup'd)
    mapping(address => bool) private inQuoteAssetList;                // slot 11
    /// @dev JUP-587: the V4 hook createPool auto-registers new pairs with.
    ///      address(0) = feature off (createPool behaves exactly as pre-upgrade).
    address public trustedHook;                                       // slot 12
    /// @dev JUP-612: per-quote-asset inventory floor, in that asset's units (so
    ///      20 USDG = 20e6, 0.008 aeWETH = 8e15). A pool whose reachable inventory
    ///      is worth less than this at the trade rate is EMPTY: quotes answer
    ///      available = false, buys revert NoLiquidity, maxBuy answers zero. A
    ///      restock above it reopens the pool in the same block; a price move
    ///      across it closes or reopens without any call. 0 = no floor (legacy).
    ///      Founder decision 2 Sep 2026: $20 equivalent, retuned rarely.
    mapping(address => uint256) public inventoryFloor;                // slot 13
    /// @dev JUP-619: per-quote-asset MINIMUM DEPOSIT, in that asset's units. A
    ///      token-side contribution must be worth at least max(inventoryFloor,
    ///      minContribution) in at least one seeded asset that has either set,
    ///      valued at that asset's durable anchor. 0 = fall back to the floor.
    ///      Founder decision 3 Sep 2026: $100 equivalent (a smaller position has
    ///      no price-impact pain that a C1 deposit would relieve), so 100e6 USDG
    ///      and 4e16 aeWETH at ~$2,500.
    mapping(address => uint256) public minContribution;               // slot 14
    uint256[35] private __gap;

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

    /// @notice One live pool per TOKEN (multi-asset change): the pool accepts every
    ///         approved quote asset. Creation seeds one anchor per approved asset the
    ///         oracle can price — the depositor picks the seeding moment (plan R13),
    ///         and at least one asset must be priceable for the token to be listable.
    ///         Assets that fail here (or get approved later) are seeded through the
    ///         admin resetAnchor lane; they simply decline to trade until then.
    /// @dev Fee-on-transfer tokens are unsupported as inventory (review F-M2-2):
    ///      contributions are balance-diff safe, but buyers of a FoT token pay oracle
    ///      price for more than they receive. Listing discretion, not a code check.
    /// @param anchorBandBps 0 ⇒ default 1000 (10%); otherwise bounded [100, 5000].
    function createPool(
        address token,
        uint256 amount,
        uint16 anchorBandBps,
        FlowstateStructs.AnchorFloor[] calldata floors
    )
        external
        whenNotPaused
        nonReentrant
        returns (address pool)
    {
        if (token == address(0)) revert ZeroAddress();
        if (poolByToken[token] != address(0)) revert PoolAlreadyExists();
        uint256 floorCount = floors.length;
        if (floorCount == 0) revert FloorRequired();

        uint16 band = anchorBandBps == 0 ? DEFAULT_BAND_BPS : anchorBandBps;
        if (band < MIN_BAND_BPS || band > MAX_BAND_BPS) revert InvalidBand();

        pool = Clones.clone(beaconProxyTemplate);
        IInitializableBeaconProxy(pool).initialize(
            poolBeacon,
            abi.encodeCall(IFlowstatePool.initialize, (token, address(this), band))
        );

        // FS-R0-C-01b: the genesis anchor is band-check-free by definition, so its
        // value is the CREATOR's to accept, not the market's to validate. Only the
        // assets the creator listed are seeded, each against the creator's own floor.
        // A read below the floor means the venue is displaced at the moment of
        // creation (a sandwich, or a flash the creator did not choose): the honest
        // creator reverts instead of being born poisoned, and nothing is claimed for
        // the token. Assets the creator did not list stay unseeded — buys in them
        // revert AnchorNotSeeded — until an admin resetAnchor seeds them.
        // listability rule: listable iff the aggregator returns a usable direct rate
        // against AT LEAST ONE consented asset. try/catch per asset: one unpriceable
        // pairing must not block the others (a below-floor read is NOT unpriceable,
        // it is refused).
        uint256 seeded;
        for (uint256 i = 0; i < floorCount; ++i) {
            FlowstateStructs.AnchorFloor calldata f = floors[i];
            if (f.minRate == 0 || !approvedQuoteAssets[f.asset]) revert FloorRequired();
            for (uint256 j = 0; j < i; ++j) {
                if (floors[j].asset == f.asset) revert FloorRequired();
            }
            try IOracle(priceOracle).getRate(IERC20(token), IERC20(f.asset), false) returns (uint256 r) {
                if (r == 0 || r > type(uint192).max) continue;
                if (r < f.minRate) revert SeedBelowFloor(f.asset, r, f.minRate);
                IFlowstatePool(pool).seedAnchor(f.asset, uint192(r), oracleEpoch);
                ++seeded;
            } catch {
                continue;
            }
        }
        if (seeded == 0) revert NoOracleRate();
        uint256 length = quoteAssetList.length;

        poolRecords[pool] = FlowstateStructs.PoolRecord(token, true);
        poolByToken[token] = pool;

        // JUP-587: open the new pool's V4 doorway in the same transaction — one
        // registration per approved asset with the trusted hook. try/catch per
        // pair: a hook fault (or the feature being off) must NEVER block pool
        // creation; the failure event is the off-chain provisioner's repair
        // signal. Registered after poolByToken is set so the hook can read the
        // registry if it chooses to. All approved assets are registered, seeded
        // or not: an asset seeded later via resetAnchor then quotes through an
        // already-open lane instead of waiting for an operator to notice.
        address hook = trustedHook;
        if (hook != address(0)) {
            for (uint256 i = 0; i < length; ++i) {
                address asset = quoteAssetList[i];
                if (!approvedQuoteAssets[asset]) continue;
                try IFlowstateC1Hook(hook).registerPairFromMarket(asset, token, pool) {
                    emit FlowstateEvents.HookPairAutoRegistered(pool, token, asset);
                } catch {
                    emit FlowstateEvents.HookPairAutoRegistrationFailed(pool, token, asset);
                }
            }
        }

        uint256 actual = _pullToPool(token, pool, amount);
        _requireContributionAboveFloor(pool, actual);
        IFlowstatePool(pool).creditTokenContribution(msg.sender, actual);

        emit FlowstateEvents.PoolCreated(token, pool, msg.sender, actual, band);
        emit FlowstateEvents.TokensContributed(pool, msg.sender, actual);
    }

    /// @notice Token-side (exiter) contribution to an existing pool.
    /// @param contributionOwner credited depositor; msg.sender pays. Deliberately no
    ///        auth link between the two: aggregators/APIs list on behalf of users, and
    ///        crediting someone else's address spends the caller's own tokens (gift
    ///        semantics) — "position inflation" is economically self-defeating (R10).
    /// @notice Add inventory to an existing pool. `floors` is the contributor's consent
    ///         to the pool's CURRENT anchors (FS-R0-C-01b): one entry per seeded quote
    ///         asset, each naming the lowest anchor the contributor will fund against.
    ///         Reverts if any anchor sits below its floor, if a seeded asset has no
    ///         floor, or if a floor names an asset the pool has not seeded.
    function contributeTokens(
        address pool,
        uint256 amount,
        address contributionOwner,
        FlowstateStructs.AnchorFloor[] calldata floors
    )
        external
        whenNotPaused
        nonReentrant
    {
        FlowstateStructs.PoolRecord memory rec = poolRecords[pool];
        if (!rec.exists) revert UnknownPool();
        if (contributionOwner == address(0)) revert ZeroAddress();
        _requireAnchorConsent(pool, floors);

        uint256 actual = _pullToPool(rec.inventoryToken, pool, amount);
        _requireContributionAboveFloor(pool, actual);
        IFlowstatePool(pool).creditTokenContribution(contributionOwner, actual);
        emit FlowstateEvents.TokensContributed(pool, contributionOwner, actual);
    }

    /// @dev JUP-612 minimum contribution. Why: a fill reaches only the first
    ///      MAX_FILL_NODES FIFO nodes, and below the floor every buy refuses, so 50
    ///      one-wei nodes parked at the head of the queue would close the pool and
    ///      could never be bought away — a restock behind them would stay unreachable
    ///      for ever (Robin, 3 Sep 2026). The rule that removes the shape: a node is
    ///      only accepted if it is itself worth at least the floor in at least one
    ///      floored, seeded asset, valued at that asset's DURABLE anchor (never the
    ///      fresh read, which a flash loan can move). Assets with no floor impose
    ///      nothing, so with every floor at 0 this is a no-op (legacy behaviour).
    ///      The same $20 that keeps a pool listed is the least a deposit can be.
    ///      JUP-619 raises the bar above the floor: the threshold is
    ///      max(inventoryFloor, minContribution) per asset, so the least a holder
    ///      can deposit is a position worth listing, not merely one that keeps the
    ///      pool open.
    function _requireContributionAboveFloor(address pool, uint256 actual) private view {
        address[] memory seeded = IFlowstatePool(pool).seededAssets();
        uint256 n = seeded.length;
        address firstFloored;
        uint256 firstValue;
        uint256 firstFloor;
        for (uint256 i = 0; i < n; ++i) {
            address asset = seeded[i];
            uint256 floor = _depositThreshold(asset);
            if (floor == 0 || !approvedQuoteAssets[asset]) continue;
            (uint192 anchorRate,,) = IFlowstatePool(pool).anchorOf(asset);
            uint256 value = Math.mulDiv(actual, anchorRate, 1e18);
            if (value >= floor) return; // clears the floor in this asset: accepted
            if (firstFloored == address(0)) {
                firstFloored = asset;
                firstValue = value;
                firstFloor = floor;
            }
        }
        if (firstFloored != address(0)) revert ContributionBelowFloor(firstFloored, firstValue, firstFloor);
        // no floored asset seeded ⇒ nothing to enforce
    }

    /// @dev The per-asset value a token-side deposit must clear (and a partial
    ///      withdrawal must leave), in `asset` units: JUP-619 = the larger of the
    ///      inventory floor and the minimum deposit.
    function _depositThreshold(address asset) internal view returns (uint256) {
        uint256 floor = inventoryFloor[asset];
        uint256 minimum = minContribution[asset];
        return minimum > floor ? minimum : floor;
    }

    /// @dev The smallest position a PARTIAL withdrawal may leave, in inventory-token
    ///      units: the deposit threshold converted at each floored seeded asset's
    ///      DURABLE anchor (stored state, no oracle read, so exits never depend on a
    ///      live price), taking the least demanding asset — the mirror of "a deposit
    ///      clears the threshold in at least one asset". 0 when no seeded asset has
    ///      a threshold. Rounds UP so a residual that values to one wei under the
    ///      threshold is refused, not accepted.
    function _minResidualTokens(address pool) private view returns (uint256 minResidual) {
        address[] memory seeded = IFlowstatePool(pool).seededAssets();
        uint256 n = seeded.length;
        for (uint256 i = 0; i < n; ++i) {
            address asset = seeded[i];
            uint256 threshold = _depositThreshold(asset);
            if (threshold == 0 || !approvedQuoteAssets[asset]) continue;
            (uint192 anchorRate,,) = IFlowstatePool(pool).anchorOf(asset);
            if (anchorRate == 0) continue;
            // Never revert here (Wilko review): this runs on EVERY withdrawal, and a
            // full exit must succeed under any admin-configured threshold. A product
            // that cannot fit saturates to "any partial is refused", which is the
            // conservative reading, and a full exit ignores minResidual anyway.
            uint256 tokens = threshold > type(uint256).max / 1e18
                ? type(uint256).max
                : Math.mulDiv(threshold, 1e18, anchorRate, Math.Rounding.Ceil);
            if (minResidual == 0 || tokens < minResidual) minResidual = tokens;
        }
    }

    /// @notice Quote-side (cash) contribution — reverts unless the pool's buy-back is
    ///         enabled. Same gift semantics as contributeTokens (R10). The cash side
    ///         runs in the pool's ONE designated buy-back asset, so that is what gets
    ///         pulled — cash-side depositors are funding a specific bid, unlike
    ///         token-side depositors who stay asset-blind.
    function contributeQuote(address pool, uint256 amount, address contributionOwner)
        external
        whenNotPaused
        nonReentrant
    {
        if (!poolRecords[pool].exists) revert UnknownPool();
        if (contributionOwner == address(0)) revert ZeroAddress();

        address asset = IFlowstatePool(pool).buybackAsset();
        if (asset == address(0)) revert QuoteAssetNotApproved(); // buy-back never configured
        uint256 actual = _pullToPool(asset, pool, amount);
        IFlowstatePool(pool).creditQuoteContribution(contributionOwner, actual);
        emit FlowstateEvents.QuoteContributed(pool, contributionOwner, asset, actual);
    }

    /// @notice Withdraw an unsold token-side position. Pass amount = 0 for the full
    ///         position. (Replaces legacy cancelPool; nonReentrant per audit fix.)
    /// @dev JUP-612 (Wilko review): a partial withdrawal may not leave less than the
    ///      deposit minimum behind (see _minResidualTokens); a full withdrawal
    ///      (amount == 0, or the whole position) is never gated.
    function withdrawTokens(address pool, uint256 amount) external nonReentrant {
        if (!poolRecords[pool].exists) revert UnknownPool();
        (uint256 withdrawn, bool nowEmpty) =
            IFlowstatePool(pool).withdrawTokensFor(msg.sender, amount, _minResidualTokens(pool));
        emit FlowstateEvents.TokensWithdrawn(pool, msg.sender, withdrawn, nowEmpty);
    }

    /// @notice JUP-612 compaction (Wilko review rounds 2 and 3, 3 Sep 2026): move
    ///         token-side FIFO nodes smaller than the deposit minimum (valued at the
    ///         durable anchor, the same number withdrawTokens uses) out of the queue
    ///         and onto their owners' claim ledgers, at most `maxNodes` from the head.
    ///         The activation path for pools that hold pre-floor dust, and the repair
    ///         path after a price crash turns real nodes into dust.
    ///
    ///         ADMIN-ONLY and PAUSED-ONLY (round 3): on an active pool a permissionless
    ///         call would let a later depositor evict a smaller LIVE position — one
    ///         that fell under a raised minimum or a moved price — and jump the queue.
    ///         Behind DEFAULT_ADMIN_ROLE and a paused pool it is an operator's
    ///         maintenance step, never a trading-time lever. It moves no value: the
    ///         evicted owner claims the same tokens with claimTokens at any time.
    ///
    ///         Activation order for the floor / minimum (Wilko): pausePool → upgrade →
    ///         setInventoryFloor + setMinContribution → compactDust until
    ///         DustCompacted.nodes == 0 → unpause. Configure BEFORE compacting: with
    ///         both thresholds at zero this call is a no-op.
    function compactDust(address pool, uint256 maxNodes) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (!poolRecords[pool].exists) revert UnknownPool();
        if (!IFlowstatePool(pool).poolPaused()) revert PoolNotPaused();
        (uint256 nodes, uint256 amount) = IFlowstatePool(pool).evictDust(_minResidualTokens(pool), maxNodes);
        emit FlowstateEvents.DustCompacted(pool, msg.sender, nodes, amount);
    }

    /// @notice Withdraw unspent quote-side funds. Pass amount = 0 for the full position.
    function withdrawQuote(address pool, uint256 amount) external nonReentrant {
        if (!poolRecords[pool].exists) revert UnknownPool();
        (uint256 withdrawn, bool cashSideEmpty) = IFlowstatePool(pool).withdrawQuoteFor(msg.sender, amount);
        emit FlowstateEvents.QuoteWithdrawn(
            pool, msg.sender, IFlowstatePool(pool).buybackAsset(), withdrawn, cashSideEmpty
        );
    }

    /// @dev FS-R0-C-01b contribute-side consent. Two properties are load-bearing:
    ///      (1) it checks the DURABLE anchor `lastRate`, never max(fresh, anchor). A
    ///          poisoned-low anchor behind an honest fresh read passes a max() check
    ///          and is simply manipulated low again at buy time, when max() collapses
    ///          to the poison. The durable value is the one the contribution will be
    ///          sold against.
    ///      (2) floors must cover EVERY seeded asset, and only seeded assets. Anchors
    ///          are per quote asset and buys name the asset, so one poisoned anchor is
    ///          enough to sell the contribution cheap through that asset while the
    ///          others read honest. A contributor who consented to USDG alone has not
    ///          consented at all.
    ///      Seeded-asset counts are bounded by the approved-asset list, so the nested
    ///      scan is a handful of iterations.
    function _requireAnchorConsent(address pool, FlowstateStructs.AnchorFloor[] calldata floors) internal view {
        address[] memory seeded = IFlowstatePool(pool).seededAssets();
        uint256 n = seeded.length;
        uint256 m = floors.length;
        // shape first (deterministic error precedence): no duplicates, no zero floors,
        // no floors for assets the pool has not seeded
        for (uint256 j = 0; j < m; ++j) {
            address asset = floors[j].asset;
            if (floors[j].minRate == 0) revert FloorRequired();
            for (uint256 k = 0; k < j; ++k) {
                if (floors[k].asset == asset) revert FloorRequired();
            }
            bool seededAsset;
            for (uint256 i = 0; i < n; ++i) {
                if (seeded[i] == asset) {
                    seededAsset = true;
                    break;
                }
            }
            if (!seededAsset) revert FloorForUnseededAsset(asset);
        }
        // then consent: every seeded asset must carry a floor, and its DURABLE anchor
        // must sit at or above it
        for (uint256 i = 0; i < n; ++i) {
            address asset = seeded[i];
            bool found;
            for (uint256 j = 0; j < m; ++j) {
                if (floors[j].asset != asset) continue;
                found = true;
                (uint192 anchorRate,,) = IFlowstatePool(pool).anchorOf(asset);
                if (anchorRate < floors[j].minRate) revert AnchorBelowFloor(asset, anchorRate, floors[j].minRate);
                break;
            }
            if (!found) revert FloorMissingForAsset(asset);
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // Trading (aggregator-facing)
    // ────────────────────────────────────────────────────────────────────

    /// @notice Pull-exact buy in the NAMED quote asset: the pool computes the
    ///         band-checked oracle cost for the fillable amount; the factory pulls
    ///         exactly that from msg.sender into the pool; the pool settles ledgers,
    ///         fees, and token delivery — all denominated in `asset`.
    /// @dev Approved quote assets are vetted no-fee-on-transfer (USDC/WETH class);
    ///      the pull amount is credited at face value. The approval check is at the
    ///      market so revoking an asset stops NEW trades in it instantly, while pools
    ///      keep their anchors and depositors keep their claims.
    function buyFromPool(
        address pool,
        address asset,
        uint256 amount,
        string calldata resellerCode,
        address buyer
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokensFilled, uint256 quotePaid)
    {
        return _buyFromPool(pool, asset, amount, resellerCode, buyer);
    }

    /// @notice buyFromPool with caller-side protection (JUP-544): the anchor can
    ///         move in-band between a quote and its execution, and an unbounded
    ///         caller pays whatever the execution-block rate says. Every bound is
    ///         optional; zero disables it.
    /// @param maxCost bounds the EFFECTIVE RATE pro-rata, not just the total:
    ///        enforced as quotePaid/tokensFilled <= maxCost/amount, so a PARTIAL
    ///        fill cannot slip a worse rate under a full-size cost cap (a flat
    ///        total-cost check is vacuous the moment the fill is short). Callers
    ///        derive it from their quote: maxCost = quoteAmount plus tolerance.
    /// @param minTokensFilled floor on the fill itself; set to `amount` for
    ///        all-or-nothing.
    /// @param deadline unix seconds; the fill must execute at or before it.
    function buyFromPoolBounded(
        address pool,
        address asset,
        uint256 amount,
        string calldata resellerCode,
        address buyer,
        uint256 maxCost,
        uint256 minTokensFilled,
        uint256 deadline
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokensFilled, uint256 quotePaid)
    {
        _checkDeadline(deadline);
        (tokensFilled, quotePaid) = _buyFromPool(pool, asset, amount, resellerCode, buyer);
        if (minTokensFilled != 0 && tokensFilled < minTokensFilled) {
            revert FillBelowBound(tokensFilled, minTokensFilled);
        }
        // full-512-bit compare (review): `amount` is caller-supplied and
        // unbounded, so raw cross multiplication could panic on inputs whose
        // comparison is perfectly well-defined
        if (maxCost != 0 && Mul512Compare.gt(quotePaid, amount, maxCost, tokensFilled)) {
            revert CostAboveBound(quotePaid, tokensFilled);
        }
    }

    function _buyFromPool(
        address pool,
        address asset,
        uint256 amount,
        string calldata resellerCode,
        address buyer
    ) private returns (uint256 tokensFilled, uint256 quotePaid) {
        FlowstateStructs.PoolRecord memory rec = poolRecords[pool];
        if (!rec.exists) revert UnknownPool();
        if (!approvedQuoteAssets[asset]) revert QuoteAssetNotApproved();
        if (buyer == address(0)) revert ZeroAddress();
        _checkCode(resellerCode);
        if (freezeEnabled && (frozen[msg.sender] || frozen[buyer])) revert AccountFrozen();

        uint256 rate;
        uint256 floor = inventoryFloor[asset];
        (tokensFilled, quotePaid, rate) =
            IFlowstatePool(pool).priceBuy(asset, amount, priceOracle, oracleEpoch, floor);

        _pullQuoteExact(asset, pool, quotePaid);

        IFlowstatePool(pool).settleBuy(
            buyer, asset, tokensFilled, quotePaid, rate, floor, _feeContext(rec.inventoryToken, resellerCode)
        );
    }

    /// @notice Exact-quote-input buy (V4 hook build scope §2.2, additive pair 1/2):
    ///         the caller names the quote spend; the pool inverts to a token amount
    ///         inside its single band-checked oracle read (the view quote path is
    ///         never involved, so no second cold read exists). PARTIAL FILL (JUP-559):
    ///         if inventory cannot cover the full inverted amount, the pool fills what it
    ///         can and prices exactly that, so `tokensFilled` may be short of the ask and
    ///         `quotePaid` is the cost of what was DELIVERED, never of what was asked.
    ///         Only a genuinely empty pool refuses, with NoLiquidity. Callers must charge
    ///         their own counterparty `quotePaid` and not the amount they committed; see
    ///         the CALLER OBLIGATION note on FlowstatePool.priceBuyExactQuote.
    ///         buyFromPoolExactOut is unchanged and remains all-or-nothing.
    /// @dev Pull-exact and fee incidence are unchanged: the factory pulls `quotePaid`
    ///      — the exact oracle cost of the tokens delivered, ≤ quoteIn (the inversion
    ///      rounds tokens DOWN against the buyer, so up to one token-wei's worth of
    ///      quote dust can stay with the caller rather than be overcharged) — and the
    ///      30/30/40 fee is carved from the seller leg in settleBuy, so accounting is
    ///      wei-identical to buyFromPool of the same token amount.
    /// @return tokensFilled tokens delivered to `buyer`.
    /// @return quotePaid    quote-asset units pulled from msg.sender (≤ quoteIn).
    function buyFromPoolExactQuote(
        address pool,
        address asset,
        uint256 quoteIn,
        string calldata resellerCode,
        address buyer
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokensFilled, uint256 quotePaid)
    {
        return _buyFromPoolExactQuote(pool, asset, quoteIn, resellerCode, buyer);
    }

    /// @notice buyFromPoolExactQuote with caller-side protection (JUP-544). The
    ///         cost is already capped at quoteIn by construction, so the exposed
    ///         axis is the OTHER one: how many tokens the spend still buys after
    ///         an in-band rate move. minTokensOut is the classic exact-input
    ///         floor; both bounds optional, zero disables.
    function buyFromPoolExactQuoteBounded(
        address pool,
        address asset,
        uint256 quoteIn,
        string calldata resellerCode,
        address buyer,
        uint256 minTokensOut,
        uint256 deadline
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokensFilled, uint256 quotePaid)
    {
        _checkDeadline(deadline);
        (tokensFilled, quotePaid) = _buyFromPoolExactQuote(pool, asset, quoteIn, resellerCode, buyer);
        if (minTokensOut != 0 && tokensFilled < minTokensOut) {
            revert FillBelowBound(tokensFilled, minTokensOut);
        }
    }

    function _buyFromPoolExactQuote(
        address pool,
        address asset,
        uint256 quoteIn,
        string calldata resellerCode,
        address buyer
    ) private returns (uint256 tokensFilled, uint256 quotePaid) {
        FlowstateStructs.PoolRecord memory rec = poolRecords[pool];
        if (!rec.exists) revert UnknownPool();
        if (!approvedQuoteAssets[asset]) revert QuoteAssetNotApproved();
        if (buyer == address(0)) revert ZeroAddress();
        _checkCode(resellerCode);
        if (freezeEnabled && (frozen[msg.sender] || frozen[buyer])) revert AccountFrozen();

        uint256 rate;
        uint256 floor = inventoryFloor[asset];
        (tokensFilled, quotePaid, rate) =
            IFlowstatePool(pool).priceBuyExactQuote(asset, quoteIn, priceOracle, oracleEpoch, floor);

        _pullQuoteExact(asset, pool, quotePaid);

        IFlowstatePool(pool).settleBuy(
            buyer, asset, tokensFilled, quotePaid, rate, floor, _feeContext(rec.inventoryToken, resellerCode)
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
    function buyFromPoolExactOut(
        address pool,
        address asset,
        uint256 tokenAmountOut,
        string calldata resellerCode,
        address buyer
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokensFilled, uint256 quotePaid)
    {
        return _buyFromPoolExactOut(pool, asset, tokenAmountOut, resellerCode, buyer);
    }

    /// @notice buyFromPoolExactOut with caller-side protection (JUP-544). The
    ///         output is exact by construction, so the exposed axis is the cost:
    ///         maxCost here is an ABSOLUTE cap (no partial fill exists on this
    ///         path to make it vacuous). Both bounds optional, zero disables.
    function buyFromPoolExactOutBounded(
        address pool,
        address asset,
        uint256 tokenAmountOut,
        string calldata resellerCode,
        address buyer,
        uint256 maxCost,
        uint256 deadline
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokensFilled, uint256 quotePaid)
    {
        _checkDeadline(deadline);
        (tokensFilled, quotePaid) = _buyFromPoolExactOut(pool, asset, tokenAmountOut, resellerCode, buyer);
        if (maxCost != 0 && quotePaid > maxCost) {
            revert CostAboveBound(quotePaid, tokensFilled);
        }
    }

    function _buyFromPoolExactOut(
        address pool,
        address asset,
        uint256 tokenAmountOut,
        string calldata resellerCode,
        address buyer
    ) private returns (uint256 tokensFilled, uint256 quotePaid) {
        FlowstateStructs.PoolRecord memory rec = poolRecords[pool];
        if (!rec.exists) revert UnknownPool();
        if (!approvedQuoteAssets[asset]) revert QuoteAssetNotApproved();
        if (buyer == address(0)) revert ZeroAddress();
        _checkCode(resellerCode);
        if (freezeEnabled && (frozen[msg.sender] || frozen[buyer])) revert AccountFrozen();

        uint256 rate;
        uint256 floor = inventoryFloor[asset];
        (tokensFilled, quotePaid, rate) =
            IFlowstatePool(pool).priceBuy(asset, tokenAmountOut, priceOracle, oracleEpoch, floor);
        if (tokensFilled != tokenAmountOut) revert FillShortfall();

        IERC20 quote = IERC20(asset);
        if (
            msg.sender.code.length != 0
                && (
                    quote.balanceOf(msg.sender) < quotePaid
                        || quote.allowance(msg.sender, address(this)) < quotePaid
                )
        ) {
            IFlowstateBuyFunder(msg.sender).fundBuy(asset, quotePaid);
        }
        _pullQuoteExact(asset, pool, quotePaid);

        IFlowstatePool(pool).settleBuy(
            buyer, asset, tokensFilled, quotePaid, rate, floor, _feeContext(rec.inventoryToken, resellerCode)
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
        return _sellToPool(pool, amount, resellerCode, seller);
    }

    /// @notice sellToPool with caller-side protection (JUP-544), mirroring the
    ///         buy side: minQuoteProceeds bounds the EFFECTIVE RATE pro-rata
    ///         (quoteProceeds/tokensSold >= minQuoteProceeds/amount), so a
    ///         partial fill cannot slip a worse rate under a full-size floor;
    ///         minTokensSold floors the fill itself (set to `amount` for
    ///         all-or-nothing). All bounds optional, zero disables.
    function sellToPoolBounded(
        address pool,
        uint256 amount,
        string calldata resellerCode,
        address seller,
        uint256 minQuoteProceeds,
        uint256 minTokensSold,
        uint256 deadline
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokensSold, uint256 quoteProceeds)
    {
        _checkDeadline(deadline);
        (tokensSold, quoteProceeds) = _sellToPool(pool, amount, resellerCode, seller);
        if (minTokensSold != 0 && tokensSold < minTokensSold) {
            revert FillBelowBound(tokensSold, minTokensSold);
        }
        // full-512-bit compare (review): same unbounded-`amount` reasoning as
        // the buy side
        if (minQuoteProceeds != 0 && Mul512Compare.lt(quoteProceeds, amount, minQuoteProceeds, tokensSold)) {
            revert ProceedsBelowBound(quoteProceeds, tokensSold);
        }
    }

    function _sellToPool(address pool, uint256 amount, string calldata resellerCode, address seller)
        private
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

    /// @dev Zero = no deadline. Executable AT the deadline second, expired after.
    function _checkDeadline(uint256 deadline) private view {
        if (deadline != 0 && block.timestamp > deadline) {
            revert DeadlineExpired(deadline, block.timestamp);
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // Quoters (SOR/adapter integration — NEVER revert)
    // ────────────────────────────────────────────────────────────────────

    /// @notice Non-reverting quote for a buy in the NAMED asset. `quoteAmount` is
    ///         exactly what buyFromPool would pull in the same block with the same
    ///         args (the consistency invariant aggregators route on). `available ==
    ///         false` on any non-quotable state: unknown pool, unapproved or unseeded
    ///         asset, pause, empty, band-out, stale anchor, oracle failure. "Empty"
    ///         is the JUP-612 rule: the reachable inventory is worth less than the
    ///         asset's inventoryFloor at the trade rate — so available == true means
    ///         "this pool holds at least the floor of sellable inventory", which is
    ///         the reading integrators always gave it. Size the leg with maxBuy.
    ///         Freeze status is per-caller and deliberately not reflected.
    function quoteBuyFromPool(address pool, address asset, uint256 amount)
        external
        view
        returns (FlowstateStructs.Quote memory q)
    {
        FlowstateStructs.PoolRecord memory rec = poolRecords[pool];
        if (!rec.exists || !approvedQuoteAssets[asset] || paused()) return q;
        (bool ok, uint256 fillable, uint256 cost) =
            IFlowstatePool(pool).previewBuy(asset, amount, priceOracle, oracleEpoch, inventoryFloor[asset]);
        if (!ok) return q;
        uint16 feeBps = _feeBpsOf(rec.inventoryToken);
        q = FlowstateStructs.Quote({
            available: true,
            fillableAmount: fillable,
            quoteAmount: cost, // buyer pays cost; the fee is carved out of the seller leg
            feeAmount: (cost * feeBps) / 10_000,
            feeBps: feeBps,
            quoteAsset: asset
        });
    }

    /// @notice JUP-612: the largest exact-output this pool can fill in `asset` right
    ///         now, and the quote it costs — "read the limit, size the leg to it".
    ///         When maxTokens > 0 it is exactly the largest `tokenAmountOut`
    ///         buyFromPoolExactOut will fill in this block (maxTokens + 1 reverts
    ///         FillShortfall) and maxQuote is what that fill pulls. Applies every
    ///         POOL-STATE rule the fill applies — market pause, pool pause, asset
    ///         approval, anchor seeding, the MAX_FILL_NODES FIFO cap and the
    ///         inventory floor — so a router that models this venue off chain from
    ///         maxBuy cannot quote a size the pool then refuses. It cannot see
    ///         caller-side conditions (freeze status, the caller's balance or
    ///         allowance, a deadline or bound the caller sets). (0, 0) whenever the
    ///         pool is not quotable, which is exactly when quoteBuyFromPool answers
    ///         available == false; a buy in that state reverts (NoLiquidity for the
    ///         floor/empty case, PoolIsPaused or an oracle error for the others).
    ///         Never reverts on pool state; like quoteBuyFromPool it relies on the
    ///         pool's previewBuy being non-reverting by construction. The Quote struct
    ///         and quoteBuyFromPool are unchanged.
    function maxBuy(address pool, address asset)
        external
        view
        returns (uint256 maxTokens, uint256 maxQuote)
    {
        if (!poolRecords[pool].exists || !approvedQuoteAssets[asset] || paused()) return (0, 0);
        (bool ok, uint256 fillable, uint256 cost) = IFlowstatePool(pool).previewBuy(
            asset, type(uint256).max, priceOracle, oracleEpoch, inventoryFloor[asset]
        );
        if (!ok) return (0, 0);
        return (fillable, cost);
    }

    /// @notice Non-reverting quote for a sell. `quoteAmount` is the seller-visible
    ///         NET proceeds (gross − fee) in the pool's buy-back asset, matching
    ///         sellToPool's return value.
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
            quoteAsset: IFlowstatePool(pool).buybackAsset()
        });
    }

    // ────────────────────────────────────────────────────────────────────
    // Anchor freshness keeper + integrator compatibility views
    // ────────────────────────────────────────────────────────────────────

    /// @notice Permissionless freshness keeper (§3.4 item 1): advances one pool
    ///         anchor through the SAME band-checked path a trade uses, with no trade
    ///         attached, so an idle pool never hits the staleness bound. Factory-
    ///         routed so the oracle address and epoch are always canonical — the
    ///         pool-side function is onlyFactory precisely so nobody can feed a pool
    ///         a rate from an oracle of their choosing.
    function pokeAnchor(address pool, address asset) external whenNotPaused nonReentrant {
        if (!poolRecords[pool].exists) revert UnknownPool();
        if (!approvedQuoteAssets[asset]) revert QuoteAssetNotApproved();
        IFlowstatePool(pool).pokeAnchor(asset, priceOracle, oracleEpoch);
    }

    /// @notice Oracle-health probe for monitoring, routed so the caller always gets
    ///         the CANONICAL oracle rather than having to track migrations itself.
    ///         `readable == false` means the pool is quoting a frozen `anchorRate`
    ///         and cannot re-converge until the feed comes back: page on it. A large
    ///         gap between `freshRate` and `anchorRate` while `anchorBlock` stops
    ///         advancing means the pool is persistently clamping.
    /// @dev Non-reverting for an unknown pool or unapproved asset (returns zeros), so
    ///      a monitor loop can call it blind.
    function oracleHealth(address pool, address asset)
        external
        view
        returns (bool readable, uint256 freshRate, uint192 anchorRate, uint64 anchorBlock)
    {
        if (!poolRecords[pool].exists || !approvedQuoteAssets[asset]) return (false, 0, 0, 0);
        return IFlowstatePool(pool).oracleHealth(asset, priceOracle);
    }

    /// @notice The buy-side staleness surcharge in force for (pool, asset), in bps.
    ///         Zero whenever the pool is pricing off a live read; non-zero whenever it
    ///         is pricing off an ageing anchor (dead oracle, or a readable read that
    ///         sits below the anchor). Routed here so monitors get the canonical
    ///         oracle and epoch, and returns 0 rather than reverting for an unknown
    ///         pool or asset so a monitor loop can call it blind.
    function staleSurchargeBps(address pool, address asset) external view returns (uint256) {
        if (!poolRecords[pool].exists || !approvedQuoteAssets[asset]) return 0;
        return IFlowstatePool(pool).staleSurchargeBpsOf(asset, priceOracle, oracleEpoch);
    }

    /// @notice Legacy-shape compatibility view: pre-multi-asset integrators resolve
    ///         pools by (token, quoteAsset). Any approved asset maps to the token's
    ///         single pool now.
    function poolByPair(address token, address quoteAsset) external view returns (address) {
        if (!approvedQuoteAssets[quoteAsset]) return address(0);
        return poolByToken[token];
    }

    /// @notice Currently-approved quote assets (filters revoked entries out of the
    ///         ever-approved list).
    function getApprovedQuoteAssets() external view returns (address[] memory assets) {
        uint256 length = quoteAssetList.length;
        uint256 count;
        for (uint256 i = 0; i < length; ++i) {
            if (approvedQuoteAssets[quoteAssetList[i]]) ++count;
        }
        assets = new address[](count);
        uint256 j;
        for (uint256 i = 0; i < length; ++i) {
            address asset = quoteAssetList[i];
            if (approvedQuoteAssets[asset]) assets[j++] = asset;
        }
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

    /// @dev The ever-approved list backs createPool's seeding loop and the filtered
    ///      getApprovedQuoteAssets view; entries are never removed (revocation is the
    ///      mapping flipping false — the loops skip revoked entries), so re-approval
    ///      cannot duplicate and list growth is admin-bounded.
    /// @notice JUP-612: per-asset inventory floor, in `asset` units. Instant admin
    ///         lane like the fee tier: the floor is an economic threshold (what
    ///         inventory is worth listing), not protocol wiring. Takes effect on the
    ///         next quote and the next fill; no pool call, no pause, no unpause.
    ///         0 clears it (legacy rule: only a walk with nothing in it is empty).
    ///         Settable before the asset is approved so a listing goes live with
    ///         its floor already in force.
    function setInventoryFloor(address asset, uint256 floor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        inventoryFloor[asset] = floor;
        emit FlowstateEvents.InventoryFloorSet(asset, floor);
    }

    /// @notice JUP-619: per-asset minimum deposit, in `asset` units. Same lane and
    ///         semantics as setInventoryFloor; applies to createPool and
    ///         contributeTokens through the max(floor, minimum) threshold. 0 clears
    ///         it (the floor alone then bounds deposits).
    function setMinContribution(address asset, uint256 minimum) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        minContribution[asset] = minimum;
        emit FlowstateEvents.MinContributionSet(asset, minimum);
    }

    function setQuoteAsset(address asset, bool approved) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        approvedQuoteAssets[asset] = approved;
        if (approved && !inQuoteAssetList[asset]) {
            inQuoteAssetList[asset] = true;
            quoteAssetList.push(asset);
        }
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
        _requireRecipient(wallet);
        if (bd1 == address(0)) revert BDWalletRequired();
        _requireRecipient(bd1);
        if (bd2 == address(0)) {
            if (bd2ShareBps != 0) revert Bd2ShareWithoutWallet();
        } else {
            _requireRecipient(bd2);
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
        _requireRecipient(newWallet);
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
            _requireRecipient(newWallet); // bd1 is mandatory — cannot be cleared
            old = rc.bd1;
            rc.bd1 = newWallet;
        } else if (slot == 2) {
            if (newWallet == address(0)) {
                if (rc.bd2ShareBps != 0) revert Bd2ShareWithoutWallet();
            } else {
                _requireRecipient(newWallet);
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

    /// @notice Liveness escape hatch for drift beyond the widened band (D3), per
    ///         asset. Doubles as the LATE-SEEDING lane: an asset approved after a
    ///         pool's creation (or unpriceable at creation) is seeded here — behind
    ///         the admin role on purpose, because a first observation is band-check-
    ///         free by definition and its moment must never be attacker-chosen.
    /// @dev JUP-611 (Wilko review, 3 Sep 2026): moved from the instant admin lane to
    ///      the 48h TIMELOCK_ROLE. The consent floors a seller sets at deposit are
    ///      checked against the durable anchor; an instant, band-check-free reseed
    ///      could overwrite that anchor the block after consent was given, which
    ///      would make the consent decorative. Behind the timelock, a reseed is
    ///      announced 48h ahead, inside the same window a seller has to withdraw.
    ///      Liveness cost is nil since the 2026-08-11 redesign: anchors re-converge
    ///      on their own within one block of the next trade, so this lane is now
    ///      only the late-seeding path for assets approved after a pool was created.
    function resetAnchor(address pool, address asset) external onlyRole(TIMELOCK_ROLE) {
        if (!poolRecords[pool].exists) revert UnknownPool();
        if (!approvedQuoteAssets[asset]) revert QuoteAssetNotApproved();
        IFlowstatePool(pool).resetAnchor(asset, priceOracle, oracleEpoch);
    }

    /// @notice Per-pool buy-back config (§4 scope): the ONE asset the cash side runs
    ///         in, enable flag (ships OFF), buy-side spread, and quote-spend window
    ///         cap. The pool refuses an asset change while the cash side holds funds.
    function setBuyBack(
        address pool,
        address asset,
        bool enabled,
        uint16 spreadBps,
        uint128 maxQuotePerWindow,
        uint32 windowSeconds
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!poolRecords[pool].exists) revert UnknownPool();
        if (enabled && !approvedQuoteAssets[asset]) revert QuoteAssetNotApproved();
        IFlowstatePool(pool).setBuyBack(asset, enabled, spreadBps, maxQuotePerWindow, windowSeconds);
        emit FlowstateEvents.BuyBackConfigured(
            pool, asset, enabled, spreadBps, maxQuotePerWindow, windowSeconds
        );
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

    /// @notice Timelocked. Bumps oracleEpoch, which every pool RECORDS on its next
    ///         trade per asset — no per-pool ops needed. Corrected 2026-08-13: the
    ///         bump no longer causes a band-check-free reseed. The timelock attests
    ///         to the new oracle's IDENTITY, not to a price read at a block a third
    ///         party chooses, so the migrated oracle's first read earns adoption
    ///         under the ordinary band and one-block-confirmation rules.
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

    /// @notice Timelocked (protocol wiring lane). The V4 hook that createPool
    ///         auto-registers each new (approved asset, token) pair with — JUP-587,
    ///         kept deliberately narrow per Wilko's 24 Aug GO: no on-chain venue
    ///         discovery, no oracle-feed selection; V4 pool init, beacons and feeds
    ///         stay with the off-chain provisioner. Unlike the other wiring setters
    ///         address(0) is deliberately LEGAL here: it is the kill-switch, and a
    ///         kill-switch must not need an upgrade to reach.
    function setTrustedHook(address hook) external onlyRole(TIMELOCK_ROLE) {
        emit FlowstateEvents.TrustedHookUpdated(trustedHook, hook);
        trustedHook = hook;
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

    /// @dev Buy-side quote pull with EXACT-receipt enforcement (FS-R0-H-02). settleBuy
    ///      credits the NOMINAL quotePaid and prices token delivery against it, so the
    ///      pool must receive quotePaid to the wei. A fee-on-transfer / deflationary
    ///      quote asset delivers less and would leave the contributor claim ledger
    ///      insolvent (claimableQuote > pool balance); reject it here, exactly as the
    ///      SELL path rejects taxed inventory via the same error. This makes the
    ///      "approved quote assets are vetted no-fee-on-transfer" policy an enforced
    ///      invariant rather than an off-chain assumption.
    function _pullQuoteExact(address asset, address pool, uint256 quotePaid) private {
        if (_pullToPool(asset, pool, quotePaid) != quotePaid) revert TransferAmountMismatch();
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

    /// @dev Fee recipients are chain-specific configuration. Safes, smart-contract
    ///      wallets and EIP-7702/delegated addresses are valid recipients; the
    ///      contract enforces only the structural non-zero invariant. JUP-581
    ///      validates the intended recipient against the exact target chain and
    ///      deployed Market generation before proposing an admin transaction.
    function _requireRecipient(address account) private pure {
        if (account == address(0)) revert ZeroAddress();
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
