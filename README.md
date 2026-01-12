# [foundry](https://getfoundry.sh/)

# 执行命令
## 执行谋用例
forge test \                                                                                                                                   
  --fork-url rpc_url \
  --match-path test/token/yPUSD.security.t.sol \
  --match-test test_FlashLoan_EatYield_ByTiming \           
  -vv


forge test --fork-url "rpc_url" --match-path test/token/yPUSD.security.t.sol --match-test test_FlashLoan_EatYield_ByTiming -vvv


forge test --fork-url "rpc_url" --match-path test/Farm/Farm.security.t.sol  --match-test testStakePUSDAndCalculateReward -vvv


forge test --fork-url "rpc_url" --match-path test/Farm/FarmLend.security.t.sol  --match-test test_stakePUSD_borrowWithNFT_triggerLiquidation -vvv

# 执行整个测试文件
forge test --fork-url "rpc_url" --match-path test/Referral/ReferralReward.test.t.sol -vv