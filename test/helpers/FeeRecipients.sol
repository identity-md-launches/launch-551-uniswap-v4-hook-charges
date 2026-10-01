// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract RejectingRecipient {
    receive() external payable {
        revert("ETH rejected");
    }
}

/// @dev Configured after etching at the immutable recipient; storage never relies on a constructor.
contract ReentrantRecipient {
    IPoolManager private manager;
    PoolKey private key;
    bool public attempted;
    bool public blocked;
    bytes public revertReason;

    function configure(IPoolManager manager_, PoolKey memory key_) external {
        manager = manager_;
        key = key_;
    }

    receive() external payable {
        attempted = true;
        try manager.swap(key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "") {
            blocked = false;
        } catch (bytes memory reason) {
            blocked = true;
            revertReason = reason;
        }
    }
}
