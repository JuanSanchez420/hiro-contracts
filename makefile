fork:
	anvil --fork-url https://rpc.ankr.com/base/3ec8a99c8d8a9f1d4b41cbbd6849bd882e7af57f597634fd1f39c6cb5986656f

deploy:
	forge script script/Deploy.s.sol:Deploy --fork-url http://127.0.0.1:8545 --broadcast --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266