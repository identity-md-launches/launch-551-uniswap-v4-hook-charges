// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TaxyHook} from "../src/TaxyHook.sol";
import {TaxyToken} from "../src/TaxyToken.sol";
import {MineTaxySalt} from "../script/MineTaxySalt.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract DeploymentTest is Test {
    function test_minerProducesDeployableAddressAndPoolInitializes() public {
        IPoolManager manager = new PoolManager(address(this));
        MineTaxySalt miner = new MineTaxySalt();
        (address predicted, bytes32 salt) = miner.run(address(this), manager, 0, 200_000);
        TaxyToken token = new TaxyToken();
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3_000, 60, IHooks(predicted));
        vm.expectRevert();
        manager.initialize(key, 1 << 96);
        TaxyHook hook = new TaxyHook{salt: salt}(manager);
        assertEq(address(hook), predicted);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(manager.initialize(key, 1 << 96), 0);
        _assertNoEscapeHatches(address(hook).code);
        _assertNoEscapeHatches(address(token).code);
        bytes[] memory attempts = new bytes[](6);
        attempts[0] = abi.encodeWithSignature("setFee(uint256)", 0);
        attempts[1] = abi.encodeWithSignature("setFeeRecipient(address)", address(this));
        attempts[2] = abi.encodeWithSignature("transferOwnership(address)", address(this));
        attempts[3] = abi.encodeWithSignature("pause()");
        attempts[4] = abi.encodeWithSignature("upgradeTo(address)", address(this));
        attempts[5] = abi.encodeWithSignature("setPoolManager(address)", address(this));
        for (uint256 i; i < attempts.length; ++i) {
            (bool ok,) = address(hook).call(attempts[i]);
            assertFalse(ok);
            vm.prank(address(0xBEEF));
            (ok,) = address(hook).call(attempts[i]);
            assertFalse(ok);
        }
        assertEq(hook.FEE_BPS(), 400);
        assertEq(hook.FEE_RECIPIENT(), 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7);
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_minerRejectsInvalidArguments() public {
        MineTaxySalt miner = new MineTaxySalt();
        vm.expectRevert(MineTaxySalt.InvalidSearch.selector);
        miner.run(address(0), IPoolManager(address(1)), 0, 1);
        vm.expectRevert(MineTaxySalt.InvalidSearch.selector);
        miner.run(address(this), IPoolManager(address(0)), 0, 1);
        vm.expectRevert(MineTaxySalt.InvalidSearch.selector);
        miner.run(address(this), IPoolManager(address(1)), 0, 0);
    }

    function test_constructorRejectsManagerWithoutCode() public {
        vm.expectRevert(TaxyHook.InvalidPoolManager.selector);
        new TaxyHook(IPoolManager(address(0)));
    }

    function _assertNoEscapeHatches(bytes memory runtime) private pure {
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
            }
        }
    }
}
