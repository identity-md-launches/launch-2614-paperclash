// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {PaperclashToken} from "../src/PaperclashToken.sol";
import {DeployPaperclash} from "../script/DeployPaperclash.s.sol";

/// @notice Stands in for the launch factory: the address that deploys the token and therefore
/// receives the whole supply. It is a contract, as the real factory is, so `msg.sender` in the
/// constructor is a contract address and not the test.
contract FactoryStub {
    function deployToken() external returns (PaperclashToken) {
        return new PaperclashToken();
    }

    function send(PaperclashToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract PaperclashTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 6_000;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    FactoryStub internal factory;
    PaperclashToken internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal distributor = makeAddr("distributor");
    address internal claimant = makeAddr("claimant");

    uint256 internal signerKey;
    address internal signer;

    function setUp() public {
        factory = new FactoryStub();
        token = factory.deployToken();
        (signer, signerKey) = makeAddrAndKey("signer");
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Paperclash");
        assertEq(token.symbol(), "PAPER");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Paperclash");
        assertEq(token.TOKEN_SYMBOL(), "PAPER");
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), 1e27);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_wholeSupplyMintedToDeployer() public view {
        assertEq(token.balanceOf(address(factory)), SUPPLY, "deployer does not hold the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the test harness received tokens it did not deploy");
    }

    function test_deployerIsWhoeverCallsTheConstructor() public {
        vm.prank(alice);
        PaperclashToken fresh = new PaperclashToken();
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        new PaperclashToken();
    }

    function test_deployScriptMintsToBroadcaster() public {
        DeployPaperclash deployer = new DeployPaperclash();
        PaperclashToken deployed = deployer.deploy();
        // The script contract is `msg.sender` of the constructor when `deploy()` is called directly.
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(deployer)), SUPPLY);
        assertEq(deployed.name(), "Paperclash");
        assertEq(deployed.symbol(), "PAPER");
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: success and failure
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        uint256 amount = 1_234e18;
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(factory), alice, amount);
        assertTrue(factory.send(token, alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_holderToHolderTransfer() public {
        factory.send(token, alice, 100e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 40e18));
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(bob), 40e18);
    }

    function test_zeroAmountTransferSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        factory.send(token, alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 11e18));
        token.transfer(bob, 11e18);
    }

    function test_transferToZeroAddressReverts() public {
        factory.send(token, alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1e18);
    }

    function test_transferWithNoBalanceReverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        token.transfer(alice, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------------

    function test_approveAndTransferFrom() public {
        factory.send(token, alice, 100e18);
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(alice, bob, 30e18);
        assertTrue(token.approve(bob, 30e18));
        assertEq(token.allowance(alice, bob), 30e18);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 20e18));
        assertEq(token.balanceOf(bob), 20e18);
        assertEq(token.balanceOf(alice), 80e18);
        assertEq(token.allowance(alice, bob), 10e18, "allowance not decremented");
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        factory.send(token, alice, 100e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, bob, 50e18);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        factory.send(token, alice, 100e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1e18));
        token.transferFrom(alice, bob, 1e18);
    }

    function test_transferFromRevertsAboveAllowance() public {
        factory.send(token, alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 5e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 5e18, 6e18));
        token.transferFrom(alice, bob, 6e18);
    }

    function test_transferFromRevertsAboveBalanceEvenWithAllowance() public {
        factory.send(token, alice, 10e18);
        vm.prank(alice);
        token.approve(bob, 100e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 11e18));
        token.transferFrom(alice, bob, 11e18);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    /// @dev The deployer holds the supply but has no special power: it cannot pull from a holder
    /// without an allowance like anyone else.
    function test_deployerCannotPullFromHolderWithoutAllowance() public {
        factory.send(token, alice, 10e18);
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        token.transferFrom(alice, address(factory), 1);
        assertEq(token.balanceOf(alice), 10e18);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-2612 permit
    // ---------------------------------------------------------------------------------------------

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_permitSetsAllowanceAndBumpsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(signer, bob, 77e18, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        vm.prank(alice); // anyone may submit a permit
        token.permit(signer, bob, 77e18, deadline, v, r, s);

        assertEq(token.allowance(signer, bob), 77e18);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitThenTransferFrom() public {
        factory.send(token, signer, 100e18);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(signer, bob, 60e18, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        token.permit(signer, bob, 60e18, deadline, v, r, s);

        vm.prank(bob);
        token.transferFrom(signer, bob, 60e18);
        assertEq(token.balanceOf(bob), 60e18);
        assertEq(token.balanceOf(signer), 40e18);
    }

    function test_permitRevertsWhenExpired() public {
        uint256 deadline = block.timestamp - 1;
        bytes32 digest = _permitDigest(signer, bob, 1e18, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, bob, 1e18, deadline, v, r, s);
    }

    function test_permitRevertsOnWrongSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        (address other, uint256 otherKey) = makeAddrAndKey("other");
        bytes32 digest = _permitDigest(signer, bob, 1e18, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, digest);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, other, signer));
        token.permit(signer, bob, 1e18, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 0);
    }

    function test_permitCannotBeReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(signer, bob, 1e18, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        token.permit(signer, bob, 1e18, deadline, v, r, s);
        // Second submission: the nonce moved on, so the recovered signer no longer matches.
        vm.expectRevert();
        token.permit(signer, bob, 1e18, deadline, v, r, s);
    }

    // ---------------------------------------------------------------------------------------------
    // No mint, no owner, no privileged hand
    // ---------------------------------------------------------------------------------------------

    function test_noMintOrAdminSelectorExists() public {
        address attacker = makeAddr("attacker");
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(address(factory));
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_noFreezeOrSeizeSelectorExists() public {
        factory.send(token, alice, 1_000e18);
        string[12] memory signatures = [
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "burn(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, true);
            vm.prank(address(factory));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(alice), 1_000e18, "a privileged call moved the holder's balance");
        vm.prank(alice);
        assertTrue(token.transfer(bob, 500e18), "the holder can no longer transfer");
        assertEq(token.balanceOf(bob), 500e18);
    }

    /// @dev Reachable runtime code contains no DELEGATECALL, CALLCODE or SELFDESTRUCT, which the
    /// launch floor refuses. Mirrors the floor's walk: PUSH data bytes are skipped, and bytes after
    /// a terminating opcode are data until the next JUMPDEST.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        bool reachable = true;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flows arrive whole
    // ---------------------------------------------------------------------------------------------

    function test_swarmShareArrivesWholeAndIsClaimableWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(factory.send(token, distributor, swarm));
        assertEq(token.balanceOf(distributor), swarm, "swarm share arrived short");
        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm, "claim arrived short");
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_launchSplitSumsToSupply() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;
        address poolManager = makeAddr("poolManager");
        address remainderTo = makeAddr("remainderTo");

        factory.send(token, distributor, swarm);
        factory.send(token, poolManager, pool);
        factory.send(token, remainderTo, remainder);

        assertEq(token.balanceOf(address(factory)), 0, "the factory kept something back");
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.balanceOf(remainderTo), remainder);
        assertEq(swarm + pool + remainder, token.totalSupply());
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation and exactness
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupplyAndIsExact(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(factory));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(factory.send(token, to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 attempt) public {
        held = bound(held, 0, SUPPLY - 1);
        attempt = bound(attempt, held + 1, SUPPLY);
        factory.send(token, alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, attempt));
        token.transfer(bob, attempt);
    }

    function testFuzz_transferFromWithinAllowanceIsExact(uint256 held, uint256 allowed, uint256 pulled) public {
        held = bound(held, 1, SUPPLY);
        allowed = bound(allowed, 1, held);
        pulled = bound(pulled, 1, allowed);
        factory.send(token, alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, pulled));
        assertEq(token.balanceOf(bob), pulled);
        assertEq(token.balanceOf(alice), held - pulled);
        assertEq(token.allowance(alice, bob), allowed - pulled);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_roundTripLeavesBalancesUnchanged(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        factory.send(token, alice, amount);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
