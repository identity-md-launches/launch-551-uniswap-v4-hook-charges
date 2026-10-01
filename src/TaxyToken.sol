// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The immutable, fixed-supply token paired with the Taxy swap hook.
/// @dev The deploying launch factory receives the entire supply. Swap fees live in the hook.
contract TaxyToken is ERC20 {
    constructor() ERC20("taxy", "t4") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
