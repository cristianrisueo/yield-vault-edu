// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {AaveVault} from "../../src/AaveVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AaveVaultIntegrationTest
 * @author cristianrisueo
 * @notice Pruebas de integración para AaveVault usando contratos reales en Sepolia
 * @dev Estas pruebas interactúan con Aave v3 en Sepolia para verificar depósitos,
 *      retiros y generación de yield real. Es un Fork test, pero sorpresa, en testnets
 *      como Sepolia no hay préstamos, por lo que yield = 0. Neceitaríamos un mainnet fork
 *      para ver yield real (dejar para el final, porque vale pasta).
 */
contract AaveVaultIntegrationTest is Test {
    //* Variables de estado

    /// @notice Instancia del AaveVault a testear y del token WETH
    AaveVault public vault;
    IERC20 public weth;

    /// @notice Direcciones de prueba
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    /// @notice Balance inicial de WETH para cada usuario
    uint256 constant INITIAL_BALANCE = 10 ether;

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing.
     * @dev Hace fork de Sepolia, despliega el vault y da WETH a los usuarios.
     */
    function setUp() public {
        // Deploy del vault (usa contratos reales de Sepolia)
        vault = new AaveVault();
        weth = IERC20(vault.asset());

        // Da 10 WETH a Alice y Bob
        deal(address(weth), alice, INITIAL_BALANCE);
        deal(address(weth), bob, INITIAL_BALANCE);
    }

    //* Tests de integración principales: deposit, withdraw y yield

    /**
     * @notice Testea depósito de WETH en Aave vía el vault
     */
    function test_DepositToAave() public {
        // Usa la dirección de Alice y 1 WETH
        vm.startPrank(alice);
        uint256 depositAmount = 1 ether;

        // Aprueba y deposita en el vault
        weth.approve(address(vault), depositAmount);
        uint256 sharesMinted = vault.deposit(depositAmount, alice);

        // Comprueba que las shares en el vault y las recibidas en el depósito coinciden
        assertEq(vault.balanceOf(alice), sharesMinted);

        // Comprueba que totalAssets del vault refleja el depósito (puede ser >= por yield instantáneo, raro)
        assertGe(vault.totalAssets(), depositAmount);

        // Comprueba que el vault tiene aWETH
        assertGt(vault.getATokenBalance(), 0);

        vm.stopPrank();
    }

    /**
     * @notice Testea retiro de WETH desde Aave vía el vault
     */
    function test_WithdrawFromAave() public {
        // Usa la dirección de Alice y 1 WETH para depositar primero
        vm.startPrank(alice);
        uint256 depositAmount = 1 ether;

        // Aprueba y deposita en el vault
        weth.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        vm.stopPrank();

        // Usa la dirección de Alice de nuevo, para retirar
        vm.startPrank(alice);

        // Recoge el balance de WETH antes, retira y recoge el balance después
        uint256 wethBefore = weth.balanceOf(alice);
        vault.withdraw(depositAmount, alice, alice);
        uint256 wethAfter = weth.balanceOf(alice);

        // Comprueba que Alice recibió exactamente lo que retiró (podría fallar si yield instantáneo?)
        assertEq(wethAfter - wethBefore, depositAmount);

        vm.stopPrank();
    }

    /**
     * @notice Testea que los depósitos y retiros funcionan correctamente tras el paso del tiempo
     * @dev En testnets como Sepolia, no hay actividad de préstamos real, por lo que el yield puede
     *      es 0. Simulamos yield artificialmente inyectando aWETH directamente al vault.
     */
    function test_YieldGeneration() public {
        // Alice deposita 5 WETH
        vm.startPrank(alice);
        uint256 depositAmount = 5 ether;

        weth.approve(address(vault), depositAmount);
        uint256 sharesMinted = vault.deposit(depositAmount, alice);

        vm.stopPrank();

        // Simula el paso del tiempo (1 semana)
        skip(7 days);

        // --- SIMULACIÓN DE YIELD ---
        // Usamos un "donante" que deposita en Aave indicando al Vault como beneficiario.
        // Esto genera aWETH reales y seguros. No se puede hacer deal directamente con un aToken, sorry

        address donor = makeAddr("donor");
        uint256 simulatedYield = 0.5 ether;
        deal(address(weth), donor, simulatedYield);

        vm.startPrank(donor);
        weth.approve(address(vault.aavePool()), simulatedYield);

        // Suministramos a Aave, pero los aTokens resultantes van directamente al Vault
        AaveVault(payable(address(vault))).aavePool().supply(address(weth), simulatedYield, address(vault), 0);
        vm.stopPrank();

        // Recoge totalAssets que ahora DEBE ser mayor que el depósito original (5.5 WETH)
        uint256 assetsAfterTime = vault.totalAssets();

        console.log("Deposito original:", depositAmount);
        console.log("Assets despues de 1 semana (con yield simulado):", assetsAfterTime);
        console.log("Yield generado:", assetsAfterTime - depositAmount);

        // Verificamos que los assets han crecido debido al yield simulado
        assertGt(assetsAfterTime, depositAmount, "Deberia haber yield simulado");
        assertApproxEqAbs(
            assetsAfterTime, depositAmount + simulatedYield, 100, "El totalAssets no refleja el yield exacto"
        );

        // Alice retira TODO
        vm.startPrank(alice);

        // Recoge el balance de WETH antes, quema todas sus shares y recoge su balance de WETH después del retiro
        uint256 wethBefore = weth.balanceOf(alice);
        uint256 assetsRedeemed = vault.redeem(sharesMinted, alice, alice);
        uint256 wethAfter = weth.balanceOf(alice);

        // Comprueba que Alice recibió sus fondos + el yield simulado
        assertEq(wethAfter - wethBefore, assetsRedeemed, "Assets no corresponde con deposito + yield");
        assertApproxEqAbs(
            assetsRedeemed, depositAmount + simulatedYield, 100, "Shares no corresponde con deposito + yield"
        );

        // Comprueba lo que recibió Alice
        console.log("Alice recibio:", assetsRedeemed);

        vm.stopPrank();
    }

    /**
     * @notice Testea que múltiples usuarios pueden depositar y retirar correctamente
     *         y comprueba que el sistema de shares distribuye el yield proporcionalmente
     * @dev Se simula yield para comprobar que ambos usuarios se benefician. Recuerdo que
     *      Aave en sepolia no genera Yield
     */
    function test_MultiUserYieldDistribution() public {
        // Alice deposita 5 ETH
        vm.startPrank(alice);

        weth.approve(address(vault), 5 ether);
        uint256 aliceShares = vault.deposit(5 ether, alice);

        vm.stopPrank();

        // Bob deposita 5 ETH
        vm.startPrank(bob);

        weth.approve(address(vault), 5 ether);
        uint256 bobShares = vault.deposit(5 ether, bob);

        vm.stopPrank();

        // Simular el paso de 1 mes
        skip(30 days);

        // --- SIMULACIÓN DE YIELD ---
        // Usamos un "donante" que deposita en Aave indicando al Vault como beneficiario.
        // Esto genera aWETH reales y seguros. No se puede hacer deal directamente con un aToken, sorry

        address donor = makeAddr("donor");
        uint256 simulatedYield = 1 ether;
        deal(address(weth), donor, simulatedYield);

        vm.startPrank(donor);
        weth.approve(address(vault.aavePool()), simulatedYield);

        // Suministramos a Aave, pero los aTokens resultantes van directamente al Vault
        AaveVault(payable(address(vault))).aavePool().supply(address(weth), simulatedYield, address(vault), 0);
        vm.stopPrank();

        // Alice retira todas sus shares
        vm.prank(alice);
        uint256 aliceReceived = vault.redeem(aliceShares, alice, alice);

        // Bob retira todas sus shares
        vm.prank(bob);
        uint256 bobReceived = vault.redeem(bobShares, bob, bob);

        // Muestra los resultados
        console.log("Alice recibio:", aliceReceived);
        console.log("Bob recibio:", bobReceived);

        // Ambos depositaron lo mismo, deben recibir lo mismo (Principal + 50% del Yield)
        assertApproxEqRel(aliceReceived, bobReceived, 100, "Ambos deberian recibir cantidades similares");

        // Comprobamos que recibieron su depósito + ganancia. 5 ETH (principal) + 0.5 ETH (mitad del yield)
        uint256 expectedAmount = 5 ether + (simulatedYield / 2);

        assertApproxEqRel(aliceReceived, expectedAmount, 100, "Alice no recibio su parte del yield");
        assertApproxEqRel(bobReceived, expectedAmount, 100, "Bob no recibio su parte del yield");
    }

    //* Tests de circuit breakers y funcionalidades adicionales

    /**
     * @notice Testea que el límite máximo de TVL se aplica correctamente
     */
    function test_MaxTVLEnforced() public {
        // Setea el max TVL a 2 WETH
        vault.setMaxTVL(2 ether);

        // Usa la dirección de Alice para aprobar 10 WETH y depositar 3 WETH
        vm.startPrank(alice);
        weth.approve(address(vault), 10 ether);

        // Deposit debería revertir por exceder el max TVL
        vm.expectRevert(AaveVault.AaveVault__MaxTVLExceeded.selector);
        vault.deposit(3 ether, alice);

        vm.stopPrank();
    }

    /**
     * @notice Testea que pausar el vault impide depósitos
     */
    function test_PauseStopsDeposits() public {
        // Pausa el vault
        vault.pause();

        // Usa la dirección de Alice para aprobar 1 WETH
        vm.startPrank(alice);
        weth.approve(address(vault), 1 ether);

        // Deposit debería revertir por estar pausado
        vm.expectRevert();
        vault.deposit(1 ether, alice);

        vm.stopPrank();
    }

    /**
     * @notice Testea la obtención del APY actual de Aave
     */
    function test_GetAaveAPY() public view {
        // Obtiene y muestra el APY actual de Aave
        uint256 apy = vault.getAaveAPY();
        console.log("APY actual de Aave:", apy, "basis points");

        // En Sepolia testnet, el APY puede ser 0 debido a falta de actividad
        // de préstamos. Solo verificamos que sea un valor válido (>= 0 y < 10000)
        assertLt(apy, 10000);
    }
}
