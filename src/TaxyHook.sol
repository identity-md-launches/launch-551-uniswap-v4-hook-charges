// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable 4% native-ETH swap fee for Uniswap v4 ETH/token pools.
/// @dev The gross ETH amount is the buyer's total ETH debit or the AMM's ETH output on a sale.
/// ETH-specified swaps must fully fill. Token-specified swaps charge only on executed ETH.
contract TaxyHook is IHooks {
    using SafeCast for uint256;
    IPoolManager public immutable poolManager;
    address public constant FEE_RECIPIENT = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    uint256 public constant FEE_BPS = 400;
    uint160 public constant HOOK_FLAGS = 0x20cc;
    uint256 private constant MAX_AMOUNT = (1 << 127) - 1;

    // Held through the actual ETH transfer, including receiver callbacks. Reverts roll it back.
    bool private swapping;

    error NotPoolManager();
    error InvalidPoolManager();
    error UnsupportedPool();
    error InvalidAmount();
    error PartialFillNotSupported();
    error ReentrantSwap();
    error MissingSwap();
    error CallbackNotEnabled();

    event SwapFeePaid(PoolId indexed poolId, address indexed sender, bool zeroForOne, uint256 grossETH, uint256 feeETH);

    constructor(IPoolManager manager) {
        if (address(manager).code.length == 0) revert InvalidPoolManager();
        poolManager = manager;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        _validatePool(key);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validatePool(key);
        if (swapping) revert ReentrantSwap();
        // Bounds precede negation, multiplication and signed packing.
        if (
            params.amountSpecified == 0 || params.amountSpecified > type(int128).max
                || params.amountSpecified < -int256(type(int128).max)
        ) revert InvalidAmount();
        swapping = true;

        uint256 fee = 0;
        if (_nativeSpecified(params)) {
            fee = _specifiedFee(params);
            if (params.amountSpecified > 0 && uint256(params.amountSpecified) + fee > MAX_AMOUNT) {
                revert InvalidAmount();
            }
        }
        // A positive specified delta reserves ETH for the fee; it never consumes the whole input.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (!swapping) revert MissingSwap();
        bool specified = _nativeSpecified(params);
        int256 nativeDelta = int256(delta.amount0());
        uint256 fee;
        if (specified) {
            fee = _specifiedFee(params);
            // beforeSwap's fee was fixed before execution. Revert any partial/zero fill atomically.
            if (nativeDelta != params.amountSpecified + int256(fee)) revert PartialFillNotSupported();
        } else {
            if (params.zeroForOne) {
                if (nativeDelta > 0) revert InvalidAmount();
                // Gross-up the AMM input: floor((net + floor(net / 24)) / 25) == floor(net / 24).
                fee = uint256(-nativeDelta) / 24;
            } else {
                if (nativeDelta < 0) revert InvalidAmount();
                fee = uint256(nativeDelta) / 25;
            }
        }

        uint256 gross = params.zeroForOne ? uint256(-nativeDelta) + fee : uint256(nativeDelta);
        if (gross > MAX_AMOUNT) revert InvalidAmount();

        // take creates an ETH debt for this hook. Its positive return delta cancels that exact debt.
        // The manager transfers native ETH directly; there is no accrued balance or claim step.
        emit SwapFeePaid(key.toId(), sender, params.zeroForOne, gross, fee);
        if (fee != 0) poolManager.take(Currency.wrap(address(0)), FEE_RECIPIENT, fee);
        swapping = false;
        return (IHooks.afterSwap.selector, specified ? int128(0) : fee.toInt128());
    }

    function _nativeSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _specifiedFee(SwapParams calldata params) private pure returns (uint256) {
        return params.amountSpecified < 0 ? uint256(-params.amountSpecified) / 25 : uint256(params.amountSpecified) / 24;
    }

    function _validatePool(PoolKey calldata key) private view {
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) == address(0)
                || address(key.hooks) != address(this) || key.fee >= LPFeeLibrary.DYNAMIC_FEE_FLAG
        ) revert UnsupportedPool();
    }

    // Disabled callbacks still authenticate callers and fail explicitly if invoked.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert CallbackNotEnabled();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert CallbackNotEnabled();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert CallbackNotEnabled();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }
}
