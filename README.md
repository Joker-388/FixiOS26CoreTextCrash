# JKRFixiOS26CoreTextCrash

⚠️：iOS26.0.1已经修复了这个问题，如果可以接受这个bug，让iOS26.0.0用户主动升级，可以忽略这个bug了。

一套**iOS 26 / CoreText 崩溃防护与文本清洗**的实用工具。
针对“跨脚本组合记号堆叠、过量零宽/方向控制符、孤立代理项、异常富文本属性”等导致的 `boundingRect` / CoreText 排版崩溃，提供**可落地、可观测、可配置**的修复方案。

---

## 亮点

* **纯文本清洗**：控制字符剔除、孤立代理项替换（`U+FFFD`）、零宽字符限额、BiDi 控制符折叠/限额、组合记号（Mn/Me）限流。
* **“回粘”策略**：簇首为记号时，尝试回粘到**阿拉伯 base/Tatweel**（受簇上限约束），尽量减少视觉损失。
* **脚本相容性过滤**：只允许“与 base 脚本相容”的 Mn/Me（Latin/Arabic/Cyrillic/Common），**硬抑制跨脚本堆叠**触发的崩溃路径。
* **富文本属性修复**：字体、字距、基线、颜色、描边、段落样式等异常值自动钳制/移除。
* **测量保护**：`JKRFixMeasureSize` 钳制 `NaN/Inf/极大值`，避免 `boundingRect`/`CTFramesetter` 走到异常路径。
* **Hook 接入**：一行安装 `JKRInstallTextBoundingSafety()`，给 `NSString/NSAttributedString` 的 `boundingRect...` 追加保护。
* **观测与统计**：`JKRTextSanitizeStat` 精细标记各类命中，配合日志开关快速定位上游脏数据。

---

## 适配范围

* 重点防护 iOS 26 上已知 CoreText 崩溃路径（但其他系统版本也具备兜底意义）

---

## 快速开始

### 1) 集成代码

将以下文件加入工程（同一 Target）：

* `JKRCoreTextSafety.h/.m`（或 `JKRTextSafetyShared.h` + 实现文件）
* `NSString+JKRTextBoundingSafetyGlobal.m`（可选：全局 hook `boundingRect`）
* 确保 **`jkr_isSafeString` 访问器**只在**一个实现文件**中定义（避免类别重复实现带来的运行时冲突）。

### 2) 初始化（可选，全局 hook）

```objc
// App 启动时，默认hook全局UILabel setText、setAttributedText，自动清洗
JKRInstallTextBoundingSafety();
// App 启动时，默认hook boundingRectWithSize，计算bound前自动清洗
JKRInstallUILabelTextSafety();
```

> 作用：为 `NSString` / `NSAttributedString` 的 `boundingRect...` 注入“尺寸钳制 + 文本/属性清洗”。

### 3) 直接调用（按需）

```objc
#import "JKRCoreTextSafety.h"

// 纯文本
JKRTextSanitizeStat st = {0};
NSString *safe = JKRSanitizePlainString(rawString, &st);
BOOL ok = jkr_isSafe(st); // 是否命中异常（false 表示发生清洗/修复）

// 富文本
NSAttributedString *san = JKRSanitizeAttributedString(attr, &st);

// 仅修属性（不改文字）
BOOL fontFix,kernFix,baseFix,colorFix,strokeFix,paraFix = NO;
NSDictionary *attrs2 = jkr_localFixAttributes(attrs, &fontFix, &kernFix, &baseFix, &colorFix, &strokeFix, &paraFix);

// 测量保护
CGRect r = [safe boundingRectWithSize:JKRFixMeasureSize(size)
                              options:opts
                           attributes:attrs2
                              context:NULL];
```

---

## API 说明

### 纯文本

```objc
NSString * _Nullable JKRSanitizePlainString(NSString * _Nullable s, JKRTextSanitizeStat * _Nullable st);
NSString * JKRSanitizePlainStringEasy(NSString * _Nullable s);
```

* 删除 **控制字符**（Cc，保留 `\n`/`\t`），孤立代理项 → `U+FFFD`
* **零宽字符** 限额（默认 16，超出丢弃）
* **BiDi 控制符** 限额（默认 8，且**同一 run 折叠为一个**）
* **组合记号**（Mn/Me）**每簇上限**（默认 8），并做**脚本相容性过滤**
* 簇首为记号（无 base）时，优先尝试**回粘**到前一阿拉伯 base/Tatweel

### 富文本

```objc
NSAttributedString * _Nullable JKRSanitizeAttributedString(NSAttributedString * _Nullable attr, JKRTextSanitizeStat * _Nullable st);
NSAttributedString * JKRSanitizeAttributedStringEasy(NSAttributedString * _Nullable attr);
```

* 基于文本清洗后的**索引映射**重放原属性
* 属性值异常将被钳制/清理（见下）

### 属性修复

```objc
NSDictionary<NSAttributedStringKey,id> *
jkr_localFixAttributes(NSDictionary *attrs,
                       BOOL *fontFix, BOOL *kernFix, BOOL *baseFix,
                       BOOL *colorFix, BOOL *strokeWidthFix, BOOL *paraFix);
```

* 字体：`pointSize<=0 / NaN/Inf / >600` → 系统 14pt；CTFont 非法类型 → 替换
* `NSKern`/`kCTKern`：`[-50,50]` 区间钳制；非数移除
* 基线偏移：`[-200,200]`；非数移除
* 颜色：类型不匹配直接移除（防 CT 路径触发）
* 描边：`[-10,10]`；非数移除
* 段落：`lineSpacing/lineHeightMultiple/hyphenationFactor/...` 的 `NaN/Inf/矛盾值` 归零/矫正

### 安全判断与尺寸钳制

```objc
BOOL jkr_isSafe(JKRTextSanitizeStat st);
CGSize JKRFixMeasureSize(CGSize sz);
```

* `jkr_isSafe`：若任何清洗/修复发生（或长度变化等），返回 `NO`，便于上报与观测。
* `JKRFixMeasureSize`：将 `NaN/Inf/<=0/超大值` 钳到安全上限（默认 100000）。

### 安全标记

```objc
@interface NSString (JKRSafeCheck)
@property (nonatomic) BOOL jkr_isSafeString;
@end

@interface NSAttributedString (JKRSafeCheck)
@property (nonatomic) BOOL jkr_isSafeString;
@end
```

* 清洗返回的字符串已自动打 `jkr_isSafeString = YES`，Hook 会走**轻量路径**（仅修属性/尺寸钳制）。

---

## 配置项（默认）

```objc
static const NSUInteger kJKRMaxBidiTotal           = 8;   // 全文 BiDi 控制符上限（run 内折叠）
static const NSUInteger kJKRMaxCombiningPerCluster = 8;   // 单簇组合记号上限（Mn/Me）
static const NSUInteger kJKRMaxZeroWidthTotal      = 16;  // 全文零宽字符上限
FOUNDATION_EXPORT const CGFloat JKRDefaultFontPt   = 14.0;
```

> 可按业务调整，建议**保守**优先，先稳定再优化视觉。

---

## 日志与观测

在 `JKRCoreTextSafety.h` 顶部：

```objc
#define kJKROpenCTSLog 1
#if DEBUG && kJKROpenCTSLog
  #define JKRTextSafetyLog(...) NSLog(__VA_ARGS__)
#else
  #define JKRTextSafetyLog(...)
#endif
```

* `jkr_isSafe(st) == NO` 时会输出各类命中项，便于灰度/监控。
* 线上建议采集 `JKRTextSanitizeStat` 的**计数与比例**，做上游数据治理。

---

## 常见问题

### 1) 为什么要“脚本相容性过滤”？

iOS 26 的崩溃路径与**跨脚本 Mn/Me 堆叠**强相关（例如拉丁 base 上叠阿拉伯记号）。过滤后仍保留 VS/FE2x 等**Common** 记号，尽量不影响正常显示。

### 2) 这会“误伤”正常阿拉伯文字吗？

不会。阿拉伯记号仅允许叠到**阿拉伯 base/Tatweel**，这是阿拉伯正字法的预期。仅**跨脚本滥用**会被过滤或限流（同时有簇上限 8）。

### 3) 例子

原始：`"🌹‎᭄ͥғᷢєͥяᷤ💍💘🎸"`
处理：过滤掉跨脚本和超额的组合记号、折叠 LRM run，保留主要 base 与 emoji，**避免崩溃**。

### 4) Hook 会影响性能吗？

枚举 **composed sequences** + 轻量判定，实际开销可控；多数文本**不命中**时只做尺寸钳制与必要属性校验。对富文本大段渲染建议做**异步测量缓存**。

### 5) 重复定义 `jkr_isSafeString` 会怎样？

请**确保访问器只实现一次**。多个 Target/静态库重复实现可能导致类别冲突、行为不一致甚至崩溃。建议抽到单独 `JKRSafeFlag.m`，其他文件仅引头。

---

## 测试建议

* 构造 5 组样例：

  1. 纯拉丁 + 正常组合记号（上限内）
  2. 阿拉伯 base + 阿拉伯记号（上限内）
  3. 拉丁 base + 阿拉伯记号（应被过滤）
  4. 无 base 记号开头（应回粘/或 `U+FFFD`）
  5. 超额零宽 / 超额 BiDi run
* 分别走：`boundingRectWithSize:`、`CTFramesetterCreateWithAttributedString` + `CTFramesetterSuggestFrameSizeWithConstraints`，确保一致不崩。

---

## 目录结构（示例）

```
JKRFixiOS26CoreTextCrash/
├── TextSafety/
│   ├── JKRCoreTextSafety.h
│   ├── JKRCoreTextSafety.m
│   ├── NSString+JKRTextBoundingSafetyGlobal.h   // 可选（全局 hook）
│   ├── NSString+JKRTextBoundingSafetyGlobal.m   
│   ├── UILabel+JKRTextSafetyGlobal.h            // 可选（全局 hook）
│   └── UILabel+JKRTextSafetyGlobal.m
└── TestDemo
```
