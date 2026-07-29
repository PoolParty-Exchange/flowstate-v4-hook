// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

interface IInitializableBeaconProxy {
    function initialize(address beacon, bytes memory data) external;
}

