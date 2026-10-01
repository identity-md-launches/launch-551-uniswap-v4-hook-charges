// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SettlementRouter} from "./SettlementRouter.sol";

/// @dev Bounded stateful actor that checks each transition while the suite checks conservation.
contract SwapHandler {
    address private constant RECIPIENT = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    IPoolManager private immutable manager;
    SettlementRouter private immutable router;
    PoolKey private key;
    uint256 public expectedFees;
    uint256 public swaps;

    constructor(IPoolManager manager_, SettlementRouter router_, PoolKey memory key_, IERC20 token) {
        manager = manager_;
        router = router_;
        key = key_;
        token.approve(address(router_), type(uint256).max);
    }

    function swap(uint256 seed, bool zeroForOne, bool exactInput) external {
        uint256 amount = 1 gwei + seed % (1 ether - 1 gwei + 1);
        uint256 managerBefore = address(manager).balance;
        uint256 recipientBefore = RECIPIENT.balance;
        BalanceDelta delta = router.swap{value: zeroForOne ? 100 ether : 0}(
            key,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        uint256 gross = zeroForOne ? uint256(-int256(delta.amount0())) : managerBefore - address(manager).balance;
        uint256 fee = gross / 25;
        require(RECIPIENT.balance - recipientBefore == fee, "stateful fee mismatch");
        expectedFees += fee;
        ++swaps;
    }

    receive() external payable {}
}
