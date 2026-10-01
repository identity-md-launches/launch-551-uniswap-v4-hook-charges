// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TaxyHook} from "../src/TaxyHook.sol";
import {TaxyToken} from "../src/TaxyToken.sol";
import {SettlementRouter} from "./helpers/SettlementRouter.sol";

/// @dev A claim owner approves this test router, then redeems their own claims for native ETH.
contract NativeClaimRedeemer is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function redeem(uint256 amount) external {
        manager.unlock(abi.encode(msg.sender, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (address owner, uint256 amount) = abi.decode(data, (address, uint256));
        manager.burn(owner, 0, amount);
        manager.take(Currency.wrap(address(0)), owner, amount);
        return "";
    }
}

contract TaxyHookShortfallTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant RECIPIENT = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    uint160 internal constant ONE = 79228162514264337593543950336;
    IPoolManager internal manager;
    TaxyHook internal hook;
    TaxyToken internal token;
    SettlementRouter internal router;
    PoolKey internal key;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new TaxyToken();
        hook = _deployHook();
        router = new SettlementRouter(manager);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        manager.initialize(key, ONE);
        token.approve(address(router), type(uint256).max);
        // An entirely below-price position holds only t4, as in a token-only launch.
        BalanceDelta delta = router.modifyLiquidity(key, ModifyLiquidityParams(-600, -60, 1_000_000 ether, bytes32(0)));
        assertEq(delta.amount0(), 0);
        assertEq(address(manager).balance, 0);
        vm.deal(address(this), 1000 ether);
    }

    function test_exactInputBuyAtZeroETHMintsNativeClaim() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit TaxyHook.SwapFeeClaimMinted(key.toId(), 0.04 ether);
        _buyAndCheckClaim(-1 ether);
    }

    function test_exactOutputBuyAtZeroETHMintsNativeClaim() public {
        _buyAndCheckClaim(1 ether);
    }

    function testFuzz_buysAtZeroETHConserveFundsAndChargeFourPercent(uint96 rawAmount, bool exactInput) public {
        uint256 amount = bound(uint256(rawAmount), 1e14, 100 ether);
        _buyAndCheckClaim(exactInput ? -int256(amount) : int256(amount));
    }

    function test_managerOneWeiShortMintsTheWholeFee() public {
        vm.deal(address(manager), 0.04 ether - 1);
        _buyAndCheckClaim(-1 ether);
    }

    function test_managerHoldingExactlyTheFeePaysETH() public {
        vm.deal(address(manager), 0.04 ether);
        uint256 recipientETH = RECIPIENT.balance;
        BalanceDelta delta = router.swap{value: 1 ether}(key, _buy(-1 ether));
        assertEq(delta.amount0(), -1 ether);
        assertEq(RECIPIENT.balance - recipientETH, 0.04 ether);
        assertEq(manager.balanceOf(RECIPIENT, 0), 0);
        assertEq(address(manager).balance, 1 ether);
        _assertSettled();
    }

    function test_recipientRedeemsClaimForETHWithAuthorizedRouter() public {
        _buyAndCheckClaim(-1 ether);
        NativeClaimRedeemer redeemer = new NativeClaimRedeemer(manager);
        uint256 fee = manager.balanceOf(RECIPIENT, 0);
        uint256 recipientETH = RECIPIENT.balance;
        uint256 managerETH = address(manager).balance;
        vm.prank(RECIPIENT);
        manager.approve(address(redeemer), 0, fee);
        vm.prank(RECIPIENT);
        redeemer.redeem(fee);
        assertEq(RECIPIENT.balance - recipientETH, fee);
        assertEq(managerETH - address(manager).balance, fee);
        assertEq(manager.balanceOf(RECIPIENT, 0), 0);
        assertEq(manager.allowance(RECIPIENT, address(redeemer), 0), 0);
        assertEq(manager.currencyDelta(address(redeemer), key.currency0), 0);
        assertEq(address(redeemer).balance, 0);
        _assertSettled();
    }

    function test_unapprovedRedeemerCannotBurnRecipientClaims() public {
        _buyAndCheckClaim(-1 ether);
        NativeClaimRedeemer redeemer = new NativeClaimRedeemer(manager);
        uint256 recipientETH = RECIPIENT.balance;
        uint256 managerETH = address(manager).balance;
        vm.prank(RECIPIENT);
        vm.expectRevert();
        redeemer.redeem(0.04 ether);
        assertEq(RECIPIENT.balance, recipientETH);
        assertEq(address(manager).balance, managerETH);
        assertEq(manager.balanceOf(RECIPIENT, 0), 0.04 ether);
        assertEq(manager.currencyDelta(address(redeemer), key.currency0), 0);
        _assertSettled();
    }

    function test_insufficientBuyerFundingRollsBackClaimAndSwap() public {
        uint256 buyerETH = address(this).balance;
        uint256 buyerToken = token.balanceOf(address(this));
        uint256 recipientETH = RECIPIENT.balance;
        vm.expectRevert();
        router.swap{value: 0.5 ether}(key, _buy(-1 ether));
        _assertFailedBuyUnchanged(buyerETH, buyerToken, recipientETH);
        _buyAndCheckClaim(-1 ether);
    }

    function test_slippageFailureRollsBackClaimAndSwap() public {
        uint256 buyerETH = address(this).balance;
        uint256 buyerToken = token.balanceOf(address(this));
        uint256 recipientETH = RECIPIENT.balance;
        vm.expectRevert("maximum input");
        router.swapWithLimits{value: 1 ether}(key, _buy(-1 ether), 0, 0.99 ether);
        _assertFailedBuyUnchanged(buyerETH, buyerToken, recipientETH);
        _buyAndCheckClaim(-1 ether);
    }

    function test_subsequentBuyPaysETHAndPreservesPriorClaim() public {
        _buyAndCheckClaim(-1 ether);
        uint256 recipientETH = RECIPIENT.balance;
        uint256 managerETH = address(manager).balance;
        router.swap{value: 1 ether}(key, _buy(-1 ether));
        assertEq(RECIPIENT.balance - recipientETH, 0.04 ether);
        assertEq(address(manager).balance - managerETH, 0.96 ether);
        assertEq(manager.balanceOf(RECIPIENT, 0), 0.04 ether);
        _assertSettled();
    }

    function _buyAndCheckClaim(int256 amount) internal {
        uint256 buyerETH = address(this).balance;
        uint256 recipientETH = RECIPIENT.balance;
        uint256 managerETH = address(manager).balance;
        uint256 buyerToken = token.balanceOf(address(this));
        uint256 managerToken = token.balanceOf(address(manager));
        BalanceDelta delta = router.swap{value: 200 ether}(key, _buy(amount));
        uint256 paid = uint256(-int256(delta.amount0()));
        uint256 fee = paid / 25;
        assertGt(fee, managerETH, "fixture exercises a real native balance shortfall");
        assertEq(buyerETH - address(this).balance, paid);
        assertEq(address(manager).balance - managerETH, paid, "claim ETH remains backing in the manager");
        assertEq(manager.balanceOf(RECIPIENT, 0), fee);
        assertEq(RECIPIENT.balance, recipientETH);
        assertEq(
            buyerETH + managerETH + recipientETH, address(this).balance + address(manager).balance + RECIPIENT.balance
        );
        // A native claim is a liability against manager ETH, not additional ETH in conservation.
        assertEq(address(manager).balance - managerETH - manager.balanceOf(RECIPIENT, 0), paid - fee);
        assertEq(token.balanceOf(address(this)) - buyerToken, uint256(int256(delta.amount1())));
        assertEq(buyerToken + managerToken, token.balanceOf(address(this)) + token.balanceOf(address(manager)));
        if (amount < 0) assertEq(int256(delta.amount0()), amount);
        else assertEq(int256(delta.amount1()), amount);
        _assertSettled();
    }

    function _assertFailedBuyUnchanged(uint256 buyerETH, uint256 buyerToken, uint256 recipientETH) internal view {
        assertEq(address(this).balance, buyerETH);
        assertEq(token.balanceOf(address(this)), buyerToken);
        assertEq(token.balanceOf(address(manager)), token.totalSupply() - buyerToken);
        assertEq(RECIPIENT.balance, recipientETH);
        assertEq(address(manager).balance, 0);
        assertEq(manager.balanceOf(RECIPIENT, 0), 0);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, ONE);
        _assertSettled();
    }

    function _assertSettled() internal view {
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    function _buy(int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(true, amount, TickMath.MIN_SQRT_PRICE + 1);
    }

    function _deployHook() internal returns (TaxyHook) {
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
            require(deployed != address(0), "hook CREATE2 failed");
            return TaxyHook(deployed);
        }
        revert("no salt found");
    }

    receive() external payable {}
}
