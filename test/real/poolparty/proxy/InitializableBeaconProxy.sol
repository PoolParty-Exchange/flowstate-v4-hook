// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

/**
 * @title InitializableBeaconProxy
 * @dev A BeaconProxy that can be cloned via EIP-1167.
 *
 * Unlike OZ BeaconProxy (which sets beacon in constructor), this version
 * sets the beacon in initialize(), making it compatible with Clones.clone().
 *
 * Flow:
 * 1. Deploy this contract once (template)
 * 2. Clone it with Clones.clone(template)
 * 3. Call clone.initialize(beacon, initData)
 * 4. Clone now delegates all calls to beacon's implementation
 *
 * Initialization guard: the beacon slot itself is the once-only sentinel — a
 * nonzero slot means initialized. Deliberately NOT OZ Initializable: the
 * implementation's own initialize (delegatecalled from here) uses OZ
 * Initializable in the SAME clone storage, and two `initializer` modifiers on
 * one storage context revert each other (InvalidInitialization).
 */
contract InitializableBeaconProxy {
    /// @dev ERC1967 beacon storage slot (same as OZ uses)
    bytes32 internal constant BEACON_SLOT =
        0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    error BeaconAddressZero();
    error BeaconHasNoImplementation();
    error InitializationFailed();
    error AlreadyInitialized();

    /// @dev Locks the TEMPLATE (audit Low): a sentinel in the template's own beacon
    ///      slot makes initialize() uncallable on it. Clones get fresh storage, so
    ///      they start un-initialized as intended.
    constructor() {
        assembly {
            sstore(BEACON_SLOT, 1)
        }
    }

    /**
     * @notice Initializes the proxy with beacon address and optional init data
     * @param beacon The UpgradeableBeacon contract address
     * @param data Encoded call to implementation's initialize function
     */
    function initialize(address beacon, bytes memory data) external {
        address existing;
        assembly {
            existing := sload(BEACON_SLOT)
        }
        if (existing != address(0)) revert AlreadyInitialized();
        if (beacon == address(0)) revert BeaconAddressZero();
        if (IBeacon(beacon).implementation() == address(0)) revert BeaconHasNoImplementation();

        assembly {
            sstore(BEACON_SLOT, beacon)
        }

        if (data.length > 0) {
            address impl = IBeacon(beacon).implementation();
            (bool success, bytes memory returndata) = impl.delegatecall(data);
            if (!success) {
                if (returndata.length > 0) {
                    assembly {
                        revert(add(32, returndata), mload(returndata))
                    }
                }
                revert InitializationFailed();
            }
        }
    }

    /**
     * @dev Returns current implementation address from beacon
     */
    function _implementation() internal view returns (address) {
        address beacon;
        assembly {
            beacon := sload(BEACON_SLOT)
        }
        return IBeacon(beacon).implementation();
    }

    /**
     * @dev Delegates all calls to implementation
     */
    fallback() external payable {
        address impl = _implementation();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}
