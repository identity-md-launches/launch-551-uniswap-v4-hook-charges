// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TaxyHook} from "../src/TaxyHook.sol";
import {TaxyToken} from "../src/TaxyToken.sol";
import {SettlementRouter} from "./helpers/SettlementRouter.sol";
import {RejectingRecipient, ReentrantRecipient} from "./helpers/FeeRecipients.sol";
import {SwapHandler} from "./helpers/SwapHandler.sol";

contract TaxyHookTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant RECIPIENT = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    uint160 internal constant FLAGS = 0x20cc;
    uint160 internal constant ONE = 79228162514264337593543950336;
    int256 internal constant LIQUIDITY = 100_000 ether;
    IPoolManager internal manager;
    TaxyHook internal hook;
    TaxyToken internal token;
    SettlementRouter internal router;
    SwapHandler internal handler;
    PoolKey internal key;
    uint256 internal conservedETH;
    uint256 internal initialRecipientETH;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new TaxyToken();
        hook = _deployHook();
        router = new SettlementRouter(manager);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        manager.initialize(key, ONE);
        vm.deal(address(this), 100_000 ether);
        token.approve(address(router), type(uint256).max);
        router.modifyLiquidity{value: 10_000 ether}(key, ModifyLiquidityParams(-600, 600, LIQUIDITY, bytes32(0)));
        handler = new SwapHandler(manager, router, key, token);
        token.transfer(address(handler), 10_000 ether);
        vm.deal(address(handler), 10_000 ether);
        conservedETH = address(this).balance + address(manager).balance + address(handler).balance + RECIPIENT.balance;
        initialRecipientETH = RECIPIENT.balance;
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SwapHandler.swap.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _deployHook() internal returns (TaxyHook deployed) {
        bytes memory creation = abi.encodePacked(type(TaxyHook).creationCode, abi.encode(manager));
        bytes32 hash = keccak256(creation);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != FLAGS) continue;
            address at;
            assembly ("memory-safe") {
                at := create2(0, add(creation, 32), mload(creation), salt)
            }
            require(at != address(0), "hook CREATE2 failed");
            return TaxyHook(at);
        }
        revert("no salt found");
    }

    function test_permissionsAndInitialization() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, ONE);
    }

    function test_ETHExactInputChargesFourPercentAndPaysImmediately() public {
        _checkSwap(true, -10 ether);
    }

    function test_TokenExactOutputChargesFourPercentInETH() public {
        _checkSwap(true, 10 ether);
    }

    function test_TokenExactInputChargesFourPercentInETH() public {
        _checkSwap(false, -10 ether);
    }

    function test_ETHExactOutputDeliversExactNetETH() public {
        _checkSwap(false, 10 ether);
    }

    function testFuzz_allModesConserveFunds(uint96 rawAmount, bool zeroForOne, bool exactInput) public {
        uint256 amount = bound(uint256(rawAmount), 100, 100 ether);
        _checkSwap(zeroForOne, exactInput ? -int256(amount) : int256(amount));
    }

    function _checkSwap(bool zeroForOne, int256 specified) internal returns (BalanceDelta delta) {
        uint256 traderETH = address(this).balance;
        uint256 managerETH = address(manager).balance;
        uint256 recipientETH = RECIPIENT.balance;
        uint256 traderToken = token.balanceOf(address(this));
        uint256 managerToken = token.balanceOf(address(manager));
        delta = router.swap{value: zeroForOne ? 1000 ether : 0}(key, _params(zeroForOne, specified));
        uint256 fee = RECIPIENT.balance - recipientETH;
        if (zeroForOne) {
            uint256 paid = uint256(-int256(delta.amount0()));
            uint256 poolInput = address(manager).balance - managerETH;
            assertEq(traderETH - address(this).balance, paid);
            assertEq(paid, poolInput + fee);
            assertEq(fee, paid / 25, "fee must be 4% of total ETH charged");
            assertEq(token.balanceOf(address(this)) - traderToken, uint256(int256(delta.amount1())));
            if (specified < 0) assertEq(paid, uint256(-specified));
            else assertEq(int256(delta.amount1()), specified);
        } else {
            uint256 received = uint256(int256(delta.amount0()));
            uint256 grossOutput = managerETH - address(manager).balance;
            assertEq(address(this).balance - traderETH, received);
            assertEq(received + fee, grossOutput);
            assertEq(fee, grossOutput / 25, "fee must be 4% of gross ETH output");
            assertEq(traderToken - token.balanceOf(address(this)), uint256(-int256(delta.amount1())));
            if (specified > 0) assertEq(received, uint256(specified));
            else assertEq(int256(delta.amount1()), specified);
        }
        assertEq(
            traderETH + managerETH + recipientETH, address(this).balance + address(manager).balance + RECIPIENT.balance
        );
        assertEq(traderToken + managerToken, token.balanceOf(address(this)) + token.balanceOf(address(manager)));
        _assertSettled();
    }

    function test_roundingChargesZeroBelow25WeiAndOneAt25Wei() public {
        uint256 beforeFee = RECIPIENT.balance;
        _checkSwap(true, -24);
        assertEq(RECIPIENT.balance, beforeFee);
        _checkSwap(true, -25);
        assertEq(RECIPIENT.balance - beforeFee, 1);
        _checkSwap(true, -26);
        assertEq(RECIPIENT.balance - beforeFee, 2);
    }

    function test_partialTokenInputChargesOnlyActualETHOutput() public {
        uint256 recipientETH = RECIPIENT.balance;
        uint256 managerETH = address(manager).balance;
        BalanceDelta delta = router.swap(key, SwapParams(false, -100 ether, TickMath.getSqrtPriceAtTick(1)));
        assertGt(delta.amount1(), -100 ether);
        assertLt(delta.amount1(), 0);
        uint256 fee = RECIPIENT.balance - recipientETH;
        uint256 gross = managerETH - address(manager).balance;
        assertEq(fee, gross / 25);
        assertEq(uint256(int256(delta.amount0())) + fee, gross);
        _assertSettled();
    }

    function test_partialTokenOutputChargesOnlyActualETHInput() public {
        uint256 recipientETH = RECIPIENT.balance;
        uint256 managerETH = address(manager).balance;
        BalanceDelta delta =
            router.swap{value: 1000 ether}(key, SwapParams(true, 100 ether, TickMath.getSqrtPriceAtTick(-1)));
        assertGt(delta.amount1(), 0);
        assertLt(delta.amount1(), 100 ether);
        uint256 fee = RECIPIENT.balance - recipientETH;
        uint256 poolInput = address(manager).balance - managerETH;
        assertEq(fee, poolInput / 24);
        assertEq(uint256(-int256(delta.amount0())), poolInput + fee);
        _assertSettled();
    }

    function test_partialETHInputRevertsAtomically() public {
        _expectAtomicFailure(
            SwapParams(true, -100 ether, TickMath.getSqrtPriceAtTick(-1)),
            100 ether,
            _wrappedHookError(IHooks.afterSwap.selector, TaxyHook.PartialFillNotSupported.selector)
        );
        _checkSwap(true, -1 ether);
    }

    function test_partialETHOutputRevertsAtomically() public {
        _expectAtomicFailure(
            SwapParams(false, 100 ether, TickMath.getSqrtPriceAtTick(1)),
            0,
            _wrappedHookError(IHooks.afterSwap.selector, TaxyHook.PartialFillNotSupported.selector)
        );
        _checkSwap(false, 1 ether);
    }

    function test_recipientRejectingETHRevertsWholeSwap() public {
        vm.etch(RECIPIENT, address(new RejectingRecipient()).code);
        _expectAtomicFailure(_params(true, -10 ether), 10 ether);
        vm.etch(RECIPIENT, hex"");
        _checkSwap(true, -1 ether);
    }

    function test_recipientCannotReenterSwapDuringFeePayment() public {
        vm.etch(RECIPIENT, address(new ReentrantRecipient()).code);
        ReentrantRecipient(payable(RECIPIENT)).configure(manager, key);
        _checkSwap(true, -10 ether);
        assertTrue(ReentrantRecipient(payable(RECIPIENT)).attempted());
        assertTrue(ReentrantRecipient(payable(RECIPIENT)).blocked());
        assertEq(
            ReentrantRecipient(payable(RECIPIENT)).revertReason(),
            _wrappedHookError(IHooks.beforeSwap.selector, TaxyHook.ReentrantSwap.selector)
        );
    }

    function test_slippageIncludesFeeAndRevertsPayment() public {
        uint256 recipientETH = RECIPIENT.balance;
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        vm.expectRevert("maximum input");
        router.swapWithLimits{value: 100 ether}(key, _params(true, 10 ether), 10 ether, 10 ether);
        assertEq(RECIPIENT.balance, recipientETH);
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceBefore, priceAfter);
        _assertSettled();
    }

    function test_allEnabledCallbacksRejectUnauthorizedCaller() public {
        vm.expectRevert(TaxyHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, ONE);
        vm.expectRevert(TaxyHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, _params(true, -1 ether), "");
        vm.expectRevert(TaxyHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, _params(true, -1 ether), BalanceDelta.wrap(0), "");
    }

    function test_ERC20PairCannotInitialize() public {
        PoolKey memory bad = key;
        bad.currency0 = Currency.wrap(address(1));
        vm.expectRevert(_wrappedHookError(IHooks.beforeInitialize.selector, TaxyHook.UnsupportedPool.selector));
        manager.initialize(bad, ONE);
    }

    function test_dynamicLPFeeCannotInitialize() public {
        PoolKey memory bad = key;
        bad.fee = 0x800000;
        vm.expectRevert(_wrappedHookError(IHooks.beforeInitialize.selector, TaxyHook.UnsupportedPool.selector));
        manager.initialize(bad, ONE);
    }

    function test_initializationRejectsWrongHookKey() public {
        PoolKey memory bad = key;
        bad.hooks = IHooks(address(0));
        vm.prank(address(manager));
        vm.expectRevert(TaxyHook.UnsupportedPool.selector);
        hook.beforeInitialize(address(this), bad, ONE);
    }

    function test_zeroAmountRejectedAndNextSwapWorks() public {
        vm.expectRevert();
        router.swap{value: 1 ether}(key, _params(true, 0));
        _checkSwap(true, -1 ether);
    }

    function test_signedAmountBoundsRejectBeforeAccountingChanges() public {
        _expectInvalidAmount(type(int256).min, true);
        _expectInvalidAmount(type(int256).max, true);
        _expectInvalidAmount(int256(type(int128).max) + 1, false);
        _expectInvalidAmount(-int256(type(int128).max) - 1, true);
        // A native exact output must also leave room for its grossed-up fee in an int128 delta.
        _expectInvalidAmount(int256(type(int128).max), false);
        _checkSwap(true, -1 ether);
    }

    function _expectInvalidAmount(int256 amount, bool zeroForOne) internal {
        vm.prank(address(manager));
        vm.expectRevert(TaxyHook.InvalidAmount.selector);
        hook.beforeSwap(address(this), key, _params(zeroForOne, amount), "");
    }

    function test_afterSwapRequiresMatchingBeforeSwap() public {
        vm.prank(address(manager));
        vm.expectRevert(TaxyHook.MissingSwap.selector);
        hook.afterSwap(address(this), key, _params(true, -1 ether), BalanceDelta.wrap(0), "");
    }

    function test_constructorRejectsMissingManagerCode() public {
        vm.expectRevert(TaxyHook.InvalidPoolManager.selector);
        new TaxyHook(IPoolManager(address(0)));
    }

    function test_liquidityExitRemainsPossibleWhenRecipientRejectsETH() public {
        _checkSwap(true, -10 ether);
        vm.etch(RECIPIENT, address(new RejectingRecipient()).code);
        uint256 recipientETH = RECIPIENT.balance;
        BalanceDelta delta = router.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, -LIQUIDITY, bytes32(0)));
        assertGt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);
        assertEq(RECIPIENT.balance, recipientETH, "liquidity is not taxed");
        _assertSettled();
    }

    function test_sequentialSwapsDoNotLeakAccountingState() public {
        _checkSwap(true, -1 ether);
        _checkSwap(false, -1 ether);
        _checkSwap(true, 1 ether);
        _checkSwap(false, 1 ether);
    }

    function invariant_feesAndFundsConservedAcrossSwapSequences() public view {
        assertEq(RECIPIENT.balance, initialRecipientETH + handler.expectedFees());
        assertEq(
            address(this).balance + address(manager).balance + address(handler).balance + RECIPIENT.balance,
            conservedETH
        );
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(manager)) + token.balanceOf(address(handler)),
            token.totalSupply()
        );
        _assertSettled();
    }

    function _expectAtomicFailure(SwapParams memory params, uint256 value) internal {
        _expectAtomicFailure(params, value, "");
    }

    function _expectAtomicFailure(SwapParams memory params, uint256 value, bytes memory expectedError) internal {
        uint256 traderETH = address(this).balance;
        uint256 recipientETH = RECIPIENT.balance;
        uint256 managerETH = address(manager).balance;
        uint256 traderToken = token.balanceOf(address(this));
        uint256 managerToken = token.balanceOf(address(manager));
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        if (expectedError.length == 0) vm.expectRevert();
        else vm.expectRevert(expectedError);
        router.swap{value: value}(key, params);
        assertEq(address(this).balance, traderETH);
        assertEq(RECIPIENT.balance, recipientETH);
        assertEq(address(manager).balance, managerETH);
        assertEq(token.balanceOf(address(this)), traderToken);
        assertEq(token.balanceOf(address(manager)), managerToken);
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceBefore, priceAfter);
        _assertSettled();
    }

    function _wrappedHookError(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _assertSettled() internal view {
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    receive() external payable {}
}
