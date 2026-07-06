# PoC — ERC-7943 uRWA (Universal Real World Asset)

Skeleton de un proyecto Hardhat en TypeScript como punto de partida para implementar el estándar [ERC-7943](https://eips.ethereum.org/EIPS/eip-7943).

## Requisitos

- [Node.js](https://nodejs.org/) v18 o superior
- npm v9 o superior

## Instalación

```bash
npm install
```

## Comandos

### Compilar contratos

```bash
npm run compile
```

### Correr los tests

```bash
npm test
```

### Levantar la red local de Hardhat

Inicia un nodo JSON-RPC local en `http://127.0.0.1:8545` con 20 cuentas prefinanciadas. Útil para conectar MetaMask o herramientas externas.

```bash
npm run node
```

### Deploy en la red local de Hardhat

**Opción A — red efímera en memoria** (sin nodo corriendo, más rápido):

```bash
npm run deploy
```

**Opción B — contra el nodo local** (requiere `npm run node` corriendo en otra terminal):

```bash
npm run deploy:local
```

## Estructura del proyecto

```
├── contracts/
│   └── SimpleToken.sol       # Placeholder ERC-20. Aquí se implementará ERC-7943
├── scripts/
│   └── deploy.ts             # Script de deploy
├── test/
│   └── SimpleToken.test.ts   # Tests del contrato
├── .env.example              # Variables de entorno para redes live
├── hardhat.config.ts
├── package.json
└── tsconfig.json
```

## Deploy en una red live (opcional)

1. Copia `.env.example` a `.env`:

   ```bash
   cp .env.example .env
   ```

2. Rellena `PRIVATE_KEY` y `RPC_URL` en el archivo `.env`.

3. Descomenta la red correspondiente en `hardhat.config.ts` (por ejemplo `sepolia`).

4. Ejecuta el deploy indicando la red:

   ```bash
   npx hardhat run scripts/deploy.ts --network sepolia
   ```

## Próximos pasos

- Agregar la interfaz `IERC7943Fungible` en `contracts/interfaces/`
- Extender `SimpleToken` implementando las funciones del estándar: `canSend`, `canReceive`, `canTransfer`, `getFrozenTokens`, `setFrozenTokens`, `forcedTransfer`
- Ampliar los tests para cubrir los casos de compliance del ERC-7943
