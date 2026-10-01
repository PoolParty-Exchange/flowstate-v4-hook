// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @notice Stand-in listing wiring for the fork suite (29 Sep 2026). The Gen-4 hook's constructor requires
///         a listing registry and settlement that name each other and the market. The fork suite runs an
///         older vendored market with no listings, so its swap tests (the deleted Gen-3 path) are retired;
///         these stand-ins let the setup, registration, wiring and beacon tests keep running. A swap through
///         a hook wired to them reverts STOP_CLOSED (price() reports the route closed).
contract StandInListingRegistry {
    address public immutable market;
    address public settlement;

    constructor(address market_) {
        market = market_;
    }

    function setSettlement(address value) external {
        settlement = value;
    }

    function peek(address) external pure returns (uint8, uint64, uint64, uint256, uint32, uint64) {
        return (0, 0, 0, 0, 0, 0);
    }
}

contract StandInListingSettlement {
    address public immutable market;
    address public immutable registry;

    constructor(address market_, address registry_) {
        market = market_;
        registry = registry_;
    }

    function price(address, address) external pure returns (uint8 why, uint256 rate) {
        return (1, 0);
    }
}

library ListingStandIn {
    function deploy(address market) internal returns (address registry, address settlement) {
        StandInListingRegistry r = new StandInListingRegistry(market);
        StandInListingSettlement s = new StandInListingSettlement(market, address(r));
        r.setSettlement(address(s));
        return (address(r), address(s));
    }
}
