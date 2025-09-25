//
//  JKRCoreTextSafety.h
//  JKRFixiOS26CoreTextCrash
//
//  Created by 胡怀刈 on 2025/9/18.
//

#import <UIKit/UIKit.h>

// 日志输出
#ifdef DEBUG
#define JKRTextSafetyLog(...) NSLog(__VA_ARGS__)
#else
#define JKRTextSafetyLog(...)
#endif

NS_ASSUME_NONNULL_BEGIN

/*
 hadCtrl（BOOL）——命中“控制字符”清洗
 含义：文本里出现了需要被替换/删除的 Cc 类控制字符（如 U+0000…U+001F、U+2028/2029 等）。通常替换为空格；\n、\t、方向控制字符 保留。
 触发条件：controlCharacterSet 命中（排除 \n\t\方向控制）。
 典型来源：拷贝粘贴的不可见符、接口脏数据、后端转义错误。
 影响/建议：比例偏高 → 上游数据清洗；可在服务端做正则剔除。
 
 hadSur（BOOL）——命中“孤立代理项”（半个 emoji）
 含义：发现不成对的代理对（surrogate）——高位或低位代理单独出现，无法组成合法 Unicode 码点。
 触发条件：遍历字形时出现单个 0xD800–0xDBFF 或 0xDC00–0xDFFF。
 处理：替换为 U+FFFD（�）。
 典型来源：截断字符串、错误的 UTF-16/UTF-8 编解码。
 影响/建议：命中表示数据被“切半”；重点排查后端截断逻辑或网络层编码。
 
 hadMoreZero（BOOL）——命中超额零宽字符
 含义：文本包含超额零宽字符
 触发条件：大于零宽字符上限，多余会删除
 典型来源：异常长签名/机器人刷屏/富文本粘贴。
 影响/建议：过多零宽字符，会导致iOS26下，计算bound崩溃
 
 hadMoreBibi（BOOL）——命中超额控制字符
 含义：文本包含超额控制字符
 触发条件：大于控制字符上限，多余会删除
 典型来源：异常长签名/机器人刷屏/富文本粘贴。
 影响/建议：过多控制字符，会导致iOS26下，计算bound崩溃
 
 fontFix（BOOL）——修复了“非法字体”
 含义：检测到字体非法或不可用并替换为兜底字体（如 14pt 系统字）。
 按推荐实现：缺失字体不计入，只有 NaN/Inf/≤0/异常大 才置位。
 触发条件：pointSize 非有限、≤0、或超保护上限（如 >600）。
 典型来源：富文本拼装错误、跨平台样式注入、第三方控件 bug。
 影响/建议：比例高 → 排查来源控件，统一测量与渲染字体。
 
 kernFix（BOOL）——修复了“字距(kern)”
 含义：NSKernAttributeName 值非法（非数/NaN/Inf）或越界，被移除或钳制（如限定到 [-50,50]）。
 触发条件：数值非法或超范围。
 典型来源：奇怪的排版器、样式合并错误。
 影响/建议：高命中会影响布局测量一致性；约束富文本来源。
 
 baseFix（BOOL）——修复了“基线偏移(baseline)”
 含义：NSBaselineOffsetAttributeName 非法/越界，被移除或钳制（如 [-200,200]）。
 触发条件：同上。
 典型来源：手动构造富文本、编辑器导出。
 影响/建议：避免文字上下跳跃；把不必要的 baseline 清掉。
 
 colorFix（BOOL）——修复了颜色
 含义：颜色类型不匹配。
 触发条件：NSForegroundColorAttributeName 不是颜色类型。
 典型来源：手动构造富文本、编辑器导出。
 影响/建议：清掉。
 
 strokeWidthFix（BOOL）——修复了“描边(strokewidth)”
 含义：kCTStrokeWidthAttributeName 非法/越界，被移除或钳制（如 [-10,10]）。
 触发条件：同上。
 典型来源：手动构造富文本、编辑器导出。
 影响/建议：把不必要的 strokewidth 清掉。
 
 paraFix（BOOL）——修复了“段落样式”
 含义：段落样式字段（如 lineSpacing、minimum/maximumLineHeight、lineHeightMultiple、hyphenationFactor、缩进等）存在 NaN/Inf/负值/自相矛盾（min>max）等，做了归零、上限钳制或矫正。
 触发条件：任一字段非法或不自洽。
 典型来源：富文本编辑器导入、跨平台样式拷贝。
 影响/建议：防止 CoreText/排版崩溃与极端行高导致的布局溢出。
 
 len0（NSUInteger）——清洗前长度
 用途：与 len1 对比衡量清洗影响面；用于统计“异常文本体量”。
 
 len1（NSUInteger）——清洗后长度
 用途：结合 truncated 判断是否达到了上限；评估显示差异风险。

 */
typedef struct {
    BOOL hadCtrl, hadSur, hadMoreZero, hadMoreBibi; // 所有string有效
    BOOL fontFix, kernFix, baseFix, colorFix, strokeWidthFix, paraFix; // 只有attrstring才有效
    NSUInteger len0, len1; // 所有string有效
} JKRTextSanitizeStat;

FOUNDATION_EXPORT const CGFloat    JKRDefaultFontPt;            // 14.0

/// 纯文本清洗（控制字符→删除；孤立代理→U+FFFD；bidi 规范化；长度裁剪）
NSString * _Nullable JKRSanitizePlainString(NSString * _Nullable attr, JKRTextSanitizeStat * _Nullable st);


NSString * JKRSanitizePlainStringEasy(NSString * _Nullable s);


NSDictionary<NSAttributedStringKey,id> *
jkr_localFixAttributes(NSDictionary<NSAttributedStringKey,id> *attrs,  BOOL *fontFix, BOOL *kernFix, BOOL *baseFix, BOOL *colorFix, BOOL *strokeWidthFix, BOOL *paraFix);


/// 富文本整体清洗（文本替换 + 属性修复 + 裁剪）
NSAttributedString * _Nullable JKRSanitizeAttributedString(NSAttributedString * _Nullable attr, JKRTextSanitizeStat * _Nullable st);


NSAttributedString * JKRSanitizeAttributedStringEasy(NSAttributedString * _Nullable attr);

BOOL jkr_isSafe(JKRTextSanitizeStat st);

/// 尺寸钳制（防 NaN/Inf/MAXFLOAT）
CGSize JKRFixMeasureSize(CGSize sz);

@interface NSString (JKRSafeCheck)

@property (nonatomic) BOOL jkr_isSafeString;

@end

@interface NSAttributedString (JKRSafeCheck)

@property (nonatomic) BOOL jkr_isSafeString;

@end


NS_ASSUME_NONNULL_END

