## Testing

To run tests successfully run `forge test --ffi`

## Deployment to Testnet

To deploy Core run `forge script script/DeployCore.s.sol --rpc-url tarp_testnet --broadcast -vv`.

## Cast contract interface

1. Edit out/contract_name.sol/contract_name.json to only contain the ABI array
2. Call `cast interface -n I{contract_name} -o src/interfaces/I{contract_name}.sol out/{contract_name}.sol/{contract_name}.json`

## Impersonate Binance hot wallet in Anvil to get some tokens

`cast rpc anvil_impersonateAccount 0xF977814e90dA44bFA03b6295A0616a897441aceC --rpc-url tarp_testnet`
`cast send 0xdAC17F958D2ee523a2206206994597C13D831ec7 --from 0xF977814e90dA44bFA03b6295A0616a897441aceC "transfer(address,uint256)(bool)" 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc 10000000000 --unlocked --rpc-url tarp_testnet`
