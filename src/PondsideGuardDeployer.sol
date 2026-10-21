// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PondsideGuard} from "./PondsideGuard.sol";

/// @title PondsideGuardDeployer
/// @notice The contract the launch deploys. A Uniswap v4 hook must live at an address whose low 14 bits encode
/// its permissions, so the launch cannot deploy `PondsideGuard` directly. This deployer fixes the hook's
/// constructor arguments at launch time and lets anyone deploy the hook once, with a CREATE2 salt mined off chain
/// against this deployer's address (see `script/MineSalt.s.sol`). A salt that does not produce the required bits
/// makes the hook constructor revert, so a wrong salt cannot deploy a broken hook.
/// @dev The constructor calls no other contract, so it can be rehearsed on an empty chain.
contract PondsideGuardDeployer {
    /// @notice The PoolManager the hook will serve.
    IPoolManager public immutable poolManager;
    /// @notice The hook's owner (pause / unpause only).
    address public immutable owner;
    /// @notice The wallet that receives the hook's 1% fee.
    address public immutable feeRecipient;
    /// @notice keccak256 of the hook's creation code with this deployer's constructor arguments appended, fixed
    /// at construction so that salt searches (`isValidSalt`, `predict`) do not rehash the creation code each call.
    bytes32 public immutable initCodeHash;
    /// @notice The deployed hook, or zero until `deploy` has run.
    PondsideGuard public hook;

    event PondsideGuardDeployed(address indexed hook, bytes32 salt);

    error ZeroAddress();
    error AlreadyDeployed(address hook);

    /// @param poolManager_ Uniswap v4 PoolManager on the launch chain.
    /// @param owner_ Account allowed to pause and unpause swaps on the hook.
    /// @param feeRecipient_ Wallet receiving the hook's 1% fee.
    constructor(IPoolManager poolManager_, address owner_, address feeRecipient_) {
        if (address(poolManager_) == address(0) || owner_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        owner = owner_;
        feeRecipient = feeRecipient_;
        initCodeHash = keccak256(
            abi.encodePacked(type(PondsideGuard).creationCode, abi.encode(poolManager_, owner_, feeRecipient_))
        );
    }

    /// @notice The permission bits the hook address must carry (mask over the low 14 bits).
    function requiredFlags() public pure returns (uint160) {
        return Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    /// @notice The address `deploy(salt)` creates.
    function predict(bytes32 salt) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /// @notice Whether `salt` yields an address with the required permission bits.
    function isValidSalt(bytes32 salt) public view returns (bool) {
        return (uint160(predict(salt)) & Hooks.ALL_HOOK_MASK) == requiredFlags();
    }

    /// @notice Deploy the hook with a mined salt. Anyone may call, exactly once; the result does not depend on
    /// the caller because every constructor argument was fixed at launch.
    function deploy(bytes32 salt) external returns (PondsideGuard deployed) {
        if (address(hook) != address(0)) revert AlreadyDeployed(address(hook));
        deployed = new PondsideGuard{salt: salt}(poolManager, owner, feeRecipient);
        hook = deployed;
        emit PondsideGuardDeployed(address(deployed), salt);
    }
}
