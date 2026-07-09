# Hardhat local + frontend HTML minimo

Proyecto reducido al minimo para interactuar con `SimpleToken` en red local de Hardhat.

## Requisitos

- Node.js 18+
- npm 9+
- MetaMask

## Instalacion

```bash
npm install
```

## Flujo rapido

1. Levanta el nodo local de Hardhat:

```bash
npm run node
```

2. En otra terminal, despliega el contrato al nodo local:

```bash
npm run deploy:local
```

3. Levanta el frontend estatico:

```bash
npm run front
```

4. Abre en el navegador:

```text
http://127.0.0.1:5500
```

5. En la pagina:

- Conecta MetaMask
- Cambia a red Hardhat (chainId 31337)
- Carga el ultimo deploy
- Usa refresh, transfer y mint

## Scripts

- `npm run compile`: compila contratos
- `npm test`: ejecuta tests
- `npm run node`: inicia red local Hardhat
- `npm run deploy`: deploy en red temporal en memoria
- `npm run deploy:local`: deploy contra localhost:8545
- `npm run front`: servidor HTTP del frontend

## Nota MetaMask

Para firmar en local, importa en MetaMask una clave privada de las cuentas que imprime `npm run node`.
