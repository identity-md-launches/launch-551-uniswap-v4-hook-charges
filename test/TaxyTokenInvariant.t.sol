// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TaxyToken} from "src/TaxyToken.sol";

/// @dev The four actors form a closed balance domain. Ghost values are seeded from
/// the fixed supply and changed only by requested operations, never token getters.
contract TaxyTokenSequenceHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    TaxyToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor() {
        token = new TaxyToken();
        for (uint256 i; i < actors.length; ++i) {
            address actor = address(uint160(0x1001 + i));
            actors[i] = actor;
            expectedBalance[actor] = SUPPLY / actors.length;
            token.transfer(actor, SUPPLY / actors.length);
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool fullBalance) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = fullBalance ? expectedBalance[from] : bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, uint8 mode) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount;
        if (mode % 3 == 0) amount = 0;
        else if (mode % 3 == 1) amount = type(uint256).max;
        else amount = bound(amountSeed, 0, SUPPLY);
        _approve(owner, spender, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed, bool fullAmount)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        uint256 amount = fullAmount ? available : bound(amountSeed, 0, available);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function rejectOverspend(uint256 fromSeed, uint256 toSeed, uint256 excessSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = expectedBalance[from];
        uint256 amount = balance + bound(excessSeed, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(to, amount);
        // No ghost writes: all observed balances must remain identical after failure.
    }

    function rejectInsufficientAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        if (allowed == type(uint256).max) {
            _approve(owner, spender, 0);
            allowed = 0;
        }
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, allowed + 1)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, allowed + 1);
    }

    function rejectDelegatedOverspend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 balance = expectedBalance[owner];
        uint256 amount = balance + 1;
        _approve(owner, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        // The failed transfer must also roll back the allowance consumed internally.
    }

    function rejectZeroReceiver(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[owner]);
        _approve(owner, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
    }

    function rejectSupplyOrAdminChanges(uint256 actorSeed, uint8 selectorSeed) external {
        address actor = _actor(actorSeed);
        uint256 selectorIndex = selectorSeed % 6;
        bytes memory data;
        if (selectorIndex == 0) data = abi.encodeWithSignature("mint(address,uint256)", actor, SUPPLY);
        else if (selectorIndex == 1) data = abi.encodeWithSignature("burn(uint256)", 1);
        else if (selectorIndex == 2) data = abi.encodeWithSignature("setMinter(address)", actor);
        else if (selectorIndex == 3) data = abi.encodeWithSignature("transferOwnership(address)", actor);
        else if (selectorIndex == 4) data = abi.encodeWithSignature("upgradeTo(address)", actor);
        else data = abi.encodeWithSignature("initialize(address)", actor);
        vm.prank(actor);
        (bool success,) = address(token).call(data);
        assertFalse(success, "an immutable token exposed an administrative entry point");
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TaxyTokenInvariantTest is StdInvariant, Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    TaxyTokenSequenceHandler internal handler;
    TaxyToken internal token;

    function setUp() public {
        handler = new TaxyTokenSequenceHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectOverspend.selector;
        selectors[4] = handler.rejectInsufficientAllowance.selector;
        selectors[5] = handler.rejectDelegatedOverspend.selector;
        selectors[6] = handler.rejectZeroReceiver.selector;
        selectors[7] = handler.rejectSupplyOrAdminChanges.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Fixed supply and exact ERC20 balance conservation must survive failures as well as transfers.
    function invariant_balancesMatchIndependentLedgerAndConserveFixedSupply() public view {
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "balance diverged from transfer ledger");
            total += balance;
        }
        assertEq(total, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    /// @dev Approval replacement/revocation and finite spending follow the ERC20 allowance ledger.
    function invariant_allowancesMatchIndependentLedger() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }

    function invariant_metadataCannotChange() public view {
        assertEq(token.name(), "taxy");
        assertEq(token.symbol(), "t4");
        assertEq(token.decimals(), 18);
    }

    /// @dev A pinned sequence reaches every handler and exercises nonzero delegated spending.
    function test_seededSequenceExercisesSuccessFailureAndAllowanceRevocation() public {
        handler.transfer(0, 1, 1, false);
        handler.approve(1, 2, 100, 2);
        handler.transferFrom(1, 2, 3, 40, false);
        handler.rejectOverspend(1, 3, 1);
        handler.rejectInsufficientAllowance(1, 2, 3);
        handler.rejectDelegatedOverspend(1, 2, 3);
        handler.rejectZeroReceiver(1, 2, 10);
        handler.approve(1, 2, 0, 1);
        handler.transferFrom(1, 2, 3, 1, false);
        handler.approve(1, 2, 0, 0);
        handler.rejectInsufficientAllowance(1, 2, 3);
        handler.rejectSupplyOrAdminChanges(0, 0);
        handler.transfer(3, 3, 0, true);
        handler.transfer(3, 0, 0, true);
        invariant_balancesMatchIndependentLedgerAndConserveFixedSupply();
        invariant_allowancesMatchIndependentLedger();
        invariant_metadataCannotChange();
    }
}
