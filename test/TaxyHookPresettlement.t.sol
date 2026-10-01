// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TaxyHook} from "src/TaxyHook.sol";
import {TaxyToken} from "src/TaxyToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test adapter that funds immediate hook fees before the swap, then reconciles actual credits.
contract TaxyPresettlementRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    address private constant RECIPIENT = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    uint256 public feeObservedBeforeReconciliation;

    struct Action {
        address payer;
        PoolKey key;
        bool isSwap;
        SwapParams swapParams;
        uint256 nativeCredit;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function seedTokenOnly(PoolKey memory key) external {
        Action memory action;
        action.payer = msg.sender;
        action.key = key;
        manager.unlock(abi.encode(action));
    }

    function swap(PoolKey memory key, SwapParams memory params) external payable returns (BalanceDelta) {
        Action memory action = Action(msg.sender, key, true, params, msg.value);
        return abi.decode(manager.unlock(abi.encode(action)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        Action memory action = abi.decode(data, (Action));
        BalanceDelta delta;
        if (action.isSwap) {
            if (action.nativeCredit != 0) {
                manager.sync(Currency.wrap(address(0)));
                manager.settle{value: action.nativeCredit}();
            }
            uint256 recipientBefore = RECIPIENT.balance;
            delta = manager.swap(action.key, action.swapParams, "");
            // Capture the actual recipient payment before the caller's remaining credits are settled.
            feeObservedBeforeReconciliation = RECIPIENT.balance - recipientBefore;
        } else {
            // At tick zero, [-600, 0] is entirely token1: no native currency is deposited.
            (delta,) =
                manager.modifyLiquidity(action.key, ModifyLiquidityParams(-600, 0, 100_000 ether, bytes32(0)), "");
        }
        _reconcile(action.key.currency0, action.payer);
        _reconcile(action.key.currency1, action.payer);
        return abi.encode(delta);
    }

    function _reconcile(Currency currency, address payer) private {
        // A prepayment changes the caller's credit independently of the returned swap delta.
        int256 remaining = manager.currencyDelta(address(this), currency);
        if (remaining > 0) {
            manager.take(currency, payer, uint256(remaining));
        } else if (remaining < 0) {
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: uint256(-remaining)}();
            } else {
                require(
                    IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(-remaining)),
                    "token settlement failed"
                );
                manager.settle();
            }
        }
    }
}

contract TaxyHookPresettlementTest is Test {
    using TransientStateLibrary for IPoolManager;

    uint160 private constant ONE = 79228162514264337593543950336;
    address private constant RECIPIENT = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    IPoolManager private manager;
    TaxyHook private hook;
    TaxyToken private token;
    TaxyPresettlementRouter private router;
    PoolKey private key;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new TaxyToken();
        hook = _deployHook();
        router = new TaxyPresettlementRouter(manager);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        manager.initialize(key, ONE);
        token.approve(address(router), type(uint256).max);
        router.seedTokenOnly(key);
        vm.deal(address(this), 1_000 ether);
        assertEq(address(manager).balance, 0, "fixture must have no native reserves");
        assertGt(token.balanceOf(address(manager)), 0);
    }

    function test_prepaidBuyPaysFeeImmediatelyFromZeroNativeReserves() public {
        _checkBuy(1 ether, 0);
    }

    function test_unusedPrepaidCreditIsRefundedWithoutDoublePayment() public {
        _checkBuy(1 ether, 1 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_prepaidBuysConserveFundsAndRefundSurplus(uint96 rawInput, uint96 rawSurplus) public {
        _checkBuy(bound(rawInput, 25, 100 ether), bound(rawSurplus, 0, 100 ether));
    }

    function test_emptyPoolTokenSpecifiedSwapsRefundAllCreditAndPayNoFee() public {
        PoolKey memory empty = key;
        empty.fee = 500;
        manager.initialize(empty, ONE);
        uint256 traderETH = address(this).balance;
        uint256 traderToken = token.balanceOf(address(this));
        uint256 recipientETH = RECIPIENT.balance;

        BalanceDelta buy = router.swap{value: 1 ether}(empty, SwapParams(true, 1 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(BalanceDelta.unwrap(buy), 0, "empty pool must execute no exchange");
        assertEq(router.feeObservedBeforeReconciliation(), 0);
        BalanceDelta sell = router.swap(empty, SwapParams(false, -1 ether, TickMath.MAX_SQRT_PRICE - 1));
        assertEq(BalanceDelta.unwrap(sell), 0, "empty pool must execute no exchange");
        assertEq(router.feeObservedBeforeReconciliation(), 0);
        assertEq(address(this).balance, traderETH, "all unspent native credit must be refunded");
        assertEq(token.balanceOf(address(this)), traderToken);
        assertEq(RECIPIENT.balance, recipientETH);
        assertEq(address(manager).balance, 0);
        _assertReconciled();
    }

    function _checkBuy(uint256 grossInput, uint256 surplus) private {
        uint256 traderETH = address(this).balance;
        uint256 traderToken = token.balanceOf(address(this));
        uint256 managerToken = token.balanceOf(address(manager));
        uint256 recipientETH = RECIPIENT.balance;
        BalanceDelta delta = router.swap{value: grossInput + surplus}(
            key, SwapParams(true, -int256(grossInput), TickMath.MIN_SQRT_PRICE + 1)
        );
        uint256 fee = grossInput * 400 / 10_000;
        assertEq(int256(delta.amount0()), -int256(grossInput), "the requested ETH input must fully execute");
        assertGt(delta.amount1(), 0, "the funded token position must supply output");
        assertEq(traderETH - address(this).balance, grossInput, "surplus must be returned to the trader");
        assertEq(RECIPIENT.balance - recipientETH, fee);
        assertEq(router.feeObservedBeforeReconciliation(), fee, "fee must arrive during the swap");
        assertEq(address(manager).balance, grossInput - fee);
        assertEq(token.balanceOf(address(this)) - traderToken, uint256(int256(delta.amount1())));
        assertEq(managerToken - token.balanceOf(address(manager)), uint256(int256(delta.amount1())));
        assertEq(token.balanceOf(RECIPIENT), 0, "the fee must be native currency only");
        _assertReconciled();
    }

    function _assertReconciled() private view {
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

    function _deployHook() private returns (TaxyHook) {
        bytes memory creation = abi.encodePacked(type(TaxyHook).creationCode, abi.encode(manager));
        bytes32 hash = keccak256(creation);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != 0x20cc) continue;
            address deployed;
            assembly ("memory-safe") {
                deployed := create2(0, add(creation, 32), mload(creation), salt)
            }
            require(deployed != address(0), "hook deployment failed");
            return TaxyHook(deployed);
        }
        revert("no hook salt found");
    }

    receive() external payable {}
}
