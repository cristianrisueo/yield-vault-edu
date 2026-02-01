// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {IAToken} from "@aave/contracts/interfaces/IAToken.sol";
import {IPoolDataProvider} from "@aave/contracts/interfaces/IPoolDataProvider.sol";

/**
 * @title AaveVault
 * @author cristianrisueo
 * @notice Vault ERC4626 que deposita WETH en Aave v3 para generar yield
 * @dev Implementa circuit breakers y emergency withdraw para máxima seguridad en caso
 *      de error/hack en Aave. No debería ser necesario pero mejor prevenir que curar
 */
contract AaveVault is ERC4626, Ownable, Pausable {
    //* library attachments

    /**
     * @notice Usa SafeERC20 para todas las operaciones de IERC20 de manera segura
     * @dev Evita errores comunes con tokens legacy o mal implementados
     */
    using SafeERC20 for IERC20;

    //* Errores

    /**
     * @notice Error lanzado cuando se intenta depositar una cantidad cero en el vault
     */
    error AaveVault__ZeroAmount();

    /**
     * @notice Error lanzado cuando el TVL máximo del vault es excedido
     * @dev Ponemos límite al TVL del vault como medida de seguridad por si
     *      Aave tuviera problemas de liquidez
     */
    error AaveVault__MaxTVLExceeded();

    /**
     * @notice Error lanzado cuando Aave no tiene suficiente liquidez para un withdraw
     */
    error AaveVault__AaveLiquidityInsufficient();

    /**
     * @notice Error lanzado cuando el depósito en Aave falla
     */
    error AaveVault__DepositFailed();

    /**
     * @notice Error lanzado cuando el retiro de Aave falla
     */
    error AaveVault__WithdrawFailed();

    //* Eventos

    /**
     * @notice Evento lanzado cuando un usuario deposita assets en el vault
     * @param user Dirección del usuario que realiza el depósito
     * @param assets Cantidad de assets depositados
     * @param shares Cantidad de shares mintadas al usuario
     */
    event Deposited(address indexed user, uint256 assets, uint256 shares);

    /**
     * @notice Evento lanzado cuando un usuario retira assets del vault
     * @param user Dirección del usuario que realiza el retiro
     * @param assets Cantidad de assets retirados
     * @param shares Cantidad de shares quemadas del usuario
     */
    event Withdrawn(address indexed user, uint256 assets, uint256 shares);

    /**
     * @notice Evento lanzado cuando se realiza un retiro de emergencia de aTokens
     * @param receiver Dirección que recibe los aTokens
     * @param aTokenAmount Cantidad de aTokens retirados
     */
    event EmergencyWithdraw(address indexed receiver, uint256 aTokenAmount);

    /**
     * @notice Evento lanzado cuando se actualiza el máximo TVL permitido del vault
     * @param oldMax Valor antiguo del máximo TVL
     * @param newMax Nuevo valor del máximo TVL
     */
    event MaxTVLUpdated(uint256 oldMax, uint256 newMax);

    /**
     * @notice Evento lanzado cuando Aave tiene una crisis de liquidez
     */
    event AaveLiquidityCrisis();

    /**
     * @notice Evento lanzado cuando se ejecuta un emergency exit
     * @param caller Dirección que ejecuta el emergency exit
     * @param amount_withdrawn Cantidad de assets retirados
     */
    event EmergencyExit(address indexed caller, uint256 amount_withdrawn);

    //* Variables de estado

    /// @notice Instancia del Pool de Aave
    IPool public immutable aavePool;

    /// @notice Token que representa los assets depositados en Aave
    IAToken public immutable aToken;

    /// @notice Máximo TVL permitido en el vault (en WETH)
    uint256 public maxTVL;

    //* Constructor

    /**
     * @notice Constructor del AaveVault
     * @dev Inicializa el vault con el asset subyacente y configura los contratos Aave
     * @param _asset Dirección del token subyacente (WETH)
     * @param _aavePool Dirección del Pool de Aave v3
     */
    constructor(address _asset, address _aavePool)
        ERC4626(IERC20(_asset))
        ERC20("Aave Vault WETH", "avWETH")
        Ownable(msg.sender)
    {
        // Asigna las variables immutable
        aavePool = IPool(_aavePool);

        // Obtiene la dirección del aToken dinámicamente desde Aave Pool
        address aTokenAddress = aavePool.getReserveData(_asset).aTokenAddress;
        aToken = IAToken(aTokenAddress);

        // Setea un TVL máximo inicial (circuit breaker)
        maxTVL = 100 ether;

        // Allowance infinito de WETH al Aave Pool (Permite a Aave mover todo el WETH necesario del vault)
        IERC20(asset()).forceApprove(address(aavePool), type(uint256).max);
    }

    //* Funciones internas de integración con Aave

    /**
     * @notice Deposita assets en Aave Pool
     * @dev Función interna que centraliza la lógica de supply a Aave
     * @dev Transfiere tokens del usuario al vault y hace supply a Aave
     * @param assets Cantidad de assets a depositar en Aave
     */
    function _depositToAave(uint256 assets) internal {
        // Transfiere el WETH del usuario al vault
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        // Hace supply de WETH a Aave (recibe aWETH 1:1 inicialmente). Si algo falla, revertimos
        try aavePool.supply(asset(), assets, address(this), 0) {}
        catch {
            revert AaveVault__DepositFailed();
        }
    }

    /**
     * @notice Retira assets de Aave Pool
     * @dev Función interna que centraliza la lógica de withdraw de Aave
     * @dev Retira de Aave al vault y luego transfiere al receiver
     * @param assets Cantidad de assets a retirar de Aave
     * @param receiver Dirección que recibirá los assets
     */
    function _withdrawFromAave(uint256 assets, address receiver) internal {
        // Withdraw de Aave. Quemamos aWETH y recibimos WETH (+yield) directo al vault
        try aavePool.withdraw(asset(), assets, address(this)) returns (uint256) {}
        catch {
            revert AaveVault__WithdrawFailed();
        }

        // Transferir WETH del vault al receiver
        IERC20(asset()).safeTransfer(receiver, assets);
    }

    //* Lógica principal: deposit, mint, withdraw y redeem

    /**
     * @notice Deposita WETH en Aave y mintea shares al usuario
     * @dev Override de ERC4626.deposit()
     * @dev La diferencia con mint() es que aquí se especifica la cantidad de assets que
     *      se quieren depositar, en lugar de la cantidad de shares que se quieren recibir
     * @param assets Cantidad de WETH a depositar
     * @param receiver Dirección que recibirá las shares
     * @return shares Cantidad de shares mintadas al usuario
     */
    function deposit(uint256 assets, address receiver) public override whenNotPaused returns (uint256 shares) {
        // Comprueba que no se deposite 0 WETH
        if (assets == 0) revert AaveVault__ZeroAmount();

        // Comprueba que no se exceda el max TVL del vault
        if (totalAssets() + assets > maxTVL) {
            revert AaveVault__MaxTVLExceeded();
        }

        // Calcula las shares a mintear por el depósito. Se hace antes de mover fondos para evitar reentrancy
        shares = previewDeposit(assets);

        // Deposita en Aave usando función interna
        _depositToAave(assets);

        // Mintea las shares calculadas previamente al receiver
        _mint(receiver, shares);

        // Emite evento de depósito en el vault y retorna las shares mintadas
        emit Deposited(receiver, assets, shares);
    }

    /**
     * @notice Mintea shares exactas y deposita los WETH necesarios en Aave
     * @dev Override de ERC4626.mint().
     * @dev La diferencia con deposit() es que aquí se especifica la cantidad de shares que
     *      se quieren recibir, en lugar de la cantidad de assets que se quieren depositar
     * @param shares Cantidad de shares a mintear
     * @param receiver Dirección que recibirá las shares
     * @return assets Cantidad de WETH depositados
     */
    function mint(uint256 shares, address receiver) public override whenNotPaused returns (uint256 assets) {
        // Comprueba que no se minteen 0 shares
        if (shares == 0) revert AaveVault__ZeroAmount();

        // Calcula cuántos assets se necesitan para mintear esas shares
        assets = previewMint(shares);

        // Comprueba que no se exceda el max TVL del vault
        if (totalAssets() + assets > maxTVL) {
            revert AaveVault__MaxTVLExceeded();
        }

        // Deposita en Aave usando función interna
        _depositToAave(assets);

        // Mintea las shares solicitadas al receiver
        _mint(receiver, shares);

        // Emite evento de depósito en el vault y retorna los assets depositados
        emit Deposited(receiver, assets, shares);
    }

    /**
     * @notice Retira WETH de Aave y quema shares del usuario
     * @dev Override de ERC4626.withdraw()
     * @dev la diferencia con redeem() es que aquí se especifica la cantidad de assets
     *      a retirar mientras que en redeem() se especifica la cantidad de shares a quemar
     * @param assets Cantidad de WETH a retirar
     * @param receiver Dirección que recibirá el WETH retirado
     * @param owner Dirección dueña de las shares a quemar
     * @return shares Cantidad de shares quemadas del usuario
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        returns (uint256 shares)
    {
        // Comprueba que no se retire 0 WETH
        if (assets == 0) revert AaveVault__ZeroAmount();

        // Comprueba la liquidez disponible en Aave
        uint256 aaveAvailableLiquidity = IERC20(asset()).balanceOf(address(aToken));

        // Si Aave no tiene suficiente liquidez, revertimos (y que Dios nos pille confesados)
        if (aaveAvailableLiquidity < assets) {
            emit AaveLiquidityCrisis();
            revert AaveVault__AaveLiquidityInsufficient();
        }

        // Calcula las shares a quemar
        shares = previewWithdraw(assets);

        // Comprueba allowance si el owner no es el msg.sender
        // Allowance = owner permite a msg.sender quemar sus shares
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Quemar shares antes de retirar de Aave (previene reentrancy)
        _burn(owner, shares);

        // Retira de Aave usando función interna
        _withdrawFromAave(assets, receiver);

        // Emite evento de retiro del vault y retorna las shares quemadas
        emit Withdrawn(receiver, assets, shares);
    }

    /**
     * @notice Quema shares y retira WETH de Aave
     * @dev Override de ERC4626.redeem()
     * @dev la diferencia con withdraw() es que aquí se especifica la cantidad de shares
     *      a quemar mientras que en withdraw() se especifica la cantidad de assets a retirar
     * @param shares Cantidad de shares a quemar
     * @param receiver Dirección que recibirá el WETH retirado
     * @param owner Dirección dueña de las shares a quemar
     * @return assets Cantidad de WETH retirada
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotPaused
        returns (uint256 assets)
    {
        // Comprueba que no se quemen 0 shares
        if (shares == 0) revert AaveVault__ZeroAmount();

        // Calcula los assets a retirar según las shares
        assets = previewRedeem(shares);

        // Comprueba la liquidez disponible en Aave
        uint256 aaveAvailableLiquidity = IERC20(asset()).balanceOf(address(aToken));

        // Si Aave no tiene suficiente liquidez, revertimos
        if (aaveAvailableLiquidity < assets) {
            emit AaveLiquidityCrisis();
            revert AaveVault__AaveLiquidityInsufficient();
        }

        // Comprueba allowance si el owner no es el msg.sender
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Quemar shares antes de retirar de Aave (previene reentrancy)
        _burn(owner, shares);

        // Retira de Aave usando función interna
        _withdrawFromAave(assets, receiver);

        // Emite evento de retiro del vault y retorna los assets retirados
        emit Withdrawn(receiver, assets, shares);
    }

    //* Lógica secundaria: overrides de ERC4626 para calcular TVL y límites de depósito/retiro

    /**
     * @notice Calcula total de assets en WETH
     * @dev Los aTokens en Aave v3 hacen rebase automático, por lo que aToken.balanceOf()
     *      ya devuelve el balance actualizado con yield incluido. No necesitamos
     *      multiplicar por liquidityIndex
     * @return Total WETH depositado + yield generado
     */
    function totalAssets() public view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /**
     * @notice Máximo que se puede depositar (circuit breaker)
     * @dev address es un parámetro ignorado (requerido por ERC4626)
     * @return Cantidad máxima de WETH que se puede depositar todavía
     */
    function maxDeposit(address) public view override returns (uint256) {
        // Si el vault está pausado, no se puede depositar
        if (paused()) return 0;

        // Calcula cuánto queda hasta el max TVL
        uint256 currentTVL = totalAssets();
        if (currentTVL >= maxTVL) return 0;

        // Devuelve cuánto queda para llegar al max TVL
        return maxTVL - currentTVL;
    }

    /**
     * @notice Máximo que se puede retirar (limitado por liquidez de Aave)
     * @dev Esto es un circuit breaker que no va a ocurrir nunca en condiciones normales
     * @param owner Dirección del usuario que quiere retirar
     * @return Cantidad máxima de WETH que se puede retirar
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        // Si el vault está pausado, no se puede retirar
        if (paused()) return 0;

        // Obtiene liquidez disponible en Aave
        uint256 aaveAvailableLiquidity = IERC20(asset()).balanceOf(address(aToken));

        // Calcula los assets del usuario a partir de sus shares
        uint256 userAssets = convertToAssets(balanceOf(owner));

        // Retornar el menor entre: assets del usuario y liquidez disponible en Aave
        return userAssets < aaveAvailableLiquidity ? userAssets : aaveAvailableLiquidity;
    }

    //* Funciones de emergencia y administración que solo puede usar el owner

    /**
     * @notice Pausa deposits/withdraws
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Despausa deposits/withdraws
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Actualiza el max TVL del vault
     * @param newMaxTVL Nuevo máximo TVL en WETH
     */
    function setMaxTVL(uint256 newMaxTVL) external onlyOwner {
        emit MaxTVLUpdated(maxTVL, newMaxTVL);
        maxTVL = newMaxTVL;
    }

    /**
     * @notice Pausa el protocolo y retira todos los fondos de Aave
     * @dev Solo puede ser llamado por el owner en caso de emergencia. Pausa el vault para
     *      prevenir nuevos deposits y retira todos los fondos de Aave ya convertidos a WETH
     * @dev Esta función se realiza en caso de bug en nuestro contrato más que en Aave
     *      probablemente se use antes que emergencyWithdraw() en caso de bug en nuestro contrato
     */
    function emergencyExit() external onlyOwner whenNotPaused {
        // Pausa el vault
        _pause();

        // OBtiene el balance de aToken del vault en Aave
        uint256 aave_balance = aToken.balanceOf(address(this));

        // Hace withdraw de todo el WETH correspondiente a aToken (WETH + yield)
        if (aave_balance > 0) {
            aavePool.withdraw(asset(), aave_balance, address(this));
        }

        // Emite evento de emergency exit
        emit EmergencyExit(msg.sender, aave_balance);
    }

    /**
     * @notice Envía WETH y aWETH directamente del contracto a un usuario
     * @dev Esta función se realiza en caso de bug en Aave que impida hacer withdraw normalmente
     *      Solo usar si Aave.withdraw() falla permanentemente. Con lo que este contrato queda inutilizado
     *      y los usuarios no podrán retirar sus fondos, o en fallo de seguridad en nuestro contrato
     *      que exija retirar los fondos a un lugar seguro. Si lo usas para rug pull, que dios te juzgue
     * @param receiver Dirección que recibirá los tokens WETH y aWETH
     */
    function emergencyWithdraw(address receiver) external onlyOwner whenPaused {
        // Primero envía todo el aToken disponible en el vault
        uint256 aTokenBalance = aToken.balanceOf(address(this));
        aToken.transfer(receiver, aTokenBalance);

        // Luego envía todo el WETH disponible en el vault
        uint256 wethBalance = IERC20(asset()).balanceOf(address(this));
        IERC20(asset()).safeTransfer(receiver, wethBalance);

        // Emite evento de emergency withdraw
        emit EmergencyWithdraw(receiver, aTokenBalance);
    }

    //* Funciones públicas de consulta

    /**
     * @notice APY actual de Aave (en basis points, ej: 500 = 5%)
     * @return APY actual de Aave sobre WETH en basis points
     */
    function getAaveAPY() external view returns (uint256) {
        // Aave usa RAY, su propia unidad (1e27), convertimos a basis points (1e4)
        uint256 liquidityRate = aavePool.getReserveData(asset()).currentLiquidityRate;
        return (liquidityRate * 10000) / 1e27;
    }

    /**
     * @notice Liquidez disponible en Aave (WETH no prestado)
     * @return Cantidad de WETH disponible en Aave para withdraw
     */
    function availableLiquidity() external view returns (uint256) {
        return IERC20(asset()).balanceOf(address(aToken));
    }

    /**
     * @notice Balance de aWETH del vault
     * @return Cantidad de aWETH que posee el vault en Aave
     */
    function getATokenBalance() external view returns (uint256) {
        return aToken.balanceOf(address(this));
    }
}
