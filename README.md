# 执行命令
## 执行谋用例
forge test \                                                                                                                                   
  --fork-url https://api.zan.top/node/v1/bsc/testnet/e7f93263291b4a79a83a9b5c0fe72048 \
  --match-path test/token/yPUSD.security.t.sol \
  --match-test test_FlashLoan_EatYield_ByTiming \           
  -vv


forge test --fork-url "https://api.zan.top/node/v1/bsc/testnet/e7f93263291b4a79a83a9b5c0fe72048" --match-path test/token/yPUSD.security.t.sol --match-test test_FlashLoan_EatYield_ByTiming -vvv


forge test --fork-url "https://api.zan.top/node/v1/bsc/testnet/e7f93263291b4a79a83a9b5c0fe72048" --match-path test/Farm/Farm.security.t.sol  --match-test testStakePUSDAndCalculateReward -vvv


forge test --fork-url "https://api.zan.top/node/v1/bsc/testnet/e7f93263291b4a79a83a9b5c0fe72048" --match-path test/Farm/FarmLend.security.t.sol  --match-test test_stakePUSD_borrowWithNFT_triggerLiquidation -vvv

# 执行整个测试文件
forge test --fork-url "https://api.zan.top/node/v1/bsc/testnet/e7f93263291b4a79a83a9b5c0fe72048" --match-path test/Referral/ReferralReward.test.t.sol -vv