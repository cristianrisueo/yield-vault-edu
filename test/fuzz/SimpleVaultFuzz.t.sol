// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "../../src/SimpleVault.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title SimpleVaultFuzzTest
 * @author cristianrisueo
 * @notice Fuzz tests para el contrato SimpleVault.sol
 */
contract SimpleVaultFuzzTest is Test {
    //* Variables de estado

    // Contratos: Vault y WETH mock
    SimpleVault public vault;
    ERC20Mock public weth;

    // Usuarios de test
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    //* Setup del entorno de testing

    function setUp() public {
        // Deploy de contratos
        weth = new ERC20Mock();
        vault = new SimpleVault(IERC20(address(weth)));
    }

    //* Fuzz Tests

    /**
     * @notice Fuzz test: deposit cualquier cantidad válida entre 1 y 1,000,000 WETH
     * @dev Foundry ejecutará esto 256 veces con diferentes amounts
     * @param amount Cantidad de WETH a depositar
     */
    function testFuzz_Deposit(uint256 amount) public {
        // Limita el input a rangos "reales", entre 1 y 1,000,000 WETH
        amount = bound(amount, 1, 1_000_000 ether);

        // Mintea esa cantidad de WETH a Alice
        weth.mint(alice, amount);

        // Usando el address de Alice aprueba deposit y deposita la cantidad en el vault
        vm.startPrank(alice);

        weth.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        // Comprobaciones: El ratio es correcto, balance de shares de Alice y totalAssets del vault correctos
        assertEq(shares, amount, "El balance del primer deposito es 1:1, shares y amount deben ser iguales");
        assertEq(vault.balanceOf(alice), shares, "El balance de shares de Alice debe ser igual a las shares recibidas");
        assertEq(vault.totalAssets(), amount, "El totalAssets del vault debe ser igual al amount depositado");

        // Deja de usar la dirección de Alice
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test: múltiples deposits mantienen el ratio correcto
     * @param amount1 Cantidad de WETH a depositar por Alice
     * @param amount2 Cantidad de WETH a depositar por Bob
     */
    function testFuzz_MultipleDeposits(uint256 amount1, uint256 amount2) public {
        // Limita los inputs a rangos "reales", entre 1 y 100 WETH
        amount1 = bound(amount1, 1 ether, 100 ether);
        amount2 = bound(amount2, 1 ether, 100 ether);

        // Alice deposita amount1
        weth.mint(alice, amount1);
        vm.startPrank(alice);

        weth.approve(address(vault), amount1);
        vault.deposit(amount1, alice);

        vm.stopPrank();

        // Bob deposita amount2
        weth.mint(bob, amount2);
        vm.startPrank(bob);

        weth.approve(address(vault), amount2);
        uint256 shares_bob = vault.deposit(amount2, bob);

        vm.stopPrank();

        // Comprueba que las shares de Bob mantienen el ratio correcto.
        // shares = (amount * totalSupply) / totalAssets -> totalSupply y totalAssets = amount1
        uint256 expected_shares = (amount2 * amount1) / amount1;

        assertEq(shares_bob, expected_shares, "Ratio should be preserved");
    }

    /**
     * @notice Fuzz test: withdraw nunca debe dar más de lo depositado (sin yield)
     * @param amount Cantidad de WETH a depositar por Alice
     */
    function testFuzz_WithdrawCannotExceedDeposit(uint256 amount) public {
        // Limita el input a rangos "reales", entre 1 y 1,000,000 WETH
        amount = bound(amount, 1 ether, 100 ether);

        // Mintea esa cantidad de WETH a Alice
        weth.mint(alice, amount);

        // Usando el address de Alice aprueba deposit y deposita la cantidad en el vault
        vm.startPrank(alice);

        weth.approve(address(vault), amount);
        vault.deposit(amount, alice);

        // Alice calcula su max withdraw (todo su balance de WETH en el vault)
        uint256 max_withdraw = vault.maxWithdraw(alice);

        // Comprueba que sin yield solo retira lo que ha depositado
        assertEq(max_withdraw, amount, "La cantidad depositada y la maxima a retirar deben ser iguales");

        // Deja de usar la dirección de Alice
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test: yield distribution es proporcional
     * @dev Simula yield mintando WETH directamente al vault
     * @param deposit_alice Cantidad de WETH a depositar por Alice
     * @param deposit_bob Cantidad de WETH a depositar por Bob
     * @param yield_amount Cantidad de WETH que se simula como yield
     */
    function testFuzz_YieldDistribution(uint256 deposit_alice, uint256 deposit_bob, uint256 yield_amount) public {
        // Limita los inputs a rangos "reales", entre 10-100 WETH para deposits y 1-50 WETH para yield
        deposit_alice = bound(deposit_alice, 10 ether, 100 ether);
        deposit_bob = bound(deposit_bob, 10 ether, 100 ether);
        yield_amount = bound(yield_amount, 1 ether, 50 ether);

        // Mintea a Alice su cantidad respectiva, aprueba y deposita
        weth.mint(alice, deposit_alice);
        vm.startPrank(alice);

        weth.approve(address(vault), deposit_alice);
        vault.deposit(deposit_alice, alice);

        vm.stopPrank();

        // Mintea a Bob su cantidad respectiva, aprueba y deposita
        weth.mint(bob, deposit_bob);
        vm.startPrank(bob);

        weth.approve(address(vault), deposit_bob);
        vault.deposit(deposit_bob, bob);

        vm.stopPrank();

        // Simula el yield mintando WETH directamente al vault
        weth.mint(address(vault), yield_amount);

        // Calcula los totales
        uint256 total_deposits = deposit_alice + deposit_bob;
        uint256 total_with_yield = total_deposits + yield_amount;

        // Simula el withdrawAll de Alice
        vm.prank(alice);
        uint256 alice_withdrawn = vault.withdrawAll(alice);

        // Comprueba que la cantidad retirada por Alice es proporcional a su deposit + yield
        // Permite 1 wei de error por rounding
        uint256 expected_alice = (deposit_alice * total_with_yield) / total_deposits;

        assertApproxEqAbs(alice_withdrawn, expected_alice, 1e10, "Alice debe recibir su parte del yield");
    }
}
