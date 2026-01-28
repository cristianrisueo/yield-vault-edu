// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "../../src/SimpleVault.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title SimpleVaultTest
 * @author cristianrisueo
 * @notice Tests unitarios para el contrato SimpleVault.sol
 */
contract SimpleVaultTest is Test {
    //* Variables de estado

    // Contratos: Vault y WETH mock
    SimpleVault public vault;
    ERC20Mock public weth;

    // Usuarios de test
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    // Balance inicial de WETH para cada usuario
    uint256 constant INITIAL_BALANCE = 100 ether;

    //* Setup del entorno de testing

    function setUp() public {
        // Deploy de contratos
        weth = new ERC20Mock();
        vault = new SimpleVault(IERC20(address(weth)));

        // Da WETH a los usuarios de test
        weth.mint(alice, INITIAL_BALANCE);
        weth.mint(bob, INITIAL_BALANCE);
    }

    //* Tests básicos de deposit

    /**
     * @notice Testea el primer depósito en el vault
     */
    function test_FirstDeposit() public {
        // Usa la dirección de Alice y la cantidad 10 WETH
        vm.startPrank(alice);
        uint256 deposit_amount = 10 ether;

        // Aprueba el vault para gastar 10 WETH de Alice
        weth.approve(address(vault), deposit_amount);

        // Deposita los 10 WETH de Alice en el vault
        uint256 shares = vault.deposit(deposit_amount, alice);

        // Realiza las comprobaciones
        assertEq(shares, deposit_amount, "El primer deposito debe tener un ratio de 1:1");
        assertEq(vault.balanceOf(alice), deposit_amount, "Las shares de Alice deben ser 10");
        assertEq(vault.totalAssets(), deposit_amount, "El vault debe tener 10 WETH");

        // Deja de usar la dirección de Alice
        vm.stopPrank();
    }

    /**
     * @notice Testea un segundo depósito con el mismo ratio 1:1
     */
    function test_SecondDepositSameRatio() public {
        // Cantidad a depositar
        uint256 deposit_amount = 10 ether;

        // Alice deposita primero
        vm.startPrank(alice);

        weth.approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        vm.stopPrank();

        // Bob deposita después
        vm.startPrank(bob);

        weth.approve(address(vault), deposit_amount);
        uint256 shares = vault.deposit(deposit_amount, bob);

        vm.stopPrank();

        // Realiza las comprobaciones: Bob debería recibir mismo ratio y el vault tener 20 WETH
        assertEq(shares, deposit_amount, "Bob debe recibir 10 shares");
        assertEq(vault.totalAssets(), 20 ether, "El balance total del vault debe ser 20 WETH");
    }

    //* Tests básicos de withdraw

    /**
     * @notice Testea el retiro de una cantidad exacta de WETH
     */
    function test_WithdrawExactAmount() public {
        // Cantidades a depositar y retirar
        uint256 deposit_amount = 10 ether;
        uint256 withdraw_amount = 5 ether;

        // Alice deposita 10 WETH y guarda su balance después del depósito: -10 WETH
        vm.startPrank(alice);

        weth.approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        uint256 balance_before = weth.balanceOf(alice);

        // Alice retira 5 WETH y guarda su balance después del retiro: +5 WETH
        vault.withdraw(withdraw_amount, alice, alice);

        uint256 balance_after = weth.balanceOf(alice);

        // Realiza las comprobaciones: Balance de Alice y del vault
        assertEq(balance_after - balance_before, 5 ether, "Alice no ha recibido los 5 WETH retirados");
        assertEq(vault.totalAssets(), 5 ether, "El vault debe tener 5 WETH restantes en su balance");

        // Deja de usar la dirección de Alice
        vm.stopPrank();
    }

    /**
     * @notice Testea el retiro de todo el balance de un usuario en el vault
     */
    function test_WithdrawAll() public {
        // Cantidad a depositar
        uint256 deposit_amount = 10 ether;

        // Alice deposita
        vm.startPrank(alice);
        weth.approve(address(vault), deposit_amount);
        vault.deposit(deposit_amount, alice);

        // Alice retira todo su balance en el vault
        uint256 withdrawn = vault.withdrawAll(alice);

        // Realiza las comprobaciones: Alice recibe sus 10 WETH y sus shares quedan a 0
        assertEq(withdrawn, deposit_amount, "Alice deberia tener 10 WETH");
        assertEq(vault.balanceOf(alice), 0, "Alice deberia tener 0 shares del vault");

        // Deja de usar la dirección de Alice
        vm.stopPrank();
    }

    //* Test de yield simulado

    /**
     * @notice Testea que el vault maneja correctamente yield simulado
     */
    function test_YieldFromNewDeposits() public {
        // Alice deposita 10 WETH
        vm.startPrank(alice);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, alice);
        vm.stopPrank();

        // Simulamos "yield": alguien transfiere 2 WETH directo al vault, sin mintear shares
        weth.mint(address(vault), 2 ether);

        // Comprueba que el vault tiene 12 WETH
        assertEq(vault.totalAssets(), 12 ether, "El vault debe tener 12 WETH");

        // Alice retira: Al ser unica miembro del vault debería recibir 12 WETH (10 + 2 de yield)
        vm.startPrank(alice);

        // Comprueba que Alice puede retirar 12 WETH. Con 1 wei de tolerancia
        uint256 max_withdraw = vault.maxWithdraw(alice);
        assertApproxEqAbs(max_withdraw, 12 ether, 1e10, "Alice puede retirar aprox 12 WETH");

        // Comprueba que el balance inicial de Alice ha aumentado 2 WETH tras el retiro. Con 1 wei de tolerancia
        vault.withdrawAll(alice);
        assertApproxEqAbs(max_withdraw, 12 ether, 1e10, "Alice debe retirar aprox 12 WETH");

        // Deja de usar la dirección de Alice
        vm.stopPrank();
    }
}
