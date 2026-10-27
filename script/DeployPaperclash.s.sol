// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PaperclashToken} from "../src/PaperclashToken.sol";

/// @title DeployPaperclash
/// @notice Reviewable deployment entry point. The IMD launch deploys the token from its bytecode
/// through the factory; this script exists for local dry runs and for anyone who wants to deploy
/// the same contract themselves. It takes no configuration: the token has no constructor arguments.
contract DeployPaperclash is Script {
    /// @notice Deploys the token. Whoever calls this (the broadcaster) receives the whole supply.
    /// @dev Pure deployment logic, separated from `run()` so tests can call it directly without
    /// touching the environment.
    function deploy() public returns (PaperclashToken token) {
        token = new PaperclashToken();
    }

    /// @notice Broadcast entry point: `forge script script/DeployPaperclash.s.sol --broadcast ...`.
    function run() external returns (PaperclashToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
