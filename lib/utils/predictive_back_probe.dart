/// 预测返回黑底染色探针(仅诊断用,发布前删)。
///
/// 用法:把 [kPredictiveBackProbe] 改 true,构建 debug 包,连划复现。
/// 判读:
/// - 黑区变**红** → 黑区在 Flutter 图层内(冻结铺底没盖到),继续修
///   Dart 渲染层;红色出现的范围即缺底位置。
/// - 黑区变**洋红/紫** → 黑区是 Activity 窗口底(windowBackground),
///   系统在缩放整个窗口,Flutter 只是贴图 —— 应用层能做的仅是把
///   windowBackground 调成主题色(已做),黑本身来自窗口外合成区。
/// - 仍**纯黑** → 既不在 Flutter 图层也不在 Activity 窗口底,是系统
///   合成层(SurfaceFlinger/OEM 转场)的背景,应用层无解。
library;

/// 总开关
const bool kPredictiveBackProbe = false;

/// 冻结铺底染色(Flutter 图层):红
const int kProbeFreezeBackdropColor = 0xFFFF0000;

/// Scaffold/app 底色染色(Flutter 图层):橙
const int kProbeAppBackdropColor = 0xFFFF8800;
