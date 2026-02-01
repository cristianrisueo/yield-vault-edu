# Invariant Testing - Documentación

## Problema

Los tests de invariantes con fork de Sepolia generan **errores HTTP 429** (rate limit) porque cada run del fuzzer realiza múltiples llamadas RPC a Alchemy, agotando rápidamente el free tier.

## Solución

Sistema de rate limiting controlado en Anvil que permite ejecutar tests de invariantes con bytecode real de Aave sin exceder límites de RPC.

## Arquitectura

```
1. Anvil con rate limiting
   └─> --compute-units-per-second 10 (controla llamadas RPC)
   └─> --timeout 120000ms (espera larga para delays)

2. Warmup del cache
   └─> Ejecuta test de integración simple
   └─> Foundry cachea contratos en ~/.foundry/cache

3. Fuzzing con runs configurables
   └─> 32 runs × 15 depth = 480 llamadas (default)
   └─> Usa cache para minimizar RPC calls

4. Cleanup automático
   └─> Mata procesos Anvil
   └─> Elimina archivos temporales
```

## Uso

### Básico

```bash
cd invariant-testing
./run_invariants_offline.sh
```

**Salida esperada (~40s)**:
```
╔════════════════════════════════════════════════════╗
║              ✓ TESTS PASADOS ✓                    ║
╠════════════════════════════════════════════════════╣
║  • Solvencia: OK                                  ║
║  • Integridad: OK                                 ║
║  • Total: 32 runs × 15 depth = 480 calls          ║
╚════════════════════════════════════════════════════╝
```

### Con Opciones

```bash
# Más runs (más exhaustivo)
./run_invariants_offline.sh -r 64

# Bloque custom
./run_invariants_offline.sh -b 10200000

# Ambos
./run_invariants_offline.sh -r 128 -b 10200000

# Ver ayuda
./run_invariants_offline.sh -h
```

## Invariantes Validados

### 1. Solvencia del Protocolo

**Propiedad**: El vault siempre puede cubrir el valor de todas las shares emitidas.

```solidity
invariant_ProtocolMustBeSolvent() {
    uint256 totalAssets = vault.totalAssets();
    uint256 totalSupply = vault.totalSupply();
    uint256 assetsBacked = vault.convertToAssets(totalSupply);

    assertGe(totalAssets + 10, assetsBacked);
}
```

**Qué valida**: `totalAssets() >= convertToAssets(totalSupply())`

### 2. Integridad de Activos

**Propiedad**: El balance reportado coincide con la suma física de balances.

```solidity
invariant_TotalAssetsEqualsUnderlying() {
    uint256 reportedAssets = vault.totalAssets();
    uint256 wethBalance = weth.balanceOf(address(vault));
    uint256 aWethBalance = aToken.balanceOf(address(vault));

    assertEq(reportedAssets, wethBalance + aWethBalance);
}
```

**Qué valida**: `totalAssets() == balanceOf(WETH) + balanceOf(aWETH)`

## Handler: Operaciones del Fuzzer

El [`Handler.t.sol`](../test/invariant/Handler.t.sol) restringe inputs aleatorios a valores válidos:

| Función | Descripción | Bounds |
|---------|-------------|--------|
| `deposit()` | Deposita WETH en el vault | 0.001 ETH - maxDeposit |
| `mint()` | Mintea shares del vault | 0.001 shares - maxMint |
| `withdraw()` | Retira WETH del vault | 0 - maxWithdraw |
| `redeem()` | Quema shares por WETH | 0 - balanceOf(user) |
| `generateYield()` | Simula yield donando aWETH | 0.1 - 50 ETH |

**Validaciones automáticas**:
- Respeta `maxTVL` del vault
- Skip si vault está pausado
- Limita retiros a liquidez disponible en Aave

## Configuración

### Parámetros del Script

Editables en [`run_invariants_offline.sh`](./run_invariants_offline.sh):

```bash
ALCHEMY_URL="https://eth-sepolia.g.alchemy.com/v2/YfrbfXNhnCGQkJeTMXPPi"
FORK_BLOCK="10164266"              # Bloque de Sepolia
INVARIANT_RUNS=32                  # Runs del fuzzer
INVARIANT_DEPTH=15                 # Depth por run
COMPUTE_UNITS_PER_SECOND=10        # Rate limiting
```

### Parámetros de Foundry

En [`foundry.toml`](../foundry.toml):

```toml
[profile.default]
invariant = { runs = 256, depth = 15 }  # Config original (override por script)
```

El script sobrescribe estos valores vía env vars para evitar rate limits.

## Actualizar Bloque de Fork

### Método 1: Flag en Ejecución (Recomendado)

```bash
./run_invariants_offline.sh -b <NUEVO_BLOQUE>
```

**Ejemplo**:
```bash
# Obtener bloque actual de Sepolia
cast block-number --rpc-url https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# Usar ese bloque
./run_invariants_offline.sh -b 10300000
```

### Método 2: Editar Script

Edita [`run_invariants_offline.sh`](./run_invariants_offline.sh) línea 41:

```bash
FORK_BLOCK="10300000"  # Cambiar este valor
```

### ¿Cuándo Actualizar el Bloque?

- **Contratos de Aave actualizados**: Nuevo deployment en Sepolia
- **Más liquidez**: Bloque con más actividad en Aave pool
- **Mainnet fork**: Cambiar a mainnet para yield real

```bash
# Para mainnet (requiere plan paid de Alchemy)
./run_invariants_offline.sh -b 18500000
# Y actualiza ALCHEMY_URL en el script a mainnet
```

## Troubleshooting

### Error: HTTP 429 (Aún con el Script)

**Causa**: Rate limit aún excedido (runs muy altos o CU/s muy agresivo).

**Solución**:
```bash
# Reducir runs
./run_invariants_offline.sh -r 16

# O editar script y reducir COMPUTE_UNITS_PER_SECOND a 5
```

### Error: Port 8545 Already in Use

**Causa**: Anvil anterior no se cerró correctamente.

**Solución**:
```bash
pkill -f anvil
./run_invariants_offline.sh
```

### Tests Fallan: "Insufficient Liquidity"

**Causa**: Bloque sin liquidez suficiente en Aave pool.

**Solución**:
```bash
# Usar bloque más reciente
cast block-number --rpc-url <YOUR_RPC>
./run_invariants_offline.sh -b <NUEVO_BLOQUE>
```

### Tests Pasan Local pero Fallan en CI

**Causa**: CI puede tener rate limits más estrictos.

**Solución**:
```bash
# En CI, usa runs reducidos
./run_invariants_offline.sh -r 8
```

## Estadísticas Típicas

Ejemplo de salida con 32 runs:

```
╭----------+---------------+-------+---------+----------╮
| Contract | Selector      | Calls | Reverts | Discards |
+=======================================================+
| Handler  | deposit       | 95    | 9       | 0        |
| Handler  | generateYield | 87    | 0       | 0        |
| Handler  | mint          | 92    | 82      | 0        |
| Handler  | redeem        | 97    | 0       | 0        |
| Handler  | withdraw      | 109   | 0       | 0        |
╰----------+---------------+-------+---------+----------╯
```

- **Calls**: Llamadas exitosas a la función
- **Reverts**: Llamadas que revirtieron (esperado, ej: mint sin assets)
- **Discards**: Inputs descartados (debe ser 0)

## Recursos

- [Foundry Invariant Testing](https://book.getfoundry.sh/forge/invariant-testing)
- [ERC4626 Spec](https://eips.ethereum.org/EIPS/eip-4626)
- [Aave v3 Docs](https://docs.aave.com/developers/)
