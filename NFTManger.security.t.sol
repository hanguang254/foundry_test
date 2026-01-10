// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {FarmLend} from "src/Farm/FarmLend.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FarmUpgradeable} from "src/Farm/Farm.sol";
import {Farm_Deployer_Base} from "script/Farm/base/Farm_Deployer_Base.sol";
import {Vault} from "src/Vault/Vault.sol";
import {PUSDOracleUpgradeable} from "src/Oracle/PUSDOracle.sol";
import {NFTManager} from "src/token/NFTManager/NFTManager.sol";
import {FarmLend} from "src/Farm/FarmLend.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";

import {IFarm} from "src/interfaces/IFarm.sol";
import {yPUSD} from "src/token/yPUSD/yPUSD.sol";
import {MockChainlinkFeed} from "test/mocks/MockChainlinkFeed.sol";
import {IFarmLend} from "src/interfaces/IFarmLend.sol";


contract NFTManagerSecurityTest is Test{

    NFTManager  nftManager;
    FarmLend  farmLend;
    Vault  vault;
    PUSDOracleUpgradeable  oracle;
    FarmUpgradeable  farm;
    ERC20Mock  pusd;
    ERC20Mock  tusdt;
    yPUSD  ypusd;
    MockChainlinkFeed  pusdPriceFeed;
    MockChainlinkFeed  tusdtPriceFeed;
    
    address public admin = address(0xA11CE);
    address public user1 = address(0xCAFE);
    address public user2 = address(0xBEEF);
    address public user3 = address(0xDEAD);
    address public operator = address(0x0908);
    uint256 constant CAP = 1_000_000_000 * 1e6;
    uint256 constant INITIAL_BALANCE = 1_000_000 * 1e6;

    // 全局测试变量
    uint256 public lockPeriod = 30 days;
    uint256 public stakeAmount = 2000 * 1e6;
    uint256 public tokenId;
    uint256 public tokenId2;
    uint256 public tokenId3;

    bytes32 internal salt;

    // ✅ FIX: 用 ERC1967Proxy 部署并在构造时初始化
    function _deployProxy(address impl, bytes memory initData) internal returns (address proxyAddr) {
        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);
        proxyAddr = address(proxy);
    }

    function setUp() public {
        // 固定 salt（fork-safe）
        salt = keccak256("FARMLEND_SECURITY_TEST");

        // ========= 1) 部署依赖（只保留 PUSD 相关最小集合） =========

        
        // PUSD（要求：6 decimals + mint/burn）
        pusd = new ERC20Mock("Phoenix USD", "PUSD", 6);
        tusdt = new ERC20Mock("T USD", "USDT", 6);
        // yPUSD（Farm 只查询 balance，不影响 stake 测试）
        yPUSD ypusdImpl = new yPUSD();
        bytes memory ypusdInitData =
            abi.encodeWithSelector(yPUSD.initialize.selector, IERC20(address(pusd)), CAP, admin);
        ypusd = yPUSD(_deployProxy(address(ypusdImpl), ypusdInitData));

        // ========= 2) 部署 NFTManager（Proxy + initialize，farm 地址先传 0，后续会更新） =========
        NFTManager nftManagerImpl = new NFTManager();
        bytes memory nftManagerInitData =
            abi.encodeWithSelector(NFTManager.initialize.selector, "Phoenix Stake NFT", "PSN", admin, address(0));
        nftManager = NFTManager(_deployProxy(address(nftManagerImpl), nftManagerInitData));

        // ========= 3) 部署 Vault（Proxy + initialize，需要 nftManager 地址） =========
        Vault vaultImpl = new Vault();
        bytes memory vaultInitData =
            abi.encodeWithSelector(Vault.initialize.selector, admin, address(pusd), address(nftManager));
        vault = Vault(_deployProxy(address(vaultImpl), vaultInitData));

        // ========= 4) 部署 Farm（Proxy + initialize，需要 vault 地址） =========
        FarmUpgradeable farmImpl = new FarmUpgradeable();
        bytes memory farmInitData =
            abi.encodeWithSelector(FarmUpgradeable.initialize.selector, admin, address(pusd), address(ypusd), address(vault));
        farm = FarmUpgradeable(_deployProxy(address(farmImpl), farmInitData));

        
        
        // ========= 5) 部署 Oracle（Proxy + initialize） =========
        // Oracle（用于 Vault heartbeat）
        PUSDOracleUpgradeable oracleImpl = new PUSDOracleUpgradeable();
        bytes memory oracleInitData =
            abi.encodeWithSelector(PUSDOracleUpgradeable.initialize.selector, address(vault), address(pusd), admin);
        oracle = PUSDOracleUpgradeable(_deployProxy(address(oracleImpl), oracleInitData));

        

        // ========= 6) 配置 Vault（farm 地址 + oracleManager）=========
        vm.startPrank(admin);
        vault.setFarmAddress(address(farm));
        vault.setOracleManager(address(oracle));
        // 注意：FarmLend 地址稍后在部署 FarmLend 后设置（见第 15 步）
        vm.stopPrank();

        // ========= 7) 配置 NFTManager（设置 Farm 地址） =========
        vm.prank(admin);
        nftManager.setFarm(address(farm));

        // ========= 8) Farm 侧配置（角色、NFTManager、系统参数） =========
        vm.startPrank(admin);

        // 给 operator 权限（可选，但安全测试常用）
        farm.grantRole(farm.OPERATOR_ROLE(), operator);
        farm.grantRole(farm.PAUSER_ROLE(), operator);

        // 设置 NFTManager（必须）
        farm.setNFTManager(address(nftManager));

        vm.stopPrank();

        // ========= 9) 配置 lockPeriod multipliers（stakePUSD 必需） =========
        uint256[] memory lockPeriods = new uint256[](3);
        uint16[] memory multipliers = new uint16[](3);
        uint256[] memory caps = new uint256[](3);

        lockPeriods[0] = 5 days;
        lockPeriods[1] = 30 days;
        lockPeriods[2] = 180 days;

        multipliers[0] = 10000; // 1.0x
        multipliers[1] = 15000; // 1.5x
        multipliers[2] = 30000; // 3.0x

        caps[0] = 0;
        caps[1] = 0;
        caps[2] = 0;

        vm.prank(admin);
        farm.batchSetLockPeriodConfig(lockPeriods, multipliers, caps);

        // ========= 10) 配置系统参数（修正 minLockAmount 单位） =========
        vm.startPrank(admin);

        farm.updateSystemConfig(1, 100 * 1e6); // 100 PUSD（6 decimals）
        farm.updateSystemConfig(2, 50);
        uint16 currentAPY = farm.currentAPY();
        console.log(unicode"当前年化利率", currentAPY/100);

        vm.stopPrank();

        // ========= 11) 给用户准备 PUSD 余额 =========
        pusd.mint(user1, INITIAL_BALANCE);
        pusd.mint(user2, INITIAL_BALANCE);
        pusd.mint(user3, INITIAL_BALANCE);
        pusd.mint(operator, INITIAL_BALANCE);

        pusd.mint(admin, 5_000_000 * 1e6);

        // ========= 12) 给 Vault 充值 rewardReserve（必须） =========
        vm.startPrank(admin);
        pusd.approve(address(vault), type(uint256).max);
        vault.addRewardReserve(2_000_000 * 1e6);
        vm.stopPrank();

        // ========= 13) Vault heartbeat =========
        vm.prank(address(oracle));
        vault.heartbeat();

        // ========= 14) 部署 FarmLend（Proxy + initialize） =========
        FarmLend farmLendImpl = new FarmLend();
        bytes memory farmLendInitData =
            abi.encodeWithSelector(FarmLend.initialize.selector, admin, address(nftManager), address(vault), address(oracle), address(farm));
        farmLend = FarmLend(_deployProxy(address(farmLendImpl), farmLendInitData));

        // ========= 15) 配置 Vault：设置 FarmLend 地址 =========
        vm.prank(admin);
        vault.setFarmLendAddress(address(farmLend));

        // ========= 16) 配置 FarmLend（角色、NFTManager、系统参数） =========
        vm.startPrank(admin);   
        farmLend.grantRole(farmLend.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        // ========= 17) 配置 Farm 和 FarmLend 之间的关联 =========
        vm.prank(admin);
        farm.setFarmLend(address(farmLend));

        // ========= 18) 配置 Oracle：添加价格源 =========
        // 创建 Mock Chainlink Feed for PUSD (1 PUSD = 1 USD)
        // Chainlink USD 价格 feed 通常使用 8 decimals，Oracle 会将其标准化为 18 decimals
        // 1 USD = 1e8 (8 decimals) → Oracle 标准化后 = 1e18 (18 decimals)
        pusdPriceFeed = new MockChainlinkFeed(int256(1e8), 8);
        
        // 在 Oracle 中添加 PUSD token
        vm.prank(admin);
        oracle.addToken(address(pusd), address(pusdPriceFeed), 24 hours);

        // 创建 Mock Chainlink Feed for USDT (1 USDT = 1 USD)
        tusdtPriceFeed = new MockChainlinkFeed(int256(1e8), 8);
        
        // 在 Oracle 中添加 USDT token
        vm.prank(admin);
        oracle.addToken(address(tusdt), address(tusdtPriceFeed), 24 hours);

        // ========= 19) 在 Vault 中添加 USDT 作为支持的资产 =========
        vm.prank(admin);
        vault.addAsset(address(tusdt), "Tether USD");

        // ========= 20) 给 Vault 充值 USDT 余额（用于借贷） =========
        tusdt.mint(address(vault), 10_000_000 * 1e6); // 1000万 USDT

        // ========= 21) 配置 FarmLend：设置允许的债务 token =========
        vm.prank(admin);
        farmLend.setAllowedDebtToken(address(pusd), true);
        vm.prank(admin);
        farmLend.setAllowedDebtToken(address(tusdt), true);
    }
}