ANVIL_URL ?= http://127.0.0.1:8545
BASE_RPC  ?= https://rpc.ankr.com/base/3ec8a99c8d8a9f1d4b41cbbd6849bd882e7af57f597634fd1f39c6cb5986656f
CHAIN_ID ?= 31338
SENDER  ?= 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

# Foundry’s default 10 accounts (HD index 0..9)
ANVIL_ACCOUNTS := \
  0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266 \
  0x70997970c51812dc3a010c7d01b50e0d17dc79c8 \
  0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc \
  0x90f79bf6eb2c4f870365e785982e1f101e93b906 \
  0x15d34aaf54267db7d7c367839aaf71a00a2c6a65 \
  0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc \
  0x976ea74026e726554db657fa54763abd0c3a0aa9 \
  0x14dc79964da2c08b23698b3d3cc7ca32193d9955 \
  0x23618e81e3f5cdf7f54c3d65f7fbc0abf5b21e8f \
  0xa0ee7a142d267c1f36714e4a8f75612f20a79720

fork:
	@pkill -f "^anvil" >/dev/null 2>&1 || true
	@anvil --fork-url $(BASE_RPC) --chain-id $(CHAIN_ID) --host 127.0.0.1 --port 8545 & \
	ANVIL_PID=$$!; \
	until cast chain-id --rpc-url $(ANVIL_URL) >/dev/null 2>&1; do sleep 0.2; done; \
	for a in $(ANVIL_ACCOUNTS); do \
	  cast rpc anvil_setCode $$a 0x --rpc-url $(ANVIL_URL) >/dev/null; \
	done; \
	wait $$ANVIL_PID

deploy:
	forge script script/Deploy.s.sol:Deploy --fork-url $(ANVIL_URL) --chain-id $(CHAIN_ID)  --broadcast --unlocked --sender $(SENDER)

approve-factory:
	cast send 0x9852795dbb01913439f534b4984fBf74aC8AfA12 "approve(address,uint256)" 0xf274De14171Ab928A5Ec19928cE35FaD91a42B64 100000000000000000000 --rpc-url $(ANVIL_URL) --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

create-wallet:
	cast send 0xf274De14171Ab928A5Ec19928cE35FaD91a42B64 "createHiroWallet(uint256)" --rpc-url $(ANVIL_URL) --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80