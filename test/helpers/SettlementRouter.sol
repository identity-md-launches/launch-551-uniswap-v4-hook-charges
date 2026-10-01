// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test router: performs real PoolManager accounting and settles every debt before unlock ends.
contract SettlementRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    struct CallbackData {
        address payer;
        bool isSwap;
        PoolKey key;
        SwapParams swapParams;
        ModifyLiquidityParams liquidityParams;
        uint256 minOutput;
        uint256 maxInput;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external payable returns (BalanceDelta) {
        return _swap(key, params, 0, type(uint256).max);
    }

    function swapWithLimits(PoolKey memory key, SwapParams memory params, uint256 minOutput, uint256 maxInput)
        external
        payable
        returns (BalanceDelta)
    {
        return _swap(key, params, minOutput, maxInput);
    }

    function _swap(PoolKey memory key, SwapParams memory params, uint256 minOutput, uint256 maxInput)
        internal
        returns (BalanceDelta delta)
    {
        CallbackData memory data;
        data.payer = msg.sender;
        data.isSwap = true;
        data.key = key;
        data.swapParams = params;
        data.minOutput = minOutput;
        data.maxInput = maxInput;
        delta = abi.decode(manager.unlock(abi.encode(data)), (BalanceDelta));
        _refund();
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        payable
        returns (BalanceDelta delta)
    {
        CallbackData memory data;
        data.payer = msg.sender;
        data.key = key;
        data.liquidityParams = params;
        delta = abi.decode(manager.unlock(abi.encode(data)), (BalanceDelta));
        _refund();
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;
        if (data.isSwap) {
            delta = manager.swap(data.key, data.swapParams, "");
            int128 input = data.swapParams.zeroForOne ? delta.amount0() : delta.amount1();
            int128 output = data.swapParams.zeroForOne ? delta.amount1() : delta.amount0();
            require(input <= 0 && output >= 0, "invalid swap signs");
            require(uint256(-int256(input)) <= data.maxInput, "maximum input");
            require(uint256(int256(output)) >= data.minOutput, "minimum output");
        } else {
            (delta,) = manager.modifyLiquidity(data.key, data.liquidityParams, "");
        }
        _settle(data.key.currency0, data.payer, delta.amount0());
        _settle(data.key.currency1, data.payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, int128 delta) private {
        if (delta > 0) {
            manager.take(currency, payer, uint256(int256(delta)));
        } else if (delta < 0) {
            uint256 debt = uint256(-int256(delta));
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: debt}();
            } else {
                require(
                    IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), debt), "transfer failed"
                );
                manager.settle();
            }
        }
    }

    function _refund() private {
        uint256 remaining = address(this).balance;
        if (remaining != 0) {
            (bool ok,) = msg.sender.call{value: remaining}("");
            require(ok, "refund failed");
        }
    }

    receive() external payable {}
}
