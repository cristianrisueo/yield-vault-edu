// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "../../src/SimpleVault.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title Contrato handler para Invariant Testing (Apuesto que no sabías que los handlers eran contratos)
 * @notice Define operaciones que Foundry ejecutará aleatoriamente
 */
contract VaultHandler is Test {
    //* Variables de estado del handler

    // Contratos: Vault y WETH mock
    SimpleVault public vault;
    ERC20Mock public weth;

    // Ghost variables (únicamente existen en el handler) para tracking de depósitos y retiros
    uint256 public total_deposited;
    uint256 public total_withdrawn;

    // Array con actores (los usuarios) de prueba
    address[] public actors;

    //* Constructor del handler

    /**
     * @notice Constructor del handler
     * @dev Setea los contratos y crea tres actores de prueba
     * @param _vault address del vault a testear
     * @param _weth  address del token WETH mock
     */
    constructor(SimpleVault _vault, ERC20Mock _weth) {
        vault = _vault;
        weth = _weth;

        // Crear actores de prueba
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
    }

    /**
     * @notice Función de deposito del handler
     * @param actor_seed Índice para seleccionar el actor aleatoriamente
     * @param amount     Cantidad de WETH a depositar
     */
    function deposit(uint256 actor_seed, uint256 amount) public {
        // Selecciona actor aleatoriamente y ajusta cantidad "realista"
        address actor = actors[actor_seed % actors.length];
        amount = bound(amount, 1 ether, 100 ether);

        // Mintea, aprueba y deposita para el actor seleccionado
        weth.mint(actor, amount);
        vm.startPrank(actor);

        weth.approve(address(vault), amount);
        vault.deposit(amount, actor);

        vm.stopPrank();

        // Actualiza variable ghost de depósitos
        total_deposited += amount;
    }

    /**
     * @notice Función de retiro del handler
     * @param actor_seed Índice para seleccionar el actor aleatoriamente
     * @param amount     Cantidad de WETH a retirar
     */
    function withdraw(uint256 actor_seed, uint256 amount) public {
        // Selecciona actor aleatoriamente
        address actor = actors[actor_seed % actors.length];

        // OBtiene la cantidad máxima que puede retirar el actor. Si es 0, skip
        uint256 max_withdraw = vault.maxWithdraw(actor);
        if (max_withdraw == 0) return;

        // Ajusta la cantidad a retirar entre 0 y el máximo permitido
        amount = bound(amount, 0, max_withdraw);

        // Realiza el retiro para el actor seleccionado
        vm.prank(actor);
        uint256 withdrawn = vault.withdraw(amount, actor, actor);

        // Actualiza variable ghost de retiros
        total_withdrawn += withdrawn;
    }

    /**
     * @notice Devuelve la lista de actores usados en el handler
     * @return address[] Array con las direcciones de los actores
     */
    function getActors() public view returns (address[] memory) {
        return actors;
    }
}

/**
 * @title SimpleVaultInvariantTest
 * @author cristianrisueo
 * @notice Tests de Invariant Testing para el contrato SimpleVault.sol
 * @dev Usa el contrato VaultHandler como target para los tests de invariantes
 */
contract SimpleVaultInvariantTest is Test {
    //* Variables de estado

    // Contratos: Vault, WETH mock y el handler
    SimpleVault public vault;
    ERC20Mock public weth;
    VaultHandler public handler;

    //* Setup del entorno de testing

    function setUp() public {
        // Deploy de contratos
        weth = new ERC20Mock();
        vault = new SimpleVault(IERC20(address(weth)));
        handler = new VaultHandler(vault, weth);

        // Especifica el contrato handler como target para Invariant Testing
        targetContract(address(handler));
    }

    //* Tests de invariantes

    /**
     * @notice INVARIANT 1: totalAssets siempre >= suma de lo que pueden retirar los usuarios
     */
    function invariant_SolvencyCheck() public view {
        // Obtiene totalAssets y totalSupply del vault
        uint256 total_assets = vault.totalAssets();
        uint256 total_supply = vault.totalSupply();

        // Si no hay shares, no hay assets
        if (total_supply == 0) {
            assertEq(total_assets, 0, "No shares = no assets");
            return;
        }

        // Total assets debe ser mayor o igual al supply (mayor si hay yield)
        assertGe(total_assets, total_supply, "Insolvencia del vault");
    }

    /**
     * @notice INVARIANT 2: Nadie puede tener más shares que totalSupply (total de shares emitidas)
     */
    function invariant_SharesCannotExceedSupply() public view {
        // Obtiene la lista de actores y el totalSupply del vault
        address[] memory actors = handler.getActors();
        uint256 total_supply = vault.totalSupply();

        // Recorre cada actor y comprueba que su balance de shares no excede el totalSupply
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 balance = vault.balanceOf(actors[i]);
            assertTrue(balance <= total_supply, "Un individuo no puede tener mas shares que el totalSupply");
        }
    }

    /**
     * @notice INVARIANT 3: La suma de todos los depósitos siempre debe ser >= suma de todos los retiros
     */
    function invariant_DepositWithdrawAccounting() public view {
        assertGe(handler.total_deposited(), handler.total_withdrawn(), "No puede haber mas retiros que depositos");
    }
}
