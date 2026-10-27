// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PaperclashToken} from "../src/PaperclashToken.sol";

/// @notice Deploys the token so that the whole supply lands on a contract, as it does on the factory.
contract InvariantDeployer {
    function deployToken() external returns (PaperclashToken) {
        return new PaperclashToken();
    }

    function send(PaperclashToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice Drives the token with bounded random calls from a fixed set of actors and keeps a model
/// (ghost balances, allowances and nonces) of what each call should have done. Calls that should
/// fail are made too, and must leave every piece of state untouched.
contract PaperclashHandler is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    PaperclashToken public immutable token;

    address[] public actors;
    uint256[] internal keys;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => uint256) public ghostNonce;

    uint256 public ghostSuccessfulMoves;
    uint256 public ghostExpectedReverts;
    uint256 public ghostUnexpectedOutcomes;

    constructor(PaperclashToken token_, address[] memory actors_, uint256[] memory keys_) {
        token = token_;
        actors = actors_;
        keys = keys_;
        for (uint256 i; i < actors_.length; ++i) {
            ghostBalance[actors_[i]] = token_.balanceOf(actors_[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _bad() internal {
        ghostUnexpectedOutcomes++;
    }

    // ---------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        // Mostly in range, sometimes just over the balance.
        amount = bound(amount, 0, held + 1);

        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok || amount > held) return _bad();
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            ghostSuccessfulMoves++;
        } catch {
            if (amount <= held) return _bad();
            ghostExpectedReverts++;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 value) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Exercise the infinite-allowance path often enough to matter.
        if (value % 5 == 0) value = type(uint256).max;
        else value = bound(value, 0, token.totalSupply());

        vm.prank(owner);
        try token.approve(spender, value) returns (bool ok) {
            if (!ok) return _bad();
            ghostAllowance[owner][spender] = value;
        } catch {
            _bad();
        }
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        uint256 allowed = ghostAllowance[from][spender];
        uint256 limit = held < allowed ? held : allowed;
        amount = bound(amount, 0, limit == type(uint256).max ? limit : limit + 1);
        bool shouldPass = amount <= held && amount <= allowed;

        vm.prank(spender);
        try token.transferFrom(from, to, amount) returns (bool ok) {
            if (!ok || !shouldPass) return _bad();
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
            ghostSuccessfulMoves++;
        } catch {
            if (shouldPass) return _bad();
            ghostExpectedReverts++;
        }
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint256 deadlineOffset, bool stale)
        external
    {
        uint256 idx = ownerSeed % actors.length;
        if (keys[idx] == 0) return; // the deployer contract cannot sign
        address owner = actors[idx];
        address spender = _actor(spenderSeed);
        value = bound(value, 0, type(uint256).max);
        uint256 deadline = block.timestamp + bound(deadlineOffset, 0, 365 days);
        uint256 nonce = ghostNonce[owner];
        // A stale permit replays an old nonce and must be refused.
        if (stale && nonce > 0) nonce -= 1;
        else stale = false;

        bytes memory sig = _sign(keys[idx], owner, spender, value, nonce, deadline);

        try token.permit(owner, spender, value, deadline, uint8(sig[64]), _word(sig, 0), _word(sig, 32)) {
            if (stale) return _bad();
            ghostAllowance[owner][spender] = value;
            ghostNonce[owner]++;
        } catch {
            if (!stale) return _bad();
            ghostExpectedReverts++;
        }
    }

    function _sign(uint256 key, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _word(bytes memory data, uint256 offset) internal pure returns (bytes32 w) {
        assembly ("memory-safe") {
            w := mload(add(add(data, 32), offset))
        }
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 30 days));
    }
}

contract PaperclashInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    PaperclashToken internal token;
    InvariantDeployer internal deployer;
    PaperclashHandler internal handler;

    address[] internal actors;
    uint256[] internal keys;

    function setUp() public {
        deployer = new InvariantDeployer();
        token = deployer.deployToken();

        // The deployer (holding the supply) is an actor too, so the supply flows out of it at random.
        actors.push(address(deployer));
        keys.push(0);
        string[5] memory names = ["alice", "bob", "carol", "dave", "erin"];
        for (uint256 i; i < names.length; ++i) {
            (address a, uint256 k) = makeAddrAndKey(names[i]);
            actors.push(a);
            keys.push(k);
        }
        // Spread some of the supply so that early sequences already move value between holders.
        for (uint256 i = 1; i < actors.length; ++i) {
            deployer.send(token, actors[i], SUPPLY / 10);
        }

        handler = new PaperclashHandler(token, actors, keys);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = PaperclashHandler.transfer.selector;
        selectors[1] = PaperclashHandler.approve.selector;
        selectors[2] = PaperclashHandler.transferFrom.selector;
        selectors[3] = PaperclashHandler.permit.selector;
        selectors[4] = PaperclashHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_holdersAccountForTheWholeSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "value was created or destroyed between holders");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesMatchModel() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.ghostBalance(actors[i]), "balance diverged from model");
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesAndNoncesMatchModel() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.nonces(actors[i]), handler.ghostNonce(actors[i]), "nonce diverged from model");
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.ghostAllowance(actors[i], actors[j]),
                    "allowance diverged from model"
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_everyCallBehavedAsSpecified() public view {
        assertEq(handler.ghostUnexpectedOutcomes(), 0, "a call succeeded that should fail, or failed that should pass");
    }

    /// @dev Guards against a vacuous run: value must actually have moved during the sequence.
    function afterInvariant() public view {
        assertGt(handler.ghostSuccessfulMoves(), 0, "no transfer succeeded in this run");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_tokenContractHoldsNothingUnsent() public view {
        // Nobody in the model ever sends to the token itself, so nothing may appear there.
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }
}
