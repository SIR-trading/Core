## Deployment to Testnet

To deploy Core run `forge script script/DeployCore.s.sol --rpc-url tarp_testnet --broadcast -vv`.

## Cast contract interface

1. Edit out/contract_name.sol/contract_name.json to only contain the ABI array
2. Call `cast interface -n I{contract_name} -o src/interfaces/I{contract_name}.sol out/{contract_name}.sol/{contract_name}.json`
