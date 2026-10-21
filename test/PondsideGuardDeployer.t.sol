// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PondsideGuard} from "../src/PondsideGuard.sol";
import {PondsideGuardDeployer} from "../src/PondsideGuardDeployer.sol";
import {MineSalt, SaltMiner} from "../script/MineSalt.s.sol";

contract PondsideGuardDeployerTest is Test {
    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    /// @dev The launch deploys on an empty chain: the PoolManager argument is just an address here.
    IPoolManager internal manager = IPoolManager(makeAddr("poolManager"));

    PondsideGuardDeployer internal deployer;

    function setUp() public {
        deployer = new PondsideGuardDeployer(manager, owner, recipient);
    }

    function test_constructorStoresArgumentsWithoutTouchingOtherContracts() public view {
        assertEq(address(deployer.poolManager()), address(manager));
        assertEq(deployer.owner(), owner);
        assertEq(deployer.feeRecipient(), recipient);
        assertEq(address(deployer.hook()), address(0));
        assertEq(address(manager).code.length, 0, "fixture: PoolManager must be codeless here");
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(PondsideGuardDeployer.ZeroAddress.selector);
        new PondsideGuardDeployer(IPoolManager(address(0)), owner, recipient);
        vm.expectRevert(PondsideGuardDeployer.ZeroAddress.selector);
        new PondsideGuardDeployer(manager, address(0), recipient);
        vm.expectRevert(PondsideGuardDeployer.ZeroAddress.selector);
        new PondsideGuardDeployer(manager, owner, address(0));
    }

    function test_requiredFlagsMatchHookPermissions() public view {
        uint160 expected = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        assertEq(deployer.requiredFlags(), expected);
    }

    function test_deployWithMinedSaltYieldsValidHookAddress() public {
        (bytes32 salt, address predicted) =
            SaltMiner.mine(address(deployer), deployer.initCodeHash(), deployer.requiredFlags(), 0);
        assertTrue(deployer.isValidSalt(salt));
        assertEq(deployer.predict(salt), predicted);

        vm.expectEmit(true, false, false, true, address(deployer));
        emit PondsideGuardDeployer.PondsideGuardDeployed(predicted, salt);
        PondsideGuard hook = deployer.deploy(salt);

        assertEq(address(hook), predicted);
        assertEq(address(deployer.hook()), predicted);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, deployer.requiredFlags());
        assertTrue(Hooks.isValidHookAddress(IHooks(address(hook)), 3000));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.owner(), owner);
        assertEq(hook.feeRecipient(), recipient);
        assertEq(hook.requiredFlags(), deployer.requiredFlags());
    }

    function test_deployIsSingleUse() public {
        (bytes32 salt,) = SaltMiner.mine(address(deployer), deployer.initCodeHash(), deployer.requiredFlags(), 0);
        address first = address(deployer.deploy(salt));
        (bytes32 other,) =
            SaltMiner.mine(address(deployer), deployer.initCodeHash(), deployer.requiredFlags(), uint256(salt) + 1);
        vm.expectRevert(abi.encodeWithSelector(PondsideGuardDeployer.AlreadyDeployed.selector, first));
        deployer.deploy(other);
    }

    function test_deployWithWrongSaltReverts() public {
        bytes32 salt = bytes32(uint256(1));
        // Walk forward to a salt that does not carry the required bits.
        while (deployer.isValidSalt(salt)) salt = bytes32(uint256(salt) + 1);
        address predicted = deployer.predict(salt);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        deployer.deploy(salt);
        assertEq(address(deployer.hook()), address(0));
    }

    function test_anyoneMayDeployAndResultIsCallerIndependent() public {
        (bytes32 salt, address predicted) =
            SaltMiner.mine(address(deployer), deployer.initCodeHash(), deployer.requiredFlags(), 0);
        vm.prank(makeAddr("stranger"));
        PondsideGuard hook = deployer.deploy(salt);
        assertEq(address(hook), predicted);
        assertEq(hook.owner(), owner);
    }

    function test_hookCannotBeDeployedAtAnAddressWithoutTheBits() public {
        // A plain CREATE address almost never carries exactly the required bits; the constructor must refuse it.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertTrue((uint160(predicted) & Hooks.ALL_HOOK_MASK) != deployer.requiredFlags(), "fixture address collides");
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new PondsideGuard(manager, owner, recipient);
    }

    function test_scriptMinesAgainstLiveDeployer() public {
        MineSalt script = new MineSalt();
        (bytes32 salt, address predicted) = script.mineFor(deployer);
        assertTrue(deployer.isValidSalt(salt));
        assertEq(deployer.predict(salt), predicted);
        assertEq(address(deployer.deploy(salt)), predicted);
    }

    function testFuzz_isValidSaltAgreesWithFlagMask(uint256 raw) public view {
        bytes32 salt = bytes32(raw);
        bool expected = (uint160(deployer.predict(salt)) & Hooks.ALL_HOOK_MASK) == deployer.requiredFlags();
        assertEq(deployer.isValidSalt(salt), expected);
    }

    function test_deployerRuntimeFitsAndHookRuntimeFits() public {
        assertLe(address(deployer).code.length, 24_576, "deployer runtime exceeds EIP-170");
        assertLe(type(PondsideGuardDeployer).creationCode.length, 49_152, "deployer init code exceeds EIP-3860");
        (bytes32 salt,) = SaltMiner.mine(address(deployer), deployer.initCodeHash(), deployer.requiredFlags(), 0);
        PondsideGuard hook = deployer.deploy(salt);
        assertLe(address(hook).code.length, 24_576, "hook runtime exceeds EIP-170");
    }
}
