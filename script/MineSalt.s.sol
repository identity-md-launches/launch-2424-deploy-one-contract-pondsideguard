// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PondsideGuardDeployer} from "../src/PondsideGuardDeployer.sol";

/// @notice Pure CREATE2 salt search for a hook address carrying the required permission bits.
library SaltMiner {
    uint256 internal constant MAX_ITERATIONS = 500_000;

    error SaltNotFound();

    /// @param deployer The `PondsideGuardDeployer` address (CREATE2 sender).
    /// @param initCodeHash `PondsideGuardDeployer.initCodeHash()`.
    /// @param flags `PondsideGuardDeployer.requiredFlags()`.
    /// @param start First salt to try; raise it to search a different range.
    function mine(address deployer, bytes32 initCodeHash, uint160 flags, uint256 start)
        internal
        pure
        returns (bytes32 salt, address hook)
    {
        flags &= Hooks.ALL_HOOK_MASK;
        for (uint256 i = start; i < start + MAX_ITERATIONS; ++i) {
            address candidate = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if ((uint160(candidate) & Hooks.ALL_HOOK_MASK) == flags) return (bytes32(i), candidate);
        }
        revert SaltNotFound();
    }
}

/// @notice Off-chain helper: prints the salt to pass to `PondsideGuardDeployer.deploy(bytes32)`.
/// Usage: `PONDSIDE_DEPLOYER=0x... forge script script/MineSalt.s.sol --rpc-url <robinhood rpc>`
/// No transaction is sent; the script only reads the deployer and computes.
contract MineSalt is Script {
    function run() external view {
        PondsideGuardDeployer deployer = PondsideGuardDeployer(vm.envAddress("PONDSIDE_DEPLOYER"));
        (bytes32 salt, address hook) = mineFor(deployer);
        console2.log("PondsideGuardDeployer:", address(deployer));
        console2.log("salt:");
        console2.logBytes32(salt);
        console2.log("hook address:", hook);
    }

    /// @notice The part tests call directly: mine a salt against a live deployer.
    function mineFor(PondsideGuardDeployer deployer) public view returns (bytes32 salt, address hook) {
        return SaltMiner.mine(address(deployer), deployer.initCodeHash(), deployer.requiredFlags(), 0);
    }
}
