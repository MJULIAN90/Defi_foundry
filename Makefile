
.PHONY: install

i_foundry:; forge init --force

i_chainlink:; forge install smartcontractkit/chainlink-brownie-contracts

i_solmate:; forge install transmissions11/solmate

i_foundry_dev:; forge install Cyfrin/foundry-devops

i_openzeppelin:; forge install openzeppelin/openzeppelin-contracts