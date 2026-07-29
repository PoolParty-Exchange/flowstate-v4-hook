// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/**
 * @title IUpgradeableBeacon
 * @notice The write half of OpenZeppelin's UpgradeableBeacon. OZ ships only the
 *         read-side `IBeacon` (implementation()), so the market declares the
 *         owner-gated mutator it needs to ship a pool-logic upgrade.
 * @dev Used by FlowstateMarket.upgradePoolImplementation. That call only succeeds
 *      when the market proxy is the beacon's owner — see the deployment note there.
 */
interface IUpgradeableBeacon {
    function implementation() external view returns (address);
    function owner() external view returns (address);
    function upgradeTo(address newImplementation) external;
}
