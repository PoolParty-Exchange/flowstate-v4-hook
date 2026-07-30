// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interface/IOracle.sol";

/**
 * @title FlowstateSlimOracle
 * @notice The slim price source (V4 hook build scope Phase 3; roadmap §6). One job:
 *         answer "what is this token worth right now, in the asset the buyer pays
 *         with" — by reading ONLY the venues that genuinely matter for the pair
 *         (usually one or two), weighting them by in-range liquidity, and DECLINING
 *         (returning 0) when the depth behind the answer is too thin to trust.
 *
 * WHY IT EXISTS. The general-purpose aggregator oracle scans a long venue list to
 * price anything unprompted; for a token that trades in one or two places that means
 * paying for a dozen lookups to find one real book (~474k gas measured on RH — more
 * than half the cost of a C1 purchase), and blending shallow venues in was MEASURED
 * to make the answer worse, not better (Base: 9.9 bps p50 off the deepest venue,
 * which was itself 3.4 bps off Chainlink). This contract inverts the design: a
 * per-pair REGISTRY of the venues that matter, nothing else read, nothing blended
 * that has no depth. Target: under 80k gas for a two-venue pair, so the all-in C1
 * swap fits inside the ~450k envelope routers demonstrably accept.
 *
 * WHAT IT CANNOT DO, by construction (the roadmap §6 public commitments):
 *   - it holds no funds and has no payable or token-touching path;
 *   - it does not trade — every external interaction is a STATICCALL;
 *   - it cannot be upgraded into doing either: no proxy, no delegatecall, immutable
 *     bytecode. The ONLY mutable state is the venue registry, owner-gated (the
 *     market's timelocked setPriceOracle is how a different oracle would ever be
 *     adopted; epoch reseed handles the migration pool-side).
 *
 * FRESHNESS. Readings are live pool state in the executing block — spot by
 * definition, so there is no observation timestamp to bound; the C1 pools' own
 * anchor machinery (step band, walk band vs EMA, staleness bound) is the defence
 * layer against what a single block's spot can do.
 *
 * MANIPULATION. Fewer venues is a sharper instrument in both directions (roadmap
 * §6 "what could go wrong"): chosen well it is more accurate AND harder to push
 * (depth-weighting means moving the answer requires moving the deep book);
 * chosen badly it is easier. Which venues enter the registry is therefore a real
 * per-token decision, and the minimum-depth floor turns "the book got drained"
 * into a clean decline instead of a confident wrong answer.
 *
 * INTERFACE. Drop-in IOracle: rate is dstToken raw units per 1e18-scaled srcToken
 * raw unit, the exact convention FlowstatePool consumes (quoteCost = amount x rate
 * / 1e18). getRateToEth is not part of C1's read path and reverts.
 */
contract FlowstateSlimOracle is IOracle, Ownable2Step {
    error UnsupportedLookup();
    error InvalidVenue();
    error TooManyVenues();
    error VenueTokensMismatch();

    /// @notice Venue kinds. V3: any UniswapV3Pool-shaped contract (slot0/liquidity/
    ///         token0/token1 — covers canonical V3 and same-ABI forks). V4: read
    ///         through the chain's canonical StateView by poolId.
    uint8 public constant KIND_V3 = 1;
    uint8 public constant KIND_V4 = 2;

    uint256 private constant RATE_SCALE = 1e18;
    uint256 private constant Q96 = 1 << 96;
    uint256 public constant MAX_VENUES = 2; // the slimness invariant, enforced

    struct Venue {
        uint8 kind;        // KIND_V3 | KIND_V4
        address target;    // V3: the pool. V4: the StateView.
        bool srcIsToken0;  // orientation, resolved once at registration
        bytes32 poolId;    // V4 only
    }

    struct PairFeed {
        Venue[] venues;        // 1..MAX_VENUES
        uint128 minLiquidity;  // Σ in-range L below this ⇒ decline (return 0)
    }

    mapping(bytes32 pairKey => PairFeed) private feeds;

    event FeedSet(address indexed src, address indexed dst, uint256 venueCount, uint128 minLiquidity);
    event FeedCleared(address indexed src, address indexed dst);

    constructor(address _owner) Ownable(_owner) {}

    // ────────────────────────────────────────────────────────────────────
    // Registry (owner; per-pair, deliberate — see header)
    // ────────────────────────────────────────────────────────────────────

    /// @notice Set the feed for (src, dst): the 1..2 venues that genuinely matter
    ///         and the liquidity floor below which the pair declines. Each venue is
    ///         probed at registration: a V3 target must expose token0/token1
    ///         matching the pair (orientation is stored, never recomputed); a V4
    ///         entry's orientation is supplied by the caller and its StateView is
    ///         probed for a nonzero sqrtPrice so a typo'd poolId fails HERE, loudly,
    ///         not silently on the hot path.
    /// @dev The registry is intentionally per-(src,dst) directional: C1 pools only
    ///      ever read token→quote. Register the direction you serve.
    function setFeed(
        address src,
        address dst,
        Venue[] calldata venues,
        uint128 minLiquidity
    ) external onlyOwner {
        if (venues.length == 0 || venues.length > MAX_VENUES) revert TooManyVenues();
        PairFeed storage feed = feeds[_pairKey(src, dst)];
        delete feed.venues;
        for (uint256 i = 0; i < venues.length; ++i) {
            Venue calldata v = venues[i];
            if (v.target == address(0)) revert InvalidVenue();
            if (v.kind == KIND_V3) {
                address t0 = IUniV3PoolMinimal(v.target).token0();
                address t1 = IUniV3PoolMinimal(v.target).token1();
                bool srcIs0 = src == t0 && dst == t1;
                bool srcIs1 = src == t1 && dst == t0;
                if (!srcIs0 && !srcIs1) revert VenueTokensMismatch();
                feed.venues.push(Venue(KIND_V3, v.target, srcIs0, bytes32(0)));
            } else if (v.kind == KIND_V4) {
                (uint160 sqrtP,,,) = IStateViewMinimal(v.target).getSlot0(v.poolId);
                if (sqrtP == 0) revert InvalidVenue(); // uninitialized / typo'd poolId
                feed.venues.push(Venue(KIND_V4, v.target, v.srcIsToken0, v.poolId));
            } else {
                revert InvalidVenue();
            }
        }
        feed.minLiquidity = minLiquidity;
        emit FeedSet(src, dst, venues.length, minLiquidity);
    }

    function clearFeed(address src, address dst) external onlyOwner {
        delete feeds[_pairKey(src, dst)];
        emit FeedCleared(src, dst);
    }

    function getFeed(address src, address dst)
        external
        view
        returns (Venue[] memory venues, uint128 minLiquidity)
    {
        PairFeed storage feed = feeds[_pairKey(src, dst)];
        return (feed.venues, feed.minLiquidity);
    }

    // ────────────────────────────────────────────────────────────────────
    // IOracle
    // ────────────────────────────────────────────────────────────────────

    /// @notice dst raw units per src unit, scaled by 1e18. Returns 0 — a clean
    ///         decline the pools convert to NoOracleRate / an unavailable quote —
    ///         when: no feed is registered, every venue read fails, or total
    ///         in-range liquidity sits under the pair's floor. Never reverts on
    ///         venue state (a broken venue is skipped; a drained book declines).
    function getRate(IERC20 srcToken, IERC20 dstToken, bool)
        external
        view
        override
        returns (uint256 rate)
    {
        PairFeed storage feed = feeds[_pairKey(address(srcToken), address(dstToken))];
        uint256 n = feed.venues.length;
        if (n == 0) return 0;

        uint256 weighted; // Σ rate_i × L_i
        uint256 totalL;   // Σ L_i — same-pair venues share L units, so weights compare
        for (uint256 i = 0; i < n; ++i) {
            Venue storage v = feed.venues[i];
            (bool ok, uint160 sqrtPriceX96, uint128 liquidity) = _read(v);
            if (!ok || sqrtPriceX96 == 0 || liquidity == 0) continue;
            uint256 r = _rateFromSqrtPrice(sqrtPriceX96, v.srcIsToken0);
            if (r == 0) continue;
            weighted += r * liquidity;
            totalL += liquidity;
        }
        if (totalL == 0 || totalL < feed.minLiquidity) return 0;
        rate = weighted / totalL;
    }

    /// @dev Not part of C1's read path (pools price token→quote directly); reverting
    ///      keeps the surface honest about what this contract is for.
    function getRateToEth(IERC20, bool) external pure override returns (uint256) {
        revert UnsupportedLookup();
    }

    // ────────────────────────────────────────────────────────────────────
    // Readers
    // ────────────────────────────────────────────────────────────────────

    /// @dev Both reads are staticcalls with failure tolerated: a venue that reverts
    ///      (self-destructed fork, paused pool) is skipped rather than bricking the
    ///      pair — if every venue fails, the pair declines via totalL == 0.
    function _read(Venue storage v) private view returns (bool ok, uint160 sqrtPriceX96, uint128 liquidity) {
        if (v.kind == KIND_V3) {
            (bool s1, bytes memory d1) = v.target.staticcall(abi.encodeCall(IUniV3PoolMinimal.slot0, ()));
            if (!s1 || d1.length < 32) return (false, 0, 0);
            sqrtPriceX96 = uint160(uint256(bytes32(d1))); // first word of slot0
            (bool s2, bytes memory d2) = v.target.staticcall(abi.encodeCall(IUniV3PoolMinimal.liquidity, ()));
            if (!s2 || d2.length < 32) return (false, 0, 0);
            liquidity = uint128(uint256(bytes32(d2)));
            ok = true;
        } else {
            (bool s1, bytes memory d1) =
                v.target.staticcall(abi.encodeCall(IStateViewMinimal.getSlot0, (v.poolId)));
            if (!s1 || d1.length < 32) return (false, 0, 0);
            sqrtPriceX96 = uint160(uint256(bytes32(d1)));
            (bool s2, bytes memory d2) =
                v.target.staticcall(abi.encodeCall(IStateViewMinimal.getLiquidity, (v.poolId)));
            if (!s2 || d2.length < 32) return (false, 0, 0);
            liquidity = uint128(uint256(bytes32(d2)));
            ok = true;
        }
    }

    /// @dev sqrtPriceX96 encodes token1-per-token0 in RAW units as (sqrtP/2^96)^2.
    ///      Two chained mulDivs keep every intermediate inside 512-bit space, so no
    ///      overflow for any representable sqrtPrice. Output scaled by RATE_SCALE:
    ///      src == token0:  rate = sqrtP² × 1e18 / 2^192
    ///      src == token1:  rate = 2^192 × 1e18 / sqrtP²
    function _rateFromSqrtPrice(uint160 sqrtPriceX96, bool srcIsToken0) private pure returns (uint256) {
        if (srcIsToken0) {
            uint256 p = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), Q96);
            return Math.mulDiv(p, RATE_SCALE, Q96);
        }
        uint256 inv = Math.mulDiv(Q96, RATE_SCALE, uint256(sqrtPriceX96));
        return Math.mulDiv(inv, Q96, uint256(sqrtPriceX96));
    }

    function _pairKey(address src, address dst) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(src, dst));
    }
}

/// @dev The two minimal venue surfaces. slot0's return tuples differ between V3 and
///      its forks beyond the first word; both readers decode ONLY the first word
///      (sqrtPriceX96), which is ABI-stable across every same-shape fork.
interface IUniV3PoolMinimal {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IStateViewMinimal {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}
