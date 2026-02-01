# Yield Vault Educational Project

ERC4626 Vault que deposita WETH en Aave v3 para generar yield automático. Proyecto educativo con testing exhaustivo (unit, fuzz, integration, invariant).

## ⚡ Quick Start

### Tests Básicos

```bash
# Unit tests (rápido, sin fork)
forge test --match-path test/unit/AaveVaultUnit.t.sol -vv

# Fuzz tests
forge test --match-path test/fuzz/AaveVaultFuzz.t.sol -vv
```

### Tests de Invariantes (Anti-Rate-Limit)

```bash
cd invariant-testing
./run_invariants_offline.sh
```

**Resultado esperado (~40s)**:

```
✓ TESTS PASADOS ✓
• Solvencia: OK
• Integridad: OK
Total: 32 runs × 15 depth = 480 calls
```

📖 **Documentación completa**: [`invariant-testing/invariant_tests_doc.md`](./invariant-testing/invariant_tests_doc.md)

## 🏗️ Arquitectura

### Contrato Principal

**[`AaveVault.sol`](./src/AaveVault.sol)** - ERC4626 Vault con integración Aave v3

- ✅ Yield generation automático depositando en Aave
- ✅ Circuit breakers (pause, maxTVL)
- ✅ Emergency withdraw
- ✅ Compatible con ERC4626 standard

### Suite de Testing

| Tipo            | Archivo                                                                       | Comando                                                       | Descripción                   |
| --------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------- | ----------------------------- |
| **Unit**        | [`AaveVaultUnit.t.sol`](./test/unit/AaveVaultUnit.t.sol)                      | `forge test --match-path test/unit/*`                         | Testing aislado de funciones  |
| **Fuzz**        | [`AaveVaultFuzz.t.sol`](./test/fuzz/AaveVaultFuzz.t.sol)                      | `forge test --match-path test/fuzz/*`                         | Testing con inputs aleatorios |
| **Integration** | [`AaveVaultIntegration.t.sol`](./test/integration/AaveVaultIntegration.t.sol) | `forge test --match-path test/integration/* --fork-url <RPC>` | Testing con Aave real (fork)  |
| **Invariant**   | [`AaveVaultInvariants.t.sol`](./test/invariant/AaveVaultInvariants.t.sol)     | `cd invariant-testing && ./run_invariants_offline.sh`         | Stateful fuzzing              |

## 🔒 Invariantes Validados

### 1. Solvencia del Protocolo

```solidity
totalAssets() >= convertToAssets(totalSupply())
```

El vault siempre puede cubrir el valor de todas las shares emitidas.

### 2. Integridad de Activos

```solidity
totalAssets() == WETH.balanceOf(vault) + aWETH.balanceOf(vault)
```

El balance reportado coincide exactamente con la suma física de assets.

## 📁 Estructura del Proyecto

```
yield-vault-edu/
├── src/
│   └── AaveVault.sol                    # Contrato principal ERC4626
├── test/
│   ├── unit/AaveVaultUnit.t.sol         # Unit tests
│   ├── fuzz/AaveVaultFuzz.t.sol         # Fuzz tests
│   ├── integration/
│   │   └── AaveVaultIntegration.t.sol   # Integration tests (fork)
│   └── invariant/
│       ├── AaveVaultInvariants.t.sol    # Invariant tests
│       └── Handler.t.sol                # Fuzzer handler
├── invariant-testing/
│   ├── run_invariants_offline.sh        # Script anti-rate-limit
│   └── invariant_tests_doc.md           # Documentación completa
├── foundry.toml                         # Configuración de Foundry
└── README.md                            # Este archivo
```

## 🛠️ Setup

### Instalación

```bash
# Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Dependencias del proyecto
forge install
```

### Build

```bash
forge build
```

## 🧪 Testing

### Todos los Tests (sin fork)

```bash
forge test --no-match-path "test/integration/*|test/invariant/*" -vv
```

### Tests con Fork

```bash
# Integration tests (requiere RPC)
forge test --match-path test/integration/AaveVaultIntegration.t.sol \
  --fork-url https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY -vv

# Invariant tests (usa script anti-rate-limit)
cd invariant-testing
./run_invariants_offline.sh -r 32  # 32 runs (configurable)
```

### Opciones del Script de Invariantes

```bash
# Ver ayuda
./run_invariants_offline.sh -h

# Más runs (más exhaustivo)
./run_invariants_offline.sh -r 64

# Bloque custom de fork
./run_invariants_offline.sh -b 10200000

# Ambos
./run_invariants_offline.sh -r 128 -b 10200000
```

## 📊 Gas Optimization

Configuración en [`foundry.toml`](./foundry.toml):

```toml
[profile.default]
optimizer = true
optimizer_runs = 200
via_ir = true  # Optimización vía-IR
```

### Gas Snapshots

```bash
forge snapshot
```

## 🐛 Troubleshooting

### Error: HTTP 429 en Invariant Tests

**Solución**: Usa el script anti-rate-limit:

```bash
cd invariant-testing
./run_invariants_offline.sh
```

❌ **NO** uses `forge test --match-path test/invariant/*` directamente (fallará con 429)

### Error: Port 8545 Already in Use

```bash
pkill -f anvil
```

### Tests Fallan: "Insufficient Liquidity"

Usa un bloque más reciente:

```bash
cd invariant-testing
./run_invariants_offline.sh -b <NUEVO_BLOQUE>
```

## 📚 Documentación

- **Testing de Invariantes**: [`invariant-testing/invariant_tests_doc.md`](./invariant-testing/invariant_tests_doc.md)
- **Foundry Book**: https://book.getfoundry.sh/
- **ERC4626 Spec**: https://eips.ethereum.org/EIPS/eip-4626
- **Aave v3 Docs**: https://docs.aave.com/developers/

## 📝 Comandos Útiles

### Testing

```bash
forge test                           # Todos los tests
forge test -vvv                      # Verbosidad alta
forge test --match-test testName     # Test específico
forge test --gas-report              # Reporte de gas
```

### Build & Format

```bash
forge build                          # Compila
forge fmt                            # Formatea
forge clean                          # Limpia artifacts
```

### Blockchain Interaction

```bash
anvil                                # Nodo local
cast call <address> <sig>            # Call (read-only)
cast send <address> <sig>            # Send (write)
cast block-number --rpc-url <RPC>   # Bloque actual
```

## 📄 Licencia

MIT

---

**Proyecto educativo de Solidity + Foundry + Aave v3**
