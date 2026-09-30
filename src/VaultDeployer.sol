// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StealthVault} from "./StealthVault.sol";

/// @title VaultDeployer
/// @notice Holds the StealthVault creation code so the factory's own runtime stays small. Deployed by
/// the factory's constructor; only that factory may deploy through it. Vault addresses are CREATE2
/// from this contract, so they are predictable before anything is sent.
contract VaultDeployer {
    address public immutable factory;

    error OnlyFactory();

    constructor() {
        factory = msg.sender;
    }

    function deploy(bytes32 salt, StealthVault.Wiring calldata w, uint16 taxBps) external returns (address) {
        if (msg.sender != factory) revert OnlyFactory();
        return address(new StealthVault{salt: salt}(w, taxBps, factory));
    }

    function predict(bytes32 salt, StealthVault.Wiring calldata w, uint16 taxBps) external view returns (address) {
        bytes32 initHash = keccak256(abi.encodePacked(type(StealthVault).creationCode, abi.encode(w, taxBps, factory)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }
}
