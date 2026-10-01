// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TaxyHook} from "../src/TaxyHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Offline CREATE2 salt search; run against the actual CREATE2 caller and constructor args.
/// @dev No environment reads, broadcasting, filesystem access or private keys.
contract MineTaxySalt {
    error SaltNotFound();
    error InvalidSearch();

    function run(address deployer, IPoolManager manager, uint256 start, uint256 attempts)
        external
        pure
        returns (address predicted, bytes32 salt)
    {
        if (deployer == address(0) || address(manager) == address(0) || attempts == 0 || attempts > 1_000_000) {
            revert InvalidSearch();
        }
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(TaxyHook).creationCode, abi.encode(manager)));
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == 0x20cc) return (predicted, salt);
        }
        revert SaltNotFound();
    }
}
