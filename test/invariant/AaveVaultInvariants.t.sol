// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AaveVault} from "../../src/AaveVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

/**
 * @title AaveVaultInvariants
 * @notice Suite de Invariant Testing (Stateful Fuzzing)
 * @dev Comprueba las propiedades que deben cumplirse SIEMPRE, tras cualquier secuencia de operaciones
 *      Requiere fork de Sepolia.
 */
contract AaveVaultInvariants is StdInvariant, Test {
    //* Variables de estado

    /// @notice Instancia del AaveVault, del contrato handler y del token WETH
    AaveVault vault;
    Handler handler;
    IERC20 weth;

    /// @notice Direcciones de los contratos en Sepolia
    address constant WETH = 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c;
    address constant POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing.
     * @dev Despliega los contratos weth, vault y handler. Setea el target en el handler
     */
    function setUp() public {
        weth = IERC20(WETH);
        vault = new AaveVault(WETH, POOL);
        handler = new Handler(vault, weth);

        targetContract(address(handler));
    }

    /**
     * @notice Invariante 1: Solvencia
     * @dev El valor total de los activos en el Vault siempre debe ser suficiente
     *      para respaldar todas las shares emitidas. totalAssets >= convertToAssets(totalSupply)
     */
    function invariant_ProtocolMustBeSolvent() public view {
        // Obtiene total de WETH + aWETH (los assets) del contrato y de shares emitidas
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();

        // Si no hay WETH depositado skip del test
        if (totalSupply == 0) return;

        // Convierte a underlying asset (WETH) las shares emitidas por el vault
        uint256 assetsBacked = vault.convertToAssets(totalSupply);

        // Comprueba que el total de WETH (con un desfase de 10 wei por el redondeo que hace ERC4626)
        // sea mayor que el total de shares convertidos a assets. Si no es así, exite insolvencia
        assertGe(totalAssets + 10, assetsBacked, "El Vault es insolvente");
    }

    /**
     * @notice Invariante 2: Integridad de Activos
     * @dev totalAssets() debe coincidir siempre con la suma física de balances (WETH + aWETH)
     */
    function invariant_TotalAssetsEqualsUnderlying() public view {
        // Obtiene total de WETH + aWETH (los assets) del contrato
        uint256 reportedAssets = vault.totalAssets();

        // Obtiene los balances de WETH y aToken del vault por separado de sus respectivos contratos
        uint256 wethBalance = weth.balanceOf(address(vault));
        uint256 aWethBalance = IERC20(address(vault.aToken())).balanceOf(address(vault));

        // Comprueba los valores obtenidos por vías distintas sean los mismos, si no el contrato
        // tiene mala tesorería
        assertEq(reportedAssets, wethBalance + aWethBalance, "totalAssets desincronizado del balance real");
    }
}
