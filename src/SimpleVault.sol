// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SimpleVault
 * @author cristianrisueo
 * @notice Vault educativo ERC4626 para depositar WETH y recibir shares proporcionales
 *
 * ARQUITECTURA:
 * - Usuario deposita WETH → recibe shares (svWETH tokens)
 * - Shares representan % de ownership del pool total
 * - Yield inicial = 0 (viene de nuevos deposits, accounting puro)
 * - Withdraw = quema shares y devuelve WETH proporcional
 *
 * SEGURIDAD:
 * - Hereda ReentrancyGuard de ERC4626 (OpenZeppelin lo incluye)
 * - No tiene privileged functions que puedan robar fondos
 * - Todos los cálculos usan math de OpenZeppelin (safe de overflows)
 */
contract SimpleVault is ERC4626, Ownable {
    //* Errores

    /**
     * @notice Error lanzado cuando la cantidad de assets es cero
     */
    error SimpleVault__ZeroAmount();

    /**
     * @notice Error lanzado cuando el usuario no tiene suficientes shares
     */
    error SimpleVault__InsufficientShares();

    //* Eventos

    /**
     * @notice Evento lanzado cuando un usuario deposita WETH
     * @param user Dirección del usuario que depositó
     * @param assets Cantidad de WETH depositados
     * @param shares Cantidad de shares minteados
     */
    event Deposited(address indexed user, uint256 assets, uint256 shares);

    /**
     * @notice Evento lanzado cuando un usuario retira WETH
     * @param user Dirección del usuario que retiró
     * @param assets Cantidad de WETH retirados
     * @param shares Cantidad de shares quemados
     */
    event Withdrawn(address indexed user, uint256 assets, uint256 shares);

    //* Constructor

    /**
     * @notice Constructor del SimpleVault
     * @param _weth Dirección del token WETH (asset del vault)
     * @dev ERC4626 automáticamente inicializa el vault con WETH como asset subyacente
     * @dev ERC20 automáticamente inicializa el vault con nombre y símbolo de los shares
     */
    constructor(IERC20 _weth) ERC4626(_weth) ERC20("Simple Vault WETH", "svWETH") Ownable(msg.sender) {}

    //* Lógica principal del vault

    /**
     * @notice Deposita WETH y recibe shares proporcionales
     * @dev Usa la lógica de ERC4626.deposit() de OpenZeppelin
     * @param assets Cantidad de WETH a depositar
     * @param receiver Dirección que recibirá los shares
     * @return shares Cantidad de shares minteados
     *
     * CÁLCULO DE SHARES:
     * - Si es el primer deposit: shares = assets (ratio 1:1)
     * - Si ya hay deposits: shares = (assets * totalSupply) / totalAssets
     * - Sólo para aclarar: totalSupply = total shares minteado, totalAssets = total WETH en el vault
     * - Si alguien deposita WETH en el vault, totalSupply y totalAssets crecen de manera proporcional
     * - Si totalAssets crece sin que totalSupply crezca es porque se ha producido "yield" sobre el WETH
     * - del vault, por lo que cada share ahora vale más WETH
     *
     * EJEMPLO:
     * Pool tiene: 100 WETH, 100 shares
     * Usuario deposita: 10 WETH
     * Shares minteados: (10 * 100) / 100 = 10 shares
     */
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256 shares) {
        if (assets == 0) revert SimpleVault__ZeroAmount();

        shares = super.deposit(assets, receiver);

        emit Deposited(receiver, assets, shares);
    }

    /**
     * @notice Retira WETH quemando shares
     * @dev Usa la lógica de ERC4626.withdraw() de OpenZeppelin
     * @param assets Cantidad de WETH a retirar
     * @param receiver Dirección que recibirá el WETH
     * @param owner Dueño de los shares (debe aprobar si caller != owner)
     * @return shares Cantidad de shares quemados
     *
     * CÁLCULO:
     * Pool tiene: 110 WETH, 100 shares (alguien depositó 10 WETH extra = "yield")
     * Usuario tiene: 10 shares
     * Usuario retira: 11 WETH (su % del pool: 10/100 * 110 = 11)
     * Es la fórmula inversa a deposit() -> assets = (shares/totalSupply) * totalAssets
     * Shares quemados: 10
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override
        returns (uint256 shares)
    {
        if (assets == 0) revert SimpleVault__ZeroAmount();

        shares = super.withdraw(assets, receiver, owner);

        emit Withdrawn(receiver, assets, shares);
    }

    /**
     * @notice Retira todo el balance de un usuario
     * @dev Esta función la creamos nosotros, no es parte del standard ERC4626
     * @param receiver Dirección que recibirá el WETH
     * @return assets Cantidad de WETH retirados
     */
    function withdrawAll(address receiver) external returns (uint256 assets) {
        // Obtiene el balance de shares del usuario (balanceOf viene de ERC20)
        uint256 shares_to_burn = balanceOf(msg.sender);
        if (shares_to_burn == 0) revert SimpleVault__InsufficientShares();

        // redeem() quema shares y devuelve assets proporcionales al usuario
        assets = redeem(shares_to_burn, receiver, msg.sender);
    }

    //* Funciones view / pure sobrescritas

    /**
     * @notice Retorna el total de WETH en el vault
     * @dev Override de ERC4626.totalAssets()
     * @return Cantidad total de WETH en el vault
     */
    function totalAssets() public view virtual override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @notice Calcula cuánto WETH puede retirar un usuario
     * @param user Dirección del usuario
     * @return Cantidad de WETH disponible para withdraw
     */
    function maxWithdraw(address user) public view virtual override returns (uint256) {
        return convertToAssets(balanceOf(user));
    }
}
