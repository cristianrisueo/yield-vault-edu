// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {AaveVault} from "../../src/AaveVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";

/**
 * @title Handler
 * @notice Contrato auxiliar para manejar interacciones complejas en Invariant Testing
 * @dev Restringe los inputs aleatorios a valores válidos para maximizar la profundidad del test
 */
contract Handler is Test {
    //* Variables de estado

    /// @notice Instancia del AaveVault, del token WETH y del pool de Aave
    AaveVault public vault;
    IERC20 public weth;
    IPool public aavePool;

    /// @notice Usuarios de prueba para simular actividad real
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    //* Constructor

    /**
     * @notice constructor del contrato Handler
     * @param _vault dirección del contrato vault
     * @param _weth  dirección del contrato weth
     */
    constructor(AaveVault _vault, IERC20 _weth) {
        vault = _vault;
        weth = _weth;

        // Obtenemos la dirección del pool de aave directamente del vault desplegado
        aavePool = IPool(vault.aavePool());
    }

    //* Funciones

    /**
     * @notice Simula un depósito válido de un usuario aleatorio
     * @dev Se asegura de no exceder el MaxTVL para evitar reverts inútiles
     * @param amount Cantidad aleatoria de assets a depositar
     * @param userSeed Semilla para elegir un usuario de forma aleatoria
     */
    function deposit(uint256 amount, uint256 userSeed) public {
        // Selecciona un usuario aleatorio entre los disponibles
        address sender = userSeed % 2 == 0 ? user1 : user2;

        // Limita la cantidad para respetar el MaxTVL actual del vault
        uint256 maxDeposit = vault.maxDeposit(sender);

        // Si el vault está lleno o pausado, no hace nada (skip)
        if (maxDeposit == 0) return;

        // Acota la cantidad a depositar entre el mínimo viable y el máximo permitido
        amount = bound(amount, 0.001 ether, maxDeposit);

        // Entrega los fondos al usuario y realiza la aprobación al vault
        deal(address(weth), sender, amount);

        vm.startPrank(sender);
        weth.approve(address(vault), amount);
        vault.deposit(amount, sender);
        vm.stopPrank();
    }

    /**
     * @notice Simula un minteo de shares válido de un usuario aleatorio
     * @dev A diferencia de deposit, aquí se define cuántas shares se quieren obtener
     * @param shares Cantidad aleatoria de shares a mintear
     * @param userSeed Semilla para elegir un usuario de forma aleatoria
     */
    function mint(uint256 shares, uint256 userSeed) public {
        // Selecciona un usuario aleatorio
        address sender = userSeed % 2 == 0 ? user1 : user2;

        // Limita las shares para no exceder el TVL máximo
        uint256 maxMint = vault.maxMint(sender);
        if (maxMint == 0) return;

        // Acota la cantidad de shares a mintear
        shares = bound(shares, 0.001 ether, maxMint);

        // Calcula cuántos assets (WETH) costarán esas shares
        uint256 assetsNeeded = vault.previewMint(shares);

        // Entrega los fondos exactos al usuario y aprueba al vault
        deal(address(weth), sender, assetsNeeded);

        vm.startPrank(sender);
        weth.approve(address(vault), assetsNeeded);
        vault.mint(shares, sender);
        vm.stopPrank();
    }

    /**
     * @notice Simula un retiro basado en una cantidad de activos (assets)
     * @dev Comprueba la contraparte de deposit() en el estándar ERC4626
     * @param amountAssets Cantidad aleatoria de activos a retirar
     * @param userSeed Semilla para elegir un usuario de forma aleatoria
     */
    function withdraw(uint256 amountAssets, uint256 userSeed) public {
        // Selecciona un usuario aleatorio
        address sender = userSeed % 2 == 0 ? user1 : user2;

        // Obtiene el máximo que el usuario puede retirar según su balance y liquidez de Aave
        uint256 maxWithdraw = vault.maxWithdraw(sender);

        // Si no puede retirar nada, skip del test
        if (maxWithdraw == 0) return;

        // Limita el retiro entre 0 y el máximo permitido
        amountAssets = bound(amountAssets, 0, maxWithdraw);

        if (amountAssets == 0) return;

        vm.startPrank(sender);
        vault.withdraw(amountAssets, sender, sender);
        vm.stopPrank();
    }

    /**
     * @notice Simula un retiro basado en una cantidad de acciones (shares)
     * @dev Comprueba la contraparte de mint() en el estándar ERC4626
     * @param amountShares Cantidad aleatoria de shares a quemar para retirar
     * @param userSeed Semilla para elegir un usuario de forma aleatoria
     */
    function redeem(uint256 amountShares, uint256 userSeed) public {
        // Selecciona un usuario aleatorio
        address sender = userSeed % 2 == 0 ? user1 : user2;

        // Obtiene el balance actual de acciones del usuario
        uint256 balanceShares = vault.balanceOf(sender);

        // Si el usuario no tiene participaciones, no puede retirar
        if (balanceShares == 0) return;

        // Limita el retiro a una cantidad entre 0 y el máximo que puede retirar
        amountShares = bound(amountShares, 0, balanceShares);

        // Si la cantidad a retirar es 0, no hace nada (skip)
        if (amountShares == 0) return;

        vm.startPrank(sender);

        // Obtiene lo máximo que puede extraer el usuario (de Aave) para evitar el problema
        // de redondeo de Aave. Se queda con el mínimo entre cantidad de shares y máximo extraible
        uint256 maxRedeemable = vault.maxRedeem(sender);
        if (amountShares > maxRedeemable) amountShares = maxRedeemable;

        // Quema las shares
        vault.redeem(amountShares, sender, sender);

        vm.stopPrank();
    }

    /**
     * @notice Simula la generación de Yield en Aave
     * @dev Dona WETH directamente al Pool a nombre del Vault para inflar el precio de la share
     * @param amount Cantidad aleatoria de WETH para generar yield
     */
    function generateYield(uint256 amount) public {
        // Limita el yield a algo razonable (0.1 a 50 WETH)
        amount = bound(amount, 0.1 ether, 50 ether);

        // Se inyectan fondos directamente en Aave para el Vault
        address donor = makeAddr("yield_donor");

        deal(address(weth), donor, amount);
        vm.startPrank(donor);

        weth.approve(address(aavePool), amount);
        // Suministramos al pool a nombre del vault para que se acrediten aWETH sin emitir shares
        aavePool.supply(address(weth), amount, address(vault), 0);
        vm.stopPrank();
    }
}
