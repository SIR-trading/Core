# SIR Protocol

This repository generated with [Foundry](https://book.getfoundry.sh/) contains the core contract files of the SIR protocol.

## Deployment

The SIR protocol can be deployed using the Foundry script `script\DeployCore.s.sol`. This script will deploy all the necessary contracts and configure them to talk to each other.

## Ethereum Mainnet Addresses

| Contract Name     | Ethereum Mainnet Address                                                                                              |
| ----------------- | --------------------------------------------------------------------------------------------------------------------- |
| Vault.sol         | [0xb91ae2c8365fd45030aba84a4666c4db074e53e7](https://etherscan.io/address/0xb91ae2c8365fd45030aba84a4666c4db074e53e7) |
| SIR.sol           | [0x1278b112943abc025a0df081ee42369414c3a834](https://etherscan.io/address/0x1278b112943abc025a0df081ee42369414c3a834) |
| APE.sol           | [0x8E3a5ec5a8B23Fd169F38C9788B19e72aEd97b5A](https://etherscan.io/address/0x8E3a5ec5a8B23Fd169F38C9788B19e72aEd97b5A) |
| Oracle.sol        | [0x3CDCCFA37c1B2BEe3d810eC9dAddbB205048bB29](https://etherscan.io/address/0x3CDCCFA37c1B2BEe3d810eC9dAddbB205048bB29) |
| VaultExternal.sol | [0x80f18B12A6dBD515C5Ad01A2006abF30C5972158](https://etherscan.io/address/0x80f18B12A6dBD515C5Ad01A2006abF30C5972158) |
| SystemControl.sol | [0x8d694D1b369BdE5B274Ad643fEdD74f836E88543](https://etherscan.io/address/0x8d694D1b369BdE5B274Ad643fEdD74f836E88543) |

## License

The SIR protocol contracts are licensed under the MIT License with a few exceptions, as outlined below:

-   The `APE.sol` and `TEA.sol `contracts are a modification of the `ERC20` and `ERC1155` contracts from Solmate, which are licensed under the AGPL-3.0-only.
