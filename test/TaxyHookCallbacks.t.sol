// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TaxyHook} from "src/TaxyHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @dev Isolates callback arithmetic at int128 limits that a funded real pool cannot practically
/// reach. This recorder only checks the native transfer request; real v4 delta settlement is
/// exercised separately by the integration suites.
contract CallbackFeeRecorder {
    address public hook;
    uint256 public calls;
    uint256 public paid;
    address public recipient;

    function setHook(address hook_) external {
        require(hook == address(0));
        hook = hook_;
    }

    function take(Currency currency, address to, uint256 amount) external {
        require(msg.sender == hook, "unexpected hook");
        require(Currency.unwrap(currency) == address(0), "fee is not native ETH");
        ++calls;
        paid += amount;
        recipient = to;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "fee transfer failed");
    }
}

contract TaxyHookCallbacksTest is Test {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    address private constant RECIPIENT = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    uint256 private constant MAX_AMOUNT = uint256(uint128(type(int128).max));
    uint256 private constant MAX_NET = MAX_AMOUNT - MAX_AMOUNT / 25;
    CallbackFeeRecorder private manager;
    TaxyHook private hook;
    PoolKey private key;

    struct FeeSnapshot {
        uint256 recipientBalance;
        uint256 managerBalance;
        uint256 calls;
    }

    function setUp() public {
        manager = new CallbackFeeRecorder();
        bytes memory creation = abi.encodePacked(type(TaxyHook).creationCode, abi.encode(address(manager)));
        bytes32 hash = keccak256(creation);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == 0x20cc) {
                hook = new TaxyHook{salt: salt}(IPoolManager(address(manager)));
                break;
            }
        }
        require(address(hook) != address(0), "no hook salt");
        manager.setHook(address(hook));
        vm.deal(address(manager), MAX_AMOUNT * 2);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0x1234)), 3000, 60, IHooks(address(hook)));
    }

    function test_disabledCallbacksAuthenticateAndRejectEvenManager() public {
        bytes[] memory calls = _disabledCallbacks();
        for (uint256 i; i < calls.length; ++i) {
            _expectFailure(address(0xBEEF), calls[i], TaxyHook.NotPoolManager.selector);
            _expectFailure(address(manager), calls[i], TaxyHook.CallbackNotEnabled.selector);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_senderCannotImpersonatePoolManager(address caller, uint8 callback) public {
        if (caller == address(manager)) caller = address(0xBEEF);
        bytes[] memory calls = _disabledCallbacks();
        uint256 selected = bound(uint256(callback), 0, calls.length + 2);
        bytes memory payload;
        if (selected < calls.length) {
            payload = calls[selected];
        } else if (selected == calls.length) {
            payload = abi.encodeCall(IHooks.beforeInitialize, (address(manager), key, uint160(1 << 96)));
        } else if (selected == calls.length + 1) {
            payload = abi.encodeCall(IHooks.beforeSwap, (address(manager), key, _params(true, -1), bytes("")));
        } else {
            payload = abi.encodeCall(
                IHooks.afterSwap, (address(manager), key, _params(true, -1), BalanceDelta.wrap(0), bytes(""))
            );
        }
        _expectFailure(caller, payload, TaxyHook.NotPoolManager.selector);
        assertEq(manager.calls(), 0);
        _exercise(25, 0);
    }

    function test_allUnsupportedPoolShapesRejectedBeforeInitializeAndSwap() public {
        PoolKey memory invalid = key;
        invalid.currency0 = Currency.wrap(address(1));
        _expectUnsupported(invalid);
        invalid = key;
        invalid.currency1 = Currency.wrap(address(0));
        _expectUnsupported(invalid);
        invalid = key;
        invalid.hooks = IHooks(address(0));
        _expectUnsupported(invalid);
        invalid = key;
        invalid.hooks = IHooks(address(0x20cc));
        _expectUnsupported(invalid);
        invalid = key;
        invalid.fee = 0x800000;
        _expectUnsupported(invalid);
        invalid.fee = type(uint24).max;
        _expectUnsupported(invalid);
        _exercise(25, 0);
    }

    function test_zeroInputRejectedByHookForBothDirections() public {
        _expectBeforeFailure(true, 0, TaxyHook.InvalidAmount.selector);
        _expectBeforeFailure(false, 0, TaxyHook.InvalidAmount.selector);
        _exercise(1, 0);
    }

    function test_duplicateBeforeAndAfterCallbacksCannotChargeTwice() public {
        SwapParams memory params = _params(true, -1);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, params, "");
        _expectBeforeFailure(true, -1, TaxyHook.ReentrantSwap.selector);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, toBalanceDelta(-1, 0), "");
        _expectFailure(
            address(manager),
            abi.encodeCall(IHooks.afterSwap, (address(this), key, params, toBalanceDelta(-1, 0), bytes(""))),
            TaxyHook.MissingSwap.selector
        );
        assertEq(manager.calls(), 0);
        _exercise(25, 0);
        assertEq(manager.calls(), 1);
        assertEq(manager.paid(), 1);
    }

    function test_grossedUpNativeExactOutputLimitAndOneBeyond() public {
        _expectBeforeFailure(false, int256(MAX_NET + 1), TaxyHook.InvalidAmount.selector);
        _exercise(MAX_NET, 3);
        _exercise(MAX_AMOUNT, 0);
        _exercise(MAX_AMOUNT, 2);
    }

    function test_oneWeiAndRoundingBoundariesInEveryMode() public {
        uint256[7] memory amounts = [uint256(1), 23, 24, 25, 26, 47, 48];
        for (uint8 mode; mode < 4; ++mode) {
            for (uint256 i; i < amounts.length; ++i) {
                _exercise(amounts[i], mode);
            }
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeDeltasMatchETHDeliveredAcrossInt128Domain(uint128 raw, uint8 modeSeed) public {
        uint8 mode = uint8(bound(uint256(modeSeed), 0, 3));
        uint256 amount = bound(uint256(raw), 1, mode == 1 || mode == 3 ? MAX_NET : MAX_AMOUNT);
        _exercise(amount, mode);
    }

    function test_unexpectedNativeSignsCannotCausePayment() public {
        // These deliberately malformed deltas test defensive callback checks. The real manager
        // supplies the delta from the matching swap, so they are not an external attack path.
        _invalidUnspecifiedDelta(true, toBalanceDelta(1, 1));
        _invalidUnspecifiedDelta(false, toBalanceDelta(-1, -1));
    }

    function test_tokenSpecifiedBuyRejectsGrossBeyondInt128() public {
        SwapParams memory params = _params(true, 1);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, params, "");
        _expectFailure(
            address(manager),
            abi.encodeCall(
                IHooks.afterSwap,
                (address(this), key, params, toBalanceDelta(-int128(int256(MAX_NET + 1)), 1), bytes(""))
            ),
            TaxyHook.InvalidAmount.selector
        );
        assertEq(manager.calls(), 0);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, toBalanceDelta(-1, 1), "");
        _exercise(MAX_NET, 1);
    }

    /// @dev Four modes: ETH exact input, token exact output, token exact input, ETH exact output.
    /// The oracle checks fee rounding inequalities and conservation between the actual transfer
    /// and return deltas, without reproducing the hook's branch-specific fee formulas.
    function _exercise(uint256 nativeAmount, uint8 mode) private {
        bool buy = mode < 2;
        bool nativeSpecified = mode == 0 || mode == 3;
        SwapParams memory params = _params(
            buy,
            mode == 0 ? -int256(nativeAmount) : mode == 3 ? int256(nativeAmount) : mode == 1 ? int256(1) : -int256(1)
        );
        FeeSnapshot memory beforeFee = FeeSnapshot(RECIPIENT.balance, address(manager).balance, manager.calls());
        int128 reserved = _before(params);
        if (!nativeSpecified) assertEq(reserved, 0);
        if (mode == 0) assertLt(uint256(uint128(reserved)), nativeAmount, "fee consumes entire input");

        int256 nativeDelta = buy ? -int256(nativeAmount) : int256(nativeAmount);
        if (nativeSpecified) nativeDelta += reserved;
        int128 afterDelta = _after(params, int128(nativeDelta));
        if (nativeSpecified) assertEq(afterDelta, 0);

        uint256 paid = RECIPIENT.balance - beforeFee.recipientBalance;
        assertEq(beforeFee.managerBalance - address(manager).balance, paid);
        assertEq(uint256(uint128(reserved)) + uint256(uint128(afterDelta)), paid, "fee debt must cancel exactly");
        uint256 gross = (mode == 1 || mode == 3) ? nativeAmount + paid : nativeAmount;
        assertLe(paid * 10_000, gross * 400, "fee rounds above 4%");
        assertLt(gross * 400, (paid + 1) * 10_000, "fee rounds below 4%");
        assertEq(manager.calls() - beforeFee.calls, paid == 0 ? 0 : 1);
        if (paid != 0) assertEq(manager.recipient(), RECIPIENT);
        assertEq(address(hook).balance, 0);
    }

    function _before(SwapParams memory params) private returns (int128 reserved) {
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 overrideFee) =
            hook.beforeSwap(address(this), key, params, hex"deadbeef");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(overrideFee, 0, "hook must not override LP fee");
        assertEq(delta.getUnspecifiedDelta(), 0);
        reserved = delta.getSpecifiedDelta();
        assertGe(reserved, 0);
    }

    function _after(SwapParams memory params, int128 nativeDelta) private returns (int128 feeDelta) {
        vm.prank(address(manager));
        bytes4 selector;
        (selector, feeDelta) = hook.afterSwap(
            address(this), key, params, toBalanceDelta(nativeDelta, params.zeroForOne ? int128(1) : int128(-1)), ""
        );
        assertEq(selector, IHooks.afterSwap.selector);
        assertGe(feeDelta, 0);
    }

    function _invalidUnspecifiedDelta(bool buy, BalanceDelta invalidDelta) private {
        SwapParams memory params = _params(buy, buy ? int256(1) : -int256(1));
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, params, "");
        _expectFailure(
            address(manager),
            abi.encodeCall(IHooks.afterSwap, (address(this), key, params, invalidDelta, bytes(""))),
            TaxyHook.InvalidAmount.selector
        );
        assertEq(manager.calls(), 0);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, toBalanceDelta(buy ? int128(-1) : int128(1), 0), "");
    }

    function _expectUnsupported(PoolKey memory invalid) private {
        _expectFailure(
            address(manager),
            abi.encodeCall(IHooks.beforeInitialize, (address(this), invalid, uint160(1 << 96))),
            TaxyHook.UnsupportedPool.selector
        );
        _expectFailure(
            address(manager),
            abi.encodeCall(IHooks.beforeSwap, (address(this), invalid, _params(true, -25), bytes(""))),
            TaxyHook.UnsupportedPool.selector
        );
    }

    function _expectBeforeFailure(bool buy, int256 amount, bytes4 errorSelector) private {
        _expectFailure(
            address(manager),
            abi.encodeCall(IHooks.beforeSwap, (address(this), key, _params(buy, amount), bytes(""))),
            errorSelector
        );
    }

    function _expectFailure(address caller, bytes memory payload, bytes4 errorSelector) private {
        vm.prank(caller);
        (bool ok, bytes memory reason) = address(hook).call(payload);
        assertFalse(ok, "callback unexpectedly succeeded");
        assertEq(reason, abi.encodeWithSelector(errorSelector));
    }

    function _disabledCallbacks() private view returns (bytes[] memory calls) {
        ModifyLiquidityParams memory liquidity = ModifyLiquidityParams(-60, 60, 1, bytes32(0));
        BalanceDelta zero = BalanceDelta.wrap(0);
        calls = new bytes[](7);
        calls[0] = abi.encodeCall(IHooks.afterInitialize, (address(manager), key, uint160(1 << 96), int24(0)));
        calls[1] = abi.encodeCall(IHooks.beforeAddLiquidity, (address(manager), key, liquidity, bytes("")));
        calls[2] = abi.encodeCall(IHooks.afterAddLiquidity, (address(manager), key, liquidity, zero, zero, bytes("")));
        calls[3] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(manager), key, liquidity, bytes("")));
        calls[4] =
            abi.encodeCall(IHooks.afterRemoveLiquidity, (address(manager), key, liquidity, zero, zero, bytes("")));
        calls[5] = abi.encodeCall(IHooks.beforeDonate, (address(manager), key, uint256(1), uint256(1), bytes("")));
        calls[6] = abi.encodeCall(IHooks.afterDonate, (address(manager), key, uint256(1), uint256(1), bytes("")));
    }

    function _params(bool buy, int256 amount) private pure returns (SwapParams memory) {
        return SwapParams(buy, amount, uint160(1 << 96));
    }
}
