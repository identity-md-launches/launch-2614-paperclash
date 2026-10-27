// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {PaperclashToken} from "../src/PaperclashToken.sol";

contract EdgeDeployer {
    function deployToken() external returns (PaperclashToken) {
        return new PaperclashToken();
    }

    function send(PaperclashToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice Edge inputs the main suite does not pin: self-transfers, the whole supply, zero
/// addresses on every path, allowance overwrites, and the permit domain and signature checks.
contract PaperclashTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    EdgeDeployer internal deployer;
    PaperclashToken internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal signer;
    uint256 internal signerKey;

    function setUp() public {
        deployer = new EdgeDeployer();
        token = deployer.deployToken();
        (signer, signerKey) = makeAddrAndKey("signer");
    }

    function _digest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    // ---------------------------------------------------------------------------------------------
    // Supply edges
    // ---------------------------------------------------------------------------------------------

    function test_wholeSupplyCanMoveInOneTransfer() public {
        assertTrue(deployer.send(token, alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(deployer)), 0);
        vm.prank(address(deployer));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(deployer), 0, 1));
        token.transfer(alice, 1);
    }

    function test_oneWeiOverTheSupplyReverts() public {
        vm.prank(address(deployer));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(deployer), SUPPLY, SUPPLY + 1
            )
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_maxUintTransferReverts() public {
        vm.prank(address(deployer));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(deployer), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_eachDeploymentIsIndependent() public {
        PaperclashToken second = deployer.deployToken();
        assertTrue(address(second) != address(token));
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(address(deployer)), SUPPLY);
        assertTrue(second.DOMAIN_SEPARATOR() != token.DOMAIN_SEPARATOR(), "permits would replay across deployments");
    }

    // ---------------------------------------------------------------------------------------------
    // Self-transfers and odd recipients
    // ---------------------------------------------------------------------------------------------

    function testFuzz_selfTransferIsANoOp(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        deployer.send(token, alice, held);
        vm.prank(alice);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferAboveBalanceStillReverts() public {
        deployer.send(token, alice, 5);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5, 6));
        token.transfer(alice, 6);
    }

    function test_selfTransferFromSpendsOwnAllowance() public {
        deployer.send(token, alice, 10e18);
        // Pulling from yourself is not special: it needs an allowance like anyone else.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(alice, alice, 1);

        vm.startPrank(alice);
        token.approve(alice, 4e18);
        assertTrue(token.transferFrom(alice, alice, 3e18));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.allowance(alice, alice), 1e18);
    }

    function test_transferToTokenContractIsAcceptedAndStuck() public {
        // Plain ERC-20 behaviour: the token does not refuse itself as a recipient, and has no way to
        // return what it receives. Recorded so a change to this is a conscious one.
        deployer.send(token, address(token), 1e18);
        assertEq(token.balanceOf(address(token)), 1e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromToZeroAddressReverts() public {
        deployer.send(token, alice, 10e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 1e18);
        assertEq(token.allowance(alice, bob), 10e18, "a failed pull spent the allowance");
        assertEq(token.balanceOf(alice), 10e18);
    }

    function test_transferFromZeroAddressReverts() public {
        // Zero amount passes the allowance check; writing back the allowance refuses the zero owner.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), bob, 0);
        // A non-zero pull from the zero address fails on the allowance it cannot have.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(address(0), bob, 1);
    }

    function test_zeroAmountTransferFromNeedsNoAllowance() public {
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_zeroTransferToZeroAddressStillReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------------

    function testFuzz_approveOverwritesRatherThanAdds(uint256 first, uint256 second) public {
        vm.startPrank(alice);
        token.approve(bob, first);
        token.approve(bob, second);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), second);
    }

    function test_approveToZeroRevokes() public {
        deployer.send(token, alice, 10e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(alice);
        token.approve(bob, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_allowanceSpentExactlyToZero() public {
        deployer.send(token, alice, 10e18);
        vm.prank(alice);
        token.approve(bob, 7e18);
        vm.prank(bob);
        token.transferFrom(alice, bob, 7e18);
        assertEq(token.allowance(alice, bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_allowanceIsPerSpender() public {
        deployer.send(token, alice, 10e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        address carol = makeAddr("carol");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    function test_maxAllowanceStillBoundedByBalance() public {
        deployer.send(token, alice, 3e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 3e18, 4e18));
        token.transferFrom(alice, bob, 4e18);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Permit domain and signature checks
    // ---------------------------------------------------------------------------------------------

    function test_domainSeparatorIsTheStandardOne() public view {
        bytes32 expected = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Paperclash"), keccak256("1"), block.chainid, address(token))
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);

        (, string memory name, string memory version, uint256 chainId, address verifying,,) = token.eip712Domain();
        assertEq(name, "Paperclash");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(token));
    }

    function test_domainSeparatorFollowsChainId() public {
        bytes32 before = token.DOMAIN_SEPARATOR();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, bob, 1e18, 0, deadline));

        vm.chainId(block.chainid + 1);
        assertTrue(token.DOMAIN_SEPARATOR() != before, "domain separator ignores a chain fork");
        // A permit signed for the old chain does not verify on the new one.
        vm.expectRevert();
        token.permit(signer, bob, 1e18, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 0);
        assertEq(token.nonces(signer), 0);
    }

    function test_permitAtExactDeadlineSucceeds() public {
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, bob, 5e18, 0, deadline));
        token.permit(signer, bob, 5e18, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 5e18);
    }

    function test_permitOneSecondPastDeadlineReverts() public {
        uint256 deadline = block.timestamp + 10;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, bob, 5e18, 0, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, bob, 5e18, deadline, v, r, s);
    }

    function test_permitRejectsHighSMalleatedSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, bob, 1e18, 0, deadline));
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(signer, bob, 1e18, deadline, flippedV, r, highS);
        // The original still works once.
        token.permit(signer, bob, 1e18, deadline, v, r, s);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitRejectsInvalidV() public {
        uint256 deadline = block.timestamp + 1 hours;
        (, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, bob, 1e18, 0, deadline));
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(signer, bob, 1e18, deadline, 29, r, s);
    }

    function test_permitWithTamperedValueReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, bob, 1e18, 0, deadline));
        vm.expectRevert();
        token.permit(signer, bob, 1000e18, deadline, v, r, s);
        vm.expectRevert();
        token.permit(signer, alice, 1e18, deadline, v, r, s);
        vm.expectRevert();
        token.permit(signer, bob, 1e18, deadline + 1, v, r, s);
        assertEq(token.nonces(signer), 0);
        assertEq(token.allowance(signer, bob), 0);
    }

    function test_permitForFutureNonceReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, bob, 1e18, 1, deadline));
        vm.expectRevert();
        token.permit(signer, bob, 1e18, deadline, v, r, s);
    }

    function test_permitToZeroSpenderReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, address(0), 1e18, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(signer, address(0), 1e18, deadline, v, r, s);
        assertEq(token.nonces(signer), 0, "a refused permit consumed the nonce");
    }

    function test_permitForZeroOwnerCannotBeForged() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(address(0), bob, 1e18, deadline, 27, bytes32(0), bytes32(0));
        assertEq(token.allowance(address(0), bob), 0);
    }

    function test_permitsMustBeUsedInNonceOrder() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v0, bytes32 r0, bytes32 s0) = vm.sign(signerKey, _digest(signer, bob, 1e18, 0, deadline));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(signerKey, _digest(signer, bob, 2e18, 1, deadline));
        vm.expectRevert();
        token.permit(signer, bob, 2e18, deadline, v1, r1, s1);
        token.permit(signer, bob, 1e18, deadline, v0, r0, s0);
        token.permit(signer, bob, 2e18, deadline, v1, r1, s1);
        assertEq(token.allowance(signer, bob), 2e18);
        assertEq(token.nonces(signer), 2);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_permitSetsExactValue(uint256 value, uint256 deadlineOffset) public {
        uint256 deadline = block.timestamp + bound(deadlineOffset, 0, 10 * 365 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, bob, value, 0, deadline));
        token.permit(signer, bob, value, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), value);
        assertEq(token.nonces(signer), 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_permitFromAnyOtherKeyReverts(uint256 otherKey) public {
        otherKey = bound(otherKey, 1, SECP256K1_N - 1);
        address other = vm.addr(otherKey);
        if (other == signer) return;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, _digest(signer, bob, 1e18, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, other, signer));
        token.permit(signer, bob, 1e18, deadline, v, r, s);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: failed calls change nothing
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_failedTransferFromLeavesStateUntouched(uint256 held, uint256 allowed, uint256 pulled) public {
        held = bound(held, 0, SUPPLY);
        allowed = bound(allowed, 0, SUPPLY);
        uint256 limit = held < allowed ? held : allowed;
        pulled = bound(pulled, limit + 1, type(uint256).max);
        deployer.send(token, alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);

        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, bob, pulled);

        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, bob), allowed);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
