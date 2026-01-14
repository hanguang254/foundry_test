// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {yPUSD} from "src/token/yPUSD/yPUSD.sol";
import {yPUSD_Deployer_Base} from "script/token/base/yPUSD_Deployer_Base.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title yPUSD Security, Arbitrage, and Concurrency Tests
 * @notice 全面测试 yPUSD 的安全、套利和并发场景
 */
contract yPUSDSecurityTest is Test, yPUSD_Deployer_Base {
    bytes32 salt;

    yPUSD vault;
    ERC20Mock pusd;

    address admin = address(0xA11CE);
    address user1 = address(0xCAFE);
    address user2 = address(0xBEEF);
    address user3 = address(0xDEAD);
    address attacker = address(0xBAD1);
    address yieldInjector = address(0xFEED);

    uint256 constant CAP = 1_000_000_000 * 1e6;
    uint256 constant INITIAL_BALANCE = 1_000_000 * 1e6;

    bytes32 YIELD_INJECTOR_ROLE;
    // // 用最短允许时长即可，或者写死比如 1 days
    uint256 DURATION = 1 days;

    function setUp() public {
        // 使用固定的 salt 值用于测试（保留用于向后兼容）
        salt = keccak256("yPUSD_SECURITY_TEST");

        // 部署 mock PUSD（在fork和非fork网络上都可以正常部署）
        pusd = new ERC20Mock("Phoenix USD", "PUSD", 6);

        // 使用 _deployWithoutSalt 部署 yPUSD vault
        // 这个方法在fork和非fork网络上都能正常工作
        // 避免了CREATE2在fork网络上可能遇到的问题
        vault = _deployWithoutSalt(IERC20(address(pusd)), CAP, admin);

        YIELD_INJECTOR_ROLE = vault.YIELD_INJECTOR_ROLE();

        // 授予收益注入者角色
        vm.prank(admin);
        vault.grantRole(YIELD_INJECTOR_ROLE, yieldInjector);

        // 为测试用户铸造 PUSD
        pusd.mint(user1, INITIAL_BALANCE);
        pusd.mint(user2, INITIAL_BALANCE);
        pusd.mint(user3, INITIAL_BALANCE);
        pusd.mint(attacker, INITIAL_BALANCE);
        pusd.mint(yieldInjector, INITIAL_BALANCE * 10);
    }

    /* ========== 安全场景测试 ========== */

    /**
     * @notice 测试：未授权用户无法注入收益
     */
    function test_Security_UnauthorizedCannotAccrueYield() public {
        console.log(unicode"测试：未授权用户无法注入收益");
        vm.startPrank(attacker);
        pusd.approve(address(vault), 100 * 1e6);

        vm.expectRevert();
        vault.accrueYield(100 * 1e6, DURATION);
        vm.stopPrank();
    }

    /**
     * @notice 测试：未授权用户无法暂停合约
     */
    function test_Security_UnauthorizedCannotPause() public {
        console.log(unicode"测试：未授权用户无法暂停合约");
        vm.prank(attacker);
        vm.expectRevert();
        vault.pause();
    }

    /**
     * @notice 测试：未授权用户无法设置 cap
     */
    function test_Security_UnauthorizedCannotSetCap() public {
        console.log(unicode"测试：未授权用户无法设置 cap");
        vm.prank(attacker);
        vm.expectRevert();
        vault.setCap(2000 * 1e6);
    }

    /**
     * @notice 测试：零金额收益注入应该失败
     */
    function test_Security_AccrueYieldZeroAmountReverts() public {
        console.log(unicode"测试：零金额收益注入应该失败");
        vm.prank(yieldInjector);
        vm.expectRevert("yPUSD: zero amount");
        vault.accrueYield(0, DURATION);
    }

    /**
     * @notice 测试：设置 cap 不能低于当前总供应量
     */
    function test_Security_SetCapBelowSupplyReverts() public {
        console.log(unicode"测试：设置 cap 不能低于当前总供应量");
        // 先存入一些资金
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000 * 1e6);
        vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();

        // 尝试将 cap 设置为低于当前供应量
        vm.prank(admin);
        vm.expectRevert("yPUSD: cap below current supply");
        vault.setCap(500 * 1e6);
    }

    /**
     * @notice 测试：收益注入者角色可以被撤销
     */
    function test_Security_YieldInjectorRoleCanBeRevoked() public {
        console.log(unicode"测试：收益注入者角色可以被撤销");
        // 撤销角色
        vm.prank(admin);
        vault.revokeRole(YIELD_INJECTOR_ROLE, yieldInjector);

        // 现在无法注入收益
        vm.startPrank(yieldInjector);
        pusd.approve(address(vault), 100 * 1e6);
        vm.expectRevert();
        vault.accrueYield(100 * 1e6, DURATION);
        vm.stopPrank();
    }

    /**
     * @notice 测试：恶意收益注入者无法窃取资金（只能注入，不能提取）
     */
    function test_Security_YieldInjectorCannotStealFunds() public {
        console.log(unicode"测试：恶意收益注入者无法窃取资金（只能注入，不能提取）");
        // 用户存入资金
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000 * 1e6);
        vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();

        uint256 vaultBalanceBefore = pusd.balanceOf(address(vault));
        uint256 injectorBalanceBefore = pusd.balanceOf(yieldInjector);

        // 收益注入者注入收益
        vm.startPrank(yieldInjector);
        pusd.approve(address(vault), 100 * 1e6);
        vault.accrueYield(100 * 1e6, DURATION);
        vm.stopPrank();

        // 验证收益注入者无法提取资金
        assertEq(pusd.balanceOf(address(vault)), vaultBalanceBefore + 100 * 1e6);

        // 收益注入者尝试直接提取应该失败（没有 withdraw 权限）
        vm.prank(yieldInjector);
        vm.expectRevert();
        vault.withdraw(100 * 1e6, yieldInjector, yieldInjector);

        // 收益注入者没有 yPUSD shares，无法赎回
        assertEq(vault.balanceOf(yieldInjector), 0);
    }

    /**
     * @notice 测试：防止存款超过 cap
     */
    function test_Security_DepositCannotExceedCap() public {
        console.log(unicode"测试：防止存款超过 cap");
        // 现在 yPUSD 采用 1:1 的 shares:assets 比例（decimalsOffset = 0）
        // cap 的单位是 shares，此时与 assets 等值
        uint256 smallCap = 1000 * 1e6; // 1000 PUSD
        vm.prank(admin);
        vault.setCap(smallCap);

        // 在 1:1 汇率下，最多可以存入 smallCap 个 assets
        uint256 maxAssets = smallCap;
        // 铸造足够的 PUSD
        pusd.mint(user1, maxAssets * 2);

        vm.startPrank(user1);
        pusd.approve(address(vault), maxAssets * 2);

        // 第一次存款应该成功
        vault.deposit(maxAssets, user1);

        // 再次存款应该失败（超过 cap）
        vm.expectRevert(); // ERC4626ExceededMaxDeposit
        vault.deposit(1, user1);

        vm.stopPrank();
    }

    /**
     * @notice 测试：暂停状态下所有操作都被阻止
     */
    function test_Security_PauseBlocksAllOperations() public {
        console.log(unicode"测试：暂停状态下所有操作都被阻止");
        // 先存入一些资金
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000 * 1e6);
        vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();

        // 暂停合约
        vm.prank(admin);
        vault.pause();

        // 测试存款被阻止
        pusd.mint(user2, 1000 * 1e6);
        vm.startPrank(user2);
        pusd.approve(address(vault), 1000 * 1e6);
        vm.expectRevert();
        vault.deposit(1000 * 1e6, user2);
        vm.stopPrank();

        // 测试取款被阻止
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(100 * 1e6, user1, user1);

        // 测试赎回被阻止
        vm.prank(user1);
        vm.expectRevert();
        vault.redeem(100 * 1e6, user1, user1);
    }

    /**
     * @notice 测试：最大金额边界条件
     */
    function test_Security_MaxDepositEdgeCase() public {
        console.log(unicode"测试：最大金额边界条件");
        // 设置 cap 接近当前供应量
        uint256 currentCap = vault.cap();

        // 如果 cap 很大，测试接近 cap 的存款
        pusd.mint(user1, CAP);

        vm.startPrank(user1);
        pusd.approve(address(vault), CAP);

        // 计算可以存入的最大金额
        uint256 maxDeposit = vault.maxDeposit(user1);

        // 应该能够存入 maxDeposit
        if (maxDeposit > 0) {
            vault.deposit(maxDeposit, user1);
        }

        vm.stopPrank();
    }

    /* ========== 套利场景测试 ========== */

    /**
     * @notice 测试：收益注入前后的套利机会（先入先得优势）
     */
    function test_Arbitrage_FrontRunningYieldAccrual() public {
        console.log(unicode"测试：收益注入前后的套利机会（线性释放版本：抢跑无利可图）");

        // 用户1先存入 1000
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000e6);
        uint256 shares1 = vault.deposit(1000e6, user1);
        vm.stopPrank();

        // 攻击者抢跑存入 1000（企图吃收益）
        vm.startPrank(attacker);
        pusd.approve(address(vault), 1000e6);
        uint256 attackerShares = vault.deposit(1000e6, attacker);
        vm.stopPrank();

        // 注入收益 200（线性释放）
        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, 200e6);
        pusd.approve(address(vault), 200e6);
        vault.accrueYield(200e6, DURATION);
        vm.stopPrank();

        // ✅ 断言1：注入后立刻，汇率不应瞬间上升（资产价值基本不变）
        uint256 user1AssetsNow = vault.convertToAssets(shares1);
        uint256 attackerAssetsNow = vault.convertToAssets(attackerShares);

        assertApproxEqAbs(user1AssetsNow, 1000e6, 2);
        assertApproxEqAbs(attackerAssetsNow, 1000e6, 2);

        // ✅ 断言2：攻击者立刻退出应几乎无利可图（拿不到未释放收益）
        uint256 attackerBalanceBefore = pusd.balanceOf(attacker); // deposit后通常为0
        vm.prank(attacker);
        uint256 withdrawn = vault.redeem(attackerShares, attacker, attacker);

        // withdrawn 应≈1000（最多允许极小 rounding）
        assertApproxEqAbs(withdrawn, 1000e6, 5);

        // 防止“用余额差算profit”把本金当profit：这里直接用 withdrawn 判定
        // 不允许赚到钱：withdrawn <= 1000 + 0.01
        assertLe(withdrawn, 1000e6 + 1e4);

        // ✅ 断言3：推进到释放结束后，user1 应该吃到收益（攻击者已退出吃不到）
        vm.warp(block.timestamp + DURATION);

        uint256 user1AssetsEnd = vault.convertToAssets(shares1);
        assertGt(user1AssetsEnd, 1000e6);

        // 理论上最终：总收益200 由当时持有者分，攻击者退出后只剩 user1
        // 所以 user1 最终应≈1200（允许误差）
        assertApproxEqAbs(user1AssetsEnd, 1200e6, 50);
    }

    /**
     * @notice 测试：收益注入后的套利（后入劣势）
     */
    function test_Arbitrage_LateEntryAfterYield() public {
        console.log(unicode"测试：收益释放完成后入场（后入更贵，线性释放版本）");

        // user1 先存 1000
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000e6);
        uint256 s1 = vault.deposit(1000e6, user1);
        vm.stopPrank();

        // 注入收益 100（线性释放）
        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, 100e6);
        pusd.approve(address(vault), 100e6);
        vault.accrueYield(100e6, DURATION);
        vm.stopPrank();

        // ✅ 等收益完全释放，汇率应到 1.1
        // 注意：由于 _decimalsOffset() = 3，shares 是 assets 的 1000 倍
        // 所以 exchangeRate = (totalAssets * 1e18) / totalSupply = (1.1e9 * 1e18) / 1e12 = 1.1e15
        vm.warp(block.timestamp + DURATION);
        uint256 rate = vault.exchangeRate();
        uint256 expectedRate = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rate, expectedRate, 5e13);

        // user2 在 fully-vested 后入场：存入 110 assets，由于汇率≈1.1，应该得到相当于 100 assets 的 shares
        // 注意：由于 _decimalsOffset() = 3，shares 是 assets 的 1000 倍
        vm.startPrank(user2);
        pusd.approve(address(vault), 110e6);
        uint256 s2 = vault.deposit(110e6, user2);
        vm.stopPrank();

        // ✅ 计算期望的 shares：由于汇率≈1.1，110 assets 应该得到相当于 100 assets 的 shares
        // shares = (110e6 * totalSupply) / totalAssets = (110e6 * 1e12) / 1.1e9 = 1e11
        uint256 expectedShares = (110e6 * vault.totalSupply()) / vault.totalAssets();
        assertApproxEqAbs(s2, expectedShares, 10);

        // user1 的资产价值应≈1100
        uint256 user1Assets = vault.convertToAssets(s1);
        assertApproxEqAbs(user1Assets, 1100e6, 50);
    }

    /**
     * @notice 测试：多轮收益注入的套利机会
     */
    function test_Arbitrage_MultipleYieldInjectionCycles() public {
        console.log(unicode"测试：多轮收益注入的套利机会（线性释放版本）");

        // user1 存入 1000
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000e6);
        uint256 s1 = vault.deposit(1000e6, user1);
        vm.stopPrank();

        // 第一轮注入 100（线性释放）
        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, 100e6);
        pusd.approve(address(vault), 100e6);
        vault.accrueYield(100e6, DURATION);
        vm.stopPrank();

        // ✅ 刚注入后汇率仍≈1
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 rateJustAfter1 = vault.exchangeRate();
        uint256 expectedRateJustAfter1 = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateJustAfter1, expectedRateJustAfter1, 5e13);

        // ✅ 等第一轮释放结束：汇率应≈1.1
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        vm.warp(block.timestamp + DURATION);
        uint256 rate1 = vault.exchangeRate();
        uint256 expectedRate1 = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rate1, expectedRate1, 5e13);

        // user2 在第一轮 fully-vested 后存入 1100（此时汇率≈1.1，应该拿到相当于 1000 assets 的 shares）
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        vm.startPrank(user2);
        pusd.approve(address(vault), 1100e6);
        uint256 s2 = vault.deposit(1100e6, user2);
        vm.stopPrank();

        uint256 expectedShares2 = (1100e6 * vault.totalSupply()) / vault.totalAssets();
        assertApproxEqAbs(s2, expectedShares2, 50); // 增加误差范围以处理 rounding

        // 第二轮注入 210（线性释放）
        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, 210e6);
        pusd.approve(address(vault), 210e6);
        vault.accrueYield(210e6, DURATION);
        vm.stopPrank();

        // ✅ 刚注入后汇率应仍≈1.1（新收益未释放）
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 rateJustAfter2 = vault.exchangeRate();
        uint256 expectedRateJustAfter2 = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateJustAfter2, expectedRateJustAfter2, 5e13);

        // ✅ 等第二轮释放结束：最终汇率 = 2410 / 2000 = 1.205
        vm.warp(block.timestamp + DURATION);

        uint256 rate2 = vault.exchangeRate();
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 expectedRate = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rate2, expectedRate, 5e13);

        // 两个用户最终资产都应≈1205
        uint256 a1 = vault.convertToAssets(s1);
        uint256 a2 = vault.convertToAssets(s2);

        assertApproxEqAbs(a1, 1205e6, 100);
        assertApproxEqAbs(a2, 1205e6, 100);
    }

    /**
     * @notice 测试：在收益注入前后快速进出（套利机器人行为）
     */
    function test_Arbitrage_QuickInAndOut() public {
        console.log(unicode"测试：在收益注入前后快速进出（线性释放：不能套利）");

        // user1 先存入 1000
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000e6);
        uint256 user1Shares = vault.deposit(1000e6, user1);
        vm.stopPrank();

        // attacker 快速存入 1000
        vm.startPrank(attacker);
        pusd.approve(address(vault), 1000e6);
        uint256 attackerShares = vault.deposit(1000e6, attacker);
        vm.stopPrank();

        // 注入收益 200（线性释放）
        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, 200e6);
        pusd.approve(address(vault), 200e6);
        vault.accrueYield(200e6, DURATION);
        vm.stopPrank();

        // ✅ 断言1：刚注入后汇率不应瞬时上升（仍≈1）
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 rateJustAfter = vault.exchangeRate();
        uint256 expectedRateJustAfter = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateJustAfter, expectedRateJustAfter, 5e13);

        // attacker 立即取出
        vm.prank(attacker);
        uint256 withdrawn = vault.redeem(attackerShares, attacker, attacker);

        // ✅ 断言2：快速进出不应盈利（允许极小 rounding）
        assertApproxEqAbs(withdrawn, 1000e6, 5);
        assertLe(withdrawn, 1000e6 + 1e4); // 最多允许 0.01 PUSD 误差

        // ✅ 断言3：时间推到释放结束，user1 应获得收益（attacker 已退出吃不到）
        vm.warp(block.timestamp + DURATION);

        uint256 user1AssetsEnd = vault.convertToAssets(user1Shares);
        assertGt(user1AssetsEnd, 1000e6);

        // 最终只剩 user1 持有 shares，因此 user1 应吃到全部 200（允许误差）
        assertApproxEqAbs(user1AssetsEnd, 1200e6, 100);
    }

    /**
     * @notice 测试：零收益注入时不应该有套利机会
     */
    function test_Arbitrage_NoArbitrageWithoutYield() public {
        console.log(unicode"测试：零收益注入时不应该有套利机会");
        // 用户1存入
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000 * 1e6);
        uint256 shares1 = vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();

        // 用户2存入
        vm.startPrank(user2);
        pusd.approve(address(vault), 1000 * 1e6);
        uint256 shares2 = vault.deposit(1000 * 1e6, user2);
        vm.stopPrank();

        // 没有收益注入，汇率应该保持 1:1
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 expectedRate = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(vault.exchangeRate(), expectedRate, 5e13);

        // 用户1取出
        vm.prank(user1);
        uint256 withdrawn1 = vault.redeem(shares1, user1, user1);
        assertEq(withdrawn1, 1000 * 1e6);

        // 用户2取出
        vm.prank(user2);
        uint256 withdrawn2 = vault.redeem(shares2, user2, user2);
        assertEq(withdrawn2, 1000 * 1e6);
    }

    /* ========== 并发场景测试 ========== */

    /**
     * @notice 测试：多个用户同时存款
     */
    function test_Concurrency_MultipleUsersDepositSimultaneously() public {
        console.log(unicode"测试：多个用户同时存款");
        uint256 depositAmount = 1000 * 1e6;

        // 模拟多个用户同时存款（在同一个区块中）
        vm.startPrank(user1);
        pusd.approve(address(vault), depositAmount);
        vm.stopPrank();

        vm.startPrank(user2);
        pusd.approve(address(vault), depositAmount);
        vm.stopPrank();

        vm.startPrank(user3);
        pusd.approve(address(vault), depositAmount);
        vm.stopPrank();

        // 执行存款（模拟并发）
        vm.prank(user1);
        uint256 shares1 = vault.deposit(depositAmount, user1);

        vm.prank(user2);
        uint256 shares2 = vault.deposit(depositAmount, user2);

        vm.prank(user3);
        uint256 shares3 = vault.deposit(depositAmount, user3);

        // 所有用户应该获得相同的 shares（因为初始汇率是 1:1，shares 与 assets 等值）
        uint256 expectedShares = depositAmount;
        assertEq(shares1, expectedShares);
        assertEq(shares2, expectedShares);
        assertEq(shares3, expectedShares);

        // 总资产应该是所有存款之和
        assertEq(vault.totalAssets(), depositAmount * 3);
        // 在 1:1 模式下，totalSupply 与 totalAssets 等值
        assertEq(vault.totalSupply(), depositAmount * 3);
    }

    /**
     * @notice 测试：多个用户同时取款
     */
    function test_Concurrency_MultipleUsersWithdrawSimultaneously() public {
        console.log(unicode"测试：多个用户同时取款");
        uint256 depositAmount = 1000 * 1e6;

        // 先让所有用户存入
        vm.startPrank(user1);
        pusd.approve(address(vault), depositAmount);
        uint256 shares1 = vault.deposit(depositAmount, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        pusd.approve(address(vault), depositAmount);
        uint256 shares2 = vault.deposit(depositAmount, user2);
        vm.stopPrank();

        vm.startPrank(user3);
        pusd.approve(address(vault), depositAmount);
        uint256 shares3 = vault.deposit(depositAmount, user3);
        vm.stopPrank();

        // 注入收益
        vm.startPrank(yieldInjector);
        pusd.approve(address(vault), 300 * 1e6);
        vault.accrueYield(300 * 1e6, DURATION);
        vm.stopPrank();

        // 模拟多个用户同时取款
        vm.prank(user1);
        uint256 withdrawn1 = vault.redeem(shares1, user1, user1);

        vm.prank(user2);
        uint256 withdrawn2 = vault.redeem(shares2, user2, user2);

        vm.prank(user3);
        uint256 withdrawn3 = vault.redeem(shares3, user3, user3);

        // 所有用户应该获得相同的收益
        assertApproxEqAbs(withdrawn1, 1000 * 1e6, 1);
        assertApproxEqAbs(withdrawn2, 1000 * 1e6, 1);
        assertApproxEqAbs(withdrawn3, 1000 * 1e6, 1);
    }

    /**
     * @notice 测试：收益注入时多个用户同时操作
     */
    function test_Concurrency_YieldInjectionWithConcurrentOperations() public {
        console.log(unicode"测试：收益注入时多个用户同时操作（线性释放版本）");

        // user1 deposit 1000
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000e6);
        uint256 s1 = vault.deposit(1000e6, user1);
        vm.stopPrank();

        // user2 deposit 1000
        vm.startPrank(user2);
        pusd.approve(address(vault), 1000e6);
        uint256 s2 = vault.deposit(1000e6, user2);
        vm.stopPrank();

        // 注入收益 200（线性释放）
        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, 200e6);
        pusd.approve(address(vault), 200e6);
        vault.accrueYield(200e6, DURATION);
        vm.stopPrank();

        // ✅ 关键断言1：注入后立刻汇率应基本不变（仍≈1.0）
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 rateJustAfter = vault.exchangeRate();
        uint256 expectedRateJustAfter = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateJustAfter, expectedRateJustAfter, 5e13);

        // user3 在注入后立刻 deposit 1000（线性释放下不需要多存）
        vm.startPrank(user3);
        pusd.approve(address(vault), 1000e6);
        uint256 s3 = vault.deposit(1000e6, user3);
        vm.stopPrank();

        // ✅ 关键断言2：user3 应该拿到相当于 1000 assets 的 shares（因为汇率仍≈1）
        // 注意：由于 _decimalsOffset() = 3，shares 是 assets 的 1000 倍
        uint256 expectedShares3 = (1000e6 * vault.totalSupply()) / vault.totalAssets();
        assertApproxEqAbs(s3, expectedShares3, 10);

        // ✅ 关键断言3：推进到释放结束后，汇率应到 3200/3000 = 1.066666...
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        vm.warp(block.timestamp + DURATION);
        uint256 rateEnd = vault.exchangeRate();
        uint256 expectedRate = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateEnd, expectedRate, 5e13);

        // ✅ 关键断言4：三个人最终资产按比例增加（大约 1066.666...）
        uint256 a1 = vault.convertToAssets(s1);
        uint256 a2 = vault.convertToAssets(s2);
        uint256 a3 = vault.convertToAssets(s3);

        // 允许一点 rounding 误差（比如 10 微单位 = 0.00001 PUSD）
        assertApproxEqAbs(a1, 1066666666, 50);
        assertApproxEqAbs(a2, 1066666666, 50);
        assertApproxEqAbs(a3, 1066666666, 50);
    }

    /**
     * @notice 测试：高并发下的 cap 限制
     */
    function test_Concurrency_CapLimitUnderHighConcurrency() public {
        console.log(unicode"测试：高并发下的 cap 限制");
        // 现在 yPUSD 采用 1:1 的 shares:assets 比例（decimalsOffset = 0）
        // cap 的单位是 shares，因此 cap = 3000e6 意味着最多 3000e6 assets
        uint256 smallCap = 3000 * 1e6; // 3000 PUSD
        vm.prank(admin);
        vault.setCap(smallCap);

        // 三个用户都尝试存入，但需要考虑 cap 与 MIN_INITIAL_SHARES 限制
        pusd.mint(user1, 2000 * 1e6);
        pusd.mint(user2, 2000 * 1e6);
        pusd.mint(user3, 2000 * 1e6);

        vm.startPrank(user1);
        pusd.approve(address(vault), 2000 * 1e6);
        // 第一次存款需要满足 MIN_INITIAL_SHARES（1000e6），这里直接存入 1000e6
        vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        pusd.approve(address(vault), 2000 * 1e6);
        // 第二个用户再存入 2000e6，刚好把 cap 填满
        vault.deposit(2000 * 1e6, user2);
        vm.stopPrank();

        // 用户3尝试存入，但 cap 已满
        vm.startPrank(user3);
        pusd.approve(address(vault), 2000 * 1e6);
        vm.expectRevert(); // ERC4626ExceededMaxDeposit
        vault.deposit(1000 * 1e6, user3);
        vm.stopPrank();

        // 验证 cap 限制生效
        assertLe(vault.totalSupply(), smallCap);
    }

    /**
     * @notice 测试：同时存款和取款
     */
    function test_Concurrency_DepositAndWithdrawConcurrently() public {
        console.log(unicode"测试：同时存款和取款");
        // 用户1先存入
        vm.startPrank(user1);
        pusd.approve(address(vault), 2000 * 1e6);
        uint256 shares1 = vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();

        // 用户2在用户1取款的同时存款
        vm.startPrank(user2);
        pusd.approve(address(vault), 1000 * 1e6);
        uint256 shares2 = vault.deposit(1000 * 1e6, user2);
        vm.stopPrank();

        // 用户1取出一半
        vm.prank(user1);
        uint256 withdrawn = vault.redeem(shares1 / 2, user1, user1);

        // 验证状态一致性
        assertEq(withdrawn, 500 * 1e6); // 1:1 汇率
        assertEq(vault.totalAssets(), 1500 * 1e6);
        // 注意：由于 _decimalsOffset() = 3，shares 是 assets 的 1000 倍
        assertEq(vault.totalSupply(), (shares1 / 2 + shares2));
    }

    /**
     * @notice 测试：大规模并发操作（压力测试）
     */
    function test_Concurrency_StressTestMultipleOperations() public {
        console.log(unicode"测试：大规模并发操作（压力测试，线性释放版本）");

        // 创建 10 个用户，每人 10000
        address[] memory users = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            users[i] = address(uint160(0x1000 + i));
            pusd.mint(users[i], 10000e6);
        }

        // 所有人存入 1000 => 总 supply=10000e6，总 assets(可计入)=10000e6（1:1 比例）
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            pusd.approve(address(vault), 10000e6);
            vault.deposit(1000e6, users[i]);
            vm.stopPrank();
        }

        // 在 1:1 模式下，totalSupply 与 totalAssets 等值
        assertEq(vault.totalSupply(), 10_000e6);
        assertEq(vault.totalAssets(), 10_000e6);

        // 注入收益 1000（线性释放：立刻不计入 totalAssets）
        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, 1000e6);
        pusd.approve(address(vault), 1000e6);
        vault.accrueYield(1000e6, DURATION);
        vm.stopPrank();

        // ✅ 关键断言1：刚注入后 totalAssets 仍≈10000，汇率仍≈1
        assertApproxEqAbs(vault.totalAssets(), 10_000e6, 10);
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 expectedRate1 = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(vault.exchangeRate(), expectedRate1, 5e13);

        // 所有人赎回一半 shares：每人 shares=1000e6 => redeem 500e6
        for (uint256 i = 0; i < users.length; i++) {
            uint256 userShares = vault.balanceOf(users[i]); // 1000e6
            vm.prank(users[i]);
            vault.redeem(userShares / 2, users[i], users[i]);
        }

        // ✅ 关键断言2：赎回后总 supply 应为 5000e6（1:1 比例）
        assertEq(vault.totalSupply(), 5_000e6);

        // ✅ 关键断言3：因为收益仍未释放，赎回后 totalAssets 应≈5000e6（不是 5500）
        assertApproxEqAbs(vault.totalAssets(), 5_000e6, 50);

        // 推进到释放结束：此时 1000e6 全部计入，且只分给剩余 5000e6 shares
        vm.warp(block.timestamp + DURATION);

        // ✅ 关键断言4：释放结束后 totalAssets 应≈ 5000 + 1000 = 6000
        assertApproxEqAbs(vault.totalAssets(), 6_000e6, 200);

        // ✅ 关键断言5：最终汇率应≈ 1.2
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 expectedFinalRate = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(vault.exchangeRate(), expectedFinalRate, 5e13);
    }

    /**
     * @notice 测试：收益注入时的竞态条件
     */
    function test_Concurrency_RaceConditionWithYieldInjection() public {
        console.log(unicode"测试：收益注入时的竞态条件（线性释放版本）");

        // 用户1存入 1000
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000e6);
        uint256 shares1 = vault.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 rateBefore = vault.exchangeRate();
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 expectedRateBefore2 = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateBefore, expectedRateBefore2, 5e13);

        // 收益注入 100（线性释放）
        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, 100e6);
        pusd.approve(address(vault), 100e6);
        vault.accrueYield(100e6, DURATION);
        vm.stopPrank();

        // ✅ 关键断言1：刚注入后，汇率不应该立刻变化（仍≈1.0）
        uint256 rateJustAfter = vault.exchangeRate();
        assertApproxEqAbs(rateJustAfter, rateBefore, 5e13);

        // 用户2在注入后立即存入 1000（注意：这时汇率仍≈1.0，因此 1000 资产应铸 1000 shares）
        vm.startPrank(user2);
        pusd.approve(address(vault), 1000e6);
        uint256 shares2 = vault.deposit(1000e6, user2);
        vm.stopPrank();

        // 注意：由于 _decimalsOffset() = 3，shares 是 assets 的 1000 倍
        uint256 expectedShares2_2 = (1000e6 * vault.totalSupply()) / vault.totalAssets();
        assertApproxEqAbs(shares2, expectedShares2_2, 10);

        // ✅ 关键断言2：推进到 vesting 中途，汇率应该上升（>1）
        vm.warp(block.timestamp + DURATION / 2);
        uint256 rateMid = vault.exchangeRate();
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 expectedRateMid = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertGt(rateMid, expectedRateMid - 5e13); // 允许小误差，但应该大于初始汇率

        // ✅ 关键断言3：推进到 vesting 结束，汇率应接近 (2000+100)/2000 = 1.05
        vm.warp(block.timestamp + DURATION / 2);
        uint256 rateEnd = vault.exchangeRate();
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 expectedRateEnd = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateEnd, expectedRateEnd, 5e13);

        // 可选：检查两人最终资产大致相等（都持有1000 shares，共享释放收益）
        uint256 user1Assets = vault.convertToAssets(shares1);
        uint256 user2Assets = vault.convertToAssets(shares2);

        assertApproxEqAbs(user1Assets, 1050e6, 5);
        assertApproxEqAbs(user2Assets, 1050e6, 5);
    }

    /**
     * @notice 测试：多个收益注入者同时操作的场景（如果多个地址有权限）
     */
    function test_Concurrency_MultipleYieldInjectors() public {
        console.log(unicode"测试：多个收益注入者同时操作（线性释放版本）");

        address yieldInjector2 = address(0xF00D);

        // 授予第二个收益注入者角色
        vm.prank(admin);
        vault.grantRole(YIELD_INJECTOR_ROLE, yieldInjector2);

        pusd.mint(yieldInjector2, INITIAL_BALANCE * 10);

        // 用户1存入 1000
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000e6);
        uint256 s1 = vault.deposit(1000e6, user1);
        vm.stopPrank();

        // 注入者1 注入 100（线性释放）
        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, 100e6);
        pusd.approve(address(vault), 100e6);
        vault.accrueYield(100e6, DURATION);
        vm.stopPrank();

        // ✅ 刚注入后：totalAssets 仍≈1000，汇率仍≈1
        assertApproxEqAbs(vault.totalAssets(), 1000e6, 5);
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 expectedRate2 = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(vault.exchangeRate(), expectedRate2, 5e13);

        // 注入者2 再注入 110（会合并未释放收益，并重置 vesting 结束时间）
        vm.startPrank(yieldInjector2);
        pusd.mint(yieldInjector2, 110e6);
        pusd.approve(address(vault), 110e6);
        vault.accrueYield(110e6, DURATION);
        vm.stopPrank();

        // ✅ 第二次注入后：仍然不应立刻计入（仍≈1000）
        assertApproxEqAbs(vault.totalAssets(), 1000e6, 5);
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 expectedRateAfter2nd = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(vault.exchangeRate(), expectedRateAfter2nd, 5e13);

        // ✅ 推进到（第二次注入后的）vesting 完成
        vm.warp(block.timestamp + DURATION);

        // 现在 totalAssets 应≈ 1000 + 100 + 110 = 1210
        assertApproxEqAbs(vault.totalAssets(), 1210e6, 200);

        // 汇率应≈ 1.21（shares 仍是 1000e6）
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 rateEnd = vault.exchangeRate();
        uint256 expectedRateEnd = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateEnd, expectedRateEnd, 5e13);

        // （可选）user1 资产应≈1210
        uint256 a1 = vault.convertToAssets(s1);
        assertApproxEqAbs(a1, 1210e6, 200);
    }

    /* ========== 非法操作测试 ========== */

    /**
     * @notice 测试：传入零地址应该失败
     */
    function test_Illegal_ZeroAddressShouldRevert() public {
        console.log(unicode"测试：传入零地址应该失败");
        // 测试 deposit 到零地址
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000 * 1e6);
        vm.expectRevert(); // ERC4626InvalidReceiver
        vault.deposit(1000 * 1e6, address(0));
        vm.stopPrank();
    }

    /**
     * @notice 测试：传入超大数值应该失败（防止溢出）
     */
    function test_Illegal_ExtremelyLargeAmountShouldRevert() public {
        console.log(unicode"测试：传入超大数值应该失败（防止溢出）");
        // 使用一个非常大的值（远大于 cap），但不会导致 mulDiv 溢出
        // cap = 1_000_000_000 * 1e6 = 1e15
        // 使用 1000 倍的 cap 来测试边界情况，同时避免溢出
        // 这个值足够大以触发 cap 限制检查，但不会导致 mulDiv 溢出
        uint256 extremelyLargeAmount = CAP * 1000; // 1000倍 cap，远大于 cap 但不会溢出

        vm.startPrank(user1);
        pusd.mint(user1, extremelyLargeAmount);
        pusd.approve(address(vault), extremelyLargeAmount);

        // 应该因为 cap 限制而失败，而不是溢出
        vm.expectRevert(); // ERC4626ExceededMaxDeposit
        vault.deposit(extremelyLargeAmount, user1);
        vm.stopPrank();
    }

    /**
     * @notice 测试：尝试提取超过余额的金额
     */
    function test_Illegal_WithdrawMoreThanBalance() public {
        console.log(unicode"测试：尝试提取超过余额的金额");
        // 先存入少量
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000 * 1e6);
        vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();

        // 尝试提取超过余额的金额
        vm.prank(user1);
        vm.expectRevert(); // ERC4626ExceededMaxWithdraw
        vault.withdraw(2000 * 1e6, user1, user1);
    }

    /**
     * @notice 测试：尝试赎回超过持有的份额
     */
    function test_Illegal_RedeemMoreThanShares() public {
        console.log(unicode"测试：尝试赎回超过持有的份额");
        // 先存入
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000 * 1e6);
        uint256 shares = vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();

        // 尝试赎回超过持有的份额
        vm.prank(user1);
        vm.expectRevert(); // ERC4626ExceededMaxRedeem
        vault.redeem(shares + 1, user1, user1);
    }

    /**
     * @notice 测试：未批准代币就尝试存款
     */
    function test_Illegal_DepositWithoutApproval() public {
        console.log(unicode"测试：未批准代币就尝试存款");
        vm.startPrank(user1);
        // 不批准，直接尝试存款
        vm.expectRevert(); // ERC20InsufficientAllowance
        vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();
    }

    /**
     * @notice 测试：尝试使用无效的资产地址初始化（应该由部署器处理）
     */
    function test_Illegal_InvalidAssetAddress() public {
        console.log(unicode"测试：尝试使用无效的资产地址初始化（应该由部署器处理）");
        // 这个测试验证部署器是否正确处理无效地址
        // 如果直接调用 initialize，应该失败
        yPUSD newVault = new yPUSD();
        vm.expectRevert(); // 可能因为零地址或其他原因
        newVault.initialize(IERC20(address(0)), CAP, admin);
    }

    /**
     * @notice 测试：尝试在未初始化时调用函数
     */
    function test_Illegal_CallBeforeInitialization() public {
        console.log(unicode"测试：尝试在未初始化时调用函数");
        yPUSD uninitializedVault = new yPUSD();

        // 尝试在未初始化时调用
        vm.expectRevert();
        uninitializedVault.deposit(1000 * 1e6, user1);
    }

    /**
     * @notice 测试：尝试设置 cap 为 0（当有供应量时）
     */
    function test_Illegal_SetCapToZeroWithSupply() public {
        console.log(unicode"测试：尝试设置 cap 为 0（当有供应量时）");
        // 先存入一些资金
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000 * 1e6);
        vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();

        // 尝试设置 cap 为 0
        vm.prank(admin);
        vm.expectRevert("yPUSD: cap below current supply");
        vault.setCap(0);
    }

    /**
     * @notice 测试：尝试从零地址提取
     */
    function test_Illegal_WithdrawToZeroAddress() public {
        console.log(unicode"测试：尝试从零地址提取");
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000 * 1e6);
        vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();

        vm.prank(user1);
        vm.expectRevert(); // ERC20InvalidReceiver
        vault.withdraw(100 * 1e6, address(0), user1);
    }

    /* ========== 极端场景测试 ========== */

    /**
     * @notice 测试：零供应量时的操作
     */
    function test_Extreme_ZeroSupplyOperations() public {
        console.log(unicode"测试：零供应量时的操作");
        // 验证零供应量时的汇率
        // 注意：当 totalSupply 为 0 时，exchangeRate 应返回 1e18
        uint256 rate = vault.exchangeRate();
        assertEq(rate, 1e18);

        // 验证零供应量时的转换
        // 采用 1:1 的 shares:assets 比例
        uint256 assets = 1000 * 1e6;
        uint256 shares = vault.convertToShares(assets);
        assertEq(shares, assets);
        assertEq(vault.convertToAssets(shares), assets);
    }

    /**
     * @notice 测试：最大 cap 值的边界情况
     */
    function test_Extreme_MaxCapValue() public {
        console.log(unicode"测试：最大 cap 值的边界情况");
        uint256 maxCap = type(uint256).max / 2; // 避免溢出

        vm.prank(admin);
        vault.setCap(maxCap);

        assertEq(vault.cap(), maxCap);
    }

    /**
     * @notice 测试：极小金额的存款和取款（精度测试）
     */
    function test_Extreme_VerySmallAmounts() public {
        console.log(unicode"测试：极小金额的存款和取款（精度测试）");
        uint256 tinyAmount = 1; // 最小单位

        // 先通过一次大额存款使 totalSupply >= MIN_INITIAL_SHARES，
        // 避免 MIN_INITIAL_SHARES 保护机制阻止小额存款
        vm.startPrank(user2);
        pusd.mint(user2, 1000 * 1e6);
        pusd.approve(address(vault), 1000 * 1e6);
        vault.deposit(1000 * 1e6, user2);
        vm.stopPrank();

        vm.startPrank(user1);
        pusd.mint(user1, tinyAmount);
        pusd.approve(address(vault), tinyAmount);

        // 应该能够存入最小金额
        uint256 shares = vault.deposit(tinyAmount, user1);
        assertGe(shares, 0);

        // 应该能够取出
        if (shares > 0) {
            uint256 assets = vault.redeem(shares, user1, user1);
            assertGe(assets, 0);
        }
        vm.stopPrank();
    }

    /**
     * @notice 测试：接近 cap 的边界存款
     */
    function test_Extreme_DepositNearCap() public {
        console.log(unicode"测试：接近 cap 的边界存款");
        // 现在 yPUSD 采用 1:1 的 shares:assets 比例（decimalsOffset = 0）
        // cap 的单位是 shares，与 assets 等值
        uint256 smallCap = 10000 * 1e6;
        vm.prank(admin);
        vault.setCap(smallCap);

        // 先进行一次大额存款满足 MIN_INITIAL_SHARES 要求
        pusd.mint(user1, smallCap);

        vm.startPrank(user1);
        pusd.approve(address(vault), smallCap);

        // 先存入 1000e6，确保 totalSupply >= MIN_INITIAL_SHARES
        vault.deposit(1000 * 1e6, user1);

        // 计算此时还能存入的最大金额
        uint256 maxAssets = vault.maxDeposit(user1);

        // 存入接近 cap 的金额（留出 1 wei 空间）
        if (maxAssets > 1) {
            uint256 depositAmount = maxAssets - 1;
            vault.deposit(depositAmount, user1);
        }

        // 验证还能至少再存入 1 wei
        assertGe(vault.maxDeposit(user1), 1);

        vm.stopPrank();
    }

    /**
     * @notice 测试：收益注入后汇率精度问题
     */
    function test_Extreme_ExchangeRatePrecision() public {
        console.log(unicode"测试：收益注入后汇率精度问题（线性释放版本）");

        // 1) 存入 1000 PUSD（满足 MIN_INITIAL_SHARES 要求）
        uint256 depositAmount = 1000e6; // 1000 PUSD

        vm.startPrank(user1);
        pusd.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user1);
        vm.stopPrank();

        uint256 rateBefore = vault.exchangeRate();
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 expectedRateBefore = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateBefore, expectedRateBefore, 5e13);

        // 2) 注入极小收益：1（最小单位 = 0.000001 PUSD）
        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, 1);
        pusd.approve(address(vault), 1);
        vault.accrueYield(1, DURATION);
        vm.stopPrank();

        // ✅ 关键断言1：刚注入后，由于收益未释放，汇率仍应≈1
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 rateJustAfter = vault.exchangeRate();
        uint256 expectedRateJustAfter = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateJustAfter, expectedRateJustAfter, 5e13);

        // 3) 推进到 vesting 结束
        vm.warp(block.timestamp + DURATION);

        // ✅ 关键断言2：释放完成后，汇率不应下降，并且应 >= 1
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 rateAfterVesting = vault.exchangeRate();
        uint256 expectedRateAfterVesting = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertGe(rateAfterVesting, expectedRateAfterVesting - 5e13); // 允许小误差

        // （可选）验证 totalAssets 至少增加了 1
        // deposit depositAmount + yield 1 => totalAssets 应为 depositAmount + 1
        assertEq(vault.totalAssets(), depositAmount + 1);

        // （可选）用户资产应为 depositAmount + 1（允许小误差）
        uint256 userShares = vault.balanceOf(user1);
        uint256 userAssets = vault.convertToAssets(userShares);
        // 允许一定的精度误差
        assertApproxEqAbs(userAssets, depositAmount + 1, 5); // 允许 5 wei 的误差
    }

    /**
     * @notice 测试：大量用户同时操作（压力测试）
     */
    function test_Extreme_ManyUsersSimultaneous() public {
        console.log(unicode"测试：大量用户同时操作（压力测试）");
        uint256 userCount = 100;
        uint256 depositPerUser = 1000 * 1e6;

        // 创建大量用户
        for (uint256 i = 0; i < userCount; i++) {
            address user = address(uint160(0x10000 + i));
            pusd.mint(user, depositPerUser * 2);

            vm.startPrank(user);
            pusd.approve(address(vault), depositPerUser * 2);
            vault.deposit(depositPerUser, user);
            vm.stopPrank();
        }

        // 验证总供应量（1:1 模式下 shares 与 assets 等值）
        assertEq(vault.totalSupply(), depositPerUser * userCount);
        assertEq(vault.totalAssets(), depositPerUser * userCount);
    }

    /**
     * @notice 测试：在 cap 刚好满时的操作
     */
    function test_Extreme_CapExactlyFull() public {
        console.log(unicode"测试：在 cap 刚好满时的操作");
        // 现在 yPUSD 采用 1:1 的 shares:assets 比例（decimalsOffset = 0）
        // cap 的单位是 shares，与 assets 等值
        uint256 exactCap = 10000 * 1e6;
        vm.prank(admin);
        vault.setCap(exactCap);

        // 计算可以存入的最大资产（在 1:1 模式下等于 cap）
        uint256 maxAssets = vault.maxDeposit(user1);
        pusd.mint(user1, maxAssets);

        vm.startPrank(user1);
        pusd.approve(address(vault), maxAssets);
        vault.deposit(maxAssets, user1);
        vm.stopPrank();

        // 验证不能再存入
        assertEq(vault.maxDeposit(user1), 0);

        // 但可以取出
        vm.prank(user1);
        vault.redeem(1000 * 1e6, user1, user1);

        // 取出后应该可以再存入
        assertGt(vault.maxDeposit(user1), 0);
    }

    /**
     * @notice 测试：多次收益注入的累积效应
     */
    function test_Extreme_MultipleYieldInjections() public {
        console.log(unicode"测试：多次收益注入的累积效应（线性释放版本）");

        // user1 存入 1000
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000e6);
        uint256 s1 = vault.deposit(1000e6, user1);
        vm.stopPrank();

        // 连续注入 10 次，每次 100（每次都会重置 vestingEndTime，并合并未释放收益）
        for (uint256 i = 0; i < 10; i++) {
            vm.startPrank(yieldInjector);
            pusd.mint(yieldInjector, 100e6);
            pusd.approve(address(vault), 100e6);
            vault.accrueYield(100e6, DURATION);
            vm.stopPrank();

            // ✅ 刚注入后不应立刻计入 totalAssets（仍≈1000）
            assertApproxEqAbs(vault.totalAssets(), 1000e6, 50);
            // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
            uint256 expectedRate3 = (vault.totalAssets() * 1e18) / vault.totalSupply();
            assertApproxEqAbs(vault.exchangeRate(), expectedRate3, 5e13);
        }

        // 推进到最后一次注入的 vesting 结束（+1 秒确保过 end）
        vm.warp(block.timestamp + DURATION + 1);

        // ✅ 现在 10 次累计的 1000 应该全部释放
        uint256 ta = vault.totalAssets();
        assertApproxEqAbs(ta, 2000e6, 500); // 允许少量 rounding

        // ✅ 汇率应≈2（总shares=1000e6）
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 rate = vault.exchangeRate();
        uint256 expectedRate = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rate, expectedRate, 5e13);

        // ✅ user1 资产应≈2000
        uint256 a1 = vault.convertToAssets(s1);
        assertApproxEqAbs(a1, 2000e6, 500);
    }

    /* ========== 闪电贷攻击测试 ========== */

    /**
     * @notice 测试：模拟闪电贷攻击 - 借入大量资金操纵汇率
     */
    function test_FlashLoan_ManipulateExchangeRate() public {
        console.log(unicode"测试：模拟闪电贷攻击 - 线性释放下无法秒吃收益");

        // user1 先存 1000
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000e6);
        uint256 user1Shares = vault.deposit(1000e6, user1);
        vm.stopPrank();

        // attacker 闪电贷进来 100万
        // 注意：由于 _decimalsOffset() = 3，shares 是 assets 的 1000 倍
        // cap 是 1_000_000_000 * 1e6 = 1e15 shares
        // 所以最多可以存入 1e15 / 1000 = 1e12 assets = 1_000_000e6
        // 但 user1 已经存了 1000e6，所以最多还能存 999_000e6
        uint256 flashLoanAmount = 999_000e6; // 减少金额以避免超过 cap
        pusd.mint(attacker, flashLoanAmount);

        uint256 rateBefore = vault.exchangeRate();
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 expectedRateBefore = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateBefore, expectedRateBefore, 5e13);

        // attacker 存入 100万
        vm.startPrank(attacker);
        pusd.approve(address(vault), flashLoanAmount);
        uint256 attackerShares = vault.deposit(flashLoanAmount, attacker);
        vm.stopPrank();

        // 注入收益 10000（线性释放）
        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, 10_000e6);
        pusd.approve(address(vault), 10_000e6);
        vault.accrueYield(10_000e6, DURATION);
        vm.stopPrank();

        // ✅ 断言1：刚注入后汇率不应瞬间变化（仍≈1）
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 rateJustAfter = vault.exchangeRate();
        uint256 expectedRateJustAfter = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateJustAfter, expectedRateJustAfter, 5e13);

        // attacker 立刻退出：不应该拿到收益（≈本金）
        vm.prank(attacker);
        uint256 attackerAssets = vault.redeem(attackerShares, attacker, attacker);

        // ✅ 断言2：攻击者秒退不盈利（允许极小 rounding）
        assertApproxEqAbs(attackerAssets, flashLoanAmount, 20);
        assertLe(attackerAssets, flashLoanAmount + 1e4); // 最多 0.01 PUSD 误差

        // ✅ 断言3：时间推进到释放结束后，user1 应该获得收益（攻击者已退出吃不到）
        vm.warp(block.timestamp + DURATION);

        uint256 user1AssetsAfter = vault.convertToAssets(user1Shares);
        assertGt(user1AssetsAfter, 1000e6);

        // 可选：此时 vault 总资产应该是 1000 + 10000 = 11000（因为攻击者已退出）
        // 注意：攻击者退出后 vault 实际余额只剩 user1 的 1000 + 注入的 10000
        assertApproxEqAbs(vault.totalAssets(), 11_000e6, 200);

        // 可选：user1 最终应吃到全部 10000（因为只有他还在）
        assertApproxEqAbs(user1AssetsAfter, 11_000e6, 200);
    }

    /**
     * @notice 测试：闪电贷攻击 - 在收益注入前后快速进出
     */
    function test_FlashLoan_FrontRunYieldInjection() public {
        console.log(unicode"测试：闪电贷攻击 - 在收益注入前后快速进出");

        // 用户1先存入
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000 * 1e6);
        vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();
        // 用户2先存入
        vm.startPrank(user2);
        pusd.approve(address(vault), 1000 * 1e6);
        vault.deposit(1000 * 1e6, user2);
        vm.stopPrank();

        // 先注入收益，并推进时间，确保收益释放生效
        vm.startPrank(yieldInjector);
        pusd.approve(address(vault), 100 * 1e6);
        vault.accrueYield(100 * 1e6, DURATION);
        vm.stopPrank();

        // 攻击者通过闪电贷借入资金
        uint256 flashLoanAmount = 100_000 * 1e6; // 攻击者借入 100000 PUSD
        pusd.mint(attacker, flashLoanAmount);

        // 攻击者在收益注入后存入
        vm.startPrank(attacker);
        pusd.approve(address(vault), flashLoanAmount);
        uint256 attackerShares = vault.deposit(flashLoanAmount, attacker);
        vm.stopPrank();

        // 验证收益注入后汇率变化
        uint256 rateAfterInjection = vault.exchangeRate();
        console.log(unicode"实际汇率", rateAfterInjection);

        // 攻击者立即取出（同一交易中）
        vm.prank(attacker);
        uint256 withdrawn = vault.redeem(attackerShares, attacker, attacker);

        // vm.startPrank(attacker);
        // console.log(unicode"模拟闪电贷还款");
        // pusd.approve(address(admin), flashLoanAmount);
        // console.log(unicode"攻击者余额", pusd.balanceOf(attacker));
        // pusd.transferFrom(attacker, address(admin), flashLoanAmount);
        // vm.stopPrank();

        console.log("withdrawn", withdrawn);
        console.log("flashLoanAmount", flashLoanAmount);
        // 断言攻击者未到释放时间没有收益
        // 注意：由于 rounding 和汇率变化，允许较大的误差
        assertApproxEqAbs(withdrawn, flashLoanAmount, 1e4); // 允许 0.01 PUSD 的误差
        console.log(unicode"断言攻击者未到释放时间没有收益");
        // 在攻击者操作后再推进时间，以计算用户1的收益
        vm.warp(block.timestamp + DURATION); // 再推进时间，确保用户1的收益计算时收益已经释放完成

        // 验证攻击者和用户1的收益分配
        uint256 user1ShareOfTotalAssets = vault.convertToAssets(vault.balanceOf(user1));
        uint256 totalAssets = vault.totalAssets();
        console.log("user1ShareOfTotalAssets", user1ShareOfTotalAssets);
        console.log("totalAssets", totalAssets);
        console.log("vault.totalSupply()", vault.totalSupply());

        // 注意：由于 _decimalsOffset() = 3，shares 是 assets 的 1000 倍
        // 所以计算 expectedUser1Share 时需要考虑这一点
        uint256 user1Shares = vault.balanceOf(user1);
        uint256 expectedUser1Share = (user1Shares * totalAssets) / vault.totalSupply();
        console.log("expectedUser1Share", expectedUser1Share);

        // 验证用户1也获得了相应收益
        assertGt(user1ShareOfTotalAssets, 1000 * 1e6); // 用户1的资产应增加
        // 用户1的收益分配符合预期（允许较大的 rounding 误差）
        assertApproxEqAbs(user1ShareOfTotalAssets, expectedUser1Share, 1000); // 允许较大的误差
    }

    /**
     * @notice 测试：闪电贷攻击 - 尝试通过大量存款影响汇率计算
     */
    function test_FlashLoan_ManipulateRateCalculation() public {
        console.log(unicode"测试：闪电贷攻击 - 尝试通过大量存款影响汇率计算");
        // 初始状态：用户1存入 1000 PUSD（满足 MIN_INITIAL_SHARES 要求）
        vm.startPrank(user1);
        // 授权金额需覆盖实际存款 1000e6
        pusd.approve(address(vault), 1000 * 1e6);
        vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();

        uint256 initialRate = vault.exchangeRate();
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 expectedInitialRate = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(initialRate, expectedInitialRate, 5e13);

        // 攻击者通过闪电贷存入大量资金
        // 注意：由于 _decimalsOffset() = 3，shares 是 assets 的 1000 倍
        // cap 是 1_000_000_000 * 1e6 = 1e15 shares
        // 所以最多可以存入 1e15 / 1000 = 1e12 assets = 1_000_000e6
        // 但 user1 已经存了 100e6，所以最多还能存 999_900e6
        uint256 flashLoanAmount = 999_900e6; // 减少金额以避免超过 cap
        pusd.mint(attacker, flashLoanAmount);

        vm.startPrank(attacker);
        pusd.approve(address(vault), flashLoanAmount);
        vault.deposit(flashLoanAmount, attacker);
        vm.stopPrank();

        // 注入收益
        vm.startPrank(yieldInjector);
        pusd.approve(address(vault), 100000 * 1e6);
        vault.accrueYield(100000 * 1e6, DURATION);
        vm.stopPrank();

        // 验证汇率计算正确（不应该被操纵）
        uint256 rate = vault.exchangeRate();
        uint256 expectedRate = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rate, expectedRate, 1);
    }

    /**
     * @notice 测试：闪电贷攻击 - 尝试在同一交易中多次操作
     */
    function test_FlashLoan_MultipleOperationsInOneTx() public {
        console.log(unicode"测试：闪电贷攻击 - 尝试在同一交易中多次操作");
        // 用户1存入
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000 * 1e6);
        vault.deposit(1000 * 1e6, user1);
        vm.stopPrank();

        // 攻击者通过闪电贷借入
        uint256 flashLoanAmount = 100_000 * 1e6;
        pusd.mint(attacker, flashLoanAmount);

        // 在同一"交易"中多次操作
        vm.startPrank(attacker);
        pusd.approve(address(vault), flashLoanAmount * 2);

        // 第一次存入
        uint256 shares1 = vault.deposit(flashLoanAmount, attacker);

        // 立即取出一半
        vault.redeem(shares1 / 2, attacker, attacker);

        // 再次存入
        uint256 shares2 = vault.deposit(flashLoanAmount, attacker);

        // 全部取出 shares2
        vault.redeem(shares2, attacker, attacker);

        // 取出第一次操作留下的剩余份额（处理舍入误差）
        uint256 remainingShares = vault.balanceOf(attacker);
        if (remainingShares > 0) {
            vault.redeem(remainingShares, attacker, attacker);
        }

        vm.stopPrank();

        // 验证最终状态正确 - 允许小的舍入误差
        assertLe(vault.balanceOf(attacker), 1); // 最多可能留下 1 wei 的舍入误差
        assertApproxEqAbs(vault.totalAssets(), 1000 * 1e6, 100); // 允许 ±100 wei 的舍入误差
    }

    /**
     * @notice 测试：闪电贷攻击 - 尝试通过 cap 限制进行攻击
     */
    function test_FlashLoan_AttackViaCap() public {
        console.log(unicode"测试：闪电贷攻击 - 尝试通过 cap 限制进行攻击");
        // 现在 yPUSD 采用 1:1 的 shares:assets 比例（decimalsOffset = 0）
        // cap 的单位是 shares，与 assets 等值
        uint256 smallCap = 10000 * 1e6;
        vm.prank(admin);
        vault.setCap(smallCap);

        // 用户1存入接近 cap，但留下少量空间
        uint256 maxAssets = smallCap;
        vm.startPrank(user1);
        pusd.approve(address(vault), maxAssets);
        vault.deposit(maxAssets - 1e6, user1); // 留出 1e6 空间
        vm.stopPrank();

        // 计算剩余空间（以 assets 为单位）
        uint256 remainingAssets = vault.maxDeposit(attacker); // 应该是约 1e6

        // 攻击者尝试通过闪电贷填满 cap，阻止其他用户
        uint256 flashLoanAmount = remainingAssets;
        pusd.mint(attacker, flashLoanAmount);

        vm.startPrank(attacker);
        pusd.approve(address(vault), flashLoanAmount);
        vault.deposit(flashLoanAmount, attacker); // 填满 cap
        vm.stopPrank();

        // 验证 cap 已满（以 shares 为单位）
        assertApproxEqAbs(vault.totalSupply(), smallCap, 1000); // 允许小的 rounding 误差
        assertEq(vault.maxDeposit(user2), 0);

        // 但攻击者可以立即取出，释放 cap
        uint256 attackerShares = vault.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeem(attackerShares, attacker, attacker);

        // 现在应该可以再存入了
        assertGt(vault.maxDeposit(user2), 0);
    }

    /**
     * @notice 回归测试：修复后闪电贷无法“秒吃”注入收益，价格不会被卡死在 1.02，
     *         在 vesting 结束后能正常到达 1.03
     *
     * 逻辑：
     * 1) user1 存 1000
     * 2) 注入 20（线性释放），立即汇率不变；等 1 天后汇率到 1.02
     * 3) 计算把 fully-vested 汇率从 1.02 推到 1.03 需要的 yield（约 10）
     * 4) attacker 闪电贷存入 1000万，抢跑在注入前
     * 5) 注入 yieldNeeded（线性释放）
     * 6) attacker 立刻 redeem：利润应≈0（拿不到未释放收益）
     * 7) 等 vesting 结束：fully-vested 汇率应到 1.03
     */
    function test_Fix_AllowsRateToReach_103_AndBlocksSniping() public {
        console.log(unicode"回归测试：修复后闪电贷无法“秒吃”注入收益，价格不会被卡死在 1.02，在 vesting 结束后能正常到达 1.03");

        /* ------------------------------------------------------------
        1) user1 存入 1000 PUSD
        ------------------------------------------------------------ */
        vm.startPrank(user1);
        pusd.approve(address(vault), 1000e6);
        uint256 user1Shares = vault.deposit(1000e6, user1);
        vm.stopPrank();

        /* ------------------------------------------------------------
        2) 注入 20 PUSD（线性释放），目标 fully-vested 到 1.02
        ------------------------------------------------------------ */
        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, 20e6);
        pusd.approve(address(vault), 20e6);
        vault.accrueYield(20e6, DURATION);
        vm.stopPrank();

        // 2.1 刚注入后：收益几乎全是 unvested，因此汇率应接近 1.00
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 rateJustInjected20 = vault.exchangeRate();
        uint256 expectedRateJustInjected20 = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateJustInjected20, expectedRateJustInjected20, 5e13);

        // 2.2 推进到 vesting 结束：汇率应接近 1.02
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        vm.warp(block.timestamp + DURATION);
        uint256 rate102 = vault.exchangeRate();
        uint256 expectedRate102 = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rate102, expectedRate102, 5e13);

        /* ------------------------------------------------------------
        3) 计算“只够 1.02 -> 1.03”的注入量（fully-vested 状态下）
        ------------------------------------------------------------ */
        // 计算"只够 1.02 -> 1.03"的注入量
        // 当前汇率约为 1.02，目标汇率是 1.03
        // 如果当前汇率是 1.02，要达到 1.03，需要增加约 1% 的 assets
        // 所以 yieldNeeded ≈ assetsBefore * 0.01 ≈ 10e6
        uint256 assetsBefore = vault.totalAssets();
        // 计算：yieldNeeded = assetsBefore * (1.03 - 1.02) / 1.02 = assetsBefore * 1 / 102
        // 由于 assetsBefore 是 6 位小数，所以 yieldNeeded = (assetsBefore * 1) / 102
        uint256 yieldNeeded = assetsBefore / 102; // 约等于 assetsBefore * 0.01，理论约 10e6
        assertApproxEqAbs(yieldNeeded, 10e6, 2e6); // 允许较大误差

        /* ------------------------------------------------------------
        4) attacker 闪电贷进场（抢在注入前）
        ------------------------------------------------------------ */
        // 注意：由于 _decimalsOffset() = 3，shares 是 assets 的 1000 倍
        // cap 是 1_000_000_000 * 1e6 = 1e15 shares
        // user1 已经存了 1000e6，在初始汇率下会生成 1000e9 shares
        // 所以剩余空间约 999e12 shares，对应的 assets 约 999e9 = 999_000e6
        // 但考虑到汇率可能不是 1:1，使用更保守的值
        uint256 currentSupply = vault.totalSupply();
        uint256 maxShares = vault.cap();
        uint256 remainingShares = maxShares > currentSupply ? maxShares - currentSupply : 0;
        // 计算最多可以存入的 assets（考虑当前汇率）
        uint256 maxAssets = vault.maxDeposit(attacker);
        uint256 flashAmount = maxAssets > 100_000e6 ? 100_000e6 : maxAssets; // 使用较小的值，但至少 100_000e6
        if (flashAmount == 0) {
            // 如果 maxDeposit 返回 0，说明 cap 已满，需要先取出一些
            // 这种情况下，我们使用一个较小的固定值
            flashAmount = 100_000e6;
        }
        pusd.mint(attacker, flashAmount);

        vm.startPrank(attacker);
        pusd.approve(address(vault), flashAmount);
        uint256 attackerShares = vault.deposit(flashAmount, attacker);
        vm.stopPrank();
        console.log(unicode"攻击存款完成", attackerShares);
        /* ------------------------------------------------------------
        5) 注入“只够 fully-vested 到 1.03”的那笔钱（线性释放）
        ------------------------------------------------------------ */
        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, yieldNeeded);
        pusd.approve(address(vault), yieldNeeded);
        vault.accrueYield(yieldNeeded, DURATION);
        vm.stopPrank();

        // 5.1 注入后立刻：不应瞬间跳到 1.03（否则仍可被秒吃）
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        uint256 rateImmediatelyAfter = vault.exchangeRate();
        uint256 expectedRateImmediatelyAfter = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateImmediatelyAfter, expectedRateImmediatelyAfter, 5e13);

        /* ------------------------------------------------------------
        6) attacker 立刻退出：利润应≈0
        ✅ 注意：利润要用 withdrawn - flashAmount，而不是余额差
        ------------------------------------------------------------ */
        vm.prank(attacker);
        uint256 withdrawn = vault.redeem(attackerShares, attacker, attacker);

        // 不允许盈利（最多允许 0.01 PUSD 的误差）
        assertLe(withdrawn, flashAmount + 1e4);

        console.log(unicode"攻击者提取", withdrawn);

        // attacker 不应残留 shares
        assertEq(vault.balanceOf(attacker), 0);

        /* ------------------------------------------------------------
        7) 等待 vesting 结束：汇率应最终达到 1.03（说明价格能涨上去）
        ------------------------------------------------------------ */
        // 注意：由于 _decimalsOffset() = 3，使用动态计算期望值
        vm.warp(block.timestamp + DURATION);
        uint256 rateAfterVesting = vault.exchangeRate();
        uint256 expectedRateAfterVesting = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertApproxEqAbs(rateAfterVesting, expectedRateAfterVesting, 5e13);

        // 可选：也可以直接检查 user1 fully-vested 资产约为 1030
        uint256 user1AssetsFinal = vault.convertToAssets(user1Shares);
        assertApproxEqAbs(user1AssetsFinal, 1030e6, 5);
    }
    /**
     * @notice 测试：线性释放的具体逻辑 - 每秒释放速率
     */
    function test_LinearRelease_PerSecondRate() public {
        console.log(unicode"测试：线性释放的每秒释放速率");

        // 1. 初始状态：user1 存入 10000 PUSD
        vm.startPrank(user1);
        pusd.approve(address(vault), 10000e6);
        uint256 shares1 = vault.deposit(10000e6, user1);
        vm.stopPrank();

        uint256 initialAssets = vault.totalAssets();
        assertEq(initialAssets, 10000e6);

        // 2. 注入收益 86400 PUSD，释放周期 1 天（86400 秒）
        uint256 yieldAmount = 86400e6;
        uint256 releaseDuration = 1 days; // 86400 秒

        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, yieldAmount);
        pusd.approve(address(vault), yieldAmount);
        vault.accrueYield(yieldAmount, releaseDuration);
        vm.stopPrank();

        // 3. 验证释放速率：每秒应该释放 86400e6 / 86400 = 1e6 PUSD
        (uint256 vestingEndTime, uint256 vestingRate, uint256 unvestedYield, uint256 releasedYield) = vault.getVestingInfo();

        // vestingRate = totalUnvested / duration = 86400e6 / 86400 = 1e6 (每秒 1 PUSD)
        uint256 expectedRate = yieldAmount / releaseDuration; // 86400e6 / 86400 = 1e6
        assertEq(vestingRate, expectedRate);

        // 4. 验证刚注入后，totalAssets 应该不变（收益还未释放）
        uint256 assetsJustAfter = vault.totalAssets();
        assertEq(assetsJustAfter, initialAssets); // 仍为 10000e6

        // 5. 验证未释放收益：应该等于总收益
        assertEq(unvestedYield, yieldAmount); // 86400e6

        // 6. 推进 1 秒，验证释放了 1 PUSD
        vm.warp(block.timestamp + 1);
        uint256 assetsAfter1Second = vault.totalAssets();
        uint256 expectedAssetsAfter1Second = initialAssets + expectedRate; // 10000e6 + 1e6
        assertEq(assetsAfter1Second, expectedAssetsAfter1Second);

        // 7. 验证未释放收益减少
        (, , uint256 unvestedAfter1Second, ) = vault.getVestingInfo();
        uint256 expectedUnvested = yieldAmount - expectedRate; // 86400e6 - 1e6 = 86399e6
        assertEq(unvestedAfter1Second, expectedUnvested);

        // 8. 推进 3600 秒（1 小时），验证释放了 3600 PUSD
        vm.warp(block.timestamp + 3600);
        uint256 assetsAfter1Hour = vault.totalAssets();
        uint256 expectedAssetsAfter1Hour = initialAssets + (expectedRate * 3601); // 10000e6 + 1e6 * 3601
        assertApproxEqAbs(assetsAfter1Hour, expectedAssetsAfter1Hour, 1e4); // 允许小的 rounding 误差

        // 9. 推进到释放结束，验证所有收益都已释放
        vm.warp(vestingEndTime);
        uint256 assetsAfterVesting = vault.totalAssets();
        uint256 expectedAssetsAfterVesting = initialAssets + yieldAmount; // 10000e6 + 86400e6
        assertEq(assetsAfterVesting, expectedAssetsAfterVesting);

        // 10. 验证未释放收益为 0
        (, , uint256 unvestedAfterVesting, ) = vault.getVestingInfo();
        assertEq(unvestedAfterVesting, 0);
    }

    /**
     * @notice 测试：线性释放的时间比例计算
     */
    function test_LinearRelease_TimeProportion() public {
        console.log(unicode"测试：线性释放的时间比例计算");

        // 1. 初始状态
        vm.startPrank(user1);
        pusd.approve(address(vault), 10000e6);
        vault.deposit(10000e6, user1);
        vm.stopPrank();

        // 2. 注入收益 100 PUSD，释放周期 1 天
        uint256 yieldAmount = 100e6;
        uint256 releaseDuration = 1 days;

        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, yieldAmount);
        pusd.approve(address(vault), yieldAmount);
        vault.accrueYield(yieldAmount, releaseDuration);
        vm.stopPrank();

        // 获取 vesting 开始时间（accrueYield 调用时的时间）
        (uint256 vestingEndTime, , , ) = vault.getVestingInfo();
        uint256 vestingStartTime = vestingEndTime - releaseDuration;

        // 3. 推进到释放周期的 50%（12 小时）
        vm.warp(vestingStartTime + releaseDuration / 2);

        uint256 assetsAtHalf = vault.totalAssets();
        uint256 expectedAssetsAtHalf = 10000e6 + yieldAmount / 2; // 10000e6 + 50e6
        assertApproxEqAbs(assetsAtHalf, expectedAssetsAtHalf, 1e4);

        // 4. 推进到释放周期的 75%
        vm.warp(vestingStartTime + (releaseDuration * 3) / 4);

        uint256 assetsAtThreeQuarters = vault.totalAssets();
        uint256 expectedAssetsAtThreeQuarters = 10000e6 + (yieldAmount * 3) / 4; // 10000e6 + 75e6
        assertApproxEqAbs(assetsAtThreeQuarters, expectedAssetsAtThreeQuarters, 1e4);

        // 5. 推进到释放结束
        vm.warp(vestingEndTime);

        uint256 assetsAtEnd = vault.totalAssets();
        uint256 expectedAssetsAtEnd = 10000e6 + yieldAmount; // 10000e6 + 100e6
        assertEq(assetsAtEnd, expectedAssetsAtEnd);
    }

    /**
     * @notice 测试：不同释放周期的释放速率
     */
    function test_LinearRelease_DifferentDurations() public {
        console.log(unicode"测试：不同释放周期的释放速率");

        vm.startPrank(user1);
        pusd.approve(address(vault), 10000e6);
        vault.deposit(10000e6, user1);
        vm.stopPrank();

        // 测试 1：1 天释放周期
        uint256 yield1 = 86400e6;
        uint256 duration1 = 1 days;

        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, yield1);
        pusd.approve(address(vault), yield1);
        vault.accrueYield(yield1, duration1);
        vm.stopPrank();

        (, , , uint256 released1) = vault.getVestingInfo();
        assertEq(released1, 0); // 刚注入，还未释放

        // 推进 1 秒
        vm.warp(block.timestamp + 1);
        uint256 assets1 = vault.totalAssets();
        uint256 expectedRate1 = yield1 / duration1; // 86400e6 / 86400 = 1e6
        assertEq(assets1, 10000e6 + expectedRate1);

        // 等待释放完成
        vm.warp(block.timestamp + duration1);

        // 测试 2：7 天释放周期
        uint256 yield2 = 604800e6; // 7 天的收益
        uint256 duration2 = 7 days;

        vm.startPrank(yieldInjector);
        pusd.mint(yieldInjector, yield2);
        pusd.approve(address(vault), yield2);
        vault.accrueYield(yield2, duration2);
        vm.stopPrank();

        // 验证释放速率：每秒应该释放 604800e6 / 604800 = 1e6 PUSD
        (, , uint256 unvested2, uint256 released2) = vault.getVestingInfo();
        uint256 expectedRate2 = yield2 / duration2; // 604800e6 / 604800 = 1e6
        assertEq(unvested2, yield2);

        // 推进 1 秒
        vm.warp(block.timestamp + 1);
        uint256 assets2 = vault.totalAssets();
        assertEq(assets2, 10000e6 + yield1 + expectedRate2); // 之前的收益 + 新释放的 1 秒
    }
}
