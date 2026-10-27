# Paperclash (PAPER)

A plain, fixed-supply ERC-20 token for the Paperclash project (X: x.com/paperclash_xyz), built
for an IMD custom-token launch on Ethereum mainnet.

| Parameter        | Value                                          |
| ---------------- | ---------------------------------------------- |
| Contract         | `PaperclashToken` (`src/PaperclashToken.sol`)  |
| Name             | Paperclash                                     |
| Symbol           | PAPER                                          |
| Decimals         | 18                                             |
| Total supply     | 1,000,000,000 PAPER = `1000000000000000000000000000` minor units |
| Minting          | Once, in the constructor, all to `msg.sender` (the deployer) |
| Constructor args | none                                           |
| Owner / admin    | none                                           |
| Compiler         | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` |

## What the token does

- Standard ERC-20 (OpenZeppelin v5.4.0 `ERC20`): `transfer`, `approve`, `transferFrom`,
  `allowance`, `balanceOf`, `totalSupply`, plus `name`, `symbol`, `decimals`.
- ERC-2612 `permit` (OpenZeppelin `ERC20Permit`): holders can grant an allowance by signature
  so a third party can submit the approval and pay the gas. Signatures are bound to this
  contract and chain by the EIP-712 domain, use a per-owner nonce, and carry a deadline.
- Nothing else. There is no owner, no minter, no pause, no blacklist, no tax, no burn-from,
  no upgrade path. The supply is fixed at deployment and can never grow.

Every transfer moves exactly the amount requested, so the launch flows (factory to
distributor, distributor to claimants, factory to pool, pool to traders, factory to the
requester's remainder address) all arrive whole. The token does not need to know the factory,
pool manager or distributor addresses and takes no constructor arguments.

## Assumptions

- The deployer receives the whole supply. In the IMD launch the deployer is the project
  factory, which then forwards the swarm share (10%), seeds the pool (60%) and sends the
  remainder (30%) to the requester's address, all according to the launch manifest. The
  token does nothing special for any of them; it just transfers.
- No tax, fee, reflection or burn-on-transfer was requested, and none is implemented.
- `permit` is a convenience the brief did not forbid. It grants no privilege to anyone: only
  the holder's own signature can create an allowance on their balance.
- The supply number is the brief's: 1,000,000,000 tokens with 18 decimals. The project
  constant `INITIAL_SUPPLY` holds it and `totalSupply()` returns it.

## Deployment parameters

The launch deploys `PaperclashToken` from its creation bytecode with no constructor arguments.
For the manifest step (written by IMD after acceptance, not by this repository):

- token.contract: `PaperclashToken`
- token.name: `Paperclash`
- token.symbol: `PAPER`
- token.decimals: `18`
- token.constructorArgs: `[]`
- token.totalSupply: `1000000000000000000000000000`
- contracts: none (this launch has no application contracts)
- pool / economics: the launch's values (pair IMD at
  `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, fee 12500, tick spacing 60, poolBps 6000,
  initialMarketCapWei 2500000000000000000000, remainderTo
  `0xee2aaa315cf7ed169f93148d30d24af9318dbb66`). The deployer derives the opening price.

`script/DeployPaperclash.s.sol` is a reviewable deployment entry point for local dry runs or an
independent deployment. Its `deploy()` function holds the logic and is exercised by the tests;
`run()` only wraps it in a broadcast. It reads no environment variables and takes no
configuration. Nothing in this repository signs or broadcasts anything on its own.

## After launch

There is nothing to configure. The contract has no owner-settable values, no setters and no
external dependencies. Operational responsibilities are limited to:

- Verifying the source on the block explorer after the launch (`forge verify-contract` with
  compiler 0.8.26, optimizer 200 runs, `bytecode_hash = none`, `cbor_metadata = false`).
- Communicating the contract address to holders through the project's own channels.
- Nobody can rescue tokens sent to a wrong address, including this contract's own address.
  Holders bear that responsibility as with any fixed-supply ERC-20.

## Security notes

- No `selfdestruct`, `delegatecall` or `callcode` in the runtime; a test walks the reachable
  bytecode to confirm it.
- `transferFrom` only moves tokens from an account that has approved the caller, and the
  deployer has no shortcut around that (tested).
- No privileged function exists: a test probes the common mint, owner, pause, freeze,
  blacklist, seize and burn-from selectors from both a stranger and the deployer and asserts
  every call reverts with the supply and balances unchanged.
- Tools run for this task: `forge build`, `forge test` (33 tests, including fuzz tests with
  the verifier's seed), `forge fmt --check`. Slither was not available on this machine; the
  code avoids the patterns its blocking detectors flag.
- Tests passing is not an audit. Anything that later holds value on behalf of users should
  receive an independent adversarial review.

## Layout

```
foundry.toml                  compiler pin and build settings
remappings.txt                forge-std and @openzeppelin/contracts remappings
src/PaperclashToken.sol       the token
script/DeployPaperclash.s.sol deployment script (deploy() + run())
test/PaperclashToken.t.sol    unit, failure-path and fuzz tests
lib/forge-std                 vendored forge-std v1.11.0 (plain files, no submodule)
lib/openzeppelin-contracts    vendored OpenZeppelin Contracts v5.4.0 (plain files, no submodule)
```

## Running the checks

```
forge build
forge test
forge fmt --check
```
