// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

/// Deployment skeleton — no deployment logic yet.
/// Will eventually: mine a CuratedLiquidityHook address via HookMiner, deploy the hook,
/// deploy CuratedLiquidityVault, and initialize the pool via PoolManager.
contract Deploy is Script {
    function run() external {}
}
