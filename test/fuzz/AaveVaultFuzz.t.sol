// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {AaveVault} from "../../src/AaveVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AaveVaultFuzzTest
 * @author cristianrisueo
 * @notice Suite de Fuzz Testing para AaveVault
 * @dev Prueba la robustez matemática del contrato con inputs aleatorios generados por Foundry
 *      Requiere ejecutarse en un entorno de Fork de Sepolia.
 */
contract AaveVaultFuzzTest is Test {
    //* Variables de estado

    /// @notice Instancia del AaveVault a testear y del token WETH
    AaveVault public vault;
    IERC20 public weth;

    /// @notice Direcciones hardcodeadas de los contratos en Sepolia
    address constant WETH_ADDRESS = 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c;

    /// @notice Usuario de prueba para fuzzing
    address public alice = makeAddr("alice");

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing
     * @dev Despliega el vault e inicializa la interfaz de WETH
     */
    function setUp() public {
        vault = new AaveVault();
        weth = IERC20(WETH_ADDRESS);
    }

    //* Fuzz Tests

    /**
     * @notice Ciclo de depósito y retiro con cantidades aleatorias
     * @dev Comprueba que no se pierdan fondos (salvo redondeo) para cualquier cantidad válida.
     *      Foundry ejecutará esto miles de veces con diferentes valores de 'amount'
     * @param amount Cantidad aleatoria generada por Foundry
     */
    function testFuzz_DepositRedeemFlow(uint256 amount) public {
        // Genera una cantidad a depositar y retirar restringida a valores "reales"
        // entre 0.001 WETH y el máximo TVL permitido
        uint256 maxTVL = vault.maxTVL();
        amount = bound(amount, 0.001 ether, maxTVL);

        // Entrega la cantidad a Alice, el único usuario de testing
        deal(address(weth), alice, amount);
        vm.startPrank(alice);

        // Aprueba y deposita
        weth.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        // Comprueba que las shares minteadas sean mayores de 0
        assertGt(shares, 0, "No se mintearon shares");

        // Retira inmediatamente (redeem usa shares como input)
        // El ratio debe ser 1:1 (1 share = 1 asset) recuerdo que en Sepolia no yield
        uint256 assetsReceived = vault.redeem(shares, alice, alice);

        vm.stopPrank();

        // Comprobación: Alice debe recuperar su depósito casi exacto (tolerancia de 2 wei para redondeo)
        assertApproxEqAbs(assetsReceived, amount, 2, "Perdida de fondos por redondeo > 2 wei");
    }

    /**
     * @notice Ciclo de Mint y Withdraw (La contraparte de Deposit/Redeem)
     * @dev ERC4626 tiene reglas de redondeo distintas para mint (round up). Comprobamos
     *      que si pido X shares, pago el WETH justo y luego puedo recuperar lo pagado
     * @param sharesToMint Cantidad aleatoria de shares que Alice quiere obtener
     */
    function testFuzz_MintWithdrawFlow(uint256 sharesToMint) public {
        // Restringe las shares a cantidades realistas basadas en el maxTVL
        // Se usa maxTVL como límite superior para evitar problemas de ratio
        sharesToMint = bound(sharesToMint, 0.001 ether, vault.maxTVL());

        // Calcula cuántos assets costarán esas shares (no debería, ratio 1:1)
        uint256 assetsRequired = vault.previewMint(sharesToMint);

        // Comprueba que no rompa el Max TVL
        if (assetsRequired > vault.maxTVL()) return;

        // Protección contra dust: Si la cantidad es demasiado pequeña, Aave puede tener problemas
        // Aave tiene un mínimo interno para depósitos efectivos
        if (assetsRequired < 1000) return;

        // Entrega a Alice los assets (+100 wei por si pasa algo con el redondeo)
        deal(address(weth), alice, assetsRequired + 100);
        vm.startPrank(alice);

        // Aprueba y mintea (un depósito, pero pidiendo las shares que quiere en lugar de dar asset)
        weth.approve(address(vault), assetsRequired + 100);
        uint256 assetsSpent = vault.mint(sharesToMint, alice);

        // Comprobación 1: No debe cobrar más de lo previsualizado
        assertEq(assetsSpent, assetsRequired, "Mint cobra cantidad distinta al preview");

        // Obtiene el balance de shares de Alice en el vault
        uint256 aliceShares = vault.balanceOf(alice);

        // Comprueba que las shares recibidas sean las esperadas (tolerancia por redondeo)
        assertApproxEqAbs(aliceShares, sharesToMint, 100, "Shares minteadas no coinciden con las solicitadas");

        // Obtiene el máximo de shares que Alice puede redimir (las minteadas debería ser ~= redondeo)
        // Esto protege contra el caso donde Aave pierde 1 wei por redondeo interno (dust problem)
        uint256 redeemableShares = vault.maxRedeem(alice);

        // Si no hay shares redeemables (dust problem extremo), salta el test
        if (redeemableShares == 0) {
            vm.stopPrank();
            return;
        }

        // Comprueba que no se haya perdido una cantidad absurda (solo polvo/dust)
        // Se acepta perder hasta 100 wei de shares por discrepancias de Aave
        assertApproxEqAbs(redeemableShares, sharesToMint, 100, "Perdida excesiva de shares post-mint");

        // Realiza un redeem con lo disponible (withdraw pero con shares, no con assets)
        uint256 assetsRecovered = vault.redeem(redeemableShares, alice, alice);
        vm.stopPrank();

        // Comprobación 2: Alice debe recuperar lo invertido (tolerancia pequeña por redondeo)
        assertApproxEqAbs(assetsRecovered, assetsSpent, 100, "Flow Mint->Redeem con perdida excesiva");
    }

    /**
     * @notice Fuzz Test: Robustez matemática ante Yield aleatorio
     * @dev Comprueba que el sistema de shares no se rompa (overflow/underflow/división por cero)
     *      cuando el Vault recibe cantidades arbitrarias de beneficio (Yield) desde Aave.
     * @param depositAmount Cantidad inicial de Alice
     * @param yieldAmount Cantidad aleatoria de beneficio generado
     */
    function testFuzz_YieldDoesNotBreakMath(uint256 depositAmount, uint256 yieldAmount) public {
        // Bound: Cantidades realistas. Depósito inicial entre 0.1 y 50 WETH
        depositAmount = bound(depositAmount, 0.1 ether, 50 ether);

        // Bound: Yield entre 1 wei y 1000 WETH (probamos yields gigantes para ver si rompe la división)
        yieldAmount = bound(yieldAmount, 1, 1000 ether);

        // 1. Alice deposita primero (para establecer el totalSupply > 0)
        deal(address(weth), alice, depositAmount);
        vm.startPrank(alice);

        weth.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        vm.stopPrank();

        // 2. Inyección de Yield Fuzzeado (Usamos la técnica del donante a Aave, no se puede directamente)
        address donor = makeAddr("donor_fuzz");
        deal(address(weth), donor, yieldAmount);

        vm.startPrank(donor);
        address aavePool = address(vault.aavePool());
        weth.approve(aavePool, yieldAmount);

        // Suministra a Aave a favor del vault
        vault.aavePool().supply(address(weth), yieldAmount, address(vault), 0);
        vm.stopPrank();

        // 3. Bob deposita después del yield. Comprueba que pueda depositar sin revert (si no excede TVL)
        address bob = makeAddr("bob");
        uint256 bobDeposit = 1 ether;

        // Check de TVL máximo no superado antes de intentar depositar, para evitar falsos errores
        if (vault.totalAssets() + bobDeposit > vault.maxTVL()) return;

        deal(address(weth), bob, bobDeposit);

        vm.startPrank(bob);
        weth.approve(address(vault), bobDeposit);

        // Esta línea es la prueba de fuego: ¿Falla la matemática con el nuevo precio de share?
        uint256 bobShares = vault.deposit(bobDeposit, bob);
        vm.stopPrank();

        // Invariante: Bob debe recibir shares > 0 (si el yield no fue astronómicamente absurdo)
        // Si el yield es inmenso (ej. 1000 ETH sobre 0.1 ETH), el precio por share sube tanto
        // que 1 ETH de Bob podría no comprar ni 1 wei de share.
        // Solo afirmamos shares > 0 si el depósito de Bob es significativo respecto al totalAssets.
        if (bobDeposit >= vault.convertToAssets(1)) {
            assertGt(bobShares, 0, "Bob debio recibir shares a pesar del yield");
        }
    }

    /**
     * @notice Comprueba la integridad del ratio de conversión
     * @dev Comprueba que la previsualización del WETH coincida con el real
     *       tras el retiro para cualquier cantidad aleatoria
     * @param amount Cantidad aleatoria
     */
    function testFuzz_PreviewMatchesRedeem(uint256 amount) public {
        // Genera una cantidad entre 0.1 WETH  y el máx. TVL permitido
        amount = bound(amount, 0.1 ether, vault.maxTVL());

        // Entrega la cantidad a Alcie
        deal(address(weth), alice, amount);
        vm.startPrank(alice);

        // Aprueba, deposita y recoge las shares minteadas
        weth.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        // Consulta cuánto WETH promete el contrato que devolverá (función interna de ERC4626)
        uint256 previewAssets = vault.previewRedeem(shares);

        // Ejecuta el retiro real
        uint256 actualAssets = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        // Invariante: La promesa (preview) debe ser igual a la realidad (actual)
        assertEq(previewAssets, actualAssets, "PreviewRedeem miente sobre la cantidad real de WETH");
    }

    /**
     * @notice Comprueba que el Max TVL se respete siempre
     * @dev Intenta depositar cantidades aleatorias SIEMPRE por encima del límite
     * @param amount Cantidad aleatoria
     */
    function testFuzz_MaxTVLEnforced(uint256 amount) public {
        // Recoge el TVL máximo permitido
        uint256 maxTVL = vault.maxTVL();

        // Genera una cantidad que SIEMPRE sea mayor al Max TVL
        amount = bound(amount, maxTVL + 1, type(uint128).max);

        // Entrega esa cantidad excesiva a Alice
        deal(address(weth), alice, amount);
        vm.startPrank(alice);

        // Aprueba, espera error por exceder el TVL máximo y deposita
        weth.approve(address(vault), amount);
        vm.expectRevert(AaveVault.AaveVault__MaxTVLExceeded.selector);
        vault.deposit(amount, alice);

        vm.stopPrank();
    }
}
