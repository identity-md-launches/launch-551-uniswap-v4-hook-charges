// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TaxyHook} from "src/TaxyHook.sol";
import {TaxyToken} from "src/TaxyToken.sol";
import {SettlementRouter} from "./helpers/SettlementRouter.sol";

/// @dev Real v4 integration. Inputs keep prices within the seeded range even for
/// 64 consecutive trades in one direction; no funds are minted during a sequence.
contract TaxyLifecycleHandler is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address public constant RECIPIENT = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    IPoolManager public immutable manager;
    TaxyToken public immutable token;
    SettlementRouter public immutable router;
    PoolKey[2] private keys;
    address[3] public actors;
    uint256[3][2] public liquidity;
    uint256 public expectedFees;
    uint256 public swaps;
    uint256 public rejectedSwaps;
    uint256 public liquidityChanges;
    uint256 public roundTrips;

    struct Balances {
        uint256 traderETH;
        uint256 traderToken;
        uint256 managerETH;
        uint256 managerToken;
        uint256 recipientETH;
    }

    constructor(
        IPoolManager manager_,
        TaxyToken token_,
        SettlementRouter router_,
        PoolKey[2] memory keys_,
        address[3] memory actors_
    ) {
        manager = manager_;
        token = token_;
        router = router_;
        for (uint256 p; p < 2; ++p) {
            keys[p] = keys_[p];
        }
        actors = actors_;
    }

    function trade(uint256 actorSeed, uint256 poolSeed, uint256 amountSeed, bool buy, bool exactInput) public {
        uint256 amount = bound(amountSeed, 1, 10 ether);
        _trade(actors[actorSeed % 3], keys[poolSeed % 2], buy, exactInput ? -int256(amount) : int256(amount));
    }

    function _trade(address actor, PoolKey memory key, bool buy, int256 amount) private returns (BalanceDelta delta) {
        Balances memory before_ = _balances(actor);
        vm.prank(actor);
        delta = router.swap{value: buy ? 100 ether : 0}(key, _params(buy, amount));
        uint256 fee = RECIPIENT.balance - before_.recipientETH;
        uint256 gross;
        if (buy) {
            gross = before_.traderETH - actor.balance;
            assertEq(int256(delta.amount0()), -int256(gross), "buy ETH delta");
            assertEq(token.balanceOf(actor) - before_.traderToken, uint256(int256(delta.amount1())), "buy token delta");
            assertEq(address(manager).balance - before_.managerETH + fee, gross, "buy allocation");
            assertEq(
                before_.managerToken - token.balanceOf(address(manager)), token.balanceOf(actor) - before_.traderToken
            );
            if (amount < 0) assertEq(gross, uint256(-amount), "exact ETH input");
            else assertEq(int256(delta.amount1()), amount, "exact token output");
        } else {
            gross = before_.managerETH - address(manager).balance;
            assertEq(actor.balance - before_.traderETH + fee, gross, "sell allocation");
            assertEq(int256(delta.amount0()), int256(actor.balance - before_.traderETH), "sell ETH delta");
            assertEq(
                before_.traderToken - token.balanceOf(actor), uint256(-int256(delta.amount1())), "sell token delta"
            );
            assertEq(
                token.balanceOf(address(manager)) - before_.managerToken, before_.traderToken - token.balanceOf(actor)
            );
            if (amount > 0) assertEq(int256(delta.amount0()), amount, "exact ETH output");
            else assertEq(int256(delta.amount1()), amount, "exact token input");
        }
        // Bound the rounding error independently of the hook's /24 and /25 branches.
        assertLe(fee * 10_000, gross * 400, "fee exceeds four percent");
        assertGt((fee + 1) * 10_000, gross * 400, "fee rounds down by more than one wei");
        expectedFees += gross * 400 / 10_000;
        ++swaps;
        assertSettled();
    }

    function changeLiquidity(uint256 actorSeed, uint256 poolSeed, uint256 amountSeed, bool remove) public {
        uint256 a = actorSeed % 3;
        uint256 p = poolSeed % 2;
        uint256 held = liquidity[p][a];
        bool withdrawing = remove && held != 0;
        uint256 amount = withdrawing ? bound(amountSeed, 1, held) : bound(amountSeed, 1 ether, 1_000 ether);
        _changeLiquidity(a, p, withdrawing ? -int256(amount) : int256(amount));
    }

    function _changeLiquidity(uint256 a, uint256 p, int256 amount) private {
        uint256 feeBefore = RECIPIENT.balance;
        vm.prank(actors[a]);
        router.modifyLiquidity{value: amount > 0 ? 1_000 ether : 0}(
            keys[p], ModifyLiquidityParams(-6000, 6000, amount, bytes32(a + 1))
        );
        if (amount > 0) liquidity[p][a] += uint256(amount);
        else liquidity[p][a] -= uint256(-amount);
        assertEq(RECIPIENT.balance, feeBefore, "liquidity operations must not charge swap fees");
        ++liquidityChanges;
        assertSettled();
    }

    function rejectedTrade(uint256 actorSeed, uint256 poolSeed, bool buy, bool failMinOutput) public {
        address actor = actors[actorSeed % 3];
        PoolKey memory key = keys[poolSeed % 2];
        Balances memory before_ = _balances(actor);
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        vm.expectRevert(failMinOutput ? bytes("minimum output") : bytes("maximum input"));
        vm.prank(actor);
        router.swapWithLimits{value: buy ? 1 ether : 0}(
            key, _params(buy, -1 ether), failMinOutput ? type(uint128).max : 0, failMinOutput ? type(uint256).max : 0
        );
        Balances memory after_ = _balances(actor);
        assertEq(abi.encode(before_), abi.encode(after_), "failed swap moved funds");
        (uint160 afterPrice, int24 afterTick,,) = manager.getSlot0(key.toId());
        (uint256 afterGrowth0, uint256 afterGrowth1) = manager.getFeeGrowthGlobals(key.toId());
        assertEq(price, afterPrice, "failed swap changed price");
        assertEq(tick, afterTick, "failed swap changed tick");
        assertEq(growth0, afterGrowth0, "failed swap accrued LP fees");
        assertEq(growth1, afterGrowth1, "failed swap accrued LP fees");
        ++rejectedSwaps;
        assertSettled();
    }

    function roundTrip(uint256 actorSeed, uint256 poolSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % 3];
        PoolKey memory key = keys[poolSeed % 2];
        uint256 amount = bound(amountSeed, 1 gwei, 10 ether);
        uint256 ethBefore = actor.balance;
        uint256 tokenBefore = token.balanceOf(actor);
        BalanceDelta buy = _trade(actor, key, true, -int256(amount));
        assertGt(buy.amount1(), 0, "round trip must execute");
        _trade(actor, key, false, -int256(buy.amount1()));
        assertEq(token.balanceOf(actor), tokenBefore, "round trip changed token holdings");
        assertLt(actor.balance, ethBefore, "round trip created ETH despite fees");
        ++roundTrips;
    }

    /// @dev Called after each invariant campaign to check withdrawal liveness.
    function closePositions() external {
        for (uint256 p; p < 2; ++p) {
            for (uint256 a; a < 3; ++a) {
                if (liquidity[p][a] != 0) _changeLiquidity(a, p, -int256(liquidity[p][a]));
            }
        }
    }

    function assertSettled() public view {
        address hook = address(keys[0].hooks);
        assertEq(hook.balance, 0, "hook retained ETH");
        assertEq(token.balanceOf(hook), 0, "hook retained tokens");
        assertEq(address(router).balance, 0, "router retained ETH");
        assertEq(token.balanceOf(address(router)), 0, "router retained tokens");
        for (uint256 c; c < 2; ++c) {
            Currency currency = c == 0 ? keys[0].currency0 : keys[0].currency1;
            assertEq(manager.currencyDelta(hook, currency), 0, "hook debt");
            assertEq(manager.currencyDelta(address(router), currency), 0, "router debt");
        }
        assertEq(manager.getNonzeroDeltaCount(), 0, "unsettled manager delta");
        assertFalse(manager.isUnlocked(), "manager left unlocked");
    }

    function _balances(address actor) private view returns (Balances memory) {
        return Balances(
            actor.balance,
            token.balanceOf(actor),
            address(manager).balance,
            token.balanceOf(address(manager)),
            RECIPIENT.balance
        );
    }

    function _params(bool buy, int256 amount) private pure returns (SwapParams memory) {
        return SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }
}

contract TaxyLifecycleTest is Test {
    using StateLibrary for IPoolManager;

    address private constant RECIPIENT = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    uint256 private constant BASE_LIQUIDITY = 100_000 ether;
    IPoolManager private manager;
    TaxyHook private hook;
    TaxyToken private token;
    SettlementRouter private router;
    TaxyLifecycleHandler private handler;
    PoolKey[2] private keys;
    address[3] private actors;
    uint256 private totalETH;
    uint256 private recipientInitialETH;

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new TaxyToken();
        bytes memory creation = abi.encodePacked(type(TaxyHook).creationCode, abi.encode(manager));
        bytes32 hash = keccak256(creation);
        for (uint256 i; i < 200_000; ++i) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != 0x20cc) continue;
            hook = new TaxyHook{salt: bytes32(i)}(manager);
            break;
        }
        require(address(hook) != address(0), "no hook salt");
        router = new SettlementRouter(manager);
        token.approve(address(router), type(uint256).max);
        vm.deal(address(this), 1_000_000 ether);
        for (uint256 p; p < 2; ++p) {
            keys[p] = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), p == 0 ? 500 : 3000, 60, hook);
            manager.initialize(keys[p], TickMath.getSqrtPriceAtTick(p == 0 ? int24(0) : int24(120)));
            router.modifyLiquidity{value: 100_000 ether}(
                keys[p], ModifyLiquidityParams(-6000, 6000, int256(BASE_LIQUIDITY), bytes32(0))
            );
        }
        for (uint256 a; a < 3; ++a) {
            actors[a] = address(uint160(0xA100 + a));
            token.transfer(actors[a], 1_000_000 ether);
            vm.deal(actors[a], 1_000_000 ether);
            vm.prank(actors[a]);
            token.approve(address(router), type(uint256).max);
        }
        handler = new TaxyLifecycleHandler(manager, token, router, keys, actors);
        totalETH = _sumETH();
        recipientInitialETH = RECIPIENT.balance;
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = TaxyLifecycleHandler.trade.selector;
        selectors[1] = TaxyLifecycleHandler.changeLiquidity.selector;
        selectors[2] = TaxyLifecycleHandler.rejectedTrade.selector;
        selectors[3] = TaxyLifecycleHandler.roundTrip.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_multiPoolLifecycleConservesFundsAndPositions() public view {
        assertEq(_sumETH(), totalETH, "ETH conservation");
        assertEq(RECIPIENT.balance, recipientInitialETH + handler.expectedFees(), "immediate cumulative fees");
        assertEq(token.balanceOf(RECIPIENT), 0, "fees must never be tokens");
        uint256 balances = token.balanceOf(address(this)) + token.balanceOf(address(manager));
        for (uint256 a; a < 3; ++a) {
            balances += token.balanceOf(actors[a]);
        }
        assertEq(balances, 1_000_000_000 ether, "token conservation");
        assertEq(token.totalSupply(), 1_000_000_000 ether, "supply immutable");
        for (uint256 p; p < 2; ++p) {
            uint256 expected = BASE_LIQUIDITY;
            for (uint256 a; a < 3; ++a) {
                uint256 held = handler.liquidity(p, a);
                (uint128 actual,,) =
                    manager.getPositionInfo(keys[p].toId(), address(router), -6000, 6000, bytes32(a + 1));
                assertEq(uint256(actual), held, "LP position differs from deposits minus withdrawals");
                expected += held;
            }
            assertEq(uint256(manager.getLiquidity(keys[p].toId())), expected, "active liquidity");
        }
        handler.assertSettled();
    }

    function afterInvariant() public {
        handler.closePositions();
        invariant_multiPoolLifecycleConservesFundsAndPositions();
        for (uint256 p; p < 2; ++p) {
            assertEq(manager.getLiquidity(keys[p].toId()), BASE_LIQUIDITY);
        }
    }

    function test_handlerExercisesEveryActionAndModeAcrossBothPools() public {
        for (uint256 p; p < 2; ++p) {
            for (uint256 a; a < 3; ++a) {
                handler.changeLiquidity(a, p, 1_000 ether, false);
                handler.trade(a, p, 1 ether, true, true);
                handler.trade(a, p, 1 ether, true, false);
                handler.trade(a, p, 1 ether, false, true);
                handler.trade(a, p, 1 ether, false, false);
                handler.rejectedTrade(a, p, true, false);
                handler.rejectedTrade(a, p, false, true);
                handler.roundTrip(a, p, 1 ether);
                handler.changeLiquidity(a, p, 1_000 ether, true);
            }
        }
        assertEq(handler.swaps(), 36);
        assertEq(handler.rejectedSwaps(), 12);
        assertEq(handler.roundTrips(), 6);
        assertEq(handler.liquidityChanges(), 12);
        afterInvariant();
    }

    function test_oneWeiRequestsAllModesSettleWithoutTokenFee() public {
        handler.trade(0, 0, 1, true, true);
        handler.trade(1, 1, 1, true, false);
        handler.trade(2, 0, 1, false, true);
        handler.trade(0, 1, 1, false, false);
        invariant_multiPoolLifecycleConservesFundsAndPositions();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeEventsAgreeWithActualNativePayment(
        uint256 rawAmount,
        bool buy,
        bool exactInput,
        bool secondPool
    ) public {
        uint256 pool = secondPool ? 1 : 0;
        uint256 amount = bound(rawAmount, 1, 10 ether);
        uint256 recipientBefore = RECIPIENT.balance;
        uint256 actorBefore = actors[0].balance;
        uint256 managerBefore = address(manager).balance;
        vm.recordLogs();
        handler.trade(0, pool, amount, buy, exactInput);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 feeEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            assertEq(logs[i].topics[0], keccak256("SwapFeePaid(bytes32,address,bool,uint256,uint256)"));
            assertEq(logs[i].topics[1], PoolId.unwrap(keys[pool].toId()));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(router)))));
            (bool direction, uint256 gross, uint256 fee) = abi.decode(logs[i].data, (bool, uint256, uint256));
            assertEq(direction, buy);
            assertEq(gross, buy ? actorBefore - actors[0].balance : managerBefore - address(manager).balance);
            assertEq(fee, RECIPIENT.balance - recipientBefore);
            ++feeEvents;
        }
        assertEq(feeEvents, 1, "one fee event per swap, including zero fees");
        invariant_multiPoolLifecycleConservesFundsAndPositions();
    }

    function test_tokenSettlementFailureRollsBackAlreadyPaidFeeAndGuard() public {
        vm.prank(actors[0]);
        token.approve(address(router), 0);
        uint256 recipientBefore = RECIPIENT.balance;
        uint256 actorETH = actors[0].balance;
        uint256 actorToken = token.balanceOf(actors[0]);
        (uint160 priceBefore,,,) = manager.getSlot0(keys[0].toId());
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, 1 ether)
        );
        vm.prank(actors[0]);
        router.swap(keys[0], SwapParams(false, -1 ether, TickMath.MAX_SQRT_PRICE - 1));
        assertEq(RECIPIENT.balance, recipientBefore);
        assertEq(actors[0].balance, actorETH);
        assertEq(token.balanceOf(actors[0]), actorToken);
        (uint160 priceAfter,,,) = manager.getSlot0(keys[0].toId());
        assertEq(priceBefore, priceAfter);
        vm.prank(actors[0]);
        token.approve(address(router), type(uint256).max);
        handler.trade(0, 0, 1 ether, false, true);
        invariant_multiPoolLifecycleConservesFundsAndPositions();
    }

    function _sumETH() private view returns (uint256 total) {
        total = address(this).balance + address(manager).balance + RECIPIENT.balance;
        for (uint256 a; a < 3; ++a) {
            total += actors[a].balance;
        }
    }

    receive() external payable {}
}
