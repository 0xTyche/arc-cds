// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { CDSFactory } from "../../contracts/core/CDSFactory.sol";
import { CDSVault } from "../../contracts/infra/CDSVault.sol";
import { MarginEngine } from "../../contracts/infra/MarginEngine.sol";
import { PremiumEngine } from "../../contracts/infra/PremiumEngine.sol";
import { SettlementEngine } from "../../contracts/infra/SettlementEngine.sol";
import { ICDSFactory } from "../../contracts/interfaces/ICDSFactory.sol";
import { MockERC20 } from "../../contracts/mocks/MockERC20.sol";
import { MockCreditOracle } from "../../contracts/mocks/MockCreditOracle.sol";
import { ZeroAddress } from "../../contracts/libraries/Errors.sol";

/// @title CDSFactoryTest
/// @notice Unit tests for CDSFactory: vault deployment, registry, access control, pause,
///         implementation update, UUPS upgrade authorization.
contract CDSFactoryTest is Test {
    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    bytes32 constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");
    bytes32 constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    CDSFactory factory;
    CDSVault vaultImpl;

    // Shared infra proxies (real UUPS instances, same as CDSVault tests).
    PremiumEngine premiumEngine;
    MarginEngine marginEngine;
    SettlementEngine settlementEngine;
    MockCreditOracle creditOracle;
    MockERC20 usdc;

    address admin = makeAddr("admin");
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address vaultAdmin = makeAddr("vaultAdmin");

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(500);

        usdc = new MockERC20();
        creditOracle = new MockCreditOracle();

        // Deploy PremiumEngine proxy.
        PremiumEngine peImpl = new PremiumEngine();
        bytes memory peInit = abi.encodeCall(PremiumEngine.initialize, (admin));
        premiumEngine = PremiumEngine(address(new ERC1967Proxy(address(peImpl), peInit)));

        // Deploy MarginEngine proxy (2% liquidation bonus).
        MarginEngine meImpl = new MarginEngine();
        bytes memory meInit = abi.encodeCall(MarginEngine.initialize, (admin, address(usdc), 200));
        marginEngine = MarginEngine(address(new ERC1967Proxy(address(meImpl), meInit)));

        // Deploy SettlementEngine proxy.
        SettlementEngine seImpl = new SettlementEngine();
        bytes memory seInit =
            abi.encodeCall(SettlementEngine.initialize, (admin, address(creditOracle), address(marginEngine)));
        settlementEngine = SettlementEngine(address(new ERC1967Proxy(address(seImpl), seInit)));

        // Deploy CDSVault implementation (logic contract only — no proxy here).
        vaultImpl = new CDSVault();

        // Deploy CDSFactory proxy.
        CDSFactory factoryImpl = new CDSFactory();
        bytes memory factoryInit = abi.encodeCall(CDSFactory.initialize, (admin, address(vaultImpl)));
        factory = CDSFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));

        // Grant DEPLOYER_ROLE to deployer account.
        vm.prank(admin);
        factory.grantRole(DEPLOYER_ROLE, deployer);
    }

    // -------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------

    function test_initialize_setsRoles() public view {
        assertTrue(factory.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(factory.hasRole(UPGRADER_ROLE, admin));
        assertTrue(factory.hasRole(PAUSER_ROLE, admin));
        assertTrue(factory.hasRole(DEPLOYER_ROLE, admin));
    }

    function test_initialize_setsImplementation() public view {
        assertEq(factory.vaultImplementation(), address(vaultImpl));
    }

    function test_initialize_vaultCountIsZero() public view {
        assertEq(factory.vaultCount(), 0);
    }

    function test_initialize_zeroAdmin_reverts() public {
        CDSFactory impl2 = new CDSFactory();
        bytes memory bad = abi.encodeCall(CDSFactory.initialize, (address(0), address(vaultImpl)));
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl2), bad);
    }

    function test_initialize_zeroImpl_reverts() public {
        CDSFactory impl2 = new CDSFactory();
        bytes memory bad = abi.encodeCall(CDSFactory.initialize, (admin, address(0)));
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl2), bad);
    }

    // -------------------------------------------------------------------------
    // deployVault
    // -------------------------------------------------------------------------

    function test_deployVault_success() public {
        vm.prank(deployer);
        (uint256 vaultId, address vault) = factory.deployVault(
            vaultAdmin,
            address(usdc),
            address(creditOracle),
            address(premiumEngine),
            address(marginEngine),
            address(settlementEngine)
        );

        assertEq(vaultId, 0);
        assertTrue(vault != address(0));
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.getVault(0), vault);
        assertTrue(factory.isKnownVault(vault));
    }

    function test_deployVault_incrementsCounter() public {
        vm.startPrank(deployer);
        (, address v0) = factory.deployVault(
            vaultAdmin, address(usdc), address(creditOracle), address(premiumEngine), address(marginEngine), address(settlementEngine)
        );
        (, address v1) = factory.deployVault(
            vaultAdmin, address(usdc), address(creditOracle), address(premiumEngine), address(marginEngine), address(settlementEngine)
        );
        (, address v2) = factory.deployVault(
            vaultAdmin, address(usdc), address(creditOracle), address(premiumEngine), address(marginEngine), address(settlementEngine)
        );
        vm.stopPrank();

        assertEq(factory.vaultCount(), 3);
        assertEq(factory.getVault(0), v0);
        assertEq(factory.getVault(1), v1);
        assertEq(factory.getVault(2), v2);
    }

    function test_deployVault_uniqueAddresses() public {
        vm.startPrank(deployer);
        (, address v0) = factory.deployVault(
            vaultAdmin, address(usdc), address(creditOracle), address(premiumEngine), address(marginEngine), address(settlementEngine)
        );
        (, address v1) = factory.deployVault(
            vaultAdmin, address(usdc), address(creditOracle), address(premiumEngine), address(marginEngine), address(settlementEngine)
        );
        vm.stopPrank();

        assertTrue(v0 != v1, "each deployment must have a unique address");
    }

    function test_deployVault_vaultHasAdminRole() public {
        bytes32 adminRole = bytes32(0);
        vm.prank(deployer);
        (, address vault) = factory.deployVault(
            vaultAdmin, address(usdc), address(creditOracle), address(premiumEngine), address(marginEngine), address(settlementEngine)
        );

        CDSVault v = CDSVault(vault);
        assertTrue(v.hasRole(adminRole, vaultAdmin), "vaultAdmin must have DEFAULT_ADMIN_ROLE on vault");
        assertTrue(v.hasRole(UPGRADER_ROLE, vaultAdmin), "vaultAdmin must have UPGRADER_ROLE on vault");
    }

    function test_deployVault_emitsEvent() public {
        vm.prank(deployer);
        vm.expectEmit(true, false, false, true);
        emit ICDSFactory.VaultDeployed(
            0,
            address(0), // vault address unknown ahead of time — use wildcard check below
            vaultAdmin,
            address(usdc),
            address(creditOracle),
            address(premiumEngine),
            address(marginEngine),
            address(settlementEngine)
        );
        // Note: `address(0)` above is a placeholder; we only check indexed vaultId=0
        // and the non-indexed fields. The actual vault address is checked via getVault().
        factory.deployVault(
            vaultAdmin, address(usdc), address(creditOracle), address(premiumEngine), address(marginEngine), address(settlementEngine)
        );
    }

    function test_deployVault_onlyDeployerRole() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.deployVault(
            vaultAdmin, address(usdc), address(creditOracle), address(premiumEngine), address(marginEngine), address(settlementEngine)
        );
    }

    function test_deployVault_zeroVaultAdmin_reverts() public {
        vm.prank(deployer);
        vm.expectRevert(ZeroAddress.selector);
        factory.deployVault(
            address(0), address(usdc), address(creditOracle), address(premiumEngine), address(marginEngine), address(settlementEngine)
        );
    }

    function test_deployVault_zeroUsdc_reverts() public {
        vm.prank(deployer);
        vm.expectRevert(ZeroAddress.selector);
        factory.deployVault(
            vaultAdmin, address(0), address(creditOracle), address(premiumEngine), address(marginEngine), address(settlementEngine)
        );
    }

    function test_deployVault_zeroCreditOracle_reverts() public {
        vm.prank(deployer);
        vm.expectRevert(ZeroAddress.selector);
        factory.deployVault(
            vaultAdmin, address(usdc), address(0), address(premiumEngine), address(marginEngine), address(settlementEngine)
        );
    }

    function test_deployVault_whenPaused_reverts() public {
        vm.prank(admin);
        factory.pause();

        vm.prank(deployer);
        vm.expectRevert();
        factory.deployVault(
            vaultAdmin, address(usdc), address(creditOracle), address(premiumEngine), address(marginEngine), address(settlementEngine)
        );
    }

    function test_deployVault_afterUnpause_succeeds() public {
        vm.prank(admin);
        factory.pause();

        vm.prank(admin);
        factory.unpause();

        vm.prank(deployer);
        (uint256 vaultId,) = factory.deployVault(
            vaultAdmin, address(usdc), address(creditOracle), address(premiumEngine), address(marginEngine), address(settlementEngine)
        );
        assertEq(vaultId, 0);
    }

    // -------------------------------------------------------------------------
    // Registry views
    // -------------------------------------------------------------------------

    function test_getVault_unknownId_returnsZero() public view {
        assertEq(factory.getVault(999), address(0));
    }

    function test_isKnownVault_false_for_random() public view {
        assertFalse(factory.isKnownVault(alice));
    }

    // -------------------------------------------------------------------------
    // setVaultImplementation
    // -------------------------------------------------------------------------

    function test_setVaultImplementation_updatesAddress() public {
        address newImpl = makeAddr("newImpl");
        vm.prank(admin);
        factory.setVaultImplementation(newImpl);
        assertEq(factory.vaultImplementation(), newImpl);
    }

    function test_setVaultImplementation_emitsEvent() public {
        address newImpl = makeAddr("newImpl");
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit ICDSFactory.VaultImplementationUpdated(address(vaultImpl), newImpl);
        factory.setVaultImplementation(newImpl);
    }

    function test_setVaultImplementation_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.setVaultImplementation(makeAddr("newImpl"));
    }

    function test_setVaultImplementation_zeroAddr_reverts() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        factory.setVaultImplementation(address(0));
    }

    // -------------------------------------------------------------------------
    // Pause / Unpause
    // -------------------------------------------------------------------------

    function test_pause_onlyPauser() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.pause();
    }

    function test_unpause_onlyPauser() public {
        vm.prank(admin);
        factory.pause();

        vm.prank(alice);
        vm.expectRevert();
        factory.unpause();
    }

    // -------------------------------------------------------------------------
    // Fuzz: deploy N vaults, all registered correctly
    // -------------------------------------------------------------------------

    function test_fuzz_deployMultiple(uint8 count) public {
        vm.assume(count > 0 && count <= 10);

        vm.startPrank(deployer);
        address[] memory vaults = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            (, address v) = factory.deployVault(
                vaultAdmin, address(usdc), address(creditOracle), address(premiumEngine), address(marginEngine), address(settlementEngine)
            );
            vaults[i] = v;
        }
        vm.stopPrank();

        assertEq(factory.vaultCount(), count);
        for (uint256 i = 0; i < count; i++) {
            assertEq(factory.getVault(i), vaults[i]);
            assertTrue(factory.isKnownVault(vaults[i]));
        }
    }
}
