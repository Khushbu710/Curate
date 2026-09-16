// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {CuratedLiquidityVault} from "../src/CuratedLiquidityVault.sol";
import {CuratedLiquidityHook} from "../src/CuratedLiquidityHook.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {DemoSwapper} from "./DemoSwapper.sol";

/// @notice Local Anvil deployment for the Curated Liquidity Vault system (Stage 6B).
/// @dev Deploys two mock tokens, a fresh PoolManager, mines and deploys the curation hook via a
/// genuine CREATE2 salt search (HookMiner — no `deployCodeTo`/`vm.etch`/cheatcode shortcuts),
/// deploys the vault, initializes the pool, seeds demo accounts, and writes a JSON artifact.
///
/// The vault is deployed via plain CREATE (nonce-predicted), not CREATE2, deliberately: the
/// vault's own constructor embeds `poolKey.hooks` — the mined hook's address — as part of its
/// argument list. Predicting the vault's address via CREATE2 (hash of creation code + args) would
/// therefore require already knowing the mined hook address before mining it: a second circular
/// dependency, symmetric to the one Stage 6A.1 fixed on the hook side. Nonce-based prediction
/// (`vm.computeCreateAddress(deployer, nonce)`) has no such problem — it depends only on the
/// deployer's address and account nonce, never on constructor argument content — so it is used
/// for the vault, while HookMiner/CREATE2 (which genuinely needs address-bit control) is used only
/// for the hook. This differs from the test suite's fixtures, which use CREATE2 for the vault too;
/// that only works there because the tests choose the hook's address directly (via `deployCodeTo`)
/// instead of mining it, so no such circularity arises in that context.
contract Deploy is Script {
    /// @dev Canonical deterministic CREATE2 deployer proxy ("Arachnid's proxy" / keyless
    /// deployment factory), per HookMiner's own doc comment. Verified present at genesis on the
    /// local Anvil instance used for this deployment (checked via eth_getCode before running this
    /// script) and on essentially every public EVM chain, including all Uniswap v4-supported
    /// testnets, so no separate factory deployment step is required.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant INITIAL_TICK_LOWER = -600;
    int24 internal constant INITIAL_TICK_UPPER = 600;

    uint256 internal constant DEMO_MINT_AMOUNT = 1_000_000 ether;
    uint256 internal constant DEMO_DEPOSIT_AMOUNT = 100 ether;

    /// @dev Anvil's own well-known, publicly-documented default dev-mnemonic private keys
    /// ("test test test test test test test test test test test junk"), used ONLY to give the
    /// local demo distinct, real signing roles (curator/depositor/trader) beyond the deployer.
    /// These are identical on every Anvil instance in existence and protect nothing of value —
    /// never use them, or this pattern, outside a local/throwaway chain.
    uint256 internal constant CURATOR_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant DEPOSITOR_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant TRADER_KEY = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    /// @dev Groups the whole deployment's mutable state into one memory struct so it can be
    /// threaded through small internal functions by reference, instead of living as ~15
    /// simultaneous local variables in `run()` (which overflows the EVM stack under the
    /// legacy codegen this repo is pinned to — see foundry.toml, no `via_ir`).
    struct DeployState {
        address deployer;
        address curator;
        address depositor;
        address trader;
        Currency currency0;
        Currency currency1;
        PoolManager poolManager;
        CuratedLiquidityHook hook;
        CuratedLiquidityVault vault;
        DemoSwapper swapper;
        PoolKey poolKey;
        bytes32 hookSalt;
        address predictedVault;
    }

    function run() external {
        DeployState memory s;
        s.deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        s.curator = vm.addr(CURATOR_KEY);
        s.depositor = vm.addr(DEPOSITOR_KEY);
        s.trader = vm.addr(TRADER_KEY);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        _deployTokensAndManager(s);
        _mineAndDeployHook(s);
        _deployVaultAndInitializePool(s);
        _seedDemoAccounts(s);
        vm.stopBroadcast();

        vm.startBroadcast(DEPOSITOR_KEY);
        MockERC20(Currency.unwrap(s.currency0)).approve(address(s.vault), type(uint256).max);
        MockERC20(Currency.unwrap(s.currency1)).approve(address(s.vault), type(uint256).max);
        // Part 13 smoke test: deposit against the freshly deployed real stack.
        s.vault.deposit(DEMO_DEPOSIT_AMOUNT, DEMO_DEPOSIT_AMOUNT);
        vm.stopBroadcast();

        vm.startBroadcast(CURATOR_KEY);
        // Part 13 smoke test: openPosition against the freshly deployed real stack.
        s.vault.openPosition();
        vm.stopBroadcast();

        _writeArtifact(s);
        _logSummary(s);
    }

    /// 1-4. Tokens (sorted into currency0/currency1) and PoolManager.
    function _deployTokensAndManager(DeployState memory s) internal {
        MockERC20 tA = new MockERC20("Curate Token A", "CTA");
        MockERC20 tB = new MockERC20("Curate Token B", "CTB");
        (s.currency0, s.currency1) = address(tA) < address(tB)
            ? (Currency.wrap(address(tA)), Currency.wrap(address(tB)))
            : (Currency.wrap(address(tB)), Currency.wrap(address(tA)));

        s.poolManager = new PoolManager(s.deployer);
    }

    /// 5-8. Predict the vault's plain-CREATE address, mine a matching hook address via
    /// HookMiner, and deploy the hook at that mined address via real CREATE2.
    function _mineAndDeployHook(DeployState memory s) internal {
        uint64 nonceBeforeHook = vm.getNonce(s.deployer);
        address predictedVault = vm.computeCreateAddress(s.deployer, nonceBeforeHook + 1);

        bytes memory hookConstructorArgs = abi.encode(
            IPoolManager(address(s.poolManager)), predictedVault, s.currency0, s.currency1, FEE, TICK_SPACING
        );
        (address minedHookAddress, bytes32 hookSalt) = HookMiner.find(
            CREATE2_DEPLOYER,
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG),
            type(CuratedLiquidityHook).creationCode,
            hookConstructorArgs
        );

        s.hook = new CuratedLiquidityHook{salt: hookSalt}(
            IPoolManager(address(s.poolManager)), predictedVault, s.currency0, s.currency1, FEE, TICK_SPACING
        );
        require(address(s.hook) == minedHookAddress, "hook address mining mismatch");
        s.hookSalt = hookSalt;

        s.poolKey = PoolKey({
            currency0: s.currency0,
            currency1: s.currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(s.hook))
        });

        s.predictedVault = predictedVault;
    }

    /// 9-11. Deploy the vault at its predicted address, verify hook/vault agreement, initialize
    /// the pool, and deploy the demo swapper.
    function _deployVaultAndInitializePool(DeployState memory s) internal {
        s.vault = new CuratedLiquidityVault(
            IPoolManager(address(s.poolManager)), s.poolKey, s.curator, INITIAL_TICK_LOWER, INITIAL_TICK_UPPER
        );
        require(address(s.vault) == s.predictedVault, "vault address prediction mismatch");
        require(PoolId.unwrap(s.hook.poolId()) == PoolId.unwrap(s.vault.poolId()), "hook/vault poolId mismatch");

        s.poolManager.initialize(s.poolKey, TickMath.getSqrtPriceAtTick(0));

        // Demo-only swapper, reusing the exact settlement pattern already proven by
        // test/CuratedLiquidityVaultFees.t.sol's TestSwapper.
        s.swapper = new DemoSwapper(IPoolManager(address(s.poolManager)), s.poolKey, s.trader);
    }

    /// 12. Mint demo tokens to the depositor and the swapper.
    function _seedDemoAccounts(DeployState memory s) internal {
        MockERC20(Currency.unwrap(s.currency0)).mint(s.depositor, DEMO_MINT_AMOUNT);
        MockERC20(Currency.unwrap(s.currency1)).mint(s.depositor, DEMO_MINT_AMOUNT);
        MockERC20(Currency.unwrap(s.currency0)).mint(address(s.swapper), DEMO_MINT_AMOUNT);
        MockERC20(Currency.unwrap(s.currency1)).mint(address(s.swapper), DEMO_MINT_AMOUNT);
    }

    function _writeArtifact(DeployState memory s) internal {
        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "deployer", s.deployer);
        vm.serializeAddress(root, "curator", s.curator);
        vm.serializeAddress(root, "token0", Currency.unwrap(s.currency0));
        vm.serializeAddress(root, "token1", Currency.unwrap(s.currency1));
        vm.serializeAddress(root, "poolManager", address(s.poolManager));
        vm.serializeAddress(root, "hook", address(s.hook));
        vm.serializeAddress(root, "vault", address(s.vault));
        vm.serializeBytes32(root, "poolId", PoolId.unwrap(s.vault.poolId()));
        vm.serializeUint(root, "fee", FEE);
        vm.serializeInt(root, "tickSpacing", TICK_SPACING);
        vm.serializeInt(root, "initialTickLower", INITIAL_TICK_LOWER);
        vm.serializeInt(root, "initialTickUpper", INITIAL_TICK_UPPER);
        vm.serializeInt(root, "initialPriceTick", int256(0));
        string memory finalJson = vm.serializeBytes32(root, "hookSalt", s.hookSalt);

        vm.writeJson(finalJson, "deployments/anvil.json");
    }

    function _logSummary(DeployState memory s) internal pure {
        console2.log("=== Curate local Anvil deployment ===");
        console2.log("deployer", s.deployer);
        console2.log("curator", s.curator);
        console2.log("depositor", s.depositor);
        console2.log("trader", s.trader);
        console2.log("token0", Currency.unwrap(s.currency0));
        console2.log("token1", Currency.unwrap(s.currency1));
        console2.log("poolManager", address(s.poolManager));
        console2.log("hook", address(s.hook));
        console2.log("vault", address(s.vault));
        console2.log("swapper", address(s.swapper));
    }
}
