fork:
	anvil --fork-url https://rpc.ankr.com/base/3ec8a99c8d8a9f1d4b41cbbd6849bd882e7af57f597634fd1f39c6cb5986656f

deploy:
	forge script script/Deploy.s.sol:Deploy --fork-url http://127.0.0.1:8545 --chain-id 31338  --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

approve-factory:
	cast send 0x9852795dbb01913439f534b4984fBf74aC8AfA12 "approve(address,uint256)" 0xf274De14171Ab928A5Ec19928cE35FaD91a42B64 100000000000000000000 --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

create-wallet:
	cast send 0xf274De14171Ab928A5Ec19928cE35FaD91a42B64 "createHiroWallet()" --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80