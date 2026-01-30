// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {AaveVault} from "../../src/AaveVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title AaveVaultUnitTest
 * @notice Suite completa de tests unitarios para AaveVault
 * @dev Tests de funcionalidad basica sin integracion real con Aave (usa mocks internos)
 */
contract AaveVaultUnitTest is Test {
    //* Variables de estado

    /// @notice Instancia del AaveVault a testear
    AaveVault public vault;

    /// @notice Direcciones hardcodeadas de los contratos en Sepolia
    address constant WETH_ADDRESS = 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c;
    address constant AAVE_POOL_ADDRESS = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;

    /// @notice Usuarios de prueba
    address public owner;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing.
     * @dev Despliega el vault y asigna el owner (quien despliega el contrato).
     */
    function setUp() public {
        owner = address(this);
        vault = new AaveVault();
    }

    //* Test unitarios de lógica principal: Depósitos

    /**
     * @notice Test basico de deposito
     * @dev Comprueba que un usuario pueda depositar y recibir shares correctamente
     */
    function test_DepositBasic() public {
        // Cantidad a depositar: 1 WETH
        uint256 deposit_amount = 1 ether;

        // Entrega la cantidad a Alice y usa su cuenta para depositar
        deal(WETH_ADDRESS, alice, deposit_amount);
        vm.startPrank(alice);

        // Aprueba el vault para gastar su WETH y deposita
        IERC20(WETH_ADDRESS).approve(address(vault), deposit_amount);
        uint256 shares_received = vault.deposit(deposit_amount, alice);

        vm.stopPrank();

        // Comprueba que las shares de Alice en el vault y las recibidas coinciden
        assertEq(vault.balanceOf(alice), shares_received, "Shares incorrectas");

        // Comprueba que el total de assets del vault es igual al deposito de Alice
        assertEq(vault.totalAssets(), deposit_amount, "Total assets incorrecto");
    }

    /**
     * @notice Test de deposito con cantidad cero
     * @dev Debe revertir al intentar depositar 0
     */
    function test_DepositZeroReverts() public {
        vm.prank(alice);

        vm.expectRevert(AaveVault.AaveVault__ZeroAmount.selector);
        vault.deposit(0, alice);
    }

    /**
     * @notice Test de deposito cuando el vault esta pausado
     * @dev Debe revertir si se intenta depositar mientras esta pausado
     */
    function test_DepositWhenPausedReverts() public {
        // Cantidad a depositar: 1 WETH
        uint256 deposit_amount = 1 ether;

        // Se pausa el vault
        vault.pause();

        // Entrega la cantidad a Alice y usa su cuenta para depositar
        deal(WETH_ADDRESS, alice, deposit_amount);
        vm.startPrank(alice);

        // Aprueba el vault para gastar su WETH
        IERC20(WETH_ADDRESS).approve(address(vault), deposit_amount);

        // Espera que se revierta por estar pausado el vault, y deposita
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(deposit_amount, alice);

        vm.stopPrank();
    }

    /**
     * @notice Test de deposito excediendo max TVL
     * @dev Debe revertir si el deposito supera el limite de TVL
     */
    function test_DepositExceedingMaxTVLReverts() public {
        // Obtiene el max TVL actual del vault y aumenta la cantidad a depositar
        uint256 max_tvl = vault.maxTVL();
        uint256 exceeding_amount = max_tvl + 1 ether;

        // Dar la cantidad de exceso a Alice
        deal(WETH_ADDRESS, alice, exceeding_amount);
        vm.startPrank(alice);

        // Aprueba el vault para gastar su WETH
        IERC20(WETH_ADDRESS).approve(address(vault), exceeding_amount);

        // Espera que se revierta por exceder el max TVL, y deposita
        vm.expectRevert(AaveVault.AaveVault__MaxTVLExceeded.selector);
        vault.deposit(exceeding_amount, alice);

        vm.stopPrank();
    }

    /**
     * @notice Test de multiples depositos secuenciales
     * @dev Comprueba que varios usuarios puedan depositar sin problemas
     */
    function test_MultipleDepositsSequential() public {
        // Cantidades a depositar por cada usuario
        uint256 amount_alice = 2 ether;
        uint256 amount_bob = 3 ether;
        uint256 amount_charlie = 1.5 ether;

        // Entrega la cantidad a Alice y deposita
        deal(WETH_ADDRESS, alice, amount_alice);
        vm.startPrank(alice);

        IERC20(WETH_ADDRESS).approve(address(vault), amount_alice);
        vault.deposit(amount_alice, alice);

        vm.stopPrank();

        // Entrega la cantidad a Bob y deposita
        deal(WETH_ADDRESS, bob, amount_bob);
        vm.startPrank(bob);

        IERC20(WETH_ADDRESS).approve(address(vault), amount_bob);
        vault.deposit(amount_bob, bob);

        vm.stopPrank();

        // Entrega la cantidad a Charlie y deposita
        deal(WETH_ADDRESS, charlie, amount_charlie);
        vm.startPrank(charlie);

        IERC20(WETH_ADDRESS).approve(address(vault), amount_charlie);
        vault.deposit(amount_charlie, charlie);

        vm.stopPrank();

        // Comprueba que el total de assets del vault es correcto
        uint256 expected_total = amount_alice + amount_bob + amount_charlie;
        assertEq(vault.totalAssets(), expected_total, "Total assets incorrecto");
    }

    //* Test unitarios de lógica principal: Retiros

    /**
     * @notice Test basico de retiro
     * @dev Comprueba que un usuario pueda retirar sus fondos correctamente
     */
    function test_WithdrawBasic() public {
        // Cantidad a depositar y luego retirar: 5 WETH
        uint256 deposit_amount = 5 ether;

        // Setup: Se entrega la cantidad a Alice y deposita
        deal(WETH_ADDRESS, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH_ADDRESS).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        // Alice retira la misma cantidad
        uint256 assets_withdrawn = vault.withdraw(deposit_amount, alice, alice);

        vm.stopPrank();

        // Comprobaciones: Cantidad retirada coincide, shares de Alice a 0, balance WETH de Alice correcto
        assertEq(assets_withdrawn, deposit_amount, "Cantidad retirada incorrecta");
        assertEq(vault.balanceOf(alice), 0, "Alice aun tiene shares");
        assertEq(IERC20(WETH_ADDRESS).balanceOf(alice), deposit_amount, "Alice no recibio WETH");
    }

    /**
     * @notice Test de retiro con cantidad cero
     * @dev Debe revertir al intentar retirar 0
     */
    function test_WithdrawZeroReverts() public {
        vm.prank(alice);

        vm.expectRevert(AaveVault.AaveVault__ZeroAmount.selector);
        vault.withdraw(0, alice, alice);
    }

    /**
     * @notice Test de retiro parcial
     * @dev Usuario retira solo una parte de su deposito
     */
    function test_WithdrawPartial() public {
        // Cantidades a depositar y retirar
        uint256 deposit_amount = 10 ether;
        uint256 withdraw_amount = 4 ether;

        // Setup: Se entrega la cantidad a depositar (10 WETH) a Alice y deposita
        deal(WETH_ADDRESS, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH_ADDRESS).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        // Alice retira la cantidad parcial (4 WETH)
        vault.withdraw(withdraw_amount, alice, alice);

        vm.stopPrank();

        // Comprobaciones: Alice tiene shares y su balance de WETH es correcto
        assertGt(vault.balanceOf(alice), 0, "Alice no tiene shares restantes");
        assertEq(IERC20(WETH_ADDRESS).balanceOf(alice), withdraw_amount, "Balance WETH incorrecto");
    }

    /**
     * @notice Test de retiro excediendo balance
     * @dev Debe revertir porque intenta retirar mas de lo que tiene
     */
    function test_WithdrawMoreThanBalanceReverts() public {
        // Cantidades a depositar y retirar
        uint256 deposit_amount = 5 ether;
        uint256 withdraw_amount = 10 ether;

        // Setup: Se entrega la cantidad a depositar (5 WETH) a Alice y deposita
        deal(WETH_ADDRESS, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH_ADDRESS).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        // Se espera que revierta y Alice retira la cantidad excesiva (10 WETH)
        vm.expectRevert();
        vault.withdraw(withdraw_amount, alice, alice);

        vm.stopPrank();
    }

    //* Test unitarios de lógica adicional: Emergency Exit

    /**
     * @notice Test de emergency exit solo owner
     * @dev Comprueba que solo el owner puede ejecutar emergency exit
     */
    function test_EmergencyExitOnlyOwner() public {
        vm.prank(alice);

        // Espera que revierta por no ser el owner
        vm.expectRevert();
        vault.emergencyExit();
    }

    /**
     * @notice Test de emergency exit pausa el vault
     * @dev Comprueba que emergency exit pause el protocolo
     */
    function test_EmergencyExitPausesVault() public {
        // Cantidad a depositar: 10 WETH
        uint256 deposit_amount = 10 ether;

        // Se entrega la cantidad a depositar a Alice y deposita
        deal(WETH_ADDRESS, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH_ADDRESS).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        vm.stopPrank();

        // Owner ejecuta emergency exit
        vault.emergencyExit();

        // Comprueba que el vault esta pausado
        assertTrue(vault.paused(), "Vault no esta pausado");
    }

    /**
     * @notice Test de que no se puede depositar despues de emergency exit
     * @dev Comprueba que depositos fallen despues de emergency exit
     */
    function test_CannotDepositAfterEmergencyExit() public {
        // Cantidad a depositar: 1 WETH
        uint256 deposit_amount = 1 ether;

        // El owner ejecuta emergency exit
        vault.emergencyExit();

        // Alice intenta depositar despues de emergency exit
        deal(WETH_ADDRESS, alice, deposit_amount);
        vm.startPrank(alice);

        // Se espera que revierta al intentar depositar
        IERC20(WETH_ADDRESS).approve(address(vault), deposit_amount);
        vm.expectRevert();
        vault.deposit(deposit_amount, alice);

        vm.stopPrank();
    }

    //* Test unitarios de lógica adicional: Emergency Withdraw

    /**
     * @notice Test de emergency withdraw solo owner
     */
    function test_EmergencyWithdrawOnlyOwner() public {
        // El owner pausa para que no falle por el modificador whenPaused
        vault.pause();

        // Alice intenta llamar a la función. Se espera que revierta
        vm.prank(alice);
        vm.expectRevert();
        vault.emergencyWithdraw(alice);
    }

    /**
     * @notice Test de emergency withdraw falla si no esta pausado
     */
    function test_EmergencyWithdrawOnlyWhenPaused() public {
        // El owner llama a emergency withdraw pero no está pausado. Se espera que revierta
        vm.expectRevert(abi.encodeWithSignature("ExpectedPause()"));
        vault.emergencyWithdraw(owner);
    }

    /**
     * @notice Test de exito: rescata tanto WETH como aWETH
     */
    function test_EmergencyWithdrawSuccess() public {
        // Cantidad WETH, aWETH y receiver, que es el owner
        uint256 amountWETH = 1 ether;
        uint256 amountAWETH = 2 ether;
        address receiver = owner;

        // El address del aWETH obtenida de Aave a través del constructor del vault
        address aWETH = address(vault.aWETH());

        // Enviamos la cantidad de WETH a Alice y la deposita en el vault
        deal(WETH_ADDRESS, alice, amountAWETH);
        vm.startPrank(alice);

        IERC20(WETH_ADDRESS).approve(address(vault), amountWETH);
        vault.deposit(amountWETH, alice);

        vm.stopPrank();

        // Obtenemos los balances iniciales de WETH y aWETH del vault antes del rescate
        uint256 wethToRescue = IERC20(WETH_ADDRESS).balanceOf(address(vault));
        uint256 aWethToRescue = IERC20(aWETH).balanceOf(address(vault));

        // Pausamos el vault y ejecutamos el emergency withdraw
        vault.pause();
        vault.emergencyWithdraw(receiver);

        // Realizamos las comprobaciones: El owner recibe el aWETH y WETH
        assertEq(IERC20(aWETH).balanceOf(receiver), aWethToRescue, "aWETH no rescatado");
        assertEq(IERC20(WETH_ADDRESS).balanceOf(receiver), wethToRescue, "WETH no rescatado");

        // Realizamos las comprobaciones: El vault no tiene aWETH ni WETH
        assertEq(IERC20(aWETH).balanceOf(address(vault)), 0, "Aun queda aWETH");
        assertEq(IERC20(WETH_ADDRESS).balanceOf(address(vault)), 0, "Aun queda WETH");
    }

    //* Test unitarios de lógica adicional: Pausable

    /**
     * @notice Test de pause solo owner
     * @dev Solo el owner puede pausar
     */
    function test_PauseOnlyOwner() public {
        // Alice intenta pausar. Se espera que revierta
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();

        // Owner puede pausar. Se verifica que este pausado
        vault.pause();
        assertTrue(vault.paused(), "Vault no esta pausado");
    }

    /**
     * @notice Test de unpause solo owner
     * @dev Solo el owner puede despausar
     */
    function test_UnpauseOnlyOwner() public {
        // Owner pausa primero
        vault.pause();

        // Alice intenta despausar. Se espera que revierta
        vm.prank(alice);
        vm.expectRevert();
        vault.unpause();

        // Owner puede despausar. Se verifica que no este pausado
        vault.unpause();
        assertFalse(vault.paused(), "Vault aun esta pausado");
    }

    /**
     * @notice Test de que deposit no funciona cuando esta pausado
     * @dev Los depósitos deben revertir si el vault esta pausado
     */
    function test_DepsitFailsWhenPaused() public {
        // Cantidad a depositar: 5 WETH
        uint256 deposit_amount = 5 ether;

        // Owner pausa el vault
        vault.pause();

        // Alice no deberia poder depositar. Se espera que revierta
        deal(WETH_ADDRESS, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH_ADDRESS).approve(address(vault), deposit_amount);
        vm.expectRevert();
        vault.deposit(deposit_amount, alice);

        vm.stopPrank();
    }

    /**
     * @notice Test de que withdraw no funciona cuando esta pausado
     * @dev Los retiros deben revertir si el vault esta pausado
     */
    function test_WithdrawFailsWhenPaused() public {
        // Cantidad a depositar: 5 WETH
        uint256 deposit_amount = 5 ether;

        // Setup: Alice deposita primero
        deal(WETH_ADDRESS, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH_ADDRESS).approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        vm.stopPrank();

        // Owner pausa el vault
        vault.pause();

        // Alice no deberia poder retirar. Se espera que revierta
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(deposit_amount, alice, alice);
    }

    //* Test unitarios de lógica adicional: Max TVL

    /**
     * @notice Test de setMaxTVL solo owner
     * @dev Solo el owner puede cambiar el max TVL
     */
    function test_SetMaxTVLOnlyOwner() public {
        // Nuevo max TVL a setear
        uint256 new_max_tvl = 500 ether;

        // Alice intenta cambiar. Se espera que revierta
        vm.prank(alice);
        vm.expectRevert();
        vault.setMaxTVL(new_max_tvl);

        // Owner puede cambiar. Se comprueba que se actualizó
        vault.setMaxTVL(new_max_tvl);
        assertEq(vault.maxTVL(), new_max_tvl, "Max TVL no actualizado");
    }

    /**
     * @notice Test de aumentar max TVL permite hacer mas depositos
     * @dev Despues de aumentar max TVL, se pueden hacer depositos mayores
     */
    function test_IncreaseMaxTVLAllowsMoreDeposits() public {
        // Recoge el TVL actual y crea uno nuevo (+100)
        uint256 initial_max = vault.maxTVL();
        uint256 new_max = initial_max + 100 ether;

        // Setea el nuevo TVL
        vault.setMaxTVL(new_max);

        // Se entrega la cantidad de nuevo TVL a Alice
        deal(WETH_ADDRESS, alice, new_max);
        vm.startPrank(alice);

        // Aprueba y realiza el depósito
        IERC20(WETH_ADDRESS).approve(address(vault), new_max);
        vault.deposit(new_max, alice);
        vm.stopPrank();

        // Comprueba que se los assets totales del vault son el nuevo depósito
        assertEq(vault.totalAssets(), new_max, "Deposito no llego al nuevo max");
    }

    //* Test unitarios de lógica adicional: Conversión

    /**
     * @notice Test de conversion shares a assets
     * @dev Comprueba que la conversion de shares a assets sea correcta
     */
    function test_ConvertToAssets() public {
        // Cantidad a depositar: 10 WETH
        uint256 deposit_amount = 10 ether;

        // Se entrga la cantidad a Alice y deposita
        deal(WETH_ADDRESS, alice, deposit_amount);
        vm.startPrank(alice);

        IERC20(WETH_ADDRESS).approve(address(vault), deposit_amount);
        uint256 shares = vault.deposit(deposit_amount, alice);

        vm.stopPrank();

        // Convierte las shares recibidas del vault a assets (WETH)
        uint256 assets = vault.convertToAssets(shares);

        // Comprueba que los assets recibidos sean los del depósito
        assertEq(assets, deposit_amount, "Conversion incorrecta");
    }

    /**
     * @notice Test de conversion assets to shares
     * @dev Comprueba que la conversion de assets a shares sea correcta
     */
    function test_ConvertToShares() public view {
        // Cantidad de assets a convertir a shares: 5 WETH
        uint256 assets = 5 ether;

        // Sin depositos previos, 1:1 ratio
        uint256 shares = vault.convertToShares(assets);

        // Comprueba que shares y assets coinciden, ratio 1:1
        assertEq(shares, assets, "Conversion inicial incorrecta");
    }
}
