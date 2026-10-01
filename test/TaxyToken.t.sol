// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TaxyToken} from "../src/TaxyToken.sol";

contract TaxyTokenTest is Test {
    TaxyToken private token;
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new TaxyToken();
    }

    function test_metadataAndWholeSupplyBelongToDeployer() public view {
        assertEq(token.name(), "taxy");
        assertEq(token.symbol(), "t4");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_deployerIsNotHardcoded() public {
        vm.prank(ALICE);
        TaxyToken anotherToken = new TaxyToken();
        assertEq(anotherToken.balanceOf(ALICE), SUPPLY);
        assertEq(anotherToken.balanceOf(address(this)), 0);
    }

    function test_transferChargesNoTokenTax() public {
        assertTrue(token.transfer(ALICE, 100 ether));
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approveAndTransferFromConsumeAllowance() public {
        assertTrue(token.approve(ALICE, 100 ether));
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 40 ether));
        assertEq(token.allowance(address(this), ALICE), 60 ether);
        assertEq(token.balanceOf(BOB), 40 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 40 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_infiniteAllowanceIsPreserved() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 40 ether);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
    }

    function test_transferWithoutBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToZeroRevertsWithoutBurning() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_noMintOrAdministrativeEntryPointsForAnyCaller() public {
        bytes[] memory attempts = new bytes[](7);
        attempts[0] = abi.encodeWithSignature("mint(address,uint256)", ALICE, 1 ether);
        attempts[1] = abi.encodeWithSignature("transferOwnership(address)", ALICE);
        attempts[2] = abi.encodeWithSignature("pause()");
        attempts[3] = abi.encodeWithSignature("upgradeTo(address)", ALICE);
        attempts[4] = abi.encodeWithSignature("setFee(uint256)", 0);
        attempts[5] = abi.encodeWithSignature("initialize(address)", ALICE);
        attempts[6] = abi.encodeWithSignature("burn(uint256)", 1 ether);

        for (uint256 i; i < attempts.length; ++i) {
            (bool deployerSuccess,) = address(token).call(attempts[i]);
            assertFalse(deployerSuccess);
            vm.prank(ALICE);
            (bool strangerSuccess,) = address(token).call(attempts[i]);
            assertFalse(strangerSuccess);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testFuzz_transfersConserveSupply(uint256 firstAmount, uint256 secondAmount) public {
        firstAmount = bound(firstAmount, 0, SUPPLY);
        secondAmount = bound(secondAmount, 0, firstAmount);
        token.transfer(ALICE, firstAmount);
        vm.prank(ALICE);
        token.transfer(BOB, secondAmount);
        assertEq(token.balanceOf(address(this)), SUPPLY - firstAmount);
        assertEq(token.balanceOf(ALICE), firstAmount - secondAmount);
        assertEq(token.balanceOf(BOB), secondAmount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(ALICE) + token.balanceOf(BOB), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
