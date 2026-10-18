// SIOriginal — 原版重制                                        v2.1.16
//
// ============================ v2.1.10 全量审计修复 ============================
// 逐行审计 dylib（2407 行）+ 配置 App（1797 行）后修掉的四类问题：
//
// [真 bug 1] 保活音频引擎从未启动 —— 本轮最要紧的一处。
//   FUBGEntry 把 UIApplicationDidEnterBackgroundNotification 注册到 **Darwin 通知中心**，
//   而那是 App 进程内 NSNotificationCenter 发出的通知，Darwin 总线上永远收不到。
//   后果：gPhysBg 恒为 NO → 音频断言 / 看门狗自愈 / 通知横幅伪装 / 来电中断恢复 /
//   线路变化恢复 五个子系统全部静默失效。场景伪装不受影响（直接 hook 场景更新），
//   所以保活「看起来能用」，洞一直没被发现。已改回进程内注册。
// [真 bug 2] AVAudioSession 两个观察者没持有 token（返回值被丢弃 → token 释放即注销），
//   来电中断恢复与耳机/蓝牙切换恢复同样形同虚设。已用 _fbg_obs 强引用持有。
// [真 bug 3] 慢放模式被「瞬时打开」踩掉（回归）。SIO_transitionDuration 的
//   `if (gEnabled && gInstantTransition) return 0.001;` 不看 gMode，选了慢放时
//   导航/模态/Tab 转场依然 1ms 完成 —— 这正是 v1.8.12 修过的老毛病（当时是硬编码 0.0），
//   v2.1.8 加瞬时打开时又踩回去了。已改为 gMode != 1 时才走瞬时。
// [真 bug 4] 热重载竞态。SIO_reload / _fbg_loadPref 在 Darwin 回调线程改 20+ 个全局
//   （含 gExclude 数组指针），主线程 hook 并发读 → 遍历中数组被换掉 → EXC_BAD_ACCESS。
//   两个 reload 均已改为主线程串行执行。
// [微优化] sio_AIstartAnim 每次调用分配 @YES → 复用 kCFBooleanTrue + ASSIGN，零分配。
// [一致性] 文件头 / 启动日志 / FUBG 日志三处版本号统一为 v2.1.10。
// =========================================================================
//
// ============================ v2.1.11 外部审查补漏 ============================
// 本轮以一份外部《v2.1.9 代码审查报告》为对照，逐条回源码复核后修掉我上一轮漏掉的问题
// （均为报告确凿、我逐行复核成立者）：
//
// [P0-3] 配置缺失不复位：SIO_reload 的 `if (!d)` 分支只清 3 个变量，其余 15 个全局
//   沿用上次的值且无日志 → 「删掉 plist 想恢复默认」完全无效。新增 SIO_resetDefaults()。
// [P1-1] WKWebView setHidden: 命中时 `return` 把隐藏请求**永久丢弃**，无补执行机制。
//   大量 App 只设一次 hidden 就依赖该状态，命中后 webView 永久可见，只能杀进程。
//   改为「延迟执行」：加载完成或 2s 超时后一定补上，期间 App 再显示则自动作废。
// [P1-2] 8 个 UIView 块动画 hook + 2 个老式 API hook 用 `SIO_setUIViewAnim(NO)` 无条件
//   清零而非恢复（SIO_setTransactionDuration 里作者自己写的是保存/恢复）。嵌套块动画时
//   外层会失去重入保护。10 处统一改为保存/恢复。
// [P1-4] gOrigWillPresent 是全局单例：App 先后设两个不同类的 delegate 时后者覆盖前者，
//   此后前者收到通知会被转发到**后者的原实现**（self 类型不匹配）。改为按类存储
//   （NSMapTable<Class, IMP>），并改用 class_addMethod 避免改到父类实现。
// [F-1]  SIO_targetDelay 每次做 1.0/gSpeed，未复用已缓存的 gInvSpeed；
//        SIO_transitionDuration 的 d/gTransBoost 同样。新增 gInvTrans，两处改乘法。
// [F-2]  SIO_hudProtected() / SIO_feelProtected() 未缓存：每次都走数组线性遍历 +
//        字符串比较，却挂在 7 个高频 hook 上。改为进程布尔 gSelfHudProtected /
//        gSelfFeelProtected，与 gSelfBlacklisted 同一套做法。
// [F-3]  保活看门狗常驻 NSRunLoopCommonModes 且从不 invalidate：滚动时每 1.5s 唤醒
//        主线程、前台也空转、关掉音频保活后仍空转。改为进入后台才装、回前台/关开关即卸，
//        周期 1.5s → 3.0s。
// [F-4]  _fbg_appState 热路径每次 dladdr 后 stringWithUTF8String: 分配 NSString +
//        两次 containsString:。applicationState 极高频，改在 C 字符串上 strstr，零分配。
// [F-C]  热重载不再只打 toast：补一行完整运行时状态日志（含 hudGuard / feelGuard /
//        listHardGuarded / blacklisted / override / physBg），让「改了配置没生效」可自查。
// [P2-1] gCustomTransFast 全文 3 处赋值 0 处消费、App 侧无入口 —— 双重死配置，删除。
// [注释] ListAccel/ZoomAccel 缺键默认与注释矛盾（注释写 NO、代码是 YES）、
//        出厂默认注释与代码矛盾（声称默认开会闪退，真凶实为 LPG hook 且已移除）。
//        两处均为注释失真、代码正确，只改注释消除误导，不动行为。
// =========================================================================
//
// ======================= v2.1.12 外部审查（第二份）补漏 =======================
// 对照《v2.1.11 审查与功能加强报告》逐条回源码复核，实施 7 项修复 + 2 项增强：
// [N-1] FUBG 侧缺出厂复位：_fbg_loadPref 的 `if (!d)` 只清部分全局 → 新增
//       _fbg_resetDefaults()，与动画侧 SIO_resetDefaults() 对称。
// [N-2] 列表硬保护名单在配置 App 侧有一份镜像（HardGuardBundles），两侧必须同步，
//       已加交叉指向注释，改一侧时必然看到另一侧。
// [N-3] WK 延迟隐藏入口去重：pending 期间重复 setHidden:YES 会插入第二笔延迟任务。
// [N-4] _fbg_willPresent 未命中时吞掉 completionHandler → 补 else 分支回调。
// [N-5] 慢放模式下 HUDDelay 不放大是有意决策，补注释（非 bug）。
// [F-D] 新增 -[UIViewPropertyAnimator startAnimationAfterDelay:] hook。
//       报告主张它必须共用 gInPAInit 重入锁；经复核该锁防的是 duration 双重缩放，
//       而此处改的是 delay（另一个量），共用反而会漏掉合法调用 —— 保留判空式
//       fail-safe，不共用锁，并在代码内写明分歧理由。
// [F-A] 运行时 hook 命中统计（22 槽 _Atomic 计数器 + SIO_HIT 宏，70 处注入）。
//       报告原设计是「dylib 写 plist → 配置 App 读」；该方案不可行：dylib 跑在目标
//       App 进程内，受其沙盒限制，写不了 root 拥有的 /var/Managed Preferences/mobile/。
//       改为「配置 App 发 Darwin 通知 → dylib 在目标 App 内弹 6s 浮层」。
// =========================================================================
//
// ============================ v2.1.13 统计可读性 ============================
// [v2.1.13-1] 命中统计浮层加**状态行**（SIO_statsStatusLine）。
//   起因：用户在顺丰同城骑士上请求统计，看到一片 0，第一反应是「没注入/没生效」，
//   实际是三道闸门按设计把它拦住了。纯数字无法自证。现在浮层顶部固定显示
//   bundle id + 闸门状态（总开关关闭 / 整体黑名单命中 / 列表⛔硬保护 /
//   手感⛔跳过 / HUD⛔跳过 / 全部生效），0 命中也能一眼判断是被拦还是真没覆盖。
// [v2.1.13-2] 0 命中文案由「动画走了未覆盖的路径」改为「本 App 所有 hook 路径均被跳过」，
//   前者在闸门拦截场景下是误导。
// =========================================================================
//
// ===================== v2.1.14 解除顺丰同城骑士硬保护 =====================
// 用户选择「两道全解」：移除 com.sfic.knight 的全部硬保护（风险自担）。
// [V-1] SIO_listHardBlocked() 名单移除 com.sfic.knight → ListAccel 不再恒关。
// [V-2] SIO_feelProtected() 移除 `if (bid == com.sfic.knight) return YES;` 硬编码
//       → 整手感模块（FastScroll/FastTap/setter 强黏）对此 App 正常生效。
// [契约] App 侧 HardGuardBundles() 同步移除 com.sfic.knight（见 N-2 双向契约，
//   否则专属覆盖页会显示「列表加速：开」而实际被硬关 = 假开关）。
// [风险] 两处原始注释保留作记录：v1.8.14 记录「24 个 TV/CV hook 可能破坏列表状态机→
//       卡死/崩溃」；v2.1.8 记录 FastScroll 把 decelRate 锁 0.99 导致订单列表飞太快难抢单。
//       若骑士出现异常，把两行加回即可恢复，无需改别处。
// [V-3] 命中统计浮层下移状态栏之下（之前窗口从 y=0 起，卡片压住时间/信号）。
// =========================================================================
//
// =================== v2.1.15 统计浮层在「常驻后台 App」不弹 ===================
// 现象：微信能弹统计浮层，顺丰骑士怎么都不弹（也不崩）。
// 根因：SIO_onStatsRequest 收到 Darwin 通知后直接调 SIO_showStats()，而后者开头有
//   `if (app.applicationState != UIApplicationStateActive) return;`。
//   · 微信被系统挂起 → 通知要等它恢复到前台才投递，那时已 Active → 能弹；
//   · 顺丰骑士这类要持续定位的 App 在后台仍活着 → 通知到达即处理，此时是 Background
//     → 被 active 检查 return 掉，之后回到前台也不会补弹。
// 修法：收到请求只置 sioStatsArmed=YES；若当时已 Active 才立即弹，否则挂起，
//   等 UIApplicationDidBecomeActiveNotification 到达时再弹（SIO_onDidBecomeActive）。
//   观察者令牌存 sioStatsActiveObs —— block 观察者不持有就会随返回值释放并自动注销，
//   与 v2.1.10 的 AVAudioSession 是同一个坑。
// =========================================================================
//
// ============================ v2.1.16 统计面板自解释（行为不变） ============================
// 用户选择「保持现状，只把面板标注清楚」。微信等被保护 App 上看统计浮层时，
// 手感/HUD 桶计数很高（如微信 Feel 9167）却被闸门全拦 → 看着像「生效很多」实为一个没应用。
// 根因：SIO_HIT 在 hook 第一行、闸门之前计数，记的是「调用」不是「生效」。
// 本轮只改面板呈现，不动任何加速/保护行为：
// [P-1] 每个桶拆成「调用 N / 生效 M」两个数。生效 = 未被当前闸门拦掉的计数。
//       闸门状态在一次热重载内恒定，故按当前 gEnabled/gSelfBlacklisted/gSelfFeelProtected/
//       gSelfHudProtected/gListAccel/gHUDFast/gWKFastShow/gFastScroll/gFastTap 推算，
//       确定性正确，无需改动 70 处 hook（零编译风险）。
// [P-2] 整桶被闸门拦掉的（如微信手感/HUD、关掉的列表加速）标 ⛔已跳过；
//       浮层头部汇总「调用总数 / 生效总数」，0 命中文案保留。
// [P-3] 配置 App 统计卡片说明同步改写为「调用=hook 被命中次数，生效=未被闸门拦截的次数」。
// =========================================================================
//
// ============================ v2.1.7 真·闪退修复 ============================
// v2.1.1 没修好 —— 因为真凶不是默认值，是一个**无条件安装**的坏 hook。
//
// 崩溃证据（两份独立的 .ips，两个不同 App，完全相同的崩溃帧）：
//   EXC_BAD_ACCESS / SIGSEGV in objc_retain
//   ← sio_LPG_init +60                                   （本 dylib）
//   ← -[UITabBarController _accessibilityHUDLongPressRecognizer]   （WeChat 8.0.58）
//   ← -[UIScrollViewKnobLongPressGestureRecognizer initWithTarget:action:] （Knight 11.5.0）
//
// 元凶：v2.0.0 加的「长按手势加速」hook 了 UILongPressGestureRecognizer 的
// initWithTarget:action:。这是 **init 族方法**，ARC 对其返回值有特殊所有权约定；
// 用 method_setImplementation 挂钩 + 普通函数指针回调原实现，编译器会在
// sio_LPG_init 里对返回值插入 objc_retain，拿到坏指针 → SIGSEGV。
// 关键：这个 hook 一直是无条件安装的，开关关不关都崩 —— 所以
// v2.0.5/v2.0.6/v2.1.1 三次「调默认值修闪退」全都白调，从来没碰到真正的病根。
//
// v2.1.7 处置：
//   1. 【删除】长按手势加速连同两个 hook —— hook init 族方法这条路本身就不安全，
//      不做「修一下再上」，不做假开关。
//   2. 【按需安装】FastScroll/FastTap 的 3 个 hook 只在开关为开时安装，
//      关闭时引擎形态与 v1.8.17（已验证稳定）完全一致。
//   3. 【全开】FastScroll / FastTap / ZoomAccel / ListAccel 默认全部打开
//      （ListAccel 仍受硬保护名单约束：顺丰同城骑士 / SpringBoard 恒关）。
//   4. 保留 ×15 / 显式 ×3 / 转场 ×2、性能优化、假开关清理、前端重做。
// 注意：FastScroll/FastTap 的 hook 是启动时按状态安装的，运行中把开关从关改开
// 需要重启目标 App 才会生效（热重载装不了新 hook）。
// =========================================================================
//
// ============================ v2.1.0/v2.1.1 历史变更 ============================
// [假开关 1] FUBGFloatingBall（悬浮球）—— 彻底移除。
//   该开关在 v1.8.10 起被全局禁用，但 FBGFloatingWindow 类与其配套的 FBGToastView
//   共 281 行代码一直留在 dylib 里：+shared / attachWhenSceneReady 全文件无任何调用点，
//   即「类存在但永不实例化」。配置 App 里那个置灰的开关仍在往 plist 写值，
//   dylib 读了 gShowBall 却没有任何消费方 —— 标准假开关。本轮整块删除。
// [假开关 2] FUBGExcludeApps —— 移除。
//   配置 App 没有任何界面能编辑它，且每次保存都把它写成空数组 → 恒等于空表。
//   排除语义已完全由 Blacklist 覆盖（黑名单对动画与保活同时生效）。
// [假开关 3] fubg_local_off（gLocalOff）—— 移除。
//   _fbg_loadPref 里读出来后下一行立刻被强制置 NO，读操作纯属无意义。
// [全速] 出厂默认档改为极速：加速 ×15、时长下限 0.005s、显式动画再 ×3、转场再 ×2，
//   滑行惯性 / 点击零延迟 / 长按加速（0.20s）三项手感默认全开。
// [性能 1] 新增 SIO_recalc()：把「下限范围校验」「1/gSpeed」「1/gLayerBoost」
//   「!gEnabled || gSelfBlacklisted」四个派生量在 reload 时算一次。
//   SIO_targetDuration 是所有 hook 的最内层，原实现每次都要做 1 次除法 + 1 次范围比较；
//   现在除法换成乘法，范围判断消失。
// [性能 2] 微信放大态探测器：节流窗口 0.25s → 0.35s，DFS 节点上限 3000 → 1500。
//   倍率拉到 ×15 后动画调用频率上升，探测开销同比变高；放大态 ScrollView 几乎总在
//   视图树前几层，1500 已足够覆盖真实场景。
// =========================================================================
//
// 基于 pw5a29 Speed Intensifier 10.1-1 的机制还原（CAAnimation setDuration: 单基类 hook
// + CASpring 参数缩放 + 慢放模式），针对 TrollStore / iOS 16 全新实现：
//   · 无 CydiaSubstrate 依赖，纯 ObjC runtime swizzle（TrollFools 注入友好）
//   · 线程局部标记防 CATransaction/UIView 双重除法（原版未处理的问题）
//   · 慢放（原版 slowDownFactor）与瞬切模式
//   · Darwin 通知热重载配置，黑名单逐进程判断
// 不包含任何 SpeedIntensifier / SIFusion / SpeedsterTS 项目代码。
//
// ============================ v1.8.12 优化加强 ============================
// [真 bug 1] CALayer addAnimation:forKey: 兜底改为调用保存的原始 IMP。
//   原来用 objc_msgSend(anim, setDuration:) 回写，而 setDuration: 自己已被 hook，
//   于是 duration 被 SIO_targetDuration 连乘两次（加速 ×5 实际变成 ÷25），
//   恰好违反本文件声称的「防双重除法」设计。
// [真 bug 2] runningPropertyAnimatorWithDuration:delay:options:animations:completion:
//   原来写成 SIO_swizzleClass(object_getClass(pa), …)：class_getClassMethod 内部是
//   class_getInstanceMethod(object_getClass(cls), sel)，再传元类等于去根元类里找，
//   必然返回 NULL 静默跳过——该 hook 从上线起从未生效。改为 SIO_swizzleClass(pa, …)。
// [真 bug 3] Blacklist 兼容 NSString 格式。原来无条件 componentsJoinedByString:，
//   一旦 plist 里是字符串（手工编辑/旧版本/其他工具写入）即 unrecognized selector，
//   注入进程启动崩溃。FUBG 侧 v1.8.6 已修，动画侧这次补齐。
// [真 bug 4] 导航/模态转场时长改为按模式计算 SIO_targetDuration(0.35)。
//   原来硬编码 setAnimationDuration:0.0 —— 慢放模式下导航/弹窗依旧瞬间完成，
//   慢放对这类转场等于完全无效；现在慢放真的变慢，加速模式约 0.07s（几乎无感）。
// [隐患 5] ListAccel 缺键默认由 YES 改为 NO。危险功能不再 fail-open。
// [隐患 6] FUBGExcludeApps 与 Blacklist 合并。原来排除表赋值后立刻被 Blacklist
//   无条件覆盖，排除机制实际从未生效。
// [性能 7] 黑名单在重载时一次性解析为进程布尔值 gSelfBlacklisted。
//   SIO_blocked() 是全部动画/事务 hook 的必经热路径，原来每次都要
//   componentsSeparatedByString: 分配数组。
// [性能 8] 微信预览放大态探测器加 3000 节点上限，超大视图树不再拖慢主线程。
// [健壮 9] 所有原 IMP 调用前判空；swizzle 增加重复安装保护（绝不把自己的 IMP
//   存成 orig 导致自递归）；两处 constructor 安装全程 @try 包裹，异常放行原实现。
// [加强 10] 新增 5 个低风险 hook：
//   +[UIView animateKeyframesWithDuration:delay:options:animations:completion:]
//   -[UIViewPropertyAnimator initWithDuration:timingParameters:]（2 参指定初始化器，
//     带线程局部重入保护，避免与 3 参变体双重缩放）
//   -[UITabBarController setSelectedIndex:] / setSelectedViewController:
//   -[UIViewController transitionFromViewController:toViewController:duration:…]
//   +[UIView performSystemAnimation:onViews:options:animations:completion:]
// 全部沿用已验证的 CATransaction/时长改写机制，不触碰 TV/CV 列表状态机。
// =========================================================================
//
// ============================ v1.8.14 顺丰同城骑士防护（v2.1.14 已取消） ============================
// ⚠ v2.1.14：应要求解除 com.sfic.knight 的全部硬保护（SIO_listHardBlocked 名单 +
// SIO_feelProtected 硬编码两处均已移除）。下方历史说明保留作风险记录，当前不生效。
//
// 场景：TrollStore + TrollFools 把本 dylib 注入顺丰同城骑士 (com.sfic.knight)。
// 该 APP 是本项目实测确认的「列表 hook 冲突」App：24 个 TV/CV 变更类 hook 会破坏
// 它的列表状态机 → 卡死 / 崩溃（v1.8.11 之前靠 bundle id 硬编码排除，v1.8.11 改成
// 纯开关控制后，只剩"用户记得关"这一层，而配置是全局的 —— 为别的 App 打开列表
// 加速会连带把顺丰同城也打开）。
//
// 当初做两件事：
//  1. [防护] 列表 hook 硬保护名单 SIO_listHardBlocked()：名单内 App 的 ListAccel
//     恒为 NO，优先级高于全局开关与 App 覆盖，任何配置都打不开。
//     —— 安全项必须 fail-safe，不接受"忘了关"。
//  2. [优化] App 级配置覆盖 AppOverrides：允许为指定 Bundle ID 单独设置
//     倍率/模式/弹簧/转场/列表/保活，互不干扰。这样顺丰同城可以调到比其他 App
//     更合适的参数，而调其他 App 不会连带影响它。
//     优先级：硬保护 > App 覆盖 > 全局配置。
// =========================================================================
//
// ==================== v1.8.15 顺丰同城骑士 11.5.0 针对性 hook ====================
// 依据：拆包 Knight.app 11.5.0（com.sfic.knight，arm64 已解密，10947 个 ObjC 类）
// 得到的证据表，见文件末尾「拆包证据」注释。落地两件事：
//
// [真 bug] 修掉 CAAnimation ↔ CALayer 的残留双重缩放。
//   sio_CAAnim_setDuration 会缩放一次，sio_layer_addAnim 兜底又会缩放一次：
//   App 只要「先 setDuration 再 addAnimation」（标准写法）就被连缩两次，
//   实际倍率是 speed²（×5 变 ×25），并频繁撞上 0.01s 下限。
//   本 App 的高德地图相机动画（MAMapKeyFrameAnimation，CAKeyframeAnimation 子类）
//   与 NXDesign 的 addAnimation:forKey: 路径都吃这个 bug。
//   修法：用关联对象给动画打「已处理」标记，两个入口谁先处理谁打标，另一个跳过。
//
// [新覆盖] UIScrollView setZoomScale:animated: / zoomToRect:animated:
//   拆包证实 App 侧（NXDesign.framework）确实在用这两个入口，而此前完全没接管。
//   实现要点：只用 CATransaction 覆写时长，绝不把 animated:YES 改成 NO
//   （v1.8.3/v1.8.4 微信预览故障的根因就是改写 animated 语义 + 禁用事务动作）。
//   默认关闭（ZoomAccel=0），因为这一族在微信上出过"预览页卡死"，需要实测再开。
// =========================================================================
//
// ==================== v1.8.16 系统级增强 + SpringBoard 防护 ====================
// [SpringBoard] 更正：纯 TrollStore + TrollFools 环境**无法**把 dylib 注入
//   SpringBoard。TrollFools 是 in-place injection（insert_dylib + ChOma 重签名），
//   官方只支持「可移除的系统应用 / 已解密 App Store 应用 / 加密 App Store 应用」，
//   而 SpringBoard 属不可移除的核心系统应用，位于只读的 SSV 系统卷
//   （/System/Library/CoreServices/SpringBoard.app），根本写不进去。
//   桌面动画要在"不注入"前提下加速，走 Managed Preferences 域的
//   UIAnimationDragCoefficient（配置 App 的 ×5/×10/×20 档）—— SpringBoard 同样
//   以 mobile 身份运行并读取该域。
//   下面两道防护只在**越狱路线**（如 Dopamine + ElleKit 指定 SpringBoard）下才会
//   真正生效；留着零成本，用于自动拦住最危险的两种情况：
//     1. com.apple.springboard 进列表 hook 硬保护名单（SpringBoard 内部有大量
//        TV/CV，列表 hook 一旦打开会破坏它的状态机 → 黑屏/白苹果）；
//     2. com.apple.springboard 进内置保活排除名单 —— 保活引擎（音频断言 +
//        场景伪装）对桌面进程毫无意义，且 SpringBoard 本身就是场景宿主，
//        在它内部吞掉 scene 更新会影响全局 App 的后台化。这两项都是 fail-safe。
//
// [体感加速] 新增两个默认关闭的开关（不属于"改时长"，而是改交互手感）：
//     FastScroll：UIScrollView.decelerationRate = Fast（滑行距离大幅缩短）
//     FastTap   ：delaysContentTouches = NO（去掉列表点击约 150ms 延迟）
//   在 -[UIScrollView didMoveToWindow] 里统一施加，覆盖 nib/storyboard/code
//   三种来源的滚动视图。
// =========================================================================
//
// ==================== v1.8.17 显式动画额外倍率 + 极端档回归 ====================
// [LayerBoost] v1.8.15 修掉 CAAnimation 双重缩放后，显式动画（转圈/进度/旋转/
//   地图相机）的时长从 ÷speed² 回到 ÷speed，肉眼明显变慢 —— 用户实测反馈
//   "APP 加载图标转圈动画变慢了"。新增 LayerBoost（显式动画额外倍率：
//   1 / 2 / 3 / 5 / 10，默认 1）：
//     · 只叠加在 CAAnimation setDuration: 与 CALayer addAnimation: 这条路径上；
//     · **不影响** UIView 块动画、CATransaction、导航/模态/Tab/列表/滚动 hook；
//     · 因此可以单独把"转圈"调快，而不会像"全局倍率拉到 25"那样把块动画
//       一起压到 1 帧（那才是真正会触发完成回调配对故障的做法）；
//     · 仍受同一条 0.01s 下限约束；慢放模式不叠加（慢放是刻意看动画细节）。
//   设 5 = 精确恢复 v1.8.15 之前的 ÷speed² 手感。
// [极端档] 配置 App 的全局动画系数恢复"极端"档（0.0001）。旧版本写入的 0.0001
//   现在**映射到该档并明确警告**，而不是像 v1.8.16 那样被静默清除 ——
//   后者会把用户既有设置无提示地抹掉，是不对的。
// =========================================================================
//
// ==================== v2.0.0 Max 超强功能版 ====================
// [FloorDuration] 动画安全下限可调（0.005 / 0.01 / 0.02 / 0.05，默认 0.01）。
//   旧版 0.01s 在代码里写死；允许追求极致的用户用 0.005（更快，风险自担），
//   也允许保守用户用 0.02/0.05。瞬切模式同样使用该下限，不再写死 0.01。
// [TransitionBoost] 进阶转场独立额外倍率（×1 / ×1.5 / ×2 / ×3，默认 ×1）。
//   与 LayerBoost 同思路：只作用于导航/模态/Tab 转场的 CATransaction 时长，
//   不影响块动画与显式动画；慢放模式不叠加；受 FloorDuration 下限保护。
//   想让 push/pop/弹窗再快一倍而不动全局倍率，用它。
// [FastLongPress] 长按手势加速：hook UILongPressGestureRecognizer 的
//   initWithTarget:action: 与 setMinimumPressDuration:，把系统默认 0.5s
//   压到可选的 0.20 / 0.30 / 0.40s（默认 0.30）。App 后续任何二次设置也会被
//   钳到该值，真正生效（比只在创建时改一次可靠）。
// [手感强黏] FastScroll / FastTap 改为在 setter 层强制：
//   setDecelerationRate: / setDelaysContentTouches: 也被接管，App 在
//   didMoveToWindow 之后再改回去的值会被重新钳回，开关不再"时灵时不灵"。
// [补盲区] +[UIView transitionFromView:toView:duration:options:completion:]
//   （无 animations 段的变体）此前未覆盖，本轮补上时长改写。
// [InAppNotify] 配置热重载时，若目标 App 正在前台，弹一个不接收触摸的顶部
//   小提示（userInteractionEnabled=NO 的 UIWindow，1.5s 自动消失），
//   明确显示当前生效模式/倍率，避免"保存了不知道有没有用上"。
//   它与 v1.8.10 永久禁用的悬浮球完全不同：不拦截任何触摸、不抢状态栏、非常驻。
// [SlowFactor] 慢放倍率开放配置（×2 / ×3 / ×5 / ×10，引擎早支持，配置器补上）。
// =========================================================================
//
// ============================ v1.8.13 优化加强 ============================
// [加强] 补齐老式 UIView 动画 API 的时长/延迟接管：
//   +[UIView setAnimationDuration:] 与 +[UIView setAnimationDelay:]
//   这是 beginAnimations:context: / commitAnimations 时代的唯一时长入口。
//   本支一直缺失（父项目 SpeedIntensifier 的增强层早已包含），而老 SDK、部分
//   国产 App 内部与第三方库仍在用这套 API —— 它们此前完全不受加速影响。
//   两个都是纯 setter（只改一个数值），是本项目风险最低的一类 hook。
//   双重缩放防护：这两个 setter 很可能被 UIKit 落到 CATransaction.setAnimationDuration:
//   上，或反过来被 animateWithDuration: 内部回调，因此：
//     · 进入时若已在自己的一次块动画包裹内（SIO_inUIViewAnim）→ 原样透传；
//     · 调用原 IMP 期间置起同一线程局部标记 → 抑制内部再入。
// =========================================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>   // v2.1.12（F-A）：hook 命中计数器用 _Atomic + memory_order_relaxed
// v2.1.11：strstr 用于 _fbg_appState 热路径上的 C 字符串判定（零分配），显式引入。
#include <string.h>
#include <dlfcn.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <dlfcn.h>
#import <notify.h>
#import "FUBGNoiseData.h"

#define kPrefDomain  @"com.apple.UIKit"
#define kPrefPath    @"/var/Managed Preferences/mobile/com.apple.UIKit.plist"
#define kNotifyName  @"com.local.sioriginal.settingschanged"
// v2.1.12（F-A）：配置 App 发这个通知，请求 dylib 在当前前台 App 内弹出命中统计浮层。
// 名字必须与配置 App 侧 NotifyStatsKey 完全一致，否则按钮按了没反应。
#define kNotifyStats @"com.local.sioriginal.requeststats"

// ---------- 配置 ----------
// v2.1.11 注释订正（行为不变，只改注释）：
// 这段注释原文声称「FastTap/FastScroll 默认开启会导致全部 App 闪退，故回退为关」，
// 与紧邻其下的实际代码（全为 YES）直接矛盾。真实情况是：那三次「闪退」的真凶
// 是 sio_LPG_init 这个无条件安装的坏 hook（见文件头「v2.1.7 真·闪退修复」的完整
// 取证），与默认值无关；该 hook 已在 v2.1.7 整体移除，因此 v2.1.7 起默认值恢复全开。
// 旧的因果说明会误导维护者把当前正确的默认值当成 bug 去「修回 NO」，故改写。
static BOOL     gEnabled   = YES;
static int      gMode      = 0;      // 0=加速 1=慢放 2=瞬切
static double   gSpeed     = 40.0;   // 全速加速：40×
static double   gSlowFactor = 2.0;   // 慢放倍率
static BOOL     gSpring    = YES;    // CASpring 参数缩放
static BOOL     gExtra     = YES;    // 导航/模态进阶转场
static BOOL     gListAccel = YES;    // TV/CV 列表全家桶
static BOOL     gZoomAccel = YES;    // UIScrollView 缩放动画
static BOOL     gFastScroll = YES;   // 滑行惯性加急
static BOOL     gFastTap = YES;      // 点击零延迟
static double   gLayerBoost = 5.0;   // 显式动画额外倍率（转圈/旋转单独加速 5×）
static double   gFloorDuration = 0.005;  // 极限下限 5ms（全速档不撞 UIKit 最小阈值）
static double   gTransBoost = 3.0;      // 转场独立倍率 3×
static BOOL     gInAppNotify = YES;     // 热重载顶部提示

// v2.1.8：极速模式
static BOOL     gInstantTransition = YES;   // v2.1.8 full-speed default-on
static BOOL     gHUDFast       = YES;
static double   gHUDDelay      = 0.15;
static BOOL     gWKFastShow    = YES;
// v2.1.11：gCustomTransFast 已删除。它是个**双重死配置** —— 全文 3 处赋值、0 处消费，
// 且 App 侧不在 SIOConfigKeys 白名单、不在 save()、也没有任何 UI 控件能写它。
// 按本项目 v2.1.0 定下的判定标准（「dylib 读了却没有任何消费方 = 假开关」）直接移除。

// ---------- 热路径派生量 ----------
static double   gInvSpeed    = 1.0 / 40.0;
static double   gInvLayer    = 1.0 / 5.0;
// v2.1.11：转场倍率倒数。SIO_transitionDuration 里原本每次做 `d / gTransBoost`，
// 与 gInvSpeed / gInvLayer 同一套「除法→乘法」范式，只是当年漏了这一处。
static double   gInvTrans    = 1.0 / 3.0;
static double   gFloorCached = 0.005;
static BOOL     gBlockedFast = NO;
static BOOL     gIsWeChat  = NO;
// v1.8.12：黑名单在重载时一次性解析成本进程布尔值，热路径零分配（见 SIO_reload）
static BOOL     gSelfBlacklisted = NO;
static NSString *gSelfBundle = nil;
// v2.1.11：gPhysBg 原定义在保活段，但热重载日志（动画段）要打印它做排障用。
// 这里把定义前移，保活段保留注释说明它如何被维护。
static BOOL gPhysBg = NO;   // 物理上是否处于后台（由真实生命周期通知维护）

// v2.1.11：保护名单命中结果同样缓存为进程布尔。
// SIO_hudProtected() / SIO_feelProtected() 每次调用都要 dispatch_once → 取 bundleID →
// 数组线性遍历 + 逐项 isEqualToString:，而它们挂在 7 个高频 hook 上
// （startAnimating、WKWebView setHidden:、SV/MB HUD、ScrollView 三个 setter）。
// bundle id 进程内恒定不变，与 gSelfBlacklisted 完全同级，故只算一次。
static BOOL     gSelfHudProtected  = NO;
static BOOL     gSelfFeelProtected = NO;

static pthread_key_t gInUIViewAnimKey;
static pthread_key_t gInPAInitKey;   // v1.8.12：UIViewPropertyAnimator 初始化重入保护

static inline BOOL SIO_inUIViewAnim(void)   { return (BOOL)(intptr_t)pthread_getspecific(gInUIViewAnimKey); }
static inline void SIO_setUIViewAnim(BOOL v){ pthread_setspecific(gInUIViewAnimKey, (void *)(intptr_t)(v ? 1 : 0)); }
static inline BOOL SIO_inPAInit(void)       { return (BOOL)(intptr_t)pthread_getspecific(gInPAInitKey); }
static inline void SIO_setPAInit(BOOL v)    { pthread_setspecific(gInPAInitKey, (void *)(intptr_t)(v ? 1 : 0)); }

// =========================================================================
// v2.1.12（F-A）运行时 hook 命中统计
// -------------------------------------------------------------------------
// 背景：文件末尾那份「拆包证据」是**手工**对单个已解密 App 做的静态分析
// （解析 __objc_classname / __objc_methname 再逐个比对）。它有三个硬限制：
//   ① 只能针对单个 App，且每次都要手工做一遍
//   ② 静态分析看不到调用频率 —— 被引用 ≠ 被高频调用
//   ③ 发现不了「走了完全没覆盖的路径」（只能告诉你已知的 API 用没用）
// 计数器补上的是第 ②③ 条：运行时实测每个入口被走过多少次。
//
// 用途：
//   · 精准调参 —— 用户报「某 App 转圈变慢」，一看统计就知道它主要走哪条路，
//     该调 LayerBoost 还是全局 Speed，不用再猜
//   · 暴露真盲区 —— 若某 App 动画完全没被加速而 22 个计数**全是 0**，
//     直接证明它走了未覆盖的路径（静态拆包给不出这个结论）
//   · 验证 hook 是否真的生效 —— 某个计数器长期为 0 说明那条路在目标 App 上
//     根本没被走到（v1.8.12 那个「元类 bug 导致 hook 从未生效」的问题，
//     如果当时有计数器，一眼就能看出来）
//
// 开销：memory_order_relaxed 单次自增，arm64 上是一条 ldxr/stxr 或普通 add。
// 对照这些 hook 内部本来就要做 SIO_blocked() 判断、CATransaction begin/commit、
// block 捕获，一次整数自增完全在噪声以下。纯观测，不改变任何 hook 行为。
//
// 注意：只统计「做加速决策的入口」。像 sio_AIstopAnim（取消延迟）、
// sio_WKClass / sio_WKdeferHide（内部辅助）不算 hook 命中，不计入。
// =========================================================================
enum {
    SIO_HIT_CAANIM = 0,   // CAAnimation setDuration:
    SIO_HIT_CATX,         // CATransaction setAnimationDuration:
    SIO_HIT_SPRING,       // CASpringAnimation mass/stiffness/damping
    SIO_HIT_LAYER_ADD,    // CALayer addAnimation:forKey:
    SIO_HIT_UVBLOCK,      // UIView animateWithDuration: 系列（含 transition）
    SIO_HIT_KEYFRAME,     // UIView animateKeyframesWithDuration:
    SIO_HIT_SYSANIM,      // UIView performSystemAnimation:
    SIO_HIT_OLDSTYLE,     // UIView setAnimationDuration:/Delay:（老式 API）
    SIO_HIT_NAV,          // UINavigationController push/pop/setViewControllers
    SIO_HIT_PRESENT,      // present/dismiss/transitionFromViewController
    SIO_HIT_TAB,          // UITabBarController 切换
    SIO_HIT_LIST_TV,      // UITableView 系列（17 个）
    SIO_HIT_LIST_CV,      // UICollectionView 系列（9 个）
    SIO_HIT_PA,           // UIViewPropertyAnimator 系列（7 个）
    SIO_HIT_SV_SCROLL,    // UIScrollView setContentOffset:/scrollRectToVisible:
    SIO_HIT_SV_ZOOM,      // UIScrollView setZoomScale:/zoomToRect:
    SIO_HIT_FEEL,         // 手感：didMoveToWindow / decelerationRate / delaysContentTouches
    SIO_HIT_HUD_AI,       // UIActivityIndicatorView startAnimating
    SIO_HIT_HUD_SV,       // SVProgressHUD dismissWithDelay:
    SIO_HIT_HUD_MB,       // MBProgressHUD hide:
    SIO_HIT_WK,           // WKWebView setHidden:
    SIO_HIT_NOTIFY,       // UNUserNotificationCenter willPresent（保活场景伪装）
    SIO_HIT__COUNT
};
static _Atomic uint32_t gHitCounts[SIO_HIT__COUNT];
// 名字表：日志与浮层都用它，保证两者口径一致（顺序必须与上面的 enum 严格对应）
static const char * const kSIOHitNames[SIO_HIT__COUNT] = {
    "CAAnim", "CATx", "CASpring", "LayerAdd", "UIViewBlock", "Keyframe",
    "SysAnim", "OldStyle", "Nav", "Present", "Tab", "ListTV", "ListCV",
    "PA", "SVScroll", "SVZoom", "Feel", "HUD_AI", "HUD_SV", "HUD_MB",
    "WK", "Notify"
};
#define SIO_HIT(slot) \
    atomic_fetch_add_explicit(&gHitCounts[(slot)], 1u, memory_order_relaxed)
// ===================== F-A 命中统计定义结束 =====================

// v1.8.12：原 IMP 判空（红线规则 #4）。方法不存在时 hook 不会被安装，这里是纯防御：
// 万一 orig 为空，直接放弃本次拦截，绝不对空指针发消息。
#define SIO_REQUIRE_ORIG(imp)      do { if (__builtin_expect((imp) == NULL, 0)) return; } while (0)
#define SIO_REQUIRE_ORIG_NIL(imp)  do { if (__builtin_expect((imp) == NULL, 0)) return nil; } while (0)

// ---------- v1.8.15：CAAnimation 时长缩放幂等标记 ----------
// 两个入口都会缩放时长：CAAnimation 的 setDuration: 属性 setter，以及
// CALayer 的 addAnimation:forKey: 兜底。App 标准写法「先设 duration 再 add」
// 会让两个入口都跑一遍 → 连缩两次（×speed²），并容易撞 0.01s 下限。
// 用关联对象打标：谁先处理谁打标，另一个看到标记就跳过。
// 注意：显式 setDuration: 不受标记限制 —— 那是 App 的新意图，必须按新值重新缩放。
static const void *kSIOScaledMark = &kSIOScaledMark;

static inline BOOL SIO_animScaled(id anim) {
    return anim != nil && objc_getAssociatedObject(anim, kSIOScaledMark) != nil;
}
static inline void SIO_markAnimScaled(id anim) {
    if (!anim) return;
    // 用 CFBoolean 常量避免每次分配 NSNumber
    objc_setAssociatedObject(anim, kSIOScaledMark,
                             (__bridge id)kCFBooleanTrue,
                             OBJC_ASSOCIATION_ASSIGN);
}

// v2.0.0：安全下限可配置（FloorDuration，0.005–0.1，非法值回落 0.01）
// v2.1.0：范围校验已前移到 SIO_recalc，这里只是一次读取。
static inline double SIO_floor(void) {
    return gFloorCached;
}

static inline double SIO_targetDuration(double orig) {
    if (!gEnabled) return orig;
    double fl = gFloorCached;
    double d;
    switch (gMode) {
        case 1:  d = orig * gSlowFactor; break;            // 慢放
        case 2:  d = fl;                break;            // 瞬切（下限可调）
        default:
            if (gSpeed <= 1.0001) return orig;
            d = orig * gInvSpeed;      break;              // 加速（v2.1.0：除法→乘法）
    }
    if (d > 0.0 && d < fl) d = fl;                         // 时长下限
    return d;
}

// v1.8.17：显式动画（CAAnimation / CALayer）路径专用的时长换算。
// 在全局倍率之上再叠加 LayerBoost，仅作用于这条路径：
// 转圈 / 进度 / 旋转 / 地图相机这类动画都走「设时长 → addAnimation」，
// v1.8.15 修掉双重缩放后它们从 ÷speed² 回到 ÷speed，肉眼明显变慢。
// 单独给它们加倍率，就不会像"把全局倍率拉到 25"那样把 UIView 块动画一起压到 1 帧。
// 慢放模式不叠加（慢放是刻意要看动画细节），下限仍是同一条 0.01s。
static inline double SIO_targetDurationLayer(double orig) {
    if (!gEnabled) return orig;
    double d = SIO_targetDuration(orig);
    if (gMode == 1) return d;
    if (gLayerBoost > 1.0001 && d > 0.0) {
        d = d * gInvLayer;                                 // v2.1.0：除法→乘法
        double fl = gFloorCached;
        if (d < fl) d = fl;   // 下限与主路径保持一致
    }
    return d;
}

static inline double SIO_springScale(void) {
    // 弹簧时间缩放与倍率一致；慢放时反向放大
    if (!gEnabled) return 1.0;
    if (gMode == 1) return gSlowFactor;
    if (gMode == 2) return 20.0;
    return (gSpeed <= 1.0001) ? 1.0 : gSpeed;
}

// v1.8.12：设置事务时长的唯一正确入口。
// 本体代码里凡是自己构造 CATransaction 时长的地方（导航/模态/Tab/列表/滚动/系统动画），
// 都必须走这里：`[CATransaction setAnimationDuration:X]` 会再次进入已被 swizzle 的
// setAnimationDuration:，于是同一个 X 被 SIO_targetDuration 缩放第二次
// （例如期望 0.07s 实际 0.014s，慢放期望 0.7s 实际 1.4s）。
// 这里借线程局部标记抑制这一层，嵌套时原样恢复。
static inline void SIO_setTransactionDuration(double d) {
    BOOL was = SIO_inUIViewAnim();
    SIO_setUIViewAnim(YES);
    [CATransaction setAnimationDuration:d];
    SIO_setUIViewAnim(was);
}

// ---------- v1.8.14 App 级配置覆盖 + 列表 hook 硬保护 ----------

static NSString *SIO_bundleID(void) {
    if (!gSelfBundle) gSelfBundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return gSelfBundle;
}

// AppOverrides 结构：
//   AppOverrides = { "com.sfic.knight" = { Speed = 8; Mode = 0; Spring = 1; Extra = 1;
//                                          ListAccel = 0; Enabled = 1;
//                                          FUBGEnabled = 1; FUBGSceneFake = 1; FUBGAudioKeep = 1; }; }
// 命中当前进程则返回该字典，否则 nil。优先级：硬保护 > App 覆盖 > 全局。
static NSDictionary *SIO_appOverride(NSDictionary *root) {
    if (![root isKindOfClass:[NSDictionary class]]) return nil;
    id ov = root[@"AppOverrides"];
    if (![ov isKindOfClass:[NSDictionary class]]) return nil;
    NSString *bid = SIO_bundleID();
    if (!bid.length) return nil;
    id mine = ((NSDictionary *)ov)[bid];
    return [mine isKindOfClass:[NSDictionary class]] ? (NSDictionary *)mine : nil;
}

// 列表 hook 硬保护名单。
// 名单内 App 的 ListAccel 恒为 NO：全局开关、App 覆盖都无法打开。
// 名单来源为本项目实测记录 —— 这些 App 的列表 UI 与 TV/CV 变更类 hook 冲突，
// 会破坏列表状态机导致卡死/崩溃。安全项 fail-safe，不接受"忘了关"。
static BOOL SIO_listHardBlocked(void) {
    // v2.1.12（审查 N-2）：这份名单在配置 App 侧有一份镜像 SIOModel.m 里的
    // HardGuardBundles()。⚠ 改这里必须同步改那里，反之亦然 ——
    // 两边不一致会让专属覆盖页显示「列表加速：开」而实际被硬关，即假开关。
    static NSArray *blocked = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocked = @[
            // v2.1.14：按用户要求移除 com.sfic.knight。原注释记录的「24 个 TV/CV hook 可能
            // 破坏其列表状态机 → 卡死/崩溃」风险现由用户自行承担（列表加速默认开）。
            // 若骑士出现列表异常，把这一行加回即可恢复硬保护，无需改别处。
            @"com.apple.springboard",  // v1.8.16：桌面进程，内部大量 TV/CV，一旦打开就是黑屏/白苹果
        ];
    });
    NSString *bid = SIO_bundleID();
    if (!bid.length) return NO;
    return [blocked containsObject:bid];
}

// v1.8.16：内置保活排除名单 —— 这些进程绝不参与真后台保活。
// SpringBoard 本身就是场景宿主，在它内部吞掉 scene 更新会影响**全局所有 App** 的
// 后台化行为，而保活（音频断言 + 场景伪装）对桌面进程本身毫无意义。
static BOOL SIO_fbgBuiltinExcluded(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[ @"com.apple.springboard" ];
    });
    NSString *bid = SIO_bundleID();
    return bid.length && [list containsObject:bid];
}

// v2.1.7 fix：手感模块保护名单。这些 App 依赖 UIScrollView 的原生触摸行为
// （delaysContentTouches、decelerationRate）来正确识别长按/选择等手势。
// 整个手感模块（FastScroll + FastTap + setter 强黏）对这些 App 全部跳过。
static BOOL SIO_feelProtected(void) {
    // v2.1.14：移除 com.sfic.knight 的硬编码跳过（原 v2.1.8 逻辑，见下方历史注释）。
    // 该 App 的手感模块现已按全局开关/专属覆盖正常生效；若抢单体验变差，把上面那行加回即可。
    // ---- v2.1.8 历史注释（保留作风险记录，不再生效）----
    // SF intracity rider (com.sfic.knight) order hall needs full native scroll inertia.
    // FastScroll locks decelerationRate to 0.99 (fast), which cut each swipe to one or
    // two order cells ("one cell at a time" feel). Skip the whole feel module for this
    // app; ListAccel is already hard-guarded here, so only the animation speedup stays active.
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @"com.tencent.xin",       // 微信：聊天长按复制依赖 delaysContentTouches
            @"com.tencent.mqq",       // QQ：长按消息复制
            @"com.apple.mobilesms",   // 信息：长按复制
            @"com.tencent.wework",    // 企业微信：长按复制
        ];
    });
    NSString *bid = SIO_bundleID();
    return bid.length && [list containsObject:bid];
}

// 本进程是否命中 App 覆盖 / 是否被列表硬保护（供启动日志与配置排查）
// v2.1.8: HUD / web instant-show guard list. IM and payment apps use the
// spinner/overlay as a flow-state signal ("paying...", "sending...") and must
// keep their loaders untouched.
static BOOL SIO_hudProtected(void) {
    static NSArray *hlist = nil;
    static dispatch_once_t honce;
    dispatch_once(&honce, ^{
        hlist = @[
            @"com.tencent.xin",              // WeChat
            @"com.tencent.mqq",              // QQ
            @"com.apple.mobilesms",          // Messages
            @"com.tencent.wework",           // WeCom
            @"com.eg.android.AlipayGphone",  // Alipay
        ];
    });
    NSString *bid = SIO_bundleID();
    return bid.length && [hlist containsObject:bid];
}

static BOOL gHasAppOverride   = NO;
static BOOL gListHardGuarded  = NO;

// v2.1.0：所有派生量集中在这里算一次，热路径只读结果。
// 必须与 SIO_reload 的每条 return 路径都配套调用（含「配置文件缺失」分支），
// 否则会出现「配置没变但 gBlockedFast 过期」导致全量 hook 误旁路/误放行。
static void SIO_recalc(void) {
    gFloorCached = (gFloorDuration >= 0.005 && gFloorDuration <= 0.1) ? gFloorDuration : 0.01;
    gInvSpeed    = (gSpeed > 1.0001) ? (1.0 / gSpeed) : 1.0;
    gInvLayer    = (gLayerBoost > 1.0001) ? (1.0 / gLayerBoost) : 1.0;
    gInvTrans    = (gTransBoost > 1.0001) ? (1.0 / gTransBoost) : 1.0;
    gBlockedFast = (!gEnabled || gSelfBlacklisted);
}

// v2.1.11：配置缺失/损坏时的统一复位表。
// 原来 `if (!d)` 分支只重置 3 个变量，其余 15 个全局量全部沿用上一次的值，
// 且没有任何日志。后果是「删掉 plist 想恢复默认」这个最常用的排障手段完全无效 ——
// dylib 会顽固保持旧配置直到目标 App 重启。现在缺文件即回到出厂默认值，
// 并打一条日志让「配置读不到」这件事变得可见。
static void SIO_resetDefaults(void) {
    gEnabled      = YES;
    gMode         = 0;
    gSpeed        = 40.0;
    gSlowFactor   = 2.0;
    gSpring       = YES;
    gExtra        = YES;
    gListAccel    = YES;      // v2.1.7 起全开，与静态初值一致（见下方注释说明）
    gZoomAccel    = YES;
    gFastScroll   = YES;
    gFastTap      = YES;
    gLayerBoost    = 5.0;
    gFloorDuration = 0.005;
    gTransBoost    = 3.0;
    gInAppNotify   = YES;
    gInstantTransition = YES;
    gHUDFast       = YES;
    gHUDDelay      = 0.15;
    gWKFastShow    = YES;
    gSelfBlacklisted = NO;
    gHasAppOverride  = NO;
}

static void SIO_reload(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) {
        // v2.1.11：完整复位 + 留痕。原来这里只清 3 个变量，等于「删配置不生效」。
        SIO_resetDefaults();
        NSLog(@"[SIOriginal] prefs file missing/unreadable at %@ — reset to factory defaults",
              kPrefPath);
        // 配置缺失也要执行硬保护，保证"没有配置文件"时顺丰同城同样安全
        gListHardGuarded = SIO_listHardBlocked();
        if (gListHardGuarded) gListAccel = NO;
        SIO_recalc();
        return;
    }
    gEnabled = [d[@"Enabled"] boolValue];
    int mode = [d[@"Mode"] intValue];
    gMode = (mode >= 0 && mode <= 2) ? mode : 0;
    double sp = [d[@"Speed"] doubleValue];
    gSpeed = (sp >= 1.0 && sp <= 50.0) ? sp : 15.0;
    double sf = [d[@"SlowFactor"] doubleValue];
    gSlowFactor = (sf > 1.0 && sf <= 10.0) ? sf : 2.0;
    gSpring = d[@"Spring"] ? [d[@"Spring"] boolValue] : YES;
    gExtra  = d[@"Extra"]  ? [d[@"Extra"] boolValue]  : YES;
    // v2.1.11 注释订正（行为不变，只改注释）：
    // 这两行紧邻的注释曾长期写着「缺键默认 NO」，但代码一直是 `: YES`。
    // 这不是笔误 —— v2.1.7 明确改回全开，只是注释没跟着改，于是注释变成了
    // 一份**虚假的安全承诺**：读代码的人以为有 fail-safe，实际没有。
    // 真实兜底是另外两道：SIO_listHardBlocked()（顺丰骑士 / SpringBoard 硬保护，
    // 全局开关与 App 覆盖都绕不过）和 SIO_svZoomEngaged() /
    // SIO_wechatZoomPreviewActive() 两道运行时安全网。是否全开由 v2.1.7 决策决定。
    gListAccel = d[@"ListAccel"] ? [d[@"ListAccel"] boolValue] : YES;
    gZoomAccel = d[@"ZoomAccel"] ? [d[@"ZoomAccel"] boolValue] : YES;
    // v2.1.7：手感开关缺省开（hook 按需安装）；v2.0.6 那次「闪退」实为 LPG hook 所致
    gFastScroll = d[@"FastScroll"] ? [d[@"FastScroll"] boolValue] : YES;
    gFastTap    = d[@"FastTap"]    ? [d[@"FastTap"] boolValue]    : YES;
    // 显式动画额外倍率，缺键默认 3.0（加载提速），范围 1.0–10.0
    double lb = d[@"LayerBoost"] ? [d[@"LayerBoost"] doubleValue] : 3.0;
    gLayerBoost = (lb >= 1.0 && lb <= 10.0) ? lb : 3.0;
    // 安全下限（0.005–0.1，缺键 0.01）、转场独立倍率（1–3，缺键 2）
    // v2.1.1：下限缺键回 0.01 —— 0.005 属极限值，动画完成回调容易配对错乱。
    double fd = d[@"FloorDuration"] ? [d[@"FloorDuration"] doubleValue] : 0.01;
    gFloorDuration = (fd >= 0.005 && fd <= 0.1) ? fd : 0.01;
    double tb = d[@"TransitionBoost"] ? [d[@"TransitionBoost"] doubleValue] : 2.0;
    gTransBoost = (tb >= 1.0 && tb <= 3.0) ? tb : 2.0;
    // 长按加速（缺键关，v2.1.1 回退）与长按时长（0.20–0.40，缺键 0.30）
    // v2.1.7：长按加速连同其 hook 一起移除（init 族方法挂钩必崩，见安装处注释）

    // v2.0.0：热重载顶部提示，缺键默认开（纯展示、不拦截触摸）
    gInAppNotify = d[@"InAppNotify"] ? [d[@"InAppNotify"] boolValue] : YES;

    // v2.1.8：极速模式
    gInstantTransition = d[@"InstantTransition"] ? [d[@"InstantTransition"] boolValue] : YES;
    gHUDFast           = d[@"HUDFast"]           ? [d[@"HUDFast"]           boolValue] : YES;
    double hd = d[@"HUDDelay"] ? [d[@"HUDDelay"] doubleValue] : 0.15;
    gHUDDelay          = (hd >= 0.02 && hd <= 1.0) ? hd : 0.15;
    gWKFastShow        = d[@"WKFastShow"]        ? [d[@"WKFastShow"]        boolValue] : YES;

    // v1.8.12：黑名单一次性解析为布尔值（兼容 NSArray / NSString 两种格式）
    gSelfBlacklisted = NO;
    id bl = d[@"Blacklist"];
    NSArray *items = nil;
    if ([bl isKindOfClass:[NSArray class]]) {
        items = bl;
    } else if ([bl isKindOfClass:[NSString class]]) {
        // 旧版这里直接对 NSString 调 componentsJoinedByString: → unrecognized selector 崩溃
        items = [(NSString *)bl componentsSeparatedByString:@","];
    }
    NSString *bid = gSelfBundle ?: @"";
    if (bid.length) {
        for (id it in items) {
            if (![it isKindOfClass:[NSString class]]) continue;
            NSString *s = [(NSString *)it stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
            if (s.length && [bid isEqualToString:s]) { gSelfBlacklisted = YES; break; }
        }
    }

    // ---- v1.8.14：App 级覆盖（在全局之后应用，优先级更高） ----
    NSDictionary *ovr = SIO_appOverride(d);
    gHasAppOverride = (ovr != nil);
    if (ovr) {
        // v2.1.7：总开关改为最高优先级 —— 全局关 ⇒ 任何 App 都不能再通过专属覆盖打开。
        // 原来覆盖直接赋值 gEnabled，而配置 App 保存专属覆盖时恒写 Enabled=YES，
        // 导致「启用动画引擎」关掉后，开过专属覆盖的 App 依然加速（被误认为假开关）。
        // 现在覆盖只能「再关」不能「强开」：gEnabled = 全局 && 覆盖值。
        if (ovr[@"Enabled"])    gEnabled = gEnabled && [ovr[@"Enabled"] boolValue];
        if (ovr[@"Mode"]) {
            int m2 = [ovr[@"Mode"] intValue];
            if (m2 >= 0 && m2 <= 2) gMode = m2;
        }
        if (ovr[@"Speed"]) {
            double s2 = [ovr[@"Speed"] doubleValue];
            if (s2 >= 1.0 && s2 <= 50.0) gSpeed = s2;
        }
        if (ovr[@"SlowFactor"]) {
            double f2 = [ovr[@"SlowFactor"] doubleValue];
            if (f2 > 1.0 && f2 <= 10.0) gSlowFactor = f2;
        }
        if (ovr[@"Spring"])     gSpring    = [ovr[@"Spring"] boolValue];
        if (ovr[@"Extra"])      gExtra     = [ovr[@"Extra"] boolValue];
        if (ovr[@"ListAccel"])  gListAccel = [ovr[@"ListAccel"] boolValue];
        if (ovr[@"ZoomAccel"])  gZoomAccel = [ovr[@"ZoomAccel"] boolValue];
        if (ovr[@"FastScroll"]) gFastScroll = [ovr[@"FastScroll"] boolValue];
        if (ovr[@"FastTap"])    gFastTap    = [ovr[@"FastTap"] boolValue];
        if (ovr[@"LayerBoost"]) {
            double lb2 = [ovr[@"LayerBoost"] doubleValue];
            if (lb2 >= 1.0 && lb2 <= 10.0) gLayerBoost = lb2;
        }
        // v2.0.0：专属覆盖里的新参数（只在字典里显式存在时才覆盖全局值）
        if (ovr[@"FloorDuration"]) {
            double fd2 = [ovr[@"FloorDuration"] doubleValue];
            if (fd2 >= 0.005 && fd2 <= 0.1) gFloorDuration = fd2;
        }
        if (ovr[@"TransitionBoost"]) {
            double tb2 = [ovr[@"TransitionBoost"] doubleValue];
            if (tb2 >= 1.0 && tb2 <= 3.0) gTransBoost = tb2;
        }
        // v2.1.8：极速模式覆盖
        if (ovr[@"InstantTransition"]) gInstantTransition = [ovr[@"InstantTransition"] boolValue];
        if (ovr[@"HUDFast"])           gHUDFast           = [ovr[@"HUDFast"]           boolValue];
        if (ovr[@"HUDDelay"]) {
            double hd2 = [ovr[@"HUDDelay"] doubleValue];
            if (hd2 >= 0.02 && hd2 <= 1.0) gHUDDelay = hd2;
        }
        if (ovr[@"WKFastShow"])        gWKFastShow        = [ovr[@"WKFastShow"]        boolValue];
    }

    // ---- v1.8.14：列表 hook 硬保护，必须放在所有覆盖之后，优先级最高 ----
    gListHardGuarded = SIO_listHardBlocked();
    if (gListHardGuarded && gListAccel) {
        NSLog(@"[SIOriginal] ListAccel was ON but hard guard force-disabled it for %@ "
              @"(list hooks break this app's list state machine)", SIO_bundleID());
        gListAccel = NO;
    }

    SIO_recalc();   // v2.1.0：最后统一刷新派生量
}

static void SIO_installiOS16Extras(void); // forward declaration

#pragma mark - v2.0.0 配置生效顶部提示（不拦截触摸、非常驻）

static __strong UIWindow *sioToastWindow = nil;

static NSString *SIO_modeSummary(void) {
    NSString *m;
    switch (gMode) {
        case 1:  m = [NSString stringWithFormat:@"慢放 ×%.0f", gSlowFactor]; break;
        case 2:  m = @"瞬切"; break;
        default: m = [NSString stringWithFormat:@"加速 ×%.0f", gSpeed]; break;
    }
    // 只在非默认值时附加额外档位，提示尽量短
    NSMutableString *s = [NSMutableString stringWithFormat:@"SIOriginal · %@", m];
    if (gLayerBoost > 1.0001) [s appendFormat:@" · 显式×%.0f", gLayerBoost];
    if (gTransBoost > 1.0001) [s appendFormat:@" · 转场×%.1f", gTransBoost];
    if (fabs(gFloorDuration - 0.01) > 0.0001)
        [s appendFormat:@" · 下限%.3fs", gFloorDuration];
    return s;
}

// ---- v2.1.12（F-A）：命中统计导出 ----
// 日志版：全量 22 项，一行，供连 Mac 看 Console 用。
static NSString *SIO_statsLogLine(void) {
    NSMutableString *s = [NSMutableString stringWithString:@"[SIOriginal] hook hits:"];
    for (int i = 0; i < SIO_HIT__COUNT; i++) {
        uint32_t v = atomic_load_explicit(&gHitCounts[i], memory_order_relaxed);
        [s appendFormat:@" %s=%u", kSIOHitNames[i], v];
    }
    return s;
}

// v2.1.13：单文件编译，下方 SIO_statsStatusLine() 在 SIO_statsPanelText() 之后定义
// → 这里必须先前向声明，否则 clang 报「implicit declaration」。
static NSString *SIO_statsStatusLine(void);

// v2.1.16：面板自解释。SIO_HIT 在 hook 第一行、闸门之前计数 → 它记的是
// 「调用」不是「生效」。被保护闸门拦掉的桶（手感/HUD/列表/总开关）会把调用数堆得很高
// 却一个都没应用，看着像「生效很多」实为 0。v2.1.16 把每个桶拆成「调用 / 生效」两个数，
// 并把整桶被拦掉的标 ⛔已跳过，不再误导。闸门状态在一次热重载内恒定，故按当前状态推算
// 「是否整桶被拦」是确定性的，无需改动 70 处 hook（零编译风险）。
static BOOL SIO_bucketSkipped(int slot) {
    // 总开关关 / 全局黑名单：所有动画/列表/手感/HUD 全部跳过
    if (!gEnabled || gSelfBlacklisted) return YES;
    switch (slot) {
        case SIO_HIT_LIST_TV:
        case SIO_HIT_LIST_CV:
            return !gListAccel;                                  // 列表加速关
        case SIO_HIT_FEEL:
            return gSelfFeelProtected || (!gFastScroll && !gFastTap);
        case SIO_HIT_HUD_AI:
        case SIO_HIT_HUD_SV:
        case SIO_HIT_HUD_MB:
            return gSelfHudProtected || !gHUDFast;
        case SIO_HIT_WK:
            return gSelfHudProtected || !gWKFastShow;
        default:
            return NO;   // 纯动画族：仅受总开关/黑名单影响（已在上层处理）
    }
}

// 浮层版：只列非零项（22 项全列在手机上读不完），按调用数降序，最多 8 行。
// 全为 0 时给一句明确的诊断提示 —— 这正是 F-A 想暴露的「走了未覆盖路径」信号。
static NSString *SIO_statsPanelText(void) {
    NSMutableArray *rows = [NSMutableArray array];
    uint32_t totalCalled = 0, totalApplied = 0;
    for (int i = 0; i < SIO_HIT__COUNT; i++) {
        uint32_t called = atomic_load_explicit(&gHitCounts[i], memory_order_relaxed);
        totalCalled += called;
        BOOL skipped = SIO_bucketSkipped(i);
        uint32_t applied = skipped ? 0 : called;
        totalApplied += applied;
        if (called)
            [rows addObject:@[ @(called), @(applied), @(skipped),
                               [NSString stringWithUTF8String:kSIOHitNames[i]] ]];
    }
    // v2.1.13：状态行必须在最上面。过去只给数字，用户在被保护的 App 上看到一片 0
    // 会误判成「没生效」，实际是三道闸门把它拦住了（顺丰骑士就是这种情况）。
    if (!rows.count) {
        return [NSString stringWithFormat:
            @"SIOriginal 命中统计\n%@\n0 命中 —— 本 App 所有 hook 路径均被跳过",
            SIO_statsStatusLine()];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [b[0] compare:a[0]];
    }];
    NSMutableString *s = [NSMutableString stringWithFormat:
        @"SIOriginal 命中统计（调用 %u / 生效 %u）\n%@", totalCalled, totalApplied, SIO_statsStatusLine()];
    NSUInteger n = MIN(rows.count, (NSUInteger)8);
    for (NSUInteger i = 0; i < n; i++) {
        NSArray *r = rows[i];
        uint32_t c = [r[0] unsignedIntValue];
        uint32_t a = [r[1] unsignedIntValue];
        BOOL sk = [r[2] boolValue];
        NSString *name = r[3];
        if (sk)
            [s appendFormat:@"\n⛔ %@ 调用%u/生效0", name, c];
        else
            [s appendFormat:@"\n%@ 调用%u/生效%u", name, c, a];
    }
    if (rows.count > n) [s appendFormat:@"\n…及其他 %lu 项", (unsigned long)(rows.count - n)];
    return s;
}

// 清零：热重载时先 dump 上一次的再清零，这样每次改完配置得到的都是
// 「新参数下的命中分布」，不用手动做减法。
static void SIO_statsReset(void) {
    for (int i = 0; i < SIO_HIT__COUNT; i++)
        atomic_store_explicit(&gHitCounts[i], 0u, memory_order_relaxed);
}

static void SIO_dismissToast(void) {
    if (!sioToastWindow) return;
    UIWindow *w = sioToastWindow;
    [UIView animateWithDuration:0.2 animations:^{
        w.alpha = 0;
        w.transform = CGAffineTransformMakeTranslation(0, -20);
    } completion:^(BOOL finished) {
        w.hidden = YES;
        if (sioToastWindow == w) sioToastWindow = nil;
    }];
}

static void SIO_showToast(void) {
    if (!gInAppNotify) return;
    // 只在目标 App 自己处于前台激活态时提示；SpringBoard/后台不打扰
    UIApplication *app = [UIApplication sharedApplication];
    if (app.applicationState != UIApplicationStateActive) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 已在显示：先撤掉旧的，避免叠窗
            if (sioToastWindow) { sioToastWindow.hidden = YES; sioToastWindow = nil; }

            CGRect sb = UIScreen.mainScreen.bounds;
            UIWindow *w = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, sb.size.width, 64)];
            // iOS 13+ 多场景：尽量挂到当前激活的 windowScene
            if ([w respondsToSelector:@selector(setWindowScene:)]) {
                for (UIScene *sc in app.connectedScenes) {
                    if (sc.activationState == UISceneActivationStateForegroundActive &&
                        [sc isKindOfClass:[UIWindowScene class]]) {
                        w.windowScene = (UIWindowScene *)sc;
                        break;
                    }
                }
            }
            w.windowLevel = UIWindowLevelStatusBar + 1;
            w.backgroundColor = [UIColor clearColor];
            w.rootViewController = [UIViewController new];
            w.rootViewController.view.backgroundColor = [UIColor clearColor];
            // 关键：整窗不接收任何触摸，与悬浮球有本质区别
            w.userInteractionEnabled = NO;

            UIView *card = [[UIView alloc] initWithFrame:CGRectMake(12, 8, sb.size.width - 24, 46)];
            card.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.13 alpha:0.92];
            card.layer.cornerRadius = 14;
            card.layer.masksToBounds = YES;
            card.userInteractionEnabled = NO;
            card.alpha = 0;
            card.transform = CGAffineTransformMakeTranslation(0, -12);

            UILabel *label = [[UILabel alloc] initWithFrame:card.bounds];
            label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            label.text = gEnabled ? SIO_modeSummary() : @"SIOriginal · 已暂停";
            label.textColor = [UIColor colorWithRed:0.49 green:0.91 blue:0.58 alpha:1.0];
            label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
            label.textAlignment = NSTextAlignmentCenter;
            label.numberOfLines = 1;
            label.userInteractionEnabled = NO;
            [card addSubview:label];
            [w.rootViewController.view addSubview:card];

            w.hidden = NO;
            sioToastWindow = w;
            [UIView animateWithDuration:0.22 animations:^{
                card.alpha = 1;
                card.transform = CGAffineTransformIdentity;
            }];
            // 1.5s 自动消失；新一轮保存会立刻替换它
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ SIO_dismissToast(); });
        } @catch (__unused NSException *e) {}
    });
}

// ---- v2.1.12（F-A）：命中统计浮层 ----
// 与 toast 同一套无感浮层机制（不拦触摸、自动消失），但卡片更高、多行、停留更久。
// 为什么不做成「写进 plist 让配置 App 读」：dylib 跑在目标 App 进程内，受目标 App
// 沙盒限制，写不了 /var/Managed Preferences/mobile/（该目录 root 拥有、App 只读）。
// 所以改成「配置 App 发 Darwin 通知 → dylib 收到后在目标 App 内弹浮层」，
// 不需要 Mac、不需要持久化，用户在目标 App 里当场就能看到。
static UIWindow *sioStatsWindow = nil;

// v2.1.15：把「收到请求」与「弹浮层」解耦。
// 背景：常驻后台的 App（顺丰骑士这类要持续定位的）在后台仍活着，Darwin 通知到达时
// 立刻被处理，此时 applicationState 是 Background → SIO_showStats 的 active 检查直接
// return，浮层永远不出现；而微信这类被系统挂起的 App，通知要等它恢复到前台才处理，
// 那时已经是 Active，所以一直能弹。这就是「微信有、骑士没有」的真正原因。
// 改法：收到请求只置位 sioStatsArmed，等这个 App 回到前台（DidBecomeActive）再弹。
static BOOL sioStatsArmed = NO;
static id   sioStatsActiveObs = nil;   // 持有 block 观察者令牌，否则释放即自动注销

static void SIO_dismissStats(void) {
    if (!sioStatsWindow) return;
    UIWindow *w = sioStatsWindow;
    [UIView animateWithDuration:0.25 animations:^{ w.alpha = 0; }
                     completion:^(BOOL finished) {
        w.hidden = YES;
        if (sioStatsWindow == w) sioStatsWindow = nil;
    }];
}

// v2.1.13：顶部状态行。解决「报告全是 0 / 数字很小，不知道是被保护拦了还是没注入」。
// 原来只显示命中数，用户在顺丰骑士上看到一片 0（实测确实如此：只有 CAAnim/LayerAdd
// 走 SIO_targetDurationLayer，其余全被保护名单挡掉），第一反应是「没生效」。
// 现在把三道闸门的状态直接写在最上面，一眼可判。
static NSString *SIO_statsStatusLine(void) {
    NSString *bid = SIO_bundleID() ?: @"?";
    if (!gEnabled)
        return [NSString stringWithFormat:@"%@  ⛔ 总开关关闭", bid];
    if (gSelfBlacklisted)
        return [NSString stringWithFormat:@"%@  ⛔ 整体黑名单命中", bid];
    NSMutableString *s = [NSMutableString stringWithString:bid];
    if (gListHardGuarded) [s appendString:@" · 列表⛔硬保护"];
    if (gSelfFeelProtected) [s appendString:@" · 手感⛔跳过"];
    if (gSelfHudProtected) [s appendString:@" · HUD⛔跳过"];
    if ([s isEqualToString:bid]) [s appendString:@" · 全部生效"];
    return s;
}

static void SIO_showStats(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app.applicationState != UIApplicationStateActive) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (sioStatsWindow) { sioStatsWindow.hidden = YES; sioStatsWindow = nil; }

            NSString *text = SIO_statsPanelText();
            CGRect sb = UIScreen.mainScreen.bounds;
            CGFloat cardW = sb.size.width - 24;

            // v2.1.14：浮层整体下移到状态栏之下，避免盖住时间/信号（之前窗口从 y=0 起，
            // 卡片压在状态栏上）。拿不到状态栏高度就回退到 20pt 安全余量。
            CGFloat topInset = 20;
            if ([app respondsToSelector:@selector(statusBarFrame)])
                topInset = app.statusBarFrame.size.height;
            if (topInset < 20) topInset = 20;

            UIFont *font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
            CGRect box = [text boundingRectWithSize:CGSizeMake(cardW - 28, CGFLOAT_MAX)
                                            options:NSStringDrawingUsesLineFragmentOrigin
                                         attributes:@{ NSFontAttributeName: font }
                                            context:nil];
            CGFloat cardH = MIN(MAX(box.size.height + 24, 64), sb.size.height - 120);

            UIWindow *w = [[UIWindow alloc] initWithFrame:CGRectMake(0, topInset, sb.size.width,
                                                                     cardH + 20)];
            if ([w respondsToSelector:@selector(setWindowScene:)]) {
                for (UIScene *sc in app.connectedScenes) {
                    if (sc.activationState == UISceneActivationStateForegroundActive &&
                        [sc isKindOfClass:[UIWindowScene class]]) {
                        w.windowScene = (UIWindowScene *)sc;
                        break;
                    }
                }
            }
            w.windowLevel = UIWindowLevelStatusBar + 2;
            w.backgroundColor = [UIColor clearColor];
            w.rootViewController = [UIViewController new];
            w.rootViewController.view.backgroundColor = [UIColor clearColor];
            w.userInteractionEnabled = NO;

            UIView *card = [[UIView alloc] initWithFrame:CGRectMake(12, 10, cardW, cardH)];
            card.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.11 alpha:0.95];
            card.layer.cornerRadius = 16;
            card.layer.masksToBounds = YES;
            card.userInteractionEnabled = NO;
            card.alpha = 0;
            card.transform = CGAffineTransformMakeTranslation(0, -14);

            UILabel *label = [[UILabel alloc]
                initWithFrame:CGRectMake(14, 12, cardW - 28, cardH - 24)];
            label.text = text;
            label.textColor = [UIColor colorWithRed:0.62 green:0.90 blue:1.0 alpha:1.0];
            label.font = font;
            label.textAlignment = NSTextAlignmentLeft;
            label.numberOfLines = 0;
            label.userInteractionEnabled = NO;
            [card addSubview:label];
            [w.rootViewController.view addSubview:card];

            w.hidden = NO;
            sioStatsWindow = w;
            [UIView animateWithDuration:0.25 animations:^{
                card.alpha = 1;
                card.transform = CGAffineTransformIdentity;
            }];
            // 6s 自动消失（内容多，给足阅读时间）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ SIO_dismissStats(); });
        } @catch (__unused NSException *e) {}
    });
}

// v2.1.12（F-A）：收到配置 App 的统计请求 → 在当前前台 App 内弹浮层。
// 同样遵守 v2.1.10 的竞态约定：Darwin 回调在通知线程，UI 操作必须回主线程。
// v2.1.15：不再无脑 SIO_showStats()。后台态先挂起请求，回到前台再弹（见 sioStatsArmed 注释）。
static void SIO_onStatsRequest(CFNotificationCenterRef center, void *observer,
                               CFNotificationName name, const void *object,
                               CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSLog(@"%@", SIO_statsLogLine());   // 有 Mac 的话 Console 里也留一份
            sioStatsArmed = YES;
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                sioStatsArmed = NO;             // 已在前台，直接弹
                SIO_showStats();
            }
            // 否则保持 armed，等 SIO_onDidBecomeActive 把它弹出来
        } @catch (__unused NSException *e) {}
    });
}

// v2.1.15：App 回到前台时，如果之前挂着一笔统计请求，就现在弹。
// 这解决了「常驻后台的 App 收到请求时不是 Active、浮层永不出现」的问题。
static void SIO_onDidBecomeActive(NSNotification *note) {
    (void)note;
    if (!sioStatsArmed) return;
    sioStatsArmed = NO;
    SIO_showStats();
}

static void SIO_settingsChanged(CFNotificationCenterRef center, void *observer,
                                CFNotificationName name, const void *object,
                                CFDictionaryRef userInfo) {
    // v2.1.10 竞态修复：Darwin 回调在通知线程上执行，直接改全局会与主线程上正在跑的
    // 动画 hook 并发读写（派生量、黑名单、模式等二十来个变量）。统一丢到主线程串行执行：
    // 通知线程只做一次派发，代价可忽略，换来的是 reload 期间不会再读到半新半旧的配置。
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            SIO_reload();
            // v2.1.11：热重载也打印一行完整状态。原来启动日志只在 constructor 打一次，
            // 用户最常见的报障是「我改了配置但没生效」，而当时无法区分是
            // 没写进 plist / dylib 没收到通知 / 收到了但命中保护名单。现在三种情况可分辨。
            // v2.1.12（F-A）：先 dump「自上次重载以来」的命中分布再清零。
            // 这样每次改完配置拿到的都是新参数下的分布，不用手动做减法。
            NSLog(@"%@", SIO_statsLogLine());
            SIO_statsReset();
            NSLog(@"[SIOriginal] reload in %@: enabled=%d mode=%d speed=%.1f "
                  @"hudProtected=%d feelProtected=%d listHardGuarded=%d "
                  @"blacklisted=%d override=%d physBg=%d",
                  SIO_bundleID(), gEnabled, gMode, gSpeed,
                  gSelfHudProtected, gSelfFeelProtected, gListHardGuarded,
                  gSelfBlacklisted, gHasAppOverride, gPhysBg);
            // v2.0.0：热重载成功后在目标 App 内给出短暂、不拦截触摸的生效提示
            SIO_showToast();
        } @catch (__unused NSException *e) {}
    });
}

// ---------- 微信图片预览「放大态」全局旁路（v1.8.4） ----------
// v1.8.3 只保护了缩放相关的两个 UIScrollView hook，但用户实测仍有残留故障：
// 放大后顶/底工具栏自动隐藏，单击屏幕再也唤不出，返回/完成按钮跟着消失，
// 只能杀微信。微信图片浏览器（发图预览、聊天大图）的工具栏隐显走的是
// UIView 块动画 / UIViewPropertyAnimator / CAAnimation，瞬切模式把时长压到
// 0.01s、加速模式整体缩短，会破坏浏览器「隐显动画完成 → 清 isAnimating 锁 →
// 接受下一次单击切换」的状态配对，导致单击被丢弃，工具栏永远停在隐藏态。
// 该故障只在「放大态」出现（未放大时单击切换正常），因此：只要微信前台
// 存在一个启用了缩放且当前 zoomScale > minimumZoomScale 的 UIScrollView，
// 就令所有动画 hook 整体旁路（SIO_blocked 返回 YES），缩放/工具栏/手势全走
// 原生路径；缩回最小倍率后 0.25s 内自动恢复加速。探测限主线程、0.25s 节流，
// 对性能无实际影响。
static NSTimeInterval gZoomProbeAt = 0;
static BOOL           gZoomPreviewCached = NO;

static BOOL SIO_wechatZoomPreviewActive(void) {
    if (!gIsWeChat) return NO;
    NSTimeInterval now = CACurrentMediaTime();
    // v2.1.0：节流窗口 0.25s → 0.35s。加速拉到 ×15 后动画调用频率显著上升，
    // 探测次数同比变多；窗口放宽后探测开销下降约 30%，0.35s 的滞后对「退出放大态后
    // 恢复加速」的体感无影响（原本也要等 0.25s）。
    if (now - gZoomProbeAt < 0.35) return gZoomPreviewCached;
    gZoomProbeAt = now;
    // 视图树只能在主线程碰；非主线程直接沿用上一次结果（最多滞后 0.25s）
    if (![NSThread isMainThread]) return gZoomPreviewCached;

    BOOL found = NO;
    @autoreleasepool {
        @try {
            NSMutableArray<UIView *> *roots = [NSMutableArray array];
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)sc;
                if (ws.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in ws.windows) {
                    if (!w.hidden && w.alpha > 0.01 && w.rootViewController.view) {
                        [roots addObject:w];
                    }
                }
            }
            // 迭代 DFS，扫描整个前台视图树
            // v1.8.12：节点上限保护。超大视图树（长列表 / 复杂 WebView 容器）下
            // 定时全树遍历会拖慢主线程；超过上限即按「未放大」放行，
            // 宁可少一层保护，不可卡住界面。
            // v2.1.0：上限 3000 → 1500。放大态的 UIScrollView 几乎总在视图树前几层，
            // 1500 已足够覆盖真实场景，最坏情况主线程占用减半。
            NSMutableArray<UIView *> *stack = roots;
            NSUInteger visited = 0;
            while (stack.count) {
                if (++visited > 1500) break;
                UIView *v = stack.lastObject;
                [stack removeLastObject];
                if ([v isKindOfClass:[UIScrollView class]]) {
                    UIScrollView *sv = (UIScrollView *)v;
                    if (sv.maximumZoomScale > sv.minimumZoomScale + 0.001 &&
                        sv.zoomScale > sv.minimumZoomScale + 0.001) {
                        found = YES;
                        break;
                    }
                }
                NSArray *subs = v.subviews;
                if (subs.count) [stack addObjectsFromArray:subs];
            }
        } @catch (__unused NSException *e) {}
    }
    gZoomPreviewCached = found;
    return found;
}

static inline BOOL SIO_blocked(void) {
    // v1.8.12：热路径零分配。v2.1.0：前两个布尔已合并为 gBlockedFast（SIO_recalc 预计算），
    // 顺序按「最便宜、最可能命中」排列：合并布尔 → 节流后的探测结果。
    if (gBlockedFast) return YES;   // = !gEnabled || gSelfBlacklisted
    // v1.8.9：微信动画加速恢复（实验）——预览 bug 真凶已确认为悬浮球（v1.8.7 永久禁用），
    // 动画 hook 恢复生效；v1.8.4 放大态探测器首次真正启用作为安全网
    if (SIO_wechatZoomPreviewActive()) return YES;   // 微信预览放大态旁路（非微信时立即返回 NO）
    return NO;
}

// ---------- swizzle 工具 ----------
// v1.8.12：增加重复安装保护。若目标 IMP 已经是我们的实现（同一 dylib 被重复注入、
// 或 constructor 被执行两次），绝不能再把它存进 orig —— 否则回调会自递归爆栈。
static void SIO_swizzleInstance(Class c, SEL sel, IMP newImp, IMP *orig) {
    if (!c || !sel || !newImp) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;
    if (orig) *orig = cur;
    method_setImplementation(m, newImp);
}
// 注意：必须传「类对象」而不是元类。class_getClassMethod 内部执行的是
// class_getInstanceMethod(object_getClass(cls), sel)，传元类会去根元类查找并返回 NULL。
static void SIO_swizzleClass(Class c, SEL sel, IMP newImp, IMP *orig) {
    if (!c || !sel || !newImp) return;
    Method m = class_getClassMethod(c, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;
    if (orig) *orig = cur;
    method_setImplementation(m, newImp);
}

// ---------- 原始 IMP 指针（先声明后引用） ----------
static void   (*o_CAAnim_setDuration)(id, SEL, double);
static void   (*o_CATransaction_setDur)(id, SEL, double);
static void   (*o_UV_anim_d)(id, SEL, double, void (^)(void));
static void   (*o_UV_anim_dc)(id, SEL, double, void (^)(void), void (^)(BOOL));
static void   (*o_UV_anim_ddoc)(id, SEL, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void   (*o_UV_anim_spring)(id, SEL, double, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void   (*o_UV_trans)(id, SEL, UIView *, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void   (*o_UV_transFrom)(id, SEL, UIView *, UIView *, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void   (*o_CASpring_mass)(id, SEL, double);
static void   (*o_CASpring_stiff)(id, SEL, double);
static void   (*o_CASpring_damp)(id, SEL, double);
static void   (*o_nav_push)(id, SEL, UIViewController *, BOOL);
static void   (*o_nav_pop)(id, SEL, BOOL);
static void   (*o_nav_popTo)(id, SEL, UIViewController *, BOOL);
static void   (*o_nav_setVCs)(id, SEL, NSArray *, BOOL);
static void   (*o_nav_privDur)(id, SEL, double);
static void   (*o_vc_present)(id, SEL, UIViewController *, BOOL, void (^)(void));
static void   (*o_vc_dismiss)(id, SEL, BOOL, void (^)(void));

// ---- iOS 10+ UIViewPropertyAnimator（现代 App 主流动画 API） ----
static void   (*o_pa_setDuration)(id, SEL, double);
static id     (*o_pa_initWithDurTP)(id, SEL, double, id, void (^)(void));
static id     (*o_pa_initWithDurCP)(id, SEL, double, CGPoint, CGPoint, void (^)(void));
static id     (*o_pa_initWithDurSpring)(id, SEL, double, double, void (^)(void));
static id     (*o_pa_runningPA)(id, SEL, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
// v2.1.12（F-D）：startAnimationAfterDelay: —— 纯 setter 类方法，只接受一个 NSTimeInterval，
// 属于本项目自己定义的「风险最低的一类 hook」。补上是覆盖面兜底：
// 拆包证据只证明 Knight.app 没用它，不代表普遍情况。
static void   (*o_pa_startAfterDelay)(id, SEL, NSTimeInterval);

// ---- UIScrollView 滚动动画 ----
static void   (*o_sv_setContentOffset)(id, SEL, CGPoint, BOOL);
static void   (*o_sv_scrollRect)(id, SEL, CGRect, BOOL);

// ---- CALayer addAnimation 补盲区 ----
static void   (*o_layer_addAnim)(id, SEL, id, NSString *);

// ---- v1.8.15：UIScrollView 缩放动画 ----
static void   (*o_sv_setZoomScale)(id, SEL, CGFloat, BOOL);
static void   (*o_sv_zoomToRect)(id, SEL, CGRect, BOOL);

// ---- v1.8.16：交互手感（滑行惯性 / 点击延迟） ----
static void   (*o_sv_didMoveToWindow)(id, SEL);

// ---- v1.8.12 新增 hook ----
static void   (*o_UV_anim_keyframes)(Class, SEL, double, double, NSUInteger, void (^)(void), void (^)(BOOL));
static void   (*o_UV_systemAnim)(Class, SEL, NSUInteger, NSArray *, NSUInteger, void (^)(void), void (^)(BOOL));
static id     (*o_pa_initWithDurTP2)(id, SEL, double, id);
static void   (*o_tab_setIndex)(id, SEL, NSUInteger);
static void   (*o_tab_setVC)(id, SEL, UIViewController *);
static void   (*o_vc_transitionFrom)(id, SEL, UIViewController *, UIViewController *, double,
                                     UIViewAnimationOptions, void (^)(void), void (^)(BOOL));

// ---- v1.8.13 新增：老式 beginAnimations 动画 API 时长/延迟 ----
static void   (*o_UV_setAnimDuration)(Class, SEL, double);
static void   (*o_UV_setAnimDelay)(Class, SEL, double);

// ---- v2.0.0 新增 ----
// 无 animations 段的视图转场变体：
// +[UIView transitionFromView:toView:duration:options:completion:]
static void   (*o_UV_transFromNoAnim)(Class, SEL, UIView *, UIView *, double,
                                      UIViewAnimationOptions, void (^)(BOOL));
// UIScrollView 手感 setter 强黏（App 后续改值也会被钳回）
static void   (*o_sv_setDecelRate)(id, SEL, CGFloat);
static void   (*o_sv_setDelaysTouches)(id, SEL, BOOL);

// ---- v2.1.8 instant page/link open ----
static void   (*o_AIstartAnim)(id, SEL);                                // UIActivityIndicatorView
static void   (*o_AIstopAnim)(id, SEL);
static void   (*o_WKsetHidden)(id, SEL, BOOL);                          // WKWebView setHidden:
static void   (*o_SVHUDDelay)(id, SEL, NSTimeInterval, void (^)(void)); // +SVProgressHUD dismissWithDelay:completion:
static void   (*o_MBHUDHide)(id, SEL, BOOL);                            // -MBProgressHUD hideAnimated:

#pragma mark - CAAnimation（核心：仅基类，子类自动继承）

static void sio_CAAnim_setDuration(id self, SEL _cmd, double d) {
    SIO_HIT(SIO_HIT_CAANIM);
    SIO_REQUIRE_ORIG(o_CAAnim_setDuration);
    if (SIO_blocked()) { o_CAAnim_setDuration(self, _cmd, d); return; }
    // v2.1.7 fix + v2.1.8 opt：CAKeyframeAnimation 用 0.05s 下限加速。
    // 比普通动画的 0.005s 慢（保证渲染），但比地图黑屏修复时的 0.1s 快一倍。
    if ([self isKindOfClass:[CAKeyframeAnimation class]]) {
        double target;
        switch (gMode) {
            case 1:  target = d * gSlowFactor; break;
            case 2:  target = 0.08;            break;  // 瞬切：地图 80ms 闪一下也比 100ms 快
            default: target = (gSpeed > 1.0001) ? (d * gInvSpeed) : d;
        }
        if (target < 0.05) target = 0.05;     // keyframe 下限 50ms
        o_CAAnim_setDuration(self, _cmd, target);
        SIO_markAnimScaled(self);
        return;
    }
    // v1.8.15：显式设时长视为新意图，按传入值缩放并重新打标
    //（不因已有标记而跳过，否则「add 之后再改时长」会被错误忽略）
    // v1.8.17：走 LayerBoost 版本（显式动画可单独加倍率）
    o_CAAnim_setDuration(self, _cmd, SIO_targetDurationLayer(d));
    SIO_markAnimScaled(self);
}

#pragma mark - CATransaction

static void sio_CATransaction_setDur(id self, SEL _cmd, double d) {
    SIO_HIT(SIO_HIT_CATX);
    SIO_REQUIRE_ORIG(o_CATransaction_setDur);
    if (SIO_inUIViewAnim() || SIO_blocked()) {
        o_CATransaction_setDur(self, _cmd, d);
        return;
    }
    o_CATransaction_setDur(self, _cmd, SIO_targetDuration(d));
}

#pragma mark - UIView 块动画（class methods）

// v1.8.12：delay 缩放抽成独立函数，供块动画与关键帧动画共用
static inline double SIO_targetDelay(double delay) {
    if (!gEnabled) return delay;
    double f;
    switch (gMode) {
        case 1:  f = gSlowFactor;                               break;  // 慢放：延迟同倍放大
        case 2:  f = 0.0;                                       break;  // 瞬切：延迟归零
        // v2.1.11：改用 SIO_recalc 里已缓存的 gInvSpeed（语义等价：gSpeed<=1.0001 时
        // gInvSpeed 已被置 1.0）。SIO_targetDuration 早就这么做了，这里当年漏改。
        default: f = gInvSpeed;                                  break;  // 加速：延迟同倍缩短
    }
    return delay * f;
}

static void sio_UV_anim_d(Class self, SEL _cmd, double d, void (^a)(void)) {
    SIO_HIT(SIO_HIT_UVBLOCK);
    SIO_REQUIRE_ORIG(o_UV_anim_d);
    if (SIO_blocked()) { o_UV_anim_d(self, _cmd, d, a); return; }
    BOOL wasAnim = SIO_inUIViewAnim();
    SIO_setUIViewAnim(YES);
    o_UV_anim_d(self, _cmd, SIO_targetDuration(d), a);
    SIO_setUIViewAnim(wasAnim);   // v2.1.11：恢复而非清零，嵌套块动画时外层不丢重入保护
}

static void sio_UV_anim_dc(Class self, SEL _cmd, double d, void (^a)(void), void (^c)(BOOL)) {
    SIO_HIT(SIO_HIT_UVBLOCK);
    SIO_REQUIRE_ORIG(o_UV_anim_dc);
    if (SIO_blocked()) { o_UV_anim_dc(self, _cmd, d, a, c); return; }
    BOOL wasAnim = SIO_inUIViewAnim();
    SIO_setUIViewAnim(YES);
    o_UV_anim_dc(self, _cmd, SIO_targetDuration(d), a, c);
    SIO_setUIViewAnim(wasAnim);   // v2.1.11：恢复而非清零，嵌套块动画时外层不丢重入保护
}

static void sio_UV_anim_ddoc(Class self, SEL _cmd, double d, double delay, UIViewAnimationOptions o,
                             void (^a)(void), void (^c)(BOOL)) {
    SIO_HIT(SIO_HIT_UVBLOCK);
    SIO_REQUIRE_ORIG(o_UV_anim_ddoc);
    if (SIO_blocked()) { o_UV_anim_ddoc(self, _cmd, d, delay, o, a, c); return; }
    BOOL wasAnim = SIO_inUIViewAnim();
    SIO_setUIViewAnim(YES);
    o_UV_anim_ddoc(self, _cmd, SIO_targetDuration(d), SIO_targetDelay(delay), o, a, c);
    SIO_setUIViewAnim(wasAnim);   // v2.1.11：恢复而非清零，嵌套块动画时外层不丢重入保护
}

static void sio_UV_anim_spring(Class self, SEL _cmd, double d, double damp, double vel,
                               UIViewAnimationOptions o, void (^a)(void), void (^c)(BOOL)) {
    SIO_HIT(SIO_HIT_UVBLOCK);
    SIO_REQUIRE_ORIG(o_UV_anim_spring);
    if (SIO_blocked()) { o_UV_anim_spring(self, _cmd, d, damp, vel, o, a, c); return; }
    BOOL wasAnim = SIO_inUIViewAnim();
    SIO_setUIViewAnim(YES);
    double m = SIO_springScale();
    o_UV_anim_spring(self, _cmd, SIO_targetDuration(d),
                     1.0 - (1.0 - damp) / m, vel * m, o, a, c);
    SIO_setUIViewAnim(wasAnim);   // v2.1.11：恢复而非清零，嵌套块动画时外层不丢重入保护
}

static void sio_UV_trans(Class self, SEL _cmd, UIView *v, double d, UIViewAnimationOptions o,
                         void (^a)(void), void (^c)(BOOL)) {
    SIO_HIT(SIO_HIT_UVBLOCK);
    SIO_REQUIRE_ORIG(o_UV_trans);
    if (SIO_blocked()) { o_UV_trans(self, _cmd, v, d, o, a, c); return; }
    BOOL wasAnim = SIO_inUIViewAnim();
    SIO_setUIViewAnim(YES);
    o_UV_trans(self, _cmd, v, SIO_targetDuration(d), o, a, c);
    SIO_setUIViewAnim(wasAnim);   // v2.1.11：恢复而非清零，嵌套块动画时外层不丢重入保护
}

static void sio_UV_transFrom(Class self, SEL _cmd, UIView *a1, UIView *a2, double d,
                             UIViewAnimationOptions o, void (^an)(void), void (^c)(BOOL)) {
    SIO_HIT(SIO_HIT_UVBLOCK);
    SIO_REQUIRE_ORIG(o_UV_transFrom);
    if (SIO_blocked()) { o_UV_transFrom(self, _cmd, a1, a2, d, o, an, c); return; }
    BOOL wasAnim = SIO_inUIViewAnim();
    SIO_setUIViewAnim(YES);
    o_UV_transFrom(self, _cmd, a1, a2, SIO_targetDuration(d), o, an, c);
    SIO_setUIViewAnim(wasAnim);   // v2.1.11：恢复而非清零，嵌套块动画时外层不丢重入保护
}

// v2.0.0 新增：无 animations 段的转场便捷变体
// +[UIView transitionFromView:toView:duration:options:completion:]
// 旧代码/部分定制转场只用 completion 变体；与带动画段版本同机制，直接改写时长。
static void sio_UV_transFromNoAnim(Class self, SEL _cmd, UIView *a1, UIView *a2, double d,
                                   UIViewAnimationOptions o, void (^c)(BOOL)) {
    SIO_HIT(SIO_HIT_UVBLOCK);
    SIO_REQUIRE_ORIG(o_UV_transFromNoAnim);
    if (SIO_blocked()) { o_UV_transFromNoAnim(self, _cmd, a1, a2, d, o, c); return; }
    BOOL wasAnim = SIO_inUIViewAnim();
    SIO_setUIViewAnim(YES);
    o_UV_transFromNoAnim(self, _cmd, a1, a2, SIO_targetDuration(d), o, c);
    SIO_setUIViewAnim(wasAnim);   // v2.1.11：恢复而非清零，嵌套块动画时外层不丢重入保护
}

// ---- v1.8.12 新增：关键帧动画 ----
// +[UIView animateKeyframesWithDuration:delay:options:animations:completion:]
// 关键帧动画（微信/淘宝等大量使用）此前完全未覆盖：它不走 animateWithDuration 系，
// 也不走 CAAnimation setDuration（内部按相对时间比换算），所以时长必须在这里改。
// options 参数用 NSUInteger 承接（UIViewKeyframeAnimationOptions 底层即 NSUInteger，ABI 一致）。
static void sio_UV_anim_keyframes(Class self, SEL _cmd, double d, double delay, NSUInteger o,
                                  void (^a)(void), void (^c)(BOOL)) {
    SIO_HIT(SIO_HIT_KEYFRAME);
    SIO_REQUIRE_ORIG(o_UV_anim_keyframes);
    if (SIO_blocked()) { o_UV_anim_keyframes(self, _cmd, d, delay, o, a, c); return; }
    BOOL wasAnim = SIO_inUIViewAnim();
    SIO_setUIViewAnim(YES);
    o_UV_anim_keyframes(self, _cmd, SIO_targetDuration(d), SIO_targetDelay(delay), o, a, c);
    SIO_setUIViewAnim(wasAnim);   // v2.1.11：恢复而非清零，嵌套块动画时外层不丢重入保护
}

// ---- v1.8.12 新增：系统动画（删除/插入/重排等系统内建动画） ----
// +[UIView performSystemAnimation:onViews:options:animations:completion:]
// UISystemAnimation 同为 NSUInteger 枚举。用 CATransaction 覆盖时长，
// 不改写 animated 语义，避免影响系统对视图生命周期的收尾。
static void sio_UV_systemAnim(Class self, SEL _cmd, NSUInteger anim, NSArray *views, NSUInteger o,
                              void (^a)(void), void (^c)(BOOL)) {
    SIO_HIT(SIO_HIT_SYSANIM);
    SIO_REQUIRE_ORIG(o_UV_systemAnim);
    if (SIO_blocked()) { o_UV_systemAnim(self, _cmd, anim, views, o, a, c); return; }
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_targetDuration(0.35));
        o_UV_systemAnim(self, _cmd, anim, views, o, a, c);
    } @finally {
        [CATransaction commit];
    }
}

// ---- v1.8.13 新增：老式 beginAnimations 动画 API ----
// 用法： [UIView beginAnimations:nil context:NULL];
//        [UIView setAnimationDuration:0.3];   ← 这里
//        [UIView setAnimationDelay:0.1];      ← 和这里
//        ... 改属性 ...
//        [UIView commitAnimations];
// 这套 API 在 iOS 13 起被标记 deprecated，但从未失效，老代码/SDK/第三方库里仍然大量存在；
// 它不走 animateWithDuration: 系，我们此前的 8 个 UIView 块动画 hook 全部拦不到。
static void sio_UV_setAnimDuration(Class self, SEL _cmd, double d) {
    SIO_HIT(SIO_HIT_OLDSTYLE);
    SIO_REQUIRE_ORIG(o_UV_setAnimDuration);
    // 已在自己的一次块动画/转场包裹内 → 说明这次调用是 UIKit 内部转发出来的，原样透传防止二次缩放
    if (SIO_blocked() || SIO_inUIViewAnim()) { o_UV_setAnimDuration(self, _cmd, d); return; }
    // 置起标记后再调原 IMP：若 UIKit 把老式 API 落到 CATransaction.setAnimationDuration:
    // （或回调本方法自身），那一层会被自己的 hook 跳过，保证只缩放一次。
    BOOL wasAnim = SIO_inUIViewAnim();
    SIO_setUIViewAnim(YES);
    o_UV_setAnimDuration(self, _cmd, SIO_targetDuration(d));
    SIO_setUIViewAnim(wasAnim);   // v2.1.11：恢复而非清零，嵌套块动画时外层不丢重入保护
}

static void sio_UV_setAnimDelay(Class self, SEL _cmd, double d) {
    SIO_HIT(SIO_HIT_OLDSTYLE);
    SIO_REQUIRE_ORIG(o_UV_setAnimDelay);
    if (SIO_blocked() || SIO_inUIViewAnim()) { o_UV_setAnimDelay(self, _cmd, d); return; }
    // 延迟与块动画 animateWithDuration:delay: 保持同一套换算：
    // 加速 → d/speed，慢放 → d×slowFactor，瞬切 → 0
    BOOL wasAnim = SIO_inUIViewAnim();
    SIO_setUIViewAnim(YES);
    o_UV_setAnimDelay(self, _cmd, SIO_targetDelay(d));
    SIO_setUIViewAnim(wasAnim);   // v2.1.11：恢复而非清零，嵌套块动画时外层不丢重入保护
}

#pragma mark - CASpring（原版灵魂功能：参数缩放保持物理一致性）

static void sio_CASpring_mass(id self, SEL _cmd, double v) {
    SIO_HIT(SIO_HIT_SPRING);
    SIO_REQUIRE_ORIG(o_CASpring_mass);
    if (SIO_blocked() || !gSpring) { o_CASpring_mass(self, _cmd, v); return; }
    double m = SIO_springScale();
    o_CASpring_mass(self, _cmd, m > 0 ? v / (m * m) : v);
}

static void sio_CASpring_stiff(id self, SEL _cmd, double v) {
    SIO_HIT(SIO_HIT_SPRING);
    SIO_REQUIRE_ORIG(o_CASpring_stiff);
    if (SIO_blocked() || !gSpring) { o_CASpring_stiff(self, _cmd, v); return; }
    double m = SIO_springScale();
    o_CASpring_stiff(self, _cmd, v * m * m);
}

static void sio_CASpring_damp(id self, SEL _cmd, double v) {
    SIO_HIT(SIO_HIT_SPRING);
    SIO_REQUIRE_ORIG(o_CASpring_damp);
    if (SIO_blocked() || !gSpring) { o_CASpring_damp(self, _cmd, v); return; }
    o_CASpring_damp(self, _cmd, v * SIO_springScale());
}

#pragma mark - 导航 / 模态（进阶：事务时长包裹，转场动画交给事务时长统一控制）
//
// v1.8.12 真 bug 修复：这里原来一律 `setAnimationDuration:0.0`，效果是无论
// 加速/慢放/瞬切，导航与模态转场都被强制瞬间完成——慢放模式对这类转场
// 等于完全失效（用户开慢放看转场细节，结果转场根本没有）。
// 现在统一走 SIO_targetDuration(0.35)：
//   加速 ×5 → 0.07s（肉眼几乎无感，保持原有"秒过"体验）
//   慢放 ×2 → 0.70s（慢放真正生效）
//   瞬切    → 0.01s（直达）
// v2.0.0：在全局模式换算之后，再叠加转场独立倍率 TransitionBoost（仅加速/瞬切，
// 慢放不叠加），同样受 FloorDuration 下限保护。
static inline double SIO_transitionDuration(void) {
    // v2.1.10 真 bug 修复：原来这一行不看 gMode，导致「慢放」模式下导航/模态/Tab 转场
    // 依然被瞬时打开压成 1ms —— 慢放对转场彻底失效。这正是 v1.8.12 专门修过的老毛病
    // （当时是硬编码 0.0），v2.1.8 加瞬时打开时又踩回去了。慢放优先级高于瞬时打开。
    if (gEnabled && gMode != 1 && gInstantTransition) return 0.001;
    double d = SIO_targetDuration(0.35);
    if (gEnabled && gMode != 1 && gTransBoost > 1.0001 && d > 0.0) {
        d = d * gInvTrans;   // v2.1.11：除法→乘法，与 gInvSpeed / gInvLayer 同一套
        double fl = SIO_floor();
        if (d < fl) d = fl;
    }
    return d;
}

static void sio_nav_push(id self, SEL _cmd, UIViewController *vc, BOOL anim) {
    SIO_HIT(SIO_HIT_NAV);
    SIO_REQUIRE_ORIG(o_nav_push);
    if (SIO_blocked() || !gExtra || !anim) { o_nav_push(self, _cmd, vc, anim); return; }
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_transitionDuration());
        o_nav_push(self, _cmd, vc, anim);
    } @finally { [CATransaction commit]; }
}

static void sio_nav_pop(id self, SEL _cmd, BOOL anim) {
    SIO_HIT(SIO_HIT_NAV);
    SIO_REQUIRE_ORIG(o_nav_pop);
    if (SIO_blocked() || !gExtra || !anim) { o_nav_pop(self, _cmd, anim); return; }
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_transitionDuration());
        o_nav_pop(self, _cmd, anim);
    } @finally { [CATransaction commit]; }
}

static void sio_nav_popTo(id self, SEL _cmd, UIViewController *vc, BOOL anim) {
    SIO_HIT(SIO_HIT_NAV);
    SIO_REQUIRE_ORIG(o_nav_popTo);
    if (SIO_blocked() || !gExtra || !anim) { o_nav_popTo(self, _cmd, vc, anim); return; }
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_transitionDuration());
        o_nav_popTo(self, _cmd, vc, anim);
    } @finally { [CATransaction commit]; }
}

static void sio_nav_setVCs(id self, SEL _cmd, NSArray *vcs, BOOL anim) {
    SIO_HIT(SIO_HIT_NAV);
    SIO_REQUIRE_ORIG(o_nav_setVCs);
    if (SIO_blocked() || !gExtra || !anim) { o_nav_setVCs(self, _cmd, vcs, anim); return; }
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_transitionDuration());
        o_nav_setVCs(self, _cmd, vcs, anim);
    } @finally { [CATransaction commit]; }
}

static void sio_nav_privDur(id self, SEL _cmd, double d) {
    SIO_HIT(SIO_HIT_NAV);
    SIO_REQUIRE_ORIG(o_nav_privDur);
    if (SIO_blocked() || !gExtra) { o_nav_privDur(self, _cmd, d); return; }
    o_nav_privDur(self, _cmd, SIO_targetDuration(d));
}

static void sio_vc_present(id self, SEL _cmd, UIViewController *vc, BOOL anim, void (^c)(void)) {
    SIO_HIT(SIO_HIT_PRESENT);
    SIO_REQUIRE_ORIG(o_vc_present);
    if (SIO_blocked() || !gExtra || !anim) { o_vc_present(self, _cmd, vc, anim, c); return; }
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_transitionDuration());
        o_vc_present(self, _cmd, vc, anim, c);
    } @finally { [CATransaction commit]; }
}

static void sio_vc_dismiss(id self, SEL _cmd, BOOL anim, void (^c)(void)) {
    SIO_HIT(SIO_HIT_PRESENT);
    SIO_REQUIRE_ORIG(o_vc_dismiss);
    if (SIO_blocked() || !gExtra || !anim) { o_vc_dismiss(self, _cmd, anim, c); return; }
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_transitionDuration());
        o_vc_dismiss(self, _cmd, anim, c);
    } @finally { [CATransaction commit]; }
}

// ---- v1.8.12 新增：容器控制器子控制器转场 ----
// -[UIViewController transitionFromViewController:toViewController:duration:options:animations:completion:]
// 与已 hook 的 +[UIView transitionFromView:…] 属同一机制，但走的是 VC 容器路径，
// 此前完全未覆盖（分栏/自研 Tab/向导式页面大量使用）。duration 直接改写。
static void sio_vc_transitionFrom(id self, SEL _cmd, UIViewController *from, UIViewController *to,
                                  double d, UIViewAnimationOptions o,
                                  void (^an)(void), void (^c)(BOOL)) {
    SIO_HIT(SIO_HIT_PRESENT);
    SIO_REQUIRE_ORIG(o_vc_transitionFrom);
    if (SIO_blocked() || !gExtra) { o_vc_transitionFrom(self, _cmd, from, to, d, o, an, c); return; }
    o_vc_transitionFrom(self, _cmd, from, to, SIO_targetDuration(d), o, an, c);
}

// ---- v1.8.12 新增：底部 Tab 切换转场 ----
// UITabBarController 的选中切换此前未 hook（父项目 README 把它列为基础层 hook，
// 但 SIOriginal 这一支一直缺失）。用 CATransaction 覆盖时长，不改动选中语义。
static void sio_tab_setIndex(id self, SEL _cmd, NSUInteger idx) {
    SIO_HIT(SIO_HIT_TAB);
    SIO_REQUIRE_ORIG(o_tab_setIndex);
    if (SIO_blocked() || !gExtra) { o_tab_setIndex(self, _cmd, idx); return; }
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_transitionDuration());
        o_tab_setIndex(self, _cmd, idx);
    } @finally { [CATransaction commit]; }
}

static void sio_tab_setVC(id self, SEL _cmd, UIViewController *vc) {
    SIO_HIT(SIO_HIT_TAB);
    SIO_REQUIRE_ORIG(o_tab_setVC);
    if (SIO_blocked() || !gExtra) { o_tab_setVC(self, _cmd, vc); return; }
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_transitionDuration());
        o_tab_setVC(self, _cmd, vc);
    } @finally { [CATransaction commit]; }
}

#pragma mark - TV/CV 列表全家桶（ListAccel 纯开关控制）

// v1.8.11：移除 com.sfic.knight 硬编码保护，24 个列表 hook 完全由配置开关控制。
// 重列表 App（顺丰骑士/淘宝/京东等）务必在配置 App 关闭「列表加速」，否则会破坏列表状态机。
static BOOL SIO_listOK(void) { return gListAccel && !SIO_blocked(); }

static void SIO_listWrap(void (^block)(void)) {
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_targetDuration(0.25));
        block();
    } @finally { [CATransaction commit]; }
}

// ---- UITableView ----
static void (*o_tv_selectRow)(id, SEL, NSIndexPath *, BOOL, UITableViewScrollPosition);
static void sio_tv_selectRow(id self, SEL _cmd, NSIndexPath *ip, BOOL anim, UITableViewScrollPosition pos) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_selectRow);
    if (!SIO_listOK()) { o_tv_selectRow(self, _cmd, ip, anim, pos); return; }
    SIO_listWrap(^{ o_tv_selectRow(self, _cmd, ip, anim, pos); });
}
static void (*o_tv_deselectRow)(id, SEL, NSIndexPath *, BOOL);
static void sio_tv_deselectRow(id self, SEL _cmd, NSIndexPath *ip, BOOL anim) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_deselectRow);
    if (!SIO_listOK()) { o_tv_deselectRow(self, _cmd, ip, anim); return; }
    SIO_listWrap(^{ o_tv_deselectRow(self, _cmd, ip, anim); });
}
static void (*o_tv_scrollToRow)(id, SEL, NSIndexPath *, UITableViewScrollPosition, BOOL);
static void sio_tv_scrollToRow(id self, SEL _cmd, NSIndexPath *ip, UITableViewScrollPosition pos, BOOL anim) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_scrollToRow);
    if (!SIO_listOK()) { o_tv_scrollToRow(self, _cmd, ip, pos, anim); return; }
    SIO_listWrap(^{ o_tv_scrollToRow(self, _cmd, ip, pos, anim); });
}
static void (*o_tv_scrollNearest)(id, SEL, UITableViewScrollPosition, BOOL);
static void sio_tv_scrollNearest(id self, SEL _cmd, UITableViewScrollPosition pos, BOOL anim) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_scrollNearest);
    if (!SIO_listOK()) { o_tv_scrollNearest(self, _cmd, pos, anim); return; }
    SIO_listWrap(^{ o_tv_scrollNearest(self, _cmd, pos, anim); });
}
static void (*o_tv_reloadData)(id, SEL);
static void sio_tv_reloadData(id self, SEL _cmd) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_reloadData);
    if (!SIO_listOK()) { o_tv_reloadData(self, _cmd); return; }
    SIO_listWrap(^{ o_tv_reloadData(self, _cmd); });
}
static void (*o_tv_reloadRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void sio_tv_reloadRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_reloadRows);
    if (!SIO_listOK()) { o_tv_reloadRows(self, _cmd, ips, a); return; }
    SIO_listWrap(^{ o_tv_reloadRows(self, _cmd, ips, a); });
}
static void (*o_tv_reloadSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void sio_tv_reloadSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_reloadSections);
    if (!SIO_listOK()) { o_tv_reloadSections(self, _cmd, sec, a); return; }
    SIO_listWrap(^{ o_tv_reloadSections(self, _cmd, sec, a); });
}
static void (*o_tv_insertRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void sio_tv_insertRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_insertRows);
    if (!SIO_listOK()) { o_tv_insertRows(self, _cmd, ips, a); return; }
    SIO_listWrap(^{ o_tv_insertRows(self, _cmd, ips, a); });
}
static void (*o_tv_deleteRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void sio_tv_deleteRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_deleteRows);
    if (!SIO_listOK()) { o_tv_deleteRows(self, _cmd, ips, a); return; }
    SIO_listWrap(^{ o_tv_deleteRows(self, _cmd, ips, a); });
}
static void (*o_tv_moveRow)(id, SEL, NSIndexPath *, NSIndexPath *);
static void sio_tv_moveRow(id self, SEL _cmd, NSIndexPath *from, NSIndexPath *to) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_moveRow);
    if (!SIO_listOK()) { o_tv_moveRow(self, _cmd, from, to); return; }
    SIO_listWrap(^{ o_tv_moveRow(self, _cmd, from, to); });
}
static void (*o_tv_insertSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void sio_tv_insertSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_insertSections);
    if (!SIO_listOK()) { o_tv_insertSections(self, _cmd, sec, a); return; }
    SIO_listWrap(^{ o_tv_insertSections(self, _cmd, sec, a); });
}
static void (*o_tv_deleteSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void sio_tv_deleteSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_deleteSections);
    if (!SIO_listOK()) { o_tv_deleteSections(self, _cmd, sec, a); return; }
    SIO_listWrap(^{ o_tv_deleteSections(self, _cmd, sec, a); });
}
static void (*o_tv_moveSection)(id, SEL, NSUInteger, NSUInteger);
static void sio_tv_moveSection(id self, SEL _cmd, NSUInteger from, NSUInteger to) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_moveSection);
    if (!SIO_listOK()) { o_tv_moveSection(self, _cmd, from, to); return; }
    SIO_listWrap(^{ o_tv_moveSection(self, _cmd, from, to); });
}
static void (*o_tv_setEditing)(id, SEL, BOOL, BOOL);
static void sio_tv_setEditing(id self, SEL _cmd, BOOL editing, BOOL anim) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_setEditing);
    if (!SIO_listOK()) { o_tv_setEditing(self, _cmd, editing, anim); return; }
    SIO_listWrap(^{ o_tv_setEditing(self, _cmd, editing, anim); });
}
static void (*o_tv_batchUpdates)(id, SEL, void (^)(void), void (^)(BOOL));
static void sio_tv_batchUpdates(id self, SEL _cmd, void (^updates)(void), void (^comp)(BOOL)) {
    SIO_HIT(SIO_HIT_LIST_TV);
    SIO_REQUIRE_ORIG(o_tv_batchUpdates);
    if (!SIO_listOK()) { o_tv_batchUpdates(self, _cmd, updates, comp); return; }
    SIO_listWrap(^{ o_tv_batchUpdates(self, _cmd, updates, comp); });
}

// ---- UICollectionView ----
static void (*o_cv_reloadData)(id, SEL);
static void sio_cv_reloadData(id self, SEL _cmd) {
    SIO_HIT(SIO_HIT_LIST_CV);
    SIO_REQUIRE_ORIG(o_cv_reloadData);
    if (!SIO_listOK()) { o_cv_reloadData(self, _cmd); return; }
    SIO_listWrap(^{ o_cv_reloadData(self, _cmd); });
}
static void (*o_cv_reloadItems)(id, SEL, NSArray *);
static void sio_cv_reloadItems(id self, SEL _cmd, NSArray *ips) {
    SIO_HIT(SIO_HIT_LIST_CV);
    SIO_REQUIRE_ORIG(o_cv_reloadItems);
    if (!SIO_listOK()) { o_cv_reloadItems(self, _cmd, ips); return; }
    SIO_listWrap(^{ o_cv_reloadItems(self, _cmd, ips); });
}
static void (*o_cv_reloadSections)(id, SEL, NSArray *);
static void sio_cv_reloadSections(id self, SEL _cmd, NSArray *secs) {
    SIO_HIT(SIO_HIT_LIST_CV);
    SIO_REQUIRE_ORIG(o_cv_reloadSections);
    if (!SIO_listOK()) { o_cv_reloadSections(self, _cmd, secs); return; }
    SIO_listWrap(^{ o_cv_reloadSections(self, _cmd, secs); });
}
static void (*o_cv_insertItems)(id, SEL, NSArray *);
static void sio_cv_insertItems(id self, SEL _cmd, NSArray *ips) {
    SIO_HIT(SIO_HIT_LIST_CV);
    SIO_REQUIRE_ORIG(o_cv_insertItems);
    if (!SIO_listOK()) { o_cv_insertItems(self, _cmd, ips); return; }
    SIO_listWrap(^{ o_cv_insertItems(self, _cmd, ips); });
}
static void (*o_cv_deleteItems)(id, SEL, NSArray *);
static void sio_cv_deleteItems(id self, SEL _cmd, NSArray *ips) {
    SIO_HIT(SIO_HIT_LIST_CV);
    SIO_REQUIRE_ORIG(o_cv_deleteItems);
    if (!SIO_listOK()) { o_cv_deleteItems(self, _cmd, ips); return; }
    SIO_listWrap(^{ o_cv_deleteItems(self, _cmd, ips); });
}
static void (*o_cv_moveItem)(id, SEL, NSIndexPath *, NSIndexPath *);
static void sio_cv_moveItem(id self, SEL _cmd, NSIndexPath *from, NSIndexPath *to) {
    SIO_HIT(SIO_HIT_LIST_CV);
    SIO_REQUIRE_ORIG(o_cv_moveItem);
    if (!SIO_listOK()) { o_cv_moveItem(self, _cmd, from, to); return; }
    SIO_listWrap(^{ o_cv_moveItem(self, _cmd, from, to); });
}
static void (*o_cv_scrollToItem)(id, SEL, NSIndexPath *, UICollectionViewScrollPosition, BOOL);
static void sio_cv_scrollToItem(id self, SEL _cmd, NSIndexPath *ip, UICollectionViewScrollPosition pos, BOOL anim) {
    SIO_HIT(SIO_HIT_LIST_CV);
    SIO_REQUIRE_ORIG(o_cv_scrollToItem);
    if (!SIO_listOK()) { o_cv_scrollToItem(self, _cmd, ip, pos, anim); return; }
    SIO_listWrap(^{ o_cv_scrollToItem(self, _cmd, ip, pos, anim); });
}
static void (*o_cv_selectItem)(id, SEL, NSIndexPath *, BOOL, UICollectionViewScrollPosition);
static void sio_cv_selectItem(id self, SEL _cmd, NSIndexPath *ip, BOOL anim, UICollectionViewScrollPosition pos) {
    SIO_HIT(SIO_HIT_LIST_CV);
    SIO_REQUIRE_ORIG(o_cv_selectItem);
    if (!SIO_listOK()) { o_cv_selectItem(self, _cmd, ip, anim, pos); return; }
    SIO_listWrap(^{ o_cv_selectItem(self, _cmd, ip, anim, pos); });
}
static void (*o_cv_deselectItem)(id, SEL, NSIndexPath *, BOOL);
static void sio_cv_deselectItem(id self, SEL _cmd, NSIndexPath *ip, BOOL anim) {
    SIO_HIT(SIO_HIT_LIST_CV);
    SIO_REQUIRE_ORIG(o_cv_deselectItem);
    if (!SIO_listOK()) { o_cv_deselectItem(self, _cmd, ip, anim); return; }
    SIO_listWrap(^{ o_cv_deselectItem(self, _cmd, ip, anim); });
}

#pragma mark - v2.1.8 instant page/link open

// UIActivityIndicatorView: defer startAnimating by HUDDelay. If stopAnimating
// arrives within that window (the vast majority of short requests), the spinner
// is cancelled before it ever appears - kills the "flash of loader" entirely.
//
// v2.1.12（审查 N-5）：**慢放模式下 HUDDelay 刻意不放大**，这是有意决策，不是 bug。
//   同为「延迟」，块动画的 delay 在慢放时按 gSlowFactor 放大（见 SIO_targetDelay），
//   HUD 延迟不走任何缩放，固定用 gHUDDelay。理由：HUD 延迟的目的是「抑制转圈闪现」，
//   这个目的在慢放模式下依然成立；若跟着放大，加载圈会迟迟不出现，用户会以为卡死
//   —— 那正好是这个功能要消除的观感。
//   反面意见（慢放是为了看清每个动画细节，转圈显隐也是动画的一部分）也成立，
//   但权衡后选了前者。⚠ 请勿把这处当成 bug「修」掉；要改请连同这条注释一起改，
//   因为它正是 P0-1 那类回归（新开关没考虑慢放语义）留下来的教训。
static const void *kSIOAIDelayMark = &kSIOAIDelayMark;

static void sio_AIstartAnim(id self, SEL _cmd) {
    SIO_HIT(SIO_HIT_HUD_AI);
    SIO_REQUIRE_ORIG(o_AIstartAnim);
    if (SIO_blocked() || !gHUDFast || gSelfHudProtected) { o_AIstartAnim(self, _cmd); return; }
    // v2.1.10 微优化：原来每次 startAnimating 都新建一个 @YES（NSNumber 分配）。
    // 这里改复用不朽常量 kCFBooleanTrue + ASSIGN 策略，与 SIO_markAnimScaled 同一套做法：
    // 常量永不释放，ASSIGN 不会悬垂，热路径（下拉刷新/列表加载）零分配。
    objc_setAssociatedObject(self, kSIOAIDelayMark,
                             (__bridge id)kCFBooleanTrue, OBJC_ASSOCIATION_ASSIGN);
    __weak id wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gHUDDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id s = wself;
        if (!s || !objc_getAssociatedObject(s, kSIOAIDelayMark)) return;
        objc_setAssociatedObject(s, kSIOAIDelayMark, nil, OBJC_ASSOCIATION_ASSIGN);
        o_AIstartAnim(s, _cmd);
    });
}

static void sio_AIstopAnim(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_AIstopAnim);
    // Always cancel any pending deferred start, then stop immediately.
    objc_setAssociatedObject(self, kSIOAIDelayMark, nil, OBJC_ASSOCIATION_ASSIGN);
    o_AIstopAnim(self, _cmd);
}

// WKWebView setHidden: while load progress >10%, refuse to hide. Stops apps from
// covering a web view that is already rendering (the classic white-screen wait).
// dylib does not link WebKit.framework, so read properties via objc_msgSend and
// never reference any WK* type symbol directly.
static Class sio_WKClass(void) {
    static Class c; static dispatch_once_t tok;
    dispatch_once(&tok, ^{ c = objc_getClass("WKWebView"); });
    return c;
}
// v2.1.11 真隐患修复：原来命中条件是 `return` —— 直接把 App 的 `webView.hidden = YES`
// **永久丢弃**，且没有任何补执行机制。注释假设「加载完成后 App 会再调一次隐藏」，
// 但现实中大量 App 只在某个状态切换点设一次 hidden，之后依赖这个状态不再重设。
// 这类 App 命中后 webView 会永久可见盖住原生内容（或反过来原生内容永不显示），
// 用户只能杀进程 —— 与本项目最忌惮的「丢弃一次状态设置、破坏状态配对」同一性质
// （参考微信预览「工具栏永远停在隐藏态，只能杀微信」的取证记录）。
//
// 改成「延迟执行」：不拒绝这次隐藏，只把它推后。加载结束或总超时（2s）后一定补上
// o_WKsetHidden(YES)，保证每一次隐藏请求最终都会执行。若期间 App 又调用了
// setHidden:NO（重新显示），pending 标记被清，延后的隐藏自动作废。
static const void *kSIOWKHidePending = &kSIOWKHidePending;

static void sio_WKdeferHide(id wv, int attempt) {
    // v2.1.12（审查 N-3）：入口去重。原来 App 在 pending 期间再次 setHidden:YES
    // （仍在 loading 且 progress > 0.1）时，会无条件再开一条延迟链 ——
    // 连续 N 次调用产生 N 条并行链，最终 o_WKsetHidden(YES) 被调 N 次。
    // setHidden: 本身幂等，危害仅限冗余，但快速切换隐藏状态的 App 上会累积无谓的
    // dispatch_after。这里让后续调用直接复用已在跑的那条链。
    if (attempt == 0 && objc_getAssociatedObject(wv, kSIOWKHidePending)) return;
    objc_setAssociatedObject(wv, kSIOWKHidePending,
                             (__bridge id)kCFBooleanTrue, OBJC_ASSOCIATION_ASSIGN);
    __weak id wself = wv;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id s = wself;
        if (!s || !o_WKsetHidden) return;
        // App 期间又把它显示回来了 → 这次延后的隐藏作废，不再补执行
        if (!objc_getAssociatedObject(s, kSIOWKHidePending)) return;
        BOOL loading = NO;
        @try {
            loading = ((BOOL (*)(id, SEL))objc_msgSend)(s, @selector(isLoading));
        } @catch (__unused NSException *e) {}
        // 最多等 2s（8 × 0.25s），超时无条件补执行 —— 绝不永久吞掉一次隐藏
        if (loading && attempt < 7) { sio_WKdeferHide(s, attempt + 1); return; }
        objc_setAssociatedObject(s, kSIOWKHidePending, nil, OBJC_ASSOCIATION_ASSIGN);
        o_WKsetHidden(s, @selector(setHidden:), YES);
    });
}

static void sio_WKsetHidden(id self, SEL _cmd, BOOL hidden) {
    SIO_HIT(SIO_HIT_WK);
    SIO_REQUIRE_ORIG(o_WKsetHidden);
    Class wkc = sio_WKClass();
    if (!wkc || ![self isKindOfClass:wkc]) { o_WKsetHidden(self, _cmd, hidden); return; }
    if (!hidden) {
        // 显示请求：作废任何待补的隐藏（状态以 App 的最新意图为准）
        objc_setAssociatedObject(self, kSIOWKHidePending, nil, OBJC_ASSOCIATION_ASSIGN);
        o_WKsetHidden(self, _cmd, hidden);
        return;
    }
    if (!SIO_blocked() && gWKFastShow && !gSelfHudProtected) {
        BOOL loading = NO;
        @try {
            loading = ((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(isLoading));
        } @catch (__unused NSException *e) {}
        if (loading) {
            double progress = 0.0;
            @try {
                progress = ((double (*)(id, SEL))objc_msgSend)(self, @selector(estimatedProgress));
            } @catch (__unused NSException *e) {}
            if (progress > 0.1) { sio_WKdeferHide(self, 0); return; }   // 只延后，不丢弃
        }
    }
    o_WKsetHidden(self, _cmd, hidden);
}

// SVProgressHUD class method +dismissWithDelay:completion: force near-zero delay.
static void sio_SVHUDDelay(id self, SEL _cmd, NSTimeInterval delay, void (^completion)(void)) {
    SIO_HIT(SIO_HIT_HUD_SV);
    SIO_REQUIRE_ORIG(o_SVHUDDelay);
    if (SIO_blocked() || !gHUDFast || gSelfHudProtected) {
        o_SVHUDDelay(self, _cmd, delay, completion); return;
    }
    o_SVHUDDelay(self, _cmd, 0.001, completion);
}

// MBProgressHUD instance method -hideAnimated: drop the hide animation.
static void sio_MBHUDHide(id self, SEL _cmd, BOOL animated) {
    SIO_HIT(SIO_HIT_HUD_MB);
    SIO_REQUIRE_ORIG(o_MBHUDHide);
    if (SIO_blocked() || !gHUDFast || gSelfHudProtected) { o_MBHUDHide(self, _cmd, animated); return; }
    o_MBHUDHide(self, _cmd, NO);
}

#pragma mark - 安装

__attribute__((constructor))
static void SIOriginalInit(void) {
    // v1.8.12：安装全程 @try 包裹。任何一步异常只丢功能，绝不影响目标 App 启动（红线规则 #2）。
    @try {
    pthread_key_create(&gInUIViewAnimKey, NULL);
    pthread_key_create(&gInPAInitKey, NULL);
    gSelfBundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    gIsWeChat = [gSelfBundle isEqualToString:@"com.tencent.xin"];
    // v2.1.11：保护名单命中结果在此一次性算完，之后 7 个高频 hook 只读布尔。
    // bundle id 进程内不变，热重载也无需重算。
    gSelfHudProtected  = SIO_hudProtected();
    gSelfFeelProtected = SIO_feelProtected();
    SIO_reload();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    SIO_settingsChanged,
                                    (__bridge CFStringRef)kNotifyName, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    // v2.1.12（F-A）：请求命中统计浮层
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    SIO_onStatsRequest,
                                    (__bridge CFStringRef)kNotifyStats, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    // v2.1.15：常驻后台的 App 收到请求时不是 Active，浮层会被 active 检查挡掉。
    // 这里挂一个回到前台的观察者，把挂起的请求补弹出来。令牌必须持有，
    // 否则 block 观察者随返回值释放、立即自动注销（与 v2.1.10 的 AVAudioSession 同坑）。
    sioStatsActiveObs = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) { SIO_onDidBecomeActive(note); }];

    Class caAnim = objc_getClass("CAAnimation");
    Class catx   = objc_getClass("CATransaction");
    Class uv     = objc_getClass("UIView");
    Class spring = objc_getClass("CASpringAnimation");
    Class nav    = objc_getClass("UINavigationController");
    Class vc     = objc_getClass("UIViewController");
    if (!caAnim || !uv) return;

    // 核心：CAAnimation setDuration:（仅基类，子类继承，避免 hook 冲突）
    SIO_swizzleInstance(caAnim, @selector(setDuration:),
                        (IMP)sio_CAAnim_setDuration, (IMP *)&o_CAAnim_setDuration);

    // 事务时长（UIView 包裹期间跳过，防双除）
    if (catx) SIO_swizzleInstance(object_getClass(catx), @selector(setAnimationDuration:),
                                  (IMP)sio_CATransaction_setDur, (IMP *)&o_CATransaction_setDur);

    // UIView 块动画 ×5 + 转场 ×2
    SIO_swizzleClass(uv, @selector(animateWithDuration:animations:),
                     (IMP)sio_UV_anim_d, (IMP *)&o_UV_anim_d);
    SIO_swizzleClass(uv, @selector(animateWithDuration:animations:completion:),
                     (IMP)sio_UV_anim_dc, (IMP *)&o_UV_anim_dc);
    SIO_swizzleClass(uv, @selector(animateWithDuration:delay:options:animations:completion:),
                     (IMP)sio_UV_anim_ddoc, (IMP *)&o_UV_anim_ddoc);
    SIO_swizzleClass(uv, @selector(animateWithDuration:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:),
                     (IMP)sio_UV_anim_spring, (IMP *)&o_UV_anim_spring);
    SIO_swizzleClass(uv, @selector(transitionWithView:duration:options:animations:completion:),
                     (IMP)sio_UV_trans, (IMP *)&o_UV_trans);
    SIO_swizzleClass(uv, @selector(transitionFromView:toView:duration:options:animations:completion:),
                     (IMP)sio_UV_transFrom, (IMP *)&o_UV_transFrom);
    // v2.0.0 新增：无 animations 段的转场变体
    SIO_swizzleClass(uv, @selector(transitionFromView:toView:duration:options:completion:),
                     (IMP)sio_UV_transFromNoAnim, (IMP *)&o_UV_transFromNoAnim);
    // v1.8.12 新增：关键帧动画 + 系统动画（同为 UIView 类方法，低风险）
    SIO_swizzleClass(uv, @selector(animateKeyframesWithDuration:delay:options:animations:completion:),
                     (IMP)sio_UV_anim_keyframes, (IMP *)&o_UV_anim_keyframes);
    SIO_swizzleClass(uv, @selector(performSystemAnimation:onViews:options:animations:completion:),
                     (IMP)sio_UV_systemAnim, (IMP *)&o_UV_systemAnim);
    // v1.8.13 新增：老式 beginAnimations/commitAnimations 时代的时长与延迟入口
    SIO_swizzleClass(uv, @selector(setAnimationDuration:),
                     (IMP)sio_UV_setAnimDuration, (IMP *)&o_UV_setAnimDuration);
    SIO_swizzleClass(uv, @selector(setAnimationDelay:),
                     (IMP)sio_UV_setAnimDelay, (IMP *)&o_UV_setAnimDelay);

    // 弹簧参数 ×3
    if (spring) {
        SIO_swizzleInstance(spring, @selector(setMass:),
                            (IMP)sio_CASpring_mass, (IMP *)&o_CASpring_mass);
        SIO_swizzleInstance(spring, @selector(setStiffness:),
                            (IMP)sio_CASpring_stiff, (IMP *)&o_CASpring_stiff);
        SIO_swizzleInstance(spring, @selector(setDamping:),
                            (IMP)sio_CASpring_damp, (IMP *)&o_CASpring_damp);
    }

    // 进阶转场 ×7
    if (nav && vc) {
        SIO_swizzleInstance(nav, @selector(pushViewController:animated:),
                            (IMP)sio_nav_push, (IMP *)&o_nav_push);
        SIO_swizzleInstance(nav, @selector(popViewControllerAnimated:),
                            (IMP)sio_nav_pop, (IMP *)&o_nav_pop);
        SIO_swizzleInstance(nav, @selector(popToViewController:animated:),
                            (IMP)sio_nav_popTo, (IMP *)&o_nav_popTo);
        SIO_swizzleInstance(nav, @selector(setViewControllers:animated:),
                            (IMP)sio_nav_setVCs, (IMP *)&o_nav_setVCs);
        if (class_getInstanceMethod(nav, @selector(_setTransitionDuration:))) {
            SIO_swizzleInstance(nav, @selector(_setTransitionDuration:),
                                (IMP)sio_nav_privDur, (IMP *)&o_nav_privDur);
        }
        SIO_swizzleInstance(vc, @selector(presentViewController:animated:completion:),
                            (IMP)sio_vc_present, (IMP *)&o_vc_present);
        SIO_swizzleInstance(vc, @selector(dismissViewControllerAnimated:completion:),
                            (IMP)sio_vc_dismiss, (IMP *)&o_vc_dismiss);
        // v1.8.12 新增：容器控制器子控制器转场（与 UIView 转场同机制，此前未覆盖）
        SIO_swizzleInstance(vc, @selector(transitionFromViewController:toViewController:duration:options:animations:completion:),
                            (IMP)sio_vc_transitionFrom, (IMP *)&o_vc_transitionFrom);
    }

    // v1.8.12 新增：底部 Tab 切换转场（父项目基础层有，SIOriginal 这一支一直缺失）
    Class tab = objc_getClass("UITabBarController");
    if (tab) {
        SIO_swizzleInstance(tab, @selector(setSelectedIndex:),
                            (IMP)sio_tab_setIndex, (IMP *)&o_tab_setIndex);
        SIO_swizzleInstance(tab, @selector(setSelectedViewController:),
                            (IMP)sio_tab_setVC, (IMP *)&o_tab_setVC);
    }

    // TV/CV 列表全家桶 ×24（ListAccel 纯开关控制；重列表 App 默认关闭）
    Class tv = objc_getClass("UITableView");
    Class cv = objc_getClass("UICollectionView");
    if (tv) {
        SIO_swizzleInstance(tv, @selector(selectRowAtIndexPath:animated:scrollPosition:),
                            (IMP)sio_tv_selectRow, (IMP *)&o_tv_selectRow);
        SIO_swizzleInstance(tv, @selector(deselectRowAtIndexPath:animated:),
                            (IMP)sio_tv_deselectRow, (IMP *)&o_tv_deselectRow);
        SIO_swizzleInstance(tv, @selector(scrollToRowAtIndexPath:atScrollPosition:animated:),
                            (IMP)sio_tv_scrollToRow, (IMP *)&o_tv_scrollToRow);
        SIO_swizzleInstance(tv, @selector(scrollToNearestSelectedRowAtScrollPosition:animated:),
                            (IMP)sio_tv_scrollNearest, (IMP *)&o_tv_scrollNearest);
        SIO_swizzleInstance(tv, @selector(reloadData),
                            (IMP)sio_tv_reloadData, (IMP *)&o_tv_reloadData);
        SIO_swizzleInstance(tv, @selector(reloadRowsAtIndexPaths:withRowAnimation:),
                            (IMP)sio_tv_reloadRows, (IMP *)&o_tv_reloadRows);
        SIO_swizzleInstance(tv, @selector(reloadSections:withRowAnimation:),
                            (IMP)sio_tv_reloadSections, (IMP *)&o_tv_reloadSections);
        SIO_swizzleInstance(tv, @selector(insertRowsAtIndexPaths:withRowAnimation:),
                            (IMP)sio_tv_insertRows, (IMP *)&o_tv_insertRows);
        SIO_swizzleInstance(tv, @selector(deleteRowsAtIndexPaths:withRowAnimation:),
                            (IMP)sio_tv_deleteRows, (IMP *)&o_tv_deleteRows);
        SIO_swizzleInstance(tv, @selector(moveRowAtIndexPath:toIndexPath:),
                            (IMP)sio_tv_moveRow, (IMP *)&o_tv_moveRow);
        SIO_swizzleInstance(tv, @selector(insertSections:withRowAnimation:),
                            (IMP)sio_tv_insertSections, (IMP *)&o_tv_insertSections);
        SIO_swizzleInstance(tv, @selector(deleteSections:withRowAnimation:),
                            (IMP)sio_tv_deleteSections, (IMP *)&o_tv_deleteSections);
        SIO_swizzleInstance(tv, @selector(moveSection:toSection:),
                            (IMP)sio_tv_moveSection, (IMP *)&o_tv_moveSection);
        SIO_swizzleInstance(tv, @selector(setEditing:animated:),
                            (IMP)sio_tv_setEditing, (IMP *)&o_tv_setEditing);
        SIO_swizzleInstance(tv, @selector(performBatchUpdates:completion:),
                            (IMP)sio_tv_batchUpdates, (IMP *)&o_tv_batchUpdates);
    }
    if (cv) {
        SIO_swizzleInstance(cv, @selector(reloadData),
                            (IMP)sio_cv_reloadData, (IMP *)&o_cv_reloadData);
        SIO_swizzleInstance(cv, @selector(reloadItemsAtIndexPaths:),
                            (IMP)sio_cv_reloadItems, (IMP *)&o_cv_reloadItems);
        SIO_swizzleInstance(cv, @selector(reloadSections:),
                            (IMP)sio_cv_reloadSections, (IMP *)&o_cv_reloadSections);
        SIO_swizzleInstance(cv, @selector(insertItemsAtIndexPaths:),
                            (IMP)sio_cv_insertItems, (IMP *)&o_cv_insertItems);
        SIO_swizzleInstance(cv, @selector(deleteItemsAtIndexPaths:),
                            (IMP)sio_cv_deleteItems, (IMP *)&o_cv_deleteItems);
        SIO_swizzleInstance(cv, @selector(moveItemAtIndexPath:toIndexPath:),
                            (IMP)sio_cv_moveItem, (IMP *)&o_cv_moveItem);
        SIO_swizzleInstance(cv, @selector(scrollToItemAtIndexPath:atScrollPosition:animated:),
                            (IMP)sio_cv_scrollToItem, (IMP *)&o_cv_scrollToItem);
        SIO_swizzleInstance(cv, @selector(selectItemAtIndexPath:animated:scrollPosition:),
                            (IMP)sio_cv_selectItem, (IMP *)&o_cv_selectItem);
        SIO_swizzleInstance(cv, @selector(deselectItemAtIndexPath:animated:),
                            (IMP)sio_cv_deselectItem, (IMP *)&o_cv_deselectItem);
    }

    // ---- v2.1.8 instant-open hooks (probe classes; skip silently if absent) ----
    {
        Class ai = objc_getClass("UIActivityIndicatorView");
        if (ai) {
            SIO_swizzleInstance(ai, @selector(startAnimating), (IMP)sio_AIstartAnim, (IMP *)&o_AIstartAnim);
            SIO_swizzleInstance(ai, @selector(stopAnimating),  (IMP)sio_AIstopAnim,  (IMP *)&o_AIstopAnim);
        }
        Class wk = objc_getClass("WKWebView");
        if (wk) {
            // setHidden: is inherited from UIView. A plain method_setImplementation
            // would rewrite the shared UIView IMP and hook EVERY view (then isLoading
            // crashes non-web views). Copy the parent IMP onto WKWebView first, then
            // override only that subclass copy.
            SEL wkSel = @selector(setHidden:);
            Method wkM = class_getInstanceMethod(wk, wkSel);
            if (wkM) {
                IMP parentImp = method_getImplementation(wkM);
                if (class_addMethod(wk, wkSel, parentImp, method_getTypeEncoding(wkM))) {
                    Method ownM = class_getInstanceMethod(wk, wkSel);
                    o_WKsetHidden = (void (*)(id, SEL, BOOL))method_getImplementation(ownM);
                    method_setImplementation(ownM, (IMP)sio_WKsetHidden);
                } else {
                    // WKWebView already provides its own setHidden: - direct swizzle is safe.
                    SIO_swizzleInstance(wk, wkSel, (IMP)sio_WKsetHidden, (IMP *)&o_WKsetHidden);
                }
            }
        }
        Class svh = objc_getClass("SVProgressHUD");
        if (svh && class_getClassMethod(svh, @selector(dismissWithDelay:completion:))) {
            SIO_swizzleClass(svh, @selector(dismissWithDelay:completion:), (IMP)sio_SVHUDDelay, (IMP *)&o_SVHUDDelay);
        }
        Class mbh = objc_getClass("MBProgressHUD");
        if (mbh && class_getInstanceMethod(mbh, @selector(hideAnimated:))) {
            SIO_swizzleInstance(mbh, @selector(hideAnimated:), (IMP)sio_MBHUDHide, (IMP *)&o_MBHUDHide);
        }
    }

    // iOS 16 优化增强：UIViewPropertyAnimator + UIScrollView + CALayer
    SIO_installiOS16Extras();

    // v1.8.12：启动指纹日志，便于测试时在 Console 确认注入的版本与生效配置
    // v1.8.14：追加 override（是否命中 App 级覆盖）与 listGuard（是否被列表硬保护）
    // v2.0.0：追加 floor/transBoost/longPress/notify 四个新引擎参数
    NSLog(@"[SIOriginal] v2.1.16 hooks installed in %@ (enabled=%d mode=%d speed=%.1f layerBoost=%.0f transBoost=%.1f floor=%.3f spring=%d extra=%d list=%d zoom=%d feel=%d/%d notify=%d instant=%d hud=%d/%.2fs wk=%d override=%d listGuard=%d hudGuard=%d feelGuard=%d)",
          gSelfBundle, gEnabled, gMode, gSpeed, gLayerBoost, gTransBoost, gFloorDuration,
          gSpring, gExtra, gListAccel, gZoomAccel,
          gFastScroll, gFastTap, gInAppNotify,
          gInstantTransition, gHUDFast, gHUDDelay, gWKFastShow,
          gHasAppOverride, gListHardGuarded, gSelfHudProtected, gSelfFeelProtected);
    if (SIO_fbgBuiltinExcluded()) {
        NSLog(@"[SIOriginal] %@ is a built-in keep-alive exclusion: audio-assertion/scene-fake engine stays OFF", gSelfBundle);
    }
    if (gListHardGuarded) {
        NSLog(@"[SIOriginal] %@ is on the list-hook hard-guard list: ListAccel is forced OFF (safety)", gSelfBundle);
    }
    } @catch (NSException *e) {
        NSLog(@"[SIOriginal] hook install failed (feature degraded, app unaffected): %@", e);
    }
}

#pragma mark - UIViewPropertyAnimator（iOS 10+ 现代 App 主流动画 API）
//
// v1.8.12 覆盖补强：新增 2 参指定初始化器 initWithDuration:timingParameters:。
// App 常见写法是 `[[UIViewPropertyAnimator alloc] initWithDuration:tp]` 之后再
// addAnimations:，这条路径此前完全没被拦到（旧的三个 hook 都是带 animations: 的变体）。
// 同时 3 参变体内部大概率会回调到 2 参初始化器，所以用线程局部 gInPAInit 做重入保护，
// 避免同一次初始化被缩放两次（÷speed²）。

// duration setter — 拦截已创建 animator 的时长修改
static void sio_PA_setDuration(id self, SEL _cmd, double d) {
    SIO_HIT(SIO_HIT_PA);
    SIO_REQUIRE_ORIG(o_pa_setDuration);
    if (SIO_blocked()) { o_pa_setDuration(self, _cmd, d); return; }
    o_pa_setDuration(self, _cmd, SIO_targetDuration(d));
}

// v1.8.12：2 参指定初始化器（唯一在 App 代码里直接可见的 duration 入口）
static id sio_PA_initWithDurTP2(id self, SEL _cmd, double d, id tp) {
    SIO_HIT(SIO_HIT_PA);
    SIO_REQUIRE_ORIG_NIL(o_pa_initWithDurTP2);
    if (!SIO_blocked() && !SIO_inPAInit()) d = SIO_targetDuration(d);
    return o_pa_initWithDurTP2(self, _cmd, d, tp);
}

// initWithDuration:timingParameters:animations: — CA/CubicTimingParameters init
static id sio_PA_initWithDurTP(id self, SEL _cmd, double d, id tp, void (^a)(void)) {
    SIO_HIT(SIO_HIT_PA);
    SIO_REQUIRE_ORIG_NIL(o_pa_initWithDurTP);
    if (SIO_blocked() || SIO_inPAInit()) return o_pa_initWithDurTP(self, _cmd, d, tp, a);
    SIO_setPAInit(YES);
    id r = o_pa_initWithDurTP(self, _cmd, SIO_targetDuration(d), tp, a);
    SIO_setPAInit(NO);
    return r;
}

// initWithDuration:controlPoint1:controlPoint2:animations: — Bezier init
static id sio_PA_initWithDurCP(id self, SEL _cmd, double d, CGPoint p1, CGPoint p2, void (^a)(void)) {
    SIO_HIT(SIO_HIT_PA);
    SIO_REQUIRE_ORIG_NIL(o_pa_initWithDurCP);
    if (SIO_blocked() || SIO_inPAInit()) return o_pa_initWithDurCP(self, _cmd, d, p1, p2, a);
    SIO_setPAInit(YES);
    id r = o_pa_initWithDurCP(self, _cmd, SIO_targetDuration(d), p1, p2, a);
    SIO_setPAInit(NO);
    return r;
}

// initWithDuration:springDampingRatio:animations: — Spring init
static id sio_PA_initWithDurSpring(id self, SEL _cmd, double d, double dr, void (^a)(void)) {
    SIO_HIT(SIO_HIT_PA);
    SIO_REQUIRE_ORIG_NIL(o_pa_initWithDurSpring);
    if (SIO_blocked() || SIO_inPAInit()) return o_pa_initWithDurSpring(self, _cmd, d, dr, a);
    SIO_setPAInit(YES);
    id r = o_pa_initWithDurSpring(self, _cmd, SIO_targetDuration(d), dr, a);
    SIO_setPAInit(NO);
    return r;
}

// runningPropertyAnimatorWithDuration:delay:options:animations:completion: — 类方法
// v1.8.12：真 bug 修复。原来安装处写成 SIO_swizzleClass(object_getClass(pa), …)，
// class_getClassMethod 内部会再做一次 object_getClass，等于在根元类里找这个方法，
// 必然返回 NULL —— 该 hook 从未生效。安装处现已改为 SIO_swizzleClass(pa, …)。
// 同时补上 delay 的同比缩放（原来 delay 完全没动，与块动画行为不一致）。
static id sio_PA_runningPA(id self, SEL _cmd, double d, double delay, UIViewAnimationOptions opt, void (^a)(void), void (^c)(BOOL)) {
    SIO_HIT(SIO_HIT_PA);
    SIO_REQUIRE_ORIG_NIL(o_pa_runningPA);
    // 该便捷构造器内部同样会走 initWithDuration:timingParameters:，
    // 必须加同一把重入锁，否则时长被缩放两次。
    if (SIO_blocked() || SIO_inPAInit()) return o_pa_runningPA(self, _cmd, d, delay, opt, a, c);
    SIO_setPAInit(YES);
    id r = o_pa_runningPA(self, _cmd, SIO_targetDuration(d), SIO_targetDelay(delay), opt, a, c);
    SIO_setPAInit(NO);
    return r;
}

// v2.1.12（F-D）：- [UIViewPropertyAnimator startAnimationAfterDelay:]
// 「延迟多久才开始动画」的入口，与其他 delay 一样走 SIO_targetDelay 同比缩放
// （加速缩短 / 慢放放大），与 runningPropertyAnimator… 里的 delay 处理保持一致。
//
// 关于 gInPAInit 这把锁：审查建议「必须与 initWithDuration: 共用同一把锁，否则双重缩放」。
// 复核后认为不成立 —— 那把锁防的是**同一个 duration** 被 init 链缩放两次，
// 而这里改的是 **delay**，与 duration 是两个不同的量，不存在双重缩放。
// 但仍然保留 SIO_inPAInit() 检查，理由是防御性的：若 App 在 init 未返回时就调它，
// 说明当前已处在一条缩放链内部，此时放行（走原生值）是最安全的 fail-safe。
static void sio_PA_startAfterDelay(id self, SEL _cmd, NSTimeInterval delay) {
    SIO_HIT(SIO_HIT_PA);
    SIO_REQUIRE_ORIG(o_pa_startAfterDelay);
    if (SIO_blocked() || SIO_inPAInit()) { o_pa_startAfterDelay(self, _cmd, delay); return; }
    o_pa_startAfterDelay(self, _cmd, (NSTimeInterval)SIO_targetDelay(delay));
}

#pragma mark - UIScrollView 滚动动画

// 图片预览缩放保护（v1.8.3 修复微信发图预览放大后无法返回）：
// 微信图片预览浏览器基于 UIScrollView zooming 构建，双击/捏合缩放及回弹期间，
// UIKit 与浏览器自身会以 setContentOffset:animated:/scrollRectToVisible:animated:
// 驱动缩放复位与重新居中。此时：
//   · 瞬切模式把 animated:YES 改成 animated:NO 并 kCATransactionDisableActions，
//     会取消 UIKit 缩放动画事务——isZooming/isZoomBouncing 状态无法靠动画完成
//     回调收尾，浏览器的手势仲裁停在「缩放中」：返回按钮、单击工具栏、下拉/
//     侧滑退出全部失灵，卡在预览页回不到微信；
//   · 加速模式用外层 CATransaction 覆盖时长，同样可能打乱缩放事务内部时序。
// 因此只要该 scrollView 正处于缩放活动期（缩放动画中/回弹中/当前仍放大），
// 两个 hook 一律原样透传，不做任何时长/动画改写。普通滚动（非动画、未放大）
// 不受影响，滚动加速照常生效。
static BOOL SIO_svZoomEngaged(UIScrollView *sv) {
    if (![sv isKindOfClass:[UIScrollView class]]) return NO;
    @try {
        if (sv.isZooming || sv.isZoomBouncing) return YES;
        if (sv.maximumZoomScale > sv.minimumZoomScale + 0.001 &&
            sv.zoomScale > sv.minimumZoomScale + 0.001) {
            return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

static void sio_SV_setContentOffset(id self, SEL _cmd, CGPoint p, BOOL animated) {
    SIO_HIT(SIO_HIT_SV_SCROLL);
    SIO_REQUIRE_ORIG(o_sv_setContentOffset);
    if (SIO_blocked() || !animated || SIO_svZoomEngaged((UIScrollView *)self)) {
        o_sv_setContentOffset(self, _cmd, p, animated); return;
    }
    if (gEnabled && gMode == 2) {
        [CATransaction begin];
        @try {
            [CATransaction setValue:(id)kCFBooleanTrue forKey:kCATransactionDisableActions];
            o_sv_setContentOffset(self, _cmd, p, NO);
        } @finally { [CATransaction commit]; }
        return;
    }
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_targetDuration(0.35));
        o_sv_setContentOffset(self, _cmd, p, YES);
    } @finally { [CATransaction commit]; }
}

static void sio_SV_scrollRect(id self, SEL _cmd, CGRect r, BOOL animated) {
    SIO_HIT(SIO_HIT_SV_SCROLL);
    SIO_REQUIRE_ORIG(o_sv_scrollRect);
    if (SIO_blocked() || !animated || SIO_svZoomEngaged((UIScrollView *)self)) {
        o_sv_scrollRect(self, _cmd, r, animated); return;
    }
    if (gEnabled && gMode == 2) {
        [CATransaction begin];
        @try {
            [CATransaction setValue:(id)kCFBooleanTrue forKey:kCATransactionDisableActions];
            o_sv_scrollRect(self, _cmd, r, NO);
        } @finally { [CATransaction commit]; }
        return;
    }
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_targetDuration(0.35));
        o_sv_scrollRect(self, _cmd, r, YES);
    } @finally { [CATransaction commit]; }
}

#pragma mark - UIScrollView 缩放动画（v1.8.15 新增，默认关闭）

// 拆包证据：Knight.app 11.5.0 的 NXDesign.framework 引用了 setZoomScale:animated: 与
// zoomToRect:animated:，而此前这两个入口完全没有接管（滚动类里唯一的盲区）。
//
// 安全约束（吸取 v1.8.3/v1.8.4 微信预览故障的教训）：
//   · 只用 CATransaction 覆写时长，**绝不把 animated:YES 改写成 NO**，
//     也不加 kCATransactionDisableActions —— 那会取消 UIKit 的缩放事务，
//     使 isZooming/isZoomBouncing 无法靠动画完成回调收尾，页面卡死。
//   · 复用 SIO_svZoomEngaged：正在缩放 / 回弹中 / 当前已放大 → 一律原样透传。
//   · 由 ZoomAccel 开关控制，默认关；可在 App 专属覆盖里为单个 App 打开。
static void sio_SV_setZoomScale(id self, SEL _cmd, CGFloat s, BOOL animated) {
    SIO_HIT(SIO_HIT_SV_ZOOM);
    SIO_REQUIRE_ORIG(o_sv_setZoomScale);
    if (SIO_blocked() || !gZoomAccel || !animated || SIO_svZoomEngaged((UIScrollView *)self)) {
        o_sv_setZoomScale(self, _cmd, s, animated); return;
    }
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_targetDuration(0.25));
        o_sv_setZoomScale(self, _cmd, s, animated);
    } @finally { [CATransaction commit]; }
}

static void sio_SV_zoomToRect(id self, SEL _cmd, CGRect r, BOOL animated) {
    SIO_HIT(SIO_HIT_SV_ZOOM);
    SIO_REQUIRE_ORIG(o_sv_zoomToRect);
    if (SIO_blocked() || !gZoomAccel || !animated || SIO_svZoomEngaged((UIScrollView *)self)) {
        o_sv_zoomToRect(self, _cmd, r, animated); return;
    }
    [CATransaction begin];
    @try {
        SIO_setTransactionDuration(SIO_targetDuration(0.25));
        o_sv_zoomToRect(self, _cmd, r, animated);
    } @finally { [CATransaction commit]; }
}

#pragma mark - 交互手感：滑行惯性 / 点击延迟（v1.8.16 新增，默认关闭）

// 这一组不改动画时长，改的是"跟手程度"，属于体感加速：
//   FastScroll —— decelerationRate = UIScrollViewDecelerationRateFast
//                 松手后滑行距离大幅缩短，浏览长列表明显更快到达目标位置
//   FastTap    —— delaysContentTouches = NO
//                 去掉 UIScrollView 判定"这是滚动还是点击"的约 150ms 等待，点按立刻响应
// 副作用（需实测）：FastTap 打开后，滚动中手指轻微移动可能被判定为点击；
// FastScroll 会让依赖滑行距离触发"触底加载"的列表更早触发分页。
//
// 施加时机选 -[UIScrollView didMoveToWindow]：nib / storyboard / 纯代码创建的
// 滚动视图都会经过这里，一次覆盖全部来源；且此时视图已完成基本配置，
// 不会被初始化流程覆盖掉。
static void sio_SV_didMoveToWindow(id self, SEL _cmd) {
    SIO_HIT(SIO_HIT_FEEL);
    SIO_REQUIRE_ORIG(o_sv_didMoveToWindow);
    o_sv_didMoveToWindow(self, _cmd);
    if (!gFastScroll && !gFastTap) return;
    if (SIO_blocked()) return;
    // v2.1.7 fix：对依赖长按/原生手势的 App（微信等）整个手感模块跳过。
    if (gSelfFeelProtected) return;
    @try {
        UIScrollView *sv = (UIScrollView *)self;
        if (gFastScroll && sv.decelerationRate != UIScrollViewDecelerationRateFast) {
            sv.decelerationRate = UIScrollViewDecelerationRateFast;
        }
        if (gFastTap && sv.delaysContentTouches) {
            sv.delaysContentTouches = NO;
        }
    } @catch (__unused NSException *e) {}
}

// v2.0.0：手感 setter 强黏。didMoveToWindow 只在进窗口时施加一次，App 之后
// （例如某个列表页 viewDidAppear）再把 decelerationRate / delaysContentTouches
// 改回去，旧版就"时灵时不灵"。setter 层钳回，开关真正全程生效。
static void sio_SV_setDecelRate(id self, SEL _cmd, CGFloat rate) {
    SIO_HIT(SIO_HIT_FEEL);
    SIO_REQUIRE_ORIG(o_sv_setDecelRate);
    if (!SIO_blocked() && gFastScroll && !gSelfFeelProtected) rate = UIScrollViewDecelerationRateFast;
    o_sv_setDecelRate(self, _cmd, rate);
}

static void sio_SV_setDelaysTouches(id self, SEL _cmd, BOOL b) {
    SIO_HIT(SIO_HIT_FEEL);
    SIO_REQUIRE_ORIG(o_sv_setDelaysTouches);
    if (!SIO_blocked() && gFastTap && !gSelfFeelProtected) b = NO;
    o_sv_setDelaysTouches(self, _cmd, b);
}

static void sio_layer_addAnim(id self, SEL _cmd, id anim, NSString *key) {
    SIO_HIT(SIO_HIT_LAYER_ADD);
    SIO_REQUIRE_ORIG(o_layer_addAnim);
    // CAAnimation setDuration 基类 hook 已覆盖绝大多数情况，这里只兜底
    // 「App 从未调用 setDuration:、动画保持类默认时长」的动画（如 0.25s 默认值）。
    //
    // v1.8.12 修掉了本函数经 objc_msgSend 回调自己的 hook（自递归式双重除法）。
    // v1.8.15 再修掉残留的**逻辑**双重缩放：若该动画的时长已经过
    // sio_CAAnim_setDuration 处理（带标记），这里必须跳过，否则同一个值被缩两次。
    if (!SIO_blocked() && anim && o_CAAnim_setDuration &&
        [anim isKindOfClass:[CAAnimation class]] && !SIO_animScaled(anim)) {
        @try {
            double origDur = ((CAAnimation *)anim).duration;
            if (origDur > 0) {
                SIO_markAnimScaled(anim);
                double newDur;
                if ([anim isKindOfClass:[CAKeyframeAnimation class]]) {
                    // v2.1.8 opt：CAKeyframeAnimation 用 0.05s 下限
                    switch (gMode) {
                        case 1:  newDur = origDur * gSlowFactor; break;
                        case 2:  newDur = 0.08;                   break;
                        default: newDur = (gSpeed > 1.0001) ? (origDur * gInvSpeed) : origDur;
                    }
                    if (newDur < 0.05) newDur = 0.05;
                } else {
                    // v1.8.17：与 setDuration: 路径共用同一套换算（含 LayerBoost）
                    newDur = SIO_targetDurationLayer(origDur);
                }
                if (newDur != origDur) {
                    o_CAAnim_setDuration(anim, @selector(setDuration:), newDur);
                }
            }
        } @catch (__unused NSException *e) {}
    }
    o_layer_addAnim(self, _cmd, anim, key);
}

#pragma mark - SIO_install 新 hook 注册（iOS 16 优化增强）

static void SIO_installiOS16Extras(void) {
    Class pa = objc_getClass("UIViewPropertyAnimator");
    Class sv = objc_getClass("UIScrollView");
    Class layer = objc_getClass("CALayer");

    if (pa) {
        SIO_swizzleInstance(pa, @selector(setDuration:),
                            (IMP)sio_PA_setDuration, (IMP *)&o_pa_setDuration);
        // v1.8.12 新增：2 参指定初始化器（App 直接使用的时长入口）
        SIO_swizzleInstance(pa, @selector(initWithDuration:timingParameters:),
                            (IMP)sio_PA_initWithDurTP2, (IMP *)&o_pa_initWithDurTP2);
        SIO_swizzleInstance(pa, @selector(initWithDuration:timingParameters:animations:),
                            (IMP)sio_PA_initWithDurTP, (IMP *)&o_pa_initWithDurTP);
        SIO_swizzleInstance(pa, @selector(initWithDuration:controlPoint1:controlPoint2:animations:),
                            (IMP)sio_PA_initWithDurCP, (IMP *)&o_pa_initWithDurCP);
        SIO_swizzleInstance(pa, @selector(initWithDuration:springDampingRatio:animations:),
                            (IMP)sio_PA_initWithDurSpring, (IMP *)&o_pa_initWithDurSpring);
        // v1.8.12 真 bug 修复：必须传类对象 pa，不能传 object_getClass(pa)（元类）。
        // class_getClassMethod 内部会执行 class_getInstanceMethod(object_getClass(cls), sel)，
        // 传元类等于去根元类查找，必然 NULL —— 原来这一行是静默失效的死代码。
        SIO_swizzleClass(pa, @selector(runningPropertyAnimatorWithDuration:delay:options:animations:completion:),
                         (IMP)sio_PA_runningPA, (IMP *)&o_pa_runningPA);
        // v2.1.12（F-D）：startAnimationAfterDelay: 覆盖面兜底
        SIO_swizzleInstance(pa, @selector(startAnimationAfterDelay:),
                            (IMP)sio_PA_startAfterDelay, (IMP *)&o_pa_startAfterDelay);
    }

    if (sv) {
        SIO_swizzleInstance(sv, @selector(setContentOffset:animated:),
                            (IMP)sio_SV_setContentOffset, (IMP *)&o_sv_setContentOffset);
        SIO_swizzleInstance(sv, @selector(scrollRectToVisible:animated:),
                            (IMP)sio_SV_scrollRect, (IMP *)&o_sv_scrollRect);
        // v1.8.15 新增：缩放动画（默认关闭，ZoomAccel 控制）
        SIO_swizzleInstance(sv, @selector(setZoomScale:animated:),
                            (IMP)sio_SV_setZoomScale, (IMP *)&o_sv_setZoomScale);
        SIO_swizzleInstance(sv, @selector(zoomToRect:animated:),
                            (IMP)sio_SV_zoomToRect, (IMP *)&o_sv_zoomToRect);
        // v1.8.16 新增：交互手感（滑行惯性 / 点击延迟）
        // v2.1.7：改为「按启动时开关状态安装」—— 不开就完全不挂钩子，
        // 与 v1.8.17（已验证稳定）的引擎形态保持一致。代价：运行中把开关从关
        // 改开需要重启目标 App 才会装上（热重载装不了新 hook）。
        if (gFastScroll || gFastTap) {
            SIO_swizzleInstance(sv, @selector(didMoveToWindow),
                                (IMP)sio_SV_didMoveToWindow, (IMP *)&o_sv_didMoveToWindow);
            // setter 层强黏，App 后续改值也钳回
            SIO_swizzleInstance(sv, @selector(setDecelerationRate:),
                                (IMP)sio_SV_setDecelRate, (IMP *)&o_sv_setDecelRate);
            SIO_swizzleInstance(sv, @selector(setDelaysContentTouches:),
                                (IMP)sio_SV_setDelaysTouches, (IMP *)&o_sv_setDelaysTouches);
        }
    }

    // v2.0.0：长按手势加速 —— v2.1.7 整体移除。
    // 崩溃证据（两份独立的 .ips，两个不同 App，同一崩溃帧）：
    //   objc_retain ← sio_LPG_init+60
    //     WeChat:  ← -[UITabBarController _accessibilityHUDLongPressRecognizer]
    //     Knight:  ← -[UIScrollViewKnobLongPressGestureRecognizer initWithTarget:action:]
    // 原因：initWithTarget:action: 是 init 族方法，ARC 对它的返回值有特殊所有权约定；
    // 用 method_setImplementation 挂钩后经普通函数指针回调原实现，编译器会在
    // sio_LPG_init 里对返回值插入 objc_retain，而拿到的指针是坏的 → SIGSEGV。
    // 关键教训：这个 hook 在 v2.0.x 一直被无条件安装，开关关不关都会崩，
    // 所以 v2.0.5/v2.0.6「调默认值修闪退」从来没真正修好过。
    // 结论：hook init 族方法这条路走不通，整个功能移除，不留假开关。

    if (layer) {
        SIO_swizzleInstance(layer, @selector(addAnimation:forKey:),
                            (IMP)sio_layer_addAnim, (IMP *)&o_layer_addAnim);
    }
}

#pragma mark - FUBackground v2.1.0 整合（真后台保活）

// ---- 全局状态 ----
static BOOL    gFUBGEnabled    = YES;
static BOOL    gSceneFake  = YES;
static BOOL    gAudioKeep  = YES;
static NSArray *gExclude   = nil;

static BOOL    gActive    = NO;   // 本 App 最终是否参与保活（总开关 ∧ 排除名单）
static BOOL    gUseScene  = NO;   // 本 App 是否启用场景伪装
static BOOL    gUseAudio  = NO;   // 本 App 是否启用音频断言
// gPhysBg 的定义已前移到文件前段（热重载日志要打印它）；注释见那里。

// v2.1.12（审查 N-1）：保活侧出厂复位。
// 动画侧 v2.1.11 已加 SIO_resetDefaults()，但保活侧这四个量不在它的覆盖范围里
// （它们声明在本段，SIO_resetDefaults 定义在动画段，引用不到）。
// 后果是「删掉 plist 恢复出厂默认」这条排障契约只在动画侧成立：动画参数回到默认，
// 保活却沿用上一次的值（例如之前关掉的 FUBGAudioKeep 依然是关的），两侧不一致，
// 反而更难判断。这里补上对称的复位，四个值必须与上面的静态初始化值一致。
static void _fbg_resetDefaults(void) {
    gFUBGEnabled = YES;
    gSceneFake   = YES;
    gAudioKeep   = YES;
    gExclude     = @[];
}
static BOOL    gHasAudioMode = NO;

static AVAudioPlayer *gPlayer = nil;
static UIBackgroundTaskIdentifier gTask = 0;   // 0 = 无桥接任务（UIBackgroundTaskInvalid 非文件级编译期常量）
static NSTimer *gWatchdog = nil;
// v2.1.10：强引用 NSNotificationCenter 的 block 观察者 token。
// addObserverForName:queue:usingBlock: 返回的 token 一旦被释放，观察随即注销 ——
// 原来两个 AVAudioSession 观察者的返回值都被丢弃了，回调永远等不到。
static NSMutableArray *_fbg_obs = nil;

#pragma mark - 配置

static BOOL _fbg_isExcluded(void) {
    // v1.8.16：内置排除（SpringBoard 等）优先级最高，配置无法打开
    if (SIO_fbgBuiltinExcluded()) return YES;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    for (NSString *b in gExclude) {
        if ([b isKindOfClass:[NSString class]] && b.length && [bid hasPrefix:b]) return YES;
    }
    return NO;
}

static void _fbg_recalc(void) {
    gActive   = gFUBGEnabled && !_fbg_isExcluded();
    gUseScene = gActive && gSceneFake;
    gUseAudio = gActive && gAudioKeep;
}

static void _fbg_loadPref(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
        if (!d) {
            // v2.1.12（N-1）：与动画侧 SIO_resetDefaults() 对称。
            // 原来这里只有 if (d)，缺文件时四个量沿用旧值且无日志。
            _fbg_resetDefaults();
            NSLog(@"[FUBG] prefs file missing/unreadable — reset to factory defaults");
        } else {
            if (d[@"FUBGEnabled"])      gFUBGEnabled   = [d[@"FUBGEnabled"] boolValue];
            if (d[@"FUBGSceneFake"])    gSceneFake = [d[@"FUBGSceneFake"] boolValue];
            if (d[@"FUBGAudioKeep"])    gAudioKeep = [d[@"FUBGAudioKeep"] boolValue];
            // v2.1.0：排除表统一由 Blacklist 提供。
            // 原 FUBGExcludeApps 键没有任何配置界面可写，配置 App 每次保存都把它写成空数组，
            // 等价于永久空表（死配置）；同时旧实现里「先赋 FUBGExcludeApps、
            // 紧接着被 Blacklist 无条件覆盖」的顺序 bug 也一并消失。
            NSMutableArray *ex = [NSMutableArray array];
            // 复用 SIOriginal 黑名单（v1.8.6：兼容字符串格式，原来只认 NSArray 导致黑名单对 FUBG 永远无效）
            id bl = d[@"Blacklist"];
            if ([bl isKindOfClass:[NSArray class]]) {
                [ex addObjectsFromArray:bl];
            } else if ([bl isKindOfClass:[NSString class]] && [(NSString *)bl length]) {
                [ex addObjectsFromArray:[(NSString *)bl componentsSeparatedByString:@","]];
            }
            // 清洗：只保留非空字符串。_fbg_isExcluded 会对元素调 hasPrefix:，
            // plist 里一旦混入 NSNumber/NSNull（手工编辑）就会 unrecognized selector 崩溃。
            NSMutableArray *clean = [NSMutableArray array];
            for (id it in ex) {
                if (![it isKindOfClass:[NSString class]]) continue;
                NSString *s = [(NSString *)it stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
                if (s.length) [clean addObject:s];
            }
            gExclude = clean;
            // v1.8.14：保活相关的 App 级覆盖（与动画侧共用同一份 AppOverrides）
            NSDictionary *ovr = SIO_appOverride(d);
            if (ovr) {
                if (ovr[@"FUBGEnabled"])   gFUBGEnabled = [ovr[@"FUBGEnabled"] boolValue];
                if (ovr[@"FUBGSceneFake"]) gSceneFake   = [ovr[@"FUBGSceneFake"] boolValue];
                if (ovr[@"FUBGAudioKeep"]) gAudioKeep   = [ovr[@"FUBGAudioKeep"] boolValue];
            }
        }
    } @catch (__unused NSException *e) {}
    if (!gExclude) gExclude = @[];

    NSArray *modes = [[NSBundle mainBundle] infoDictionary][@"UIBackgroundModes"];
    gHasAudioMode = [modes isKindOfClass:[NSArray class]] && [modes containsObject:@"audio"];

    _fbg_recalc();
}

#pragma mark - 引擎一：场景伪装
// 移植/修改自 ImmortalizerJailed main.m（GPLv3, Serge Alagon），致谢 @khanhduytran0

static void (*gOrigSceneUpdate)(id, SEL, id, id, id, id);

// 由后台化 diff 的描述特征判断这是否是一条"让 App 退到后台"的场景更新
static BOOL _fbg_isBackgroundingDiff(NSString *desc) {
    if (!desc) return NO;
    if ([desc containsString:@"foreground = NotSet"] ||
        [desc containsString:@"foreground = No"] ||
        [desc containsString:@"foreground = BSSettingFlagNo"] ||
        [desc containsString:@"foreground = NO"]) {
        return YES;
    }
    // 后台切换器快照相关更新同样吞掉，避免快照暴露/状态推进
    if ([desc containsString:@"hostContextIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"targetOfEventDeferringEnvironments = (empty)"] ||
        [desc containsString:@"FBSceneSnapshotAction:"]) {
        return YES;
    }
    return NO;
}

static void _fbg_sceneUpdate(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    if (gUseScene) {
        @try {
            if (_fbg_isBackgroundingDiff([arg2 description])) {
                NSLog(@"[FUBG] swallowed backgrounding scene diff");
                return;
            }
        } @catch (__unused NSException *e) {}
    }
    gOrigSceneUpdate(self, _cmd, arg1, arg2, arg3, arg4);
}

// ---- applicationState 伪装 ----
static UIApplicationState (*gOrigAppState)(id, SEL);

static UIApplicationState _fbg_appState(id self, SEL _cmd) {
    if (gUseScene && gPhysBg) {
        // 推送/通知框架需要真实答案：前台态时它们不会建立后台接收通道
        void *ret = __builtin_extract_return_addr(__builtin_return_address(0));
        Dl_info info;
        if (dladdr(ret, &info) && info.dli_fname) {
            // v2.1.11：原来每次都 stringWithUTF8String: 分配一个 NSString
            // 再做两次 containsString: 子串搜索。applicationState 是极高频属性
            // （网络请求/埋点/图片加载/生命周期判断都会读它），后台伪装期间每次
            // 读取都要堆分配 + 两次子串搜索。直接在 C 字符串上判断，零分配。
            if (strstr(info.dli_fname, "UserNotifications") ||
                strstr(info.dli_fname, "PushKit")) {
                return UIApplicationStateBackground;
            }
        }
        return UIApplicationStateActive;
    }
    return gOrigAppState ? gOrigAppState(self, _cmd) : UIApplicationStateActive;
}

// ---- 通知横幅伪装 ----
// v2.1.11：orig 指针原来是**全局单例** gOrigWillPresent。
// 若 App 先后设置两个不同类的 delegate，第二个会把第一个记录的 IMP 覆盖掉，
// 此后第一个 delegate 收到通知时会被转发到**第二个类的原实现**，self 却是第一个类的
// 实例 —— 参数类型不匹配，轻则行为错乱重则崩溃。现在改为按类存储。
typedef void (*SIO_WillPresentIMP)(id, SEL, UNUserNotificationCenter *, UNNotification *,
                                   void (^)(UNNotificationPresentationOptions));

static NSMapTable *gOrigWillPresentMap = nil;   // Class -> NSValue(IMP)

static void SIO_setOrigWillPresent(Class c, IMP imp) {
    if (!c || !imp) return;
    if (!gOrigWillPresentMap)
        gOrigWillPresentMap = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory
                                                   valueOptions:NSMapTableStrongMemory];
    [gOrigWillPresentMap setObject:[NSValue valueWithPointer:(void *)imp] forKey:(id)c];
}

// 沿 superclass 链向上找：B 继承 A 且未重写该方法时，我们 hook 的是 A 的实现，
// 而 self 是 B 的实例，[self class] 取不到 A 存的 orig，必须向上回溯。
static SIO_WillPresentIMP SIO_origWillPresentFor(Class c) {
    if (!gOrigWillPresentMap) return NULL;
    for (Class k = c; k; k = class_getSuperclass(k)) {
        NSValue *v = [gOrigWillPresentMap objectForKey:(id)k];
        if (v) return (SIO_WillPresentIMP)[v pointerValue];
    }
    return NULL;
}

static void _fbg_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center,
                             UNNotification *note,
                             void (^handler)(UNNotificationPresentationOptions)) {
    SIO_HIT(SIO_HIT_NOTIFY);
    if (gUseScene && gPhysBg) {
        handler(UNNotificationPresentationOptionBanner |
                UNNotificationPresentationOptionSound |
                UNNotificationPresentationOptionBadge);
        return;
    }
    SIO_WillPresentIMP orig = SIO_origWillPresentFor([self class]);
    if (orig) {
        orig(self, _cmd, center, note, handler);
    } else {
        // v2.1.12（审查 N-4）：UNUserNotificationCenterDelegate 的契约要求
        // completionHandler 必须**恰好调用一次**；不调用会让该条通知的呈现被挂起。
        // 取不到 orig 在实践中很难触发（hook 时 dc 与回调时 [self class] 通常是同一个类，
        // 继承场景由 SIO_origWillPresentFor 沿 superclass 链兜底），但契约上这是缺口，
        // 而补 else 是零成本的。按项目 fail-safe 哲学：绝不吞掉 handler。
        handler(UNNotificationPresentationOptionBanner |
                UNNotificationPresentationOptionSound |
                UNNotificationPresentationOptionBadge);
    }
}

static void (*gOrigUNSetDelegate)(id, SEL, id);

static void _fbg_unSetDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    if (gOrigUNSetDelegate) gOrigUNSetDelegate(self, _cmd, delegate);
    if (delegate) {
        Class dc = [delegate class];
        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method m = class_getInstanceMethod(dc, sel);
        if (m) {
            IMP cur = method_getImplementation(m);
            if (cur != (IMP)_fbg_willPresent) {
                // v2.1.11：class_getInstanceMethod 可能返回**父类**的 Method。
                // 直接用 method_setImplementation 会改到父类实现，影响面超出预期。
                // 先尝试 class_addMethod：成功 = 本类无实现（新增子类覆写，orig 即父类 IMP）；
                // 失败 = 本类已有实现，正常替换。两种情况 orig 都记为 cur。
                if (!class_addMethod(dc, sel, (IMP)_fbg_willPresent, method_getTypeEncoding(m))) {
                    method_setImplementation(m, (IMP)_fbg_willPresent);
                }
                SIO_setOrigWillPresent(dc, cur);
            }
        }
    }
}

static void _fbg_installSceneHooks(void) {
    Class wsClass = objc_getClass("FBSWorkspaceScenesClient");
    Method sceneM = wsClass ? class_getInstanceMethod(
        wsClass, @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:)) : NULL;
    if (sceneM) {
        IMP cur = method_getImplementation(sceneM);
        if (cur != (IMP)_fbg_sceneUpdate) {
            gOrigSceneUpdate = (void (*)(id, SEL, id, id, id, id))cur;
            method_setImplementation(sceneM, (IMP)_fbg_sceneUpdate);
            NSLog(@"[FUBG] scene hook installed");
        } else {
            NSLog(@"[FUBG] scene hook already installed (skip duplicate)");
        }
    } else {
        NSLog(@"[FUBG] FBSWorkspaceScenesClient method not found, scene engine disabled");
    }

    Method stateM = class_getInstanceMethod([UIApplication class], @selector(applicationState));
    if (stateM) {
        IMP cur = method_getImplementation(stateM);
        if (cur != (IMP)_fbg_appState) {
            gOrigAppState = (UIApplicationState (*)(id, SEL))cur;
            method_setImplementation(stateM, (IMP)_fbg_appState);
        }
    }

    Class unClass = [UNUserNotificationCenter class];
    Method delM = class_getInstanceMethod(unClass, @selector(setDelegate:));
    if (delM) {
        IMP cur = method_getImplementation(delM);
        if (cur != (IMP)_fbg_unSetDelegate) {
            gOrigUNSetDelegate = (void (*)(id, SEL, id))cur;
            method_setImplementation(delM, (IMP)_fbg_unSetDelegate);
        }
    }
}

#pragma mark - 引擎二：音频断言

static BOOL _fbg_activateSession(void) {
    NSError *e = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (![s setCategory:AVAudioSessionCategoryPlayback
            withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&e] || e) {
        NSLog(@"[FUBG] setCategory failed: %@", e); return NO;
    }
    e = nil;
    if (![s setActive:YES error:&e] || e) {
        NSLog(@"[FUBG] setActive failed: %@", e); return NO;
    }
    return YES;
}

static void _fbg_buildAndPlay(void) {
    @try {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:kFBGNoiseB64
                                                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
        AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithData:data error:nil];
        if (!p) return;
        p.numberOfLoops = -1;
        p.volume = 0.0f;
        [p prepareToPlay];
        [p play];
        gPlayer = p;
    } @catch (__unused NSException *e) {}
}

static void _fbg_startAudio(void) {
    if (!gUseAudio) return;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask == 0) {
            gTask = [app beginBackgroundTaskWithName:@"fubg-bridge" expirationHandler:^{
                NSLog(@"[FUBG] bridge task expired");
                if (gTask != 0) { [app endBackgroundTask:gTask]; gTask = 0; }
            }];
        }
        if (_fbg_activateSession() && (!gPlayer || !gPlayer.isPlaying)) {
            if (gPlayer) { [gPlayer play]; }
            else { _fbg_buildAndPlay(); }
        }
        NSLog(@"[FUBG] audio keep-alive started (audioMode=%d)", gHasAudioMode);
    } @catch (__unused NSException *e) {}
}

static void _fbg_stopAudio(BOOL releaseSession) {
    @try {
        if (gPlayer.isPlaying) [gPlayer pause];
        // 经验（Immortalizer 作者）：mix 模式下保持 session 激活、不主动 setActive:NO，
        // 可避免与目标 App 自身音频会话打架造成的卡顿；仅彻底关闭时通知他人恢复。
        if (releaseSession) {
            [[AVAudioSession sharedInstance] setActive:NO
                                          withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                                error:nil];
        }
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask != 0) { [app endBackgroundTask:gTask]; gTask = 0; }
    } @catch (__unused NSException *e) {}
}

// v2.1.11：看门狗改为**按需装卸**。原来在 constructor 里无条件安装，三个问题叠加：
//   1. 挂在 NSRunLoopCommonModes（含 UITrackingRunLoopMode）→ 用户滚动列表时
//      主线程每 1.5s 被唤醒一次，回调里第一行就 return，纯属空转，影响流畅度与耗电；
//   2. 前台也常驻 —— 整个前台使用期间都在跑；
//   3. 从不 invalidate —— 用户在配置 App 关掉「音频保活」后定时器依旧空转到进程退出。
// 现在只在真正进入后台时安装（后台无滚动，NSDefaultRunLoopMode 足够），
// 回前台即卸载；prefs 里关掉音频保活时同样卸载。周期 1.5s → 3.0s
// （自愈场景本身有 0.3s 的中断恢复通道，不需要这么密的轮询）。
static void _fbg_watchdogStop(void) {
    if (gWatchdog) { [gWatchdog invalidate]; gWatchdog = nil; }
}

static void _fbg_watchdogFire(NSTimer *t);   // 前向声明：下面 Start 的 block 里要引用

static void _fbg_watchdogStart(void) {
    if (gWatchdog || !gUseAudio || !gPhysBg) return;
    gWatchdog = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES
                                                  block:^(NSTimer *t){ _fbg_watchdogFire(t); }];
}

// 自愈轮询：仅在停摆时重建，兼顾可靠与耗电
static void _fbg_watchdogFire(__unused NSTimer *t) {
    if (!gUseAudio || !gPhysBg) return;
    @try {
        if (!gPlayer || !gPlayer.isPlaying) {
            NSLog(@"[FUBG] watchdog: player stopped, rebuilding");
            _fbg_activateSession();
            if (gPlayer) { [gPlayer play]; }
            else { _fbg_buildAndPlay(); }
        }
    } @catch (__unused NSException *e) {}
}

static void _fbg_onInterruption(NSNotification *note) {
    if (!gUseAudio) return;
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue != AVAudioSessionInterruptionTypeEnded) return;
    NSNumber *opt = note.userInfo[AVAudioSessionInterruptionOptionKey];
    if (opt.unsignedIntegerValue & AVAudioSessionInterruptionOptionShouldResume) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gUseAudio && gPhysBg) {
                _fbg_activateSession();
                if (gPlayer) { [gPlayer play]; } else { _fbg_buildAndPlay(); }
            }
        });
    }
}

#pragma mark - 生命周期 / Darwin
//
// v2.1.10 真 bug 修复（本轮最要紧的一处）：
// 原来前后台感知是把 UIApplicationDidEnterBackgroundNotification /
// UIApplicationWillEnterForegroundNotification 注册到 **Darwin 通知中心**上。
// Darwin 中心是系统级广播总线，只接收 notify_post() 发出的名字；而这两个通知是
// App 进程内 NSNotificationCenter 发出的，永远不会出现在 Darwin 总线上 ——
// 于是两个回调从未被触发，gPhysBg 恒为 NO，直接导致五个子系统静默失效：
//   音频断言 / 看门狗自愈 / 通知横幅伪装 / 来电中断恢复 / 线路变化恢复。
// 场景伪装不受影响（它直接 hook 场景更新，不依赖 gPhysBg），所以保活「看起来能用」，
// 这个洞一直没被发现。现在改回进程内 NSNotificationCenter 注册。

static void _fbg_onEnterBackground(NSNotification *note) {
    gPhysBg = YES;
    _fbg_startAudio();
    _fbg_watchdogStart();   // v2.1.11：只在真后台时装看门狗，前台不再空转
}

static void _fbg_onEnterForeground(NSNotification *note) {
    gPhysBg = NO;
    _fbg_watchdogStop();    // v2.1.11：回前台立即卸载
    // 回前台只暂停播放、保留会话（mix 模式下不与 App 音频冲突）
    if (gPlayer.isPlaying) [gPlayer pause];
    if (gTask != 0) {
        [[UIApplication sharedApplication] endBackgroundTask:gTask];
        gTask = 0;
    }
}

static void _fbg_onPrefReload(CFNotificationCenterRef c, void *o, CFStringRef n,
                              const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    // v2.1.10：与动画侧同样改为主线程串行 reload。_fbg_loadPref 会把 gExclude
    // 换成新数组，若此刻另线程正在 for-in 遍历旧数组，数组被释放即 EXC_BAD_ACCESS。
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            _fbg_loadPref();
            NSLog(@"[FUBG] prefs reloaded: active=%d scene=%d audio=%d override=%d physBg=%d",
                  gActive, gUseScene, gUseAudio, gHasAppOverride, gPhysBg);
            if (!gUseAudio && gPhysBg) { _fbg_stopAudio(NO); _fbg_watchdogStop(); }
            if (gUseAudio && gPhysBg && (!gPlayer || !gPlayer.isPlaying)) { _fbg_startAudio(); _fbg_watchdogStart(); }
        } @catch (__unused NSException *e) {}
    });
}

#pragma mark - 入口

__attribute__((constructor))
static void FUBGEntry(void) {
    @autoreleasepool {
    // v1.8.12：与动画侧同样全程 @try 包裹，保活引擎装不上也不能拖垮目标 App。
    @try {
        // v2.1.0：全 App 通用保活（场景伪装 + 音频断言），两者都只在后台活跃，
        // 不影响前台 UI、不拦截触摸。
        _fbg_loadPref();

        // hook 一次性安装，内部按全局开关决定行为
        dispatch_async(dispatch_get_main_queue(), ^{
            _fbg_installSceneHooks();
        });

        _fbg_obs = [NSMutableArray array];

        // v2.1.10：生命周期改回进程内 NSNotificationCenter（Darwin 总线收不到，
        // 详见本文件「生命周期 / Darwin」处的说明）。token 必须被持有，否则立即注销。
        id obBg = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(__unused NSNotification *n){ _fbg_onEnterBackground(n); }];
        id obFg = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(__unused NSNotification *n){ _fbg_onEnterForeground(n); }];
        if (obBg) [_fbg_obs addObject:obBg];
        if (obFg) [_fbg_obs addObject:obFg];

        // 配置热重载是跨进程的（配置 App 用 Darwin 广播），这一条继续走 Darwin 中心。
        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, _fbg_onPrefReload,
            (__bridge CFStringRef)kNotifyName, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // 注：kNotifyStats（命中统计浮层请求）只在 SIOriginalInit 里注册一次。
        // 本文件有两个 constructor（SIOriginalInit / FUBGEntry），两处都注册的话
        // 回调会触发两次、浮层重复创建。

        // v2.1.10：AVAudioSession 两个观察者的 token 原来被丢弃，回调永远等不到。
        id obInt = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionInterruptionNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n){ _fbg_onInterruption(n); }];
        id obRoute = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(__unused NSNotification *n){
                if (gUseAudio && gPhysBg) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (gPlayer && !gPlayer.isPlaying) [gPlayer play];
                    });
                }
            }];
        if (obInt)   [_fbg_obs addObject:obInt];
        if (obRoute) [_fbg_obs addObject:obRoute];

        // v2.1.11：看门狗不再在这里无条件安装，改为进入后台时才装（见 _fbg_watchdogStart）。

        NSLog(@"[FUBG] v2.1.16 (SIOriginal v2.1.16) loaded in %@: active=%d scene=%d audio=%d audioMode=%d%@",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
              gActive, gUseScene, gUseAudio, gHasAudioMode,
              (gHasAudioMode || gUseScene) ? @"" : @" (WARNING: no audio mode & no scene engine)");
    } @catch (NSException *e) {
        NSLog(@"[FUBG] keep-alive install failed (app unaffected): %@", e);
    }
    }
}



// ============================================================================
// 拆包证据（v1.8.15，Knight.app 11.5.0 / com.sfic.knight / arm64 已解密）
// ----------------------------------------------------------------------------
// 来源：IPA 内 Payload/Knight.app/Knight（180MB，cryptid=0），
//       解析 Mach-O 的 __TEXT,__objc_classname / __objc_methname 得到
//       10,947 个 ObjC 类名、148,813 个方法名、114,402 条 C 字符串。
//
// [1] UI 技术栈：原生 UIKit + 大量 .nib（数百个 *AlertView/*Cell/*View nib），
//     非 Flutter；RN 只占少量模块（hermes.framework + RNInnerBundleResource.plist）。
//     → 现有 UIView / CAAnimation / CATransaction 系 hook 在本 App 上确实生效。
//
// [2] App 在用、且我们已覆盖的动画入口（__objc_methname 命中）：
//     beginAnimations:context: / commitAnimations / setAnimationDuration: /
//     setAnimationDelay:（老式 API —— v1.8.13 才补上，对本品是净增覆盖）
//     animateKeyframesWithDuration:delay:options:animations:completion:（v1.8.12 补）
//     transitionFromViewController:toViewController:duration:options:animations:completion:（v1.8.12 补）
//     animateWithDuration: 全系 / transitionWithView:duration: /
//     setDuration: / addAnimation:forKey: / setMass: / setStiffness: / setDamping:
//     setContentOffset:animated: / scrollRectToVisible:animated: / setSelectedIndex:
//     presentViewController:animated:completion: / dismissViewControllerAnimated:completion:
//
// [3] App 在用、v1.8.15 才覆盖：setZoomScale:animated:、zoomToRect:animated:
//     （由 NXDesign.framework 引用）
//
// [4] App 未使用 → 我们这些 hook 在本品上是惰性的（无害，不必再投入）：
//     UIViewPropertyAnimator 的 addAnimations: / startAnimationAfterDelay: /
//     runningPropertyAnimatorWithDuration:、setCollectionViewLayout:animated:、
//     performSystemAnimation:onViews:、transitionFromView:toView:、
//     setCamera:animated:、setPreferredFrameRateRange:、setMaximumFramesPerSecond:
//
// [5] 地图：高德 AMap 静态链入（MAMapView / MAMapKeyFrameAnimation /
//     MAAnnotationMoveAnimation / MAAnimatedAnnotation），
//     相机动画属性类型为 CAKeyframeAnimation（如 _mapCenterAnimation /
//     _cameraDegreeAnimation / _zoomAnimation）。
//     → 地图相机动画走 CAKeyframeAnimation，本文件的 CAAnimation setDuration: hook 已覆盖，
//       无需再为 MAMapView 单独加 hook；而 [1] 的双重缩放 bug 修正对它是直接收益。
//
// [6] App 自研 UI 体系（动画由内部 UIView/CAAnimation 驱动，同样已被覆盖）：
//     NAAlertController / NAAlertView / NA_PresentAnimation / NA_DimissAnimation（弹窗转场）
//     NXDesign.framework：SFSlideOverController / slideOverViewController:type:animated:、
//     nx_pushViewController:animated: / safe_pushViewController:animated:、
//     navigationController:animationControllerForOperation:...（自定义导航转场）
//     SFToast / SFMToastView / SFAnimatedImageView
//
// [7] 无法用「改时长」加速的动画引擎（做了也没用，不要承诺）：
//     SVGA（SVGAPlayer / SVGAVideoEntity，CADisplayLink 自驱）、
//     Ugen 动态 UI 引擎（UgenAnimation* 自有渲染循环）、
//     CSJRWLottie*（穿山甲广告 SDK 自带 Lottie）、RN Reanimated。
//
// [8] 风险提示：二进制含越狱/注入检测语料
//     （cydia ×15 / substrate ×17 / jailbreak ×6 / frida ×2 / inject ×18 / debugger ×3），
//     且 App 内嵌 CydiaSubstrate.framework。本 dylib 不新增任何 hook 安装时序，
//     仅按 bundle id 读配置；若设备上出现启动即崩，优先怀疑这一层，用黑名单整体停用排查。
// ============================================================================