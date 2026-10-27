// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title Paperclash (PAPER)
/// @notice A plain, fixed-supply ERC-20. The whole supply of 1,000,000,000 PAPER (18 decimals) is
/// minted once, in the constructor, to the deployer. Nothing can mint afterwards, nothing taxes or
/// blocks a transfer, and the contract has no owner or privileged role of any kind.
/// @dev The deployer is the launch factory, which distributes the supply (swarm share, pool seed and
/// the requester's remainder) according to the launch manifest. The contract does not need to know
/// any of those addresses: ordinary ERC-20 transfers move every flow exactly.
///
/// ERC-2612 `permit` is included so holders can grant allowances by signature (gasless approvals);
/// it adds no admin surface. Project: x.com/paperclash_xyz
contract PaperclashToken is ERC20, ERC20Permit {
    /// @notice Human-readable token name.
    string public constant TOKEN_NAME = "Paperclash";

    /// @notice Ticker symbol.
    string public constant TOKEN_SYMBOL = "PAPER";

    /// @notice The fixed supply in minor units: 1,000,000,000 * 10^18.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice Mints the entire fixed supply to `msg.sender` (the deployer).
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
