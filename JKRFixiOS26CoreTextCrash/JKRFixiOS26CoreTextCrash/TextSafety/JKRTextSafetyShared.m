//
//  JKRCoreTextSafety.m
//  JKRFixiOS26CoreTextCrash
//
//  Created by 胡怀刈 on 2025/9/18.
//

#import "JKRTextSafetyShared.h"
#import <CoreFoundation/CoreFoundation.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>

const CGFloat    JKRDefaultFontPt           = 14.0;

static inline BOOL jkrFinite(CGFloat v){ return isfinite(v); }
static inline BOOL jkrIsHighSur(unichar c){ return (c >= 0xD800 && c <= 0xDBFF); }
static inline BOOL jkrIsLowSur (unichar c){ return (c >= 0xDC00 && c <= 0xDFFF); }

// 孤立代理修复 + 组合记号限流 + 零宽限额
// ------------------------------------------------------------
static const NSUInteger kJKRMaxBidiTotal           = 8;   // 全文最大bidi数量
static const NSUInteger kJKRMaxCombiningPerCluster = 8;   // 单个字素簇最多保留的 Mn/Me
static const NSUInteger kJKRMaxZeroWidthTotal      = 16;  // 全文最多保留的零宽字符

// 仅 Cc（控制字符，去掉 \n \t），用于 hadCtrl & 替换
static NSCharacterSet *JKRSetCc(void) {
    static NSCharacterSet *cc;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *m = [NSMutableCharacterSet new];
        [m addCharactersInRange:NSMakeRange(0x0000, 0x20)];  // U+0000–001F
        [m addCharactersInRange:NSMakeRange(0x007F, 0x21)];  // U+007F–009F
        [m removeCharactersInRange:NSMakeRange('\n', 1)];
        [m removeCharactersInRange:NSMakeRange('\t', 1)];
        // 如需把 U+2028/U+2029 当控制，请解除下一行注释（当前实现默认保留）：
        // [m addCharactersInRange:NSMakeRange(0x2028, 2)];
        cc = [m copy];
    });
    return cc;
}

// 仅 bidi 控制符（Cf 子集），用于统计 & 折叠限额
static NSCharacterSet *JKRSetBidi(void) {
    static NSCharacterSet *bidi;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bidi = [NSCharacterSet characterSetWithCharactersInString:
                // ALM + LRM/RLM + LRE/RLE/LRO/RLO/PDF + LRI/RLI/FSI/PDI
                @"\u061C\u200E\u200F\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069"];
        // 如需把 ZWJ/ZWNJ/ZWSP/WJ 也统计进去，可在此处附加：
        // bidi = [[bidi mutableCopy] removeCharactersInString:@"\u200B\u200C\u200D\u2060"] …（或单独做一个 Cf 集合）
    });
    return bidi;
}

// 组合附加记号（Mn/Me 常见块）：0300–036F, 1AB0–1AFF, 1DC0–1DFF, 20D0–20FF, FE20–FE2F,
// 以及常见阿拉伯记号：0610–061A, 064B–065F, 0670, 06D6–06ED
static NSCharacterSet *JKRSetCombining(void) {
    static NSCharacterSet *set; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *m = [NSMutableCharacterSet new];
        [m addCharactersInRange:NSMakeRange(0x0300, 0x70)];   // 0300–036F
        [m addCharactersInRange:NSMakeRange(0x1AB0, 0x50)];   // 1AB0–1AFF
        [m addCharactersInRange:NSMakeRange(0x1DC0, 0x40)];   // 1DC0–1DFF
        [m addCharactersInRange:NSMakeRange(0x20D0, 0x30)];   // 20D0–20FF
        [m addCharactersInRange:NSMakeRange(0xFE20, 0x10)];   // FE20–FE2F
        [m addCharactersInRange:NSMakeRange(0xFE00, 0x10)];   // FE00–FE0F (VS1–VS16) 变体选择符
        [m addCharactersInRange:NSMakeRange(0x0610, 0x0B)];   // 0610–061A
        [m addCharactersInRange:NSMakeRange(0x064B, 0x15)];   // 064B–065F
        [m addCharactersInRange:NSMakeRange(0x0670, 0x01)];   // 0670
        [m addCharactersInRange:NSMakeRange(0x06D6, 0x18)];   // 06D6–06ED
        set = [m copy];
    });
    return set;
}

// ===== 脚本相容性过滤：只允许“与 base 脚本相容”的 Mn/Me，避免跨脚本堆叠触发 CoreText 崩溃 =====
typedef NS_OPTIONS(NSUInteger, JKRScriptMask) {
    JKRScriptLatin    = 1 << 0,
    JKRScriptArabic   = 1 << 1,
    JKRScriptCyrillic = 1 << 2,
    JKRScriptCommon   = 1 << 30, // VS/FE2x 等通用
    JKRScriptUnknown  = 1 << 31,
};

static inline JKRScriptMask JKRScriptOfBase(unichar b) {
    // 拉丁（含扩展）
    if ((b >= 0x0041 && b <= 0x024F) || (b >= 0x1E00 && b <= 0x1EFF)) return JKRScriptLatin;
    // 西里尔（含扩展）
    if ((b >= 0x0400 && b <= 0x052F) || (b >= 0x2DE0 && b <= 0x2DFF) || (b >= 0xA640 && b <= 0xA69F)) return JKRScriptCyrillic;
    // 阿拉伯（含呈现区/扩展）
    if ((b >= 0x0600 && b <= 0x06FF) || (b >= 0x0750 && b <= 0x077F) ||
        (b >= 0x08A0 && b <= 0x08FF) || (b >= 0xFB50 && b <= 0xFDFF) || (b >= 0xFE70 && b <= 0xFEFF)) return JKRScriptArabic;
    return JKRScriptUnknown;
}

static inline JKRScriptMask JKRScriptOfComb(unichar m) {
    // 拉丁记号：0300–036F, 1AB0–1AFF, 1DC0–1DFF
    if ((m >= 0x0300 && m <= 0x036F) || (m >= 0x1AB0 && m <= 0x1AFF) || (m >= 0x1DC0 && m <= 0x1DFF)) return JKRScriptLatin;
    // 阿拉伯记号：0610–061A, 064B–065F, 0670, 06D6–06ED
    if ((m >= 0x0610 && m <= 0x061A) || (m >= 0x064B && m <= 0x065F) || m == 0x0670 || (m >= 0x06D6 && m <= 0x06ED)) return JKRScriptArabic;
    // FE20–FE2F（组合上标桥）与 FE00–FE0F（VS）视作“通用/安全”
    if ((m >= 0xFE20 && m <= 0xFE2F) || (m >= 0xFE00 && m <= 0xFE0F)) return JKRScriptCommon;
    return JKRScriptUnknown;
}

static inline BOOL JKRCombAllowedForBase(unichar base, unichar mark) {
    JKRScriptMask bs = JKRScriptOfBase(base);
    JKRScriptMask ms = JKRScriptOfComb(mark);
    if (ms == JKRScriptCommon) return YES;
    if (bs == JKRScriptLatin && ms == JKRScriptLatin) return YES;
    if (bs == JKRScriptArabic && ms == JKRScriptArabic) return YES;
    if (bs == JKRScriptCyrillic && ms == JKRScriptCyrillic) return YES;
    return NO; // 其它组合一律不允许，保守以避坑
}


// 可回粘的“阿拉伯 base”或 Tatweel（含呈现区）
static inline BOOL JKRIsArabicBaseOrTatweel(unichar cu) {
    return (cu == 0x0640) ||                        // Tatweel
           (cu >= 0x0600 && cu <= 0x06FF) ||        // Arabic
           (cu >= 0xFB50 && cu <= 0xFDFF) ||        // Arabic Presentation Forms-A
           (cu >= 0xFE70 && cu <= 0xFEFF);          // Arabic Presentation Forms-B
}

// 取“簇首连续的 Mn/Me”前缀，至多 limit 个
static inline NSString *
JKRCombiningLimitedPrefix(NSString *sub, NSCharacterSet *comb, NSUInteger limit) {
    if (sub.length == 0 || limit == 0) return @"";
    NSMutableString *buf = [NSMutableString string];
    NSUInteger kept = 0;
    for (NSUInteger i = 0; i < sub.length; i++) {
        unichar cu = [sub characterAtIndex:i];
        if (![comb characterIsMember:cu]) break;
        [buf appendFormat:@"%C", cu];
        if (++kept >= limit) break;
    }
    return buf;
}

// 统计 fixed 尾部“紧跟在最后一个 base 后”的 Mn/Me 数量（用于回粘前算已有负载）
static inline NSUInteger
JKRTrailingCombiningCount(NSString *fixed, NSCharacterSet *comb) {
    if (fixed.length == 0) return 0;
    NSUInteger i = fixed.length;
    NSUInteger cnt = 0;
    // 从尾部向前，累加连续的 Mn/Me
    while (i > 0) {
        unichar cu = [fixed characterAtIndex:i - 1];
        if (![comb characterIsMember:cu]) break;
        cnt++;
        i--;
    }
    return cnt;
}

// 常见零宽字符：ZWSP/ZWNJ/ZWJ/WORD JOINER/BOM
static NSCharacterSet *JKRSetZeroWidth(void) {
    static NSCharacterSet *set; static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSCharacterSet characterSetWithCharactersInString:
               @"\u00AD\u200B\u200C\u200D\u2060\uFEFF"];
    });
    return set;
}

/// 将一个“单个字素簇”做 Mn/Me 限额：
/// - 若簇首即为 Mn/Me（无 base），返回 "�" 并标记 noBase=YES。
/// - 否则保留 base + 前 limit 个 Mn/Me，超过即裁剪并标记 truncated=YES。
static inline NSString *
JKRLimitCombiningInCluster(NSString *sub,
                           NSCharacterSet *comb,
                           NSUInteger limit,
                           BOOL *noBase,
                           BOOL *truncated)
{
    if (noBase) *noBase = NO;
    if (truncated) *truncated = NO;
    if (sub.length == 0) return sub;

    // 快速判定：若首 code unit 就是 Mn/Me，则视为“无 base 的异常簇”
    unichar first = [sub characterAtIndex:0];
    if ([comb characterIsMember:first]) {
        if (noBase) *noBase = YES;
        return @"\uFFFD";
    }
    
    // 以 sub[0] 作为 base（这里用首个 code unit 判脚本，足够规避崩溃路径）
    unichar base0 = first;
    NSMutableString *buf = [NSMutableString stringWithCapacity:sub.length];
    [buf appendFormat:@"%C", base0];
    
    NSUInteger keptComb = 0;
    for (NSUInteger i = 1; i < sub.length; i++) {
        unichar cu = [sub characterAtIndex:i];
        BOOL isComb = [comb characterIsMember:cu];
        if (isComb) {
            // 新增：按 base 脚本过滤，禁止跨脚本记号
            if (!JKRCombAllowedForBase(base0, cu)) {
                if (truncated) *truncated = YES;
                continue;
            }
            if (keptComb < limit) {
                [buf appendFormat:@"%C", cu];
                keptComb++;
            } else {
                if (truncated) *truncated = YES; // 超簇上限
            }
            continue;
        }
        // 非 Mn/Me：直接保留，并照顾代理对
        [buf appendFormat:@"%C", cu];
        if (0xD800 <= cu && cu <= 0xDBFF && i + 1 < sub.length) {
            unichar cu2 = [sub characterAtIndex:i+1];
            if (0xDC00 <= cu2 && cu2 <= 0xDFFF) { [buf appendFormat:@"%C", cu2]; i++; }
        }
    }
    // 若过程中有任一过滤/超限，truncated 已置位；否则表示“按相容性完整保留”
    return buf;
}

// 计算“簇首连续 Mn/Me 的原始数量”（不受 limit 影响）
static inline NSUInteger
JKRLeadingCombiningCount(NSString *sub, NSCharacterSet *comb) {
    if (sub.length == 0) return 0;
    NSUInteger cnt = 0;
    for (NSUInteger i = 0; i < sub.length; i++) {
        unichar cu = [sub characterAtIndex:i];
        if (![comb characterIsMember:cu]) break;
        cnt++;
    }
    return cnt;
}

NSDictionary<NSAttributedStringKey,id> *
jkr_localFixAttributes(NSDictionary<NSAttributedStringKey,id> *attrs,
                       BOOL *fontFix, BOOL *kernFix, BOOL *baseFix, BOOL *colorFix, BOOL *strokeWidthFix, BOOL *paraFix) {
    if (!attrs) return nil;
    BOOL changed = NO;
    NSMutableDictionary *m = [attrs mutableCopy];
    // UIFont
    UIFont *f = m[NSFontAttributeName];
    if (f) {
        if (!(isfinite(f.pointSize) && f.pointSize > 0)) {
            m[NSFontAttributeName] = [UIFont systemFontOfSize:JKRDefaultFontPt];
            if (fontFix) *fontFix = YES;
            changed = YES;
        }
    }
    // CTFont
    id ctFontObj = m[(id)kCTFontAttributeName];
    if (ctFontObj) {
        if (CFGetTypeID((__bridge CFTypeRef)ctFontObj) != CTFontGetTypeID()) {
            UIFont *sys = [UIFont systemFontOfSize:JKRDefaultFontPt];
            CTFontRef safe = CTFontCreateWithName((CFStringRef)sys.fontName, sys.pointSize, NULL);
            if (safe) {
                m[(id)kCTFontAttributeName] = (__bridge_transfer id)safe;
            } else {
                [m removeObjectForKey:(id)kCTFontAttributeName];
            }
            if (fontFix) *fontFix = YES;
            changed = YES;
        } else {
            CTFontRef ctf = (__bridge CTFontRef)ctFontObj;
            CGFloat sz = CTFontGetSize(ctf);
            if (!(isfinite(sz) && sz > 0 && sz <= 600)) {
                UIFont *sys = [UIFont systemFontOfSize:JKRDefaultFontPt];
                CTFontRef safe = CTFontCreateWithName((CFStringRef)sys.fontName, sys.pointSize, NULL);
                if (safe) {
                    m[(id)kCTFontAttributeName] = (__bridge_transfer id)safe;
                } else {
                    [m removeObjectForKey:(id)kCTFontAttributeName];
                }
                if (fontFix) *fontFix = YES;
                changed = YES;
            }
        }
    }
    
    // kern
    id kern = m[NSKernAttributeName];
    if (kern) {
        CGFloat v = [kern respondsToSelector:@selector(doubleValue)] ? [kern doubleValue] : 0;
        if (!isfinite(v)) {
            [m removeObjectForKey:NSKernAttributeName];
            if (kernFix) {
                *kernFix = YES;
            }
            changed = YES;
        }
        else if (v < -50 || v > 50) {
            m[NSKernAttributeName] = @(MAX(-50, MIN(50, v)));
            if (kernFix) {
                *kernFix = YES;
            }
            changed = YES;
        }
    }
    // kCTKern
    id ckern = m[(id)kCTKernAttributeName];
    if (ckern) {
        CGFloat v = [ckern respondsToSelector:@selector(doubleValue)] ? [ckern doubleValue] : 0;
        if (!isfinite(v)) {
            [m removeObjectForKey:(id)kCTKernAttributeName];
            if (kernFix) {
                *kernFix = YES;
            }
            changed = YES;
        } else if (v < -50 || v > 50) {
            m[(id)kCTKernAttributeName] = @(MAX(-50, MIN(50, v)));
            if (kernFix) {
                *kernFix = YES;
            }
            changed = YES;
        }
    }
    // baseline
    id base = m[NSBaselineOffsetAttributeName];
    if (base) {
        CGFloat v = [base respondsToSelector:@selector(doubleValue)] ? [base doubleValue] : 0;
        if (!isfinite(v)) {
            [m removeObjectForKey:NSBaselineOffsetAttributeName];
            if (baseFix) {
                *baseFix = YES;
            }
            changed = YES;
        } else if (v < -200 || v > 200) {
            m[NSBaselineOffsetAttributeName] = @(MAX(-200, MIN(200, v)));
            if (baseFix) {
                *baseFix = YES;
            }
            changed = YES;
        }
    }
    // 颜色（NS）：不是 UIColor 就移除
    id nsfg = m[NSForegroundColorAttributeName];
    if (nsfg && ![nsfg isKindOfClass:UIColor.class]) {
        [m removeObjectForKey:NSForegroundColorAttributeName];
        if (colorFix) {
            *colorFix = YES;
        }
        changed = YES;
    }
    // 颜色（CT）：仅移除非法类型，避免把 UIColor 转成 CGColor 以触发 CT 路径
    id fg = m[(id)kCTForegroundColorAttributeName];
    if (fg && CFGetTypeID((__bridge CFTypeRef)fg) != CGColorGetTypeID()) {
        [m removeObjectForKey:(id)kCTForegroundColorAttributeName];
        if (colorFix) {
            *colorFix = YES;
        }
        changed = YES;
    }
    // 描边（CT）
    id sw = m[(id)kCTStrokeWidthAttributeName];
    if (sw) {
        CGFloat v = [sw respondsToSelector:@selector(doubleValue)] ? [sw doubleValue] : 0;
        if (!isfinite(v)) {
            [m removeObjectForKey:(id)kCTStrokeWidthAttributeName];
            if (strokeWidthFix) {
                *strokeWidthFix = YES;
            }
            changed = YES;
        } else if (v < -10 || v > 10) {
            m[(id)kCTStrokeWidthAttributeName] = @(MAX(-10, MIN(10, v)));
            if (strokeWidthFix) {
                *strokeWidthFix = YES;
            }
            changed = YES;
        }
    }
    // 段落样式
    NSParagraphStyle *p = m[NSParagraphStyleAttributeName];
    if (p) {
        NSMutableParagraphStyle *mp = [p mutableCopy];
        BOOL fix = NO;
        if (!isfinite(mp.lineSpacing))        { mp.lineSpacing = 0; fix = YES; }
        if (!isfinite(mp.paragraphSpacing))   { mp.paragraphSpacing = 0; fix = YES; }
        if (!isfinite(mp.minimumLineHeight))  { mp.minimumLineHeight = 0; fix = YES; }
        if (!isfinite(mp.maximumLineHeight))  { mp.maximumLineHeight = 0; fix = YES; }
        if (!isfinite(mp.lineHeightMultiple)) { mp.lineHeightMultiple = 0; fix = YES; }
        if (!isfinite(mp.hyphenationFactor))  { mp.hyphenationFactor = 0; fix = YES; }
        if (mp.maximumLineHeight > 0 && mp.minimumLineHeight > mp.maximumLineHeight) {
            mp.minimumLineHeight = 0; mp.maximumLineHeight = 0; fix = YES;
        }
        if (fix) {
            if (paraFix) {
                *paraFix = YES;
            }
            m[NSParagraphStyleAttributeName] = mp;
            changed = YES;
        }
    }
    return changed ? m : attrs;
}

NSString * JKRSanitizePlainString(NSString *s, JKRTextSanitizeStat *statOut) {
    JKRTextSanitizeStat st = {0};
    if (s.length == 0) {
        if (statOut) *statOut = st;
        if (s) {
            return @"";
        } else {
            return nil;
        }
    }
    st.len0 = s.length;

    // 可变副本
    NSMutableString *m = [s mutableCopy];
    
    NSCharacterSet *cc   = JKRSetCc();
    NSCharacterSet *bidi = JKRSetBidi();
    NSCharacterSet *comb = JKRSetCombining();
    NSCharacterSet *zw   = JKRSetZeroWidth();
    
    __block BOOL hadSur = NO;
    __block BOOL hadCtrl = NO;
    __block BOOL hadMoreBidi = NO;
    __block BOOL hadMoreZero = NO;
    __block BOOL hadMoreComb = NO;
    
    __block NSUInteger bidiKept = 0;         // 全文保留的bibi数量
    __block BOOL inBidiRun = NO;             // 是否处于一段连续的bidi控制符run中
    __block NSUInteger zeroWidthKept = 0;    // 全文累计保留的零宽数量
    
    NSMutableString *fixed = [NSMutableString stringWithCapacity:m.length];
    [m enumerateSubstringsInRange:NSMakeRange(0, m.length)
                          options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString * _Nullable sub, NSRange subRange, NSRange enclosingRange, BOOL * stop){
        if (!sub) return;
        
        // 读取首个 code unit 以进行快速归类
        unichar c0 = [sub characterAtIndex:0];
        
        // 控制字符：直接丢弃
        if (sub.length == 1 && [cc characterIsMember:c0]) {
            inBidiRun = NO;
            hadCtrl = YES;
            return;
        }
        
        // bidi
        if (sub.length == 1 && [bidi characterIsMember:c0]) {
            if (!inBidiRun && bidiKept < kJKRMaxBidiTotal) {
                [fixed appendString:sub];
                bidiKept++;
                inBidiRun = YES;
            } else {
                // 折叠（同一 run 内第2个及以后）或超额：丢弃
                hadMoreBidi = YES;
            }
            return;
        } else {
            inBidiRun = NO;
        }
        
        // 孤立代理：直接替换为 U+FFFD（不改变簇状态）
        if (sub.length == 1) {
            if (jkrIsHighSur(c0) || jkrIsLowSur(c0)) {
                inBidiRun = NO;
                [fixed appendString:@"\uFFFD"];
                hadSur = YES;
                return;
            }
        }
        
        // 零宽字符：全局限额，超过后丢弃；零宽不改变簇的 base/combining 状态
        if ([zw characterIsMember:c0]) {
            inBidiRun = NO;
            if (zeroWidthKept < kJKRMaxZeroWidthTotal) {
                [fixed appendString:sub];
                zeroWidthKept++;
            } else {
                // 超额丢弃
                hadMoreZero = YES;
            }
            return;
        }
        
        // 组合附加记号处理：对“整个簇”做限额/纠正
        {
            BOOL noBase = NO, truncated = NO;
            NSString *limited = JKRLimitCombiningInCluster(sub, comb, kJKRMaxCombiningPerCluster, &noBase, &truncated);
            if (noBase) {
                // 尝试回粘：仅当 fixed 尾字符是阿拉伯 base 或 Tatweel，且不超簇总上限
                if (fixed.length > 0) {
                    unichar prev = [fixed characterAtIndex:fixed.length - 1];
                    if (JKRIsArabicBaseOrTatweel(prev)) {
                        // 已有负载
                        NSUInteger existing = JKRTrailingCombiningCount(fixed, comb);
                        if (existing < kJKRMaxCombiningPerCluster) {
                            NSUInteger capacity = kJKRMaxCombiningPerCluster - existing;
//                            NSString *marks = JKRCombiningLimitedPrefix(sub, comb, capacity);
                            // 计算原始前缀数量用于正确置位 hadMoreComb
                            NSUInteger prefix = JKRLeadingCombiningCount(sub, comb);
                            NSString *marks = JKRCombiningLimitedPrefix(sub, comb, capacity);
                            if (marks.length > 0) {
                                [fixed appendString:marks];
//                                // 若原簇前缀超过可用容量则记为截断
//                                if (marks.length < MIN(sub.length, capacity)) hadMoreComb = YES;
                                // 只有当“原始前缀”确实超过可用容量时，才标记为超限
                                if (prefix > capacity) hadMoreComb = YES;
                                inBidiRun = NO;
                                return;
                            }
                        }
                    }
                }
                // 无法回粘：退回到 U+FFFD
                hadSur = YES;
                [fixed appendString:@"\uFFFD"];
            } else {
                if (truncated) hadMoreComb = YES;
                [fixed appendString:limited];
            }
        }
        
        inBidiRun = NO;
        return;
    }];
    st.hadCtrl = hadCtrl;
    st.hadSur = hadSur;
    st.hadMoreBidi = hadMoreBidi;
    st.hadMoreZero = hadMoreZero;
    st.hadMoreComb = hadMoreComb;

    st.len1 = fixed.length;

    if (statOut) *statOut = st;
    
    NSString *res = fixed.copy;
    res.jkr_isSafeString = YES;
    return res;
}

NSString * JKRSanitizePlainStringEasy(NSString *s) {
    JKRTextSanitizeStat st = {0};
    return JKRSanitizePlainString(s, &st);
}


// 映射辅助：返回长度为 orig.length + 1 的数组，map[i] 表示“原始索引 i 在清洗后对应的新索引”
static inline NSMutableArray<NSNumber *> *
JKRCreateIndexMap(NSUInteger origLen) {
    NSMutableArray<NSNumber *> *map = [NSMutableArray arrayWithCapacity:origLen + 1];
    for (NSUInteger i = 0; i <= origLen; i++) { [map addObject:@0]; }
    return map;
}

// 带索引映射的纯文本清洗：与 JKRSanitizePlainString 逻辑保持一致
static NSString *
JKRSanitizePlainStringWithMap(NSString *s,
                              JKRTextSanitizeStat *statOut,
                              NSMutableArray<NSNumber *> **mapOut) {
    JKRTextSanitizeStat st = {0};
    if (s.length == 0) {
        if (statOut) *statOut = st;
        if (mapOut) *mapOut = JKRCreateIndexMap(0);
        return s ? @"" : nil;
    }
    st.len0 = s.length;

    NSMutableString *m = [s mutableCopy];

    NSCharacterSet *cc   = JKRSetCc();
    NSCharacterSet *bidi = JKRSetBidi();
    NSCharacterSet *comb = JKRSetCombining();
    NSCharacterSet *zw   = JKRSetZeroWidth();
    
    __block BOOL hadSur = NO;
    __block BOOL hadCtrl = NO;
    __block BOOL hadMoreBidi = NO;
    __block BOOL hadMoreZero = NO;
    __block BOOL hadMoreComb = NO;
    
    __block NSUInteger bidiKept = 0;         // 全文保留的bibi数量
    __block BOOL inBidiRun = NO;             // 是否处于一段连续的bidi控制符run中
    __block NSUInteger zeroWidthKept = 0;    // 全文累计保留的零宽数量

    // 建立旧->新映射
    NSMutableArray<NSNumber *> *map = JKRCreateIndexMap(s.length);
    __block NSUInteger newIdx = 0;
    void (^markRangeTo)(NSRange, NSUInteger) = ^(NSRange old, NSUInteger to){
        // old 是原 m 的子串在“当前 m”中的范围，但与 s 的 UTF16 索引一致（上面仅删控后 m 与 s 仍等长或更短）
        // 为稳妥：对覆盖范围逐点赋值（UTF16 粒度）
        NSUInteger end = NSMaxRange(old);
        for (NSUInteger i = old.location; i <= end && i < map.count; i++) map[i] = @(to);
    };

    NSMutableString *fixed = [NSMutableString stringWithCapacity:m.length];
    [m enumerateSubstringsInRange:NSMakeRange(0, m.length)
                          options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString * _Nullable sub, NSRange subRange, NSRange enclosingRange, BOOL * stop){
        if (!sub) return;
        unichar c0 = [sub characterAtIndex:0];

        // 控制字符：直接丢弃
        if (sub.length == 1 && [cc characterIsMember:c0]) {
            markRangeTo(subRange, newIdx);
            inBidiRun = NO;
            hadCtrl = YES;
            return;
        }
        
        // bidi
        if (sub.length == 1 && [bidi characterIsMember:c0]) {
            markRangeTo(subRange, newIdx);
            if (!inBidiRun && bidiKept < kJKRMaxBidiTotal) {
                [fixed appendString:sub];
                bidiKept++;
                newIdx += sub.length;
                NSUInteger end = NSMaxRange(subRange);
                if (end < map.count) map[end] = @(newIdx);
                inBidiRun = YES;
            } else {
                // 折叠（同一 run 内第2个及以后）或超额：丢弃（不前进 newIdx）
                hadMoreBidi = YES;
            }
            return;
        } else {
            inBidiRun = NO;
        }
        
        // 孤立代理 -> U+FFFD
        if (sub.length == 1 && (jkrIsHighSur(c0) || jkrIsLowSur(c0))) {
            inBidiRun = NO;
            markRangeTo(subRange, newIdx);
            [fixed appendString:@"\uFFFD"];
            hadSur = YES;
            newIdx += 1;
            NSUInteger end = NSMaxRange(subRange);
            if (end < map.count) map[end] = @(newIdx);
            return;
        }
        
        // 零宽：限额内保留，否则丢弃（丢弃时不要前进 newIdx）
        if ([zw characterIsMember:c0]) {
            inBidiRun = NO;
            markRangeTo(subRange, newIdx);
            if (zeroWidthKept < kJKRMaxZeroWidthTotal) {
                [fixed appendString:sub];
                zeroWidthKept++;
                newIdx += sub.length;
                // 修正端点映射
                NSUInteger end = NSMaxRange(subRange);
                if (end < map.count) map[end] = @(newIdx);
            } else {
                hadMoreZero = YES;
            }
            return;
        }
        // 组合记号：与上面逻辑一致，但维护索引映射；无 base → 优先回粘
        inBidiRun = NO;
        markRangeTo(subRange, newIdx);
        {
            BOOL noBase = NO, truncated = NO;
            NSString *limited = JKRLimitCombiningInCluster(sub, comb, kJKRMaxCombiningPerCluster, &noBase, &truncated);
            if (noBase) {
                BOOL reattached = NO;
                if (fixed.length > 0) {
                    unichar prev = [fixed characterAtIndex:fixed.length - 1];
                    if (JKRIsArabicBaseOrTatweel(prev)) {
                        NSUInteger existing = JKRTrailingCombiningCount(fixed, comb);
                        if (existing < kJKRMaxCombiningPerCluster) {
                            NSUInteger capacity = kJKRMaxCombiningPerCluster - existing;
//                            NSString *marks = JKRCombiningLimitedPrefix(sub, comb, capacity);
                            NSUInteger prefix = JKRLeadingCombiningCount(sub, comb);
                            NSString *marks = JKRCombiningLimitedPrefix(sub, comb, capacity);
                            if (marks.length > 0) {
                                [fixed appendString:marks];
                                newIdx += marks.length;
//                                if (marks.length < MIN(sub.length, capacity)) hadMoreComb = YES;
                                if (prefix > capacity) hadMoreComb = YES;
                                reattached = YES;
                            }
                        }
                    }
                }
                if (!reattached) {
                    hadSur = YES;
                    [fixed appendString:@"\uFFFD"];
                    newIdx += 1;
                }
            } else {
                if (truncated) hadMoreComb = YES;
                [fixed appendString:limited];
                newIdx += limited.length;
            }
            // 修正端点映射
            NSUInteger end = NSMaxRange(subRange);
            if (end < map.count) map[end] = @(newIdx);
        }
        
        inBidiRun = NO;
        return;
    }];
    st.hadCtrl = hadCtrl;
    st.hadSur = hadSur;
    st.hadMoreBidi = hadMoreBidi;
    st.hadMoreZero = hadMoreZero;
    st.hadMoreComb = hadMoreComb;

    st.len1 = fixed.length;

    if (statOut) *statOut = st;
    // 最终端点：确保 oldLen 的端点映射到 newLen，避免最后一段出现 end==start
    if (map.count > 0) {
        NSUInteger oldLen = s.length;
        if (oldLen < map.count) map[oldLen] = @(fixed.length);
    }
    if (mapOut) *mapOut = map;
    
    NSString *res = fixed.copy;
    res.jkr_isSafeString = YES;
    return res;
}

/// 把旧串区间 oldR 映射到新串，使用 old->new 的 UTF16 索引映射表 map（长度应为 origLen+1）
/// - Parameters:
///   - oldR: 旧区间（基于原 attributed string 的 UTF-16）
///   - map:  索引映射表，map[i] 表示旧索引 i 在新串中的索引（已做 maxLen 钳制）
///   - newLen: 新串长度（san.length）
///   - out: 成功时输出的新区间
/// - Returns: 是否有效（true 表示 out 可用）
static inline BOOL JKRMapRangeSafely(NSRange oldR,
                                     NSArray<NSNumber *> *map,
                                     NSUInteger newLen,
                                     NSRange *out)
{
    // 1) 旧区间自检：location/length 都有限且 NSMaxRange 不越界
    if (oldR.location == NSNotFound) return NO;
    // 防止 NSMaxRange 溢出
    if (oldR.length > NSUIntegerMax - oldR.location) return NO;

    NSUInteger oldEnd = oldR.location + oldR.length; // == NSMaxRange(oldR)

    // 2) map 边界：长度至少为 origLen+1，索引访问都要夹紧到 [0, map.count-1]
    if (map.count == 0) return NO;
    NSUInteger maxMapIdx = map.count - 1;

    NSUInteger clampedStartIdx = oldR.location > maxMapIdx ? maxMapIdx : oldR.location;
    NSUInteger clampedEndIdx   = oldEnd      > maxMapIdx ? maxMapIdx : oldEnd;

    // 3) 取映射值，并对 newLen 再做一次夹紧（maxLen 截断后，map 值可能等于 maxLen）
    NSUInteger start = ((NSNumber *)map[clampedStartIdx]).unsignedIntegerValue;
    NSUInteger end   = ((NSNumber *)map[clampedEndIdx]).unsignedIntegerValue;

    if (start > newLen) start = newLen;
    if (end   > newLen) end   = newLen;

    // 4) 生成新区间；若为空或逆序则无效（允许 start==end 视为“无内容”，可选择跳过）
    if (end <= start) return NO;

    if (out) *out = NSMakeRange(start, end - start);
    return YES;
}

NSAttributedString * JKRSanitizeAttributedString(NSAttributedString *attr, JKRTextSanitizeStat *st) {
    if (!attr) return nil;
    // 0) 备份“全部属性区间”
    NSMutableArray<NSDictionary *> *attrRuns = [NSMutableArray array];
    [attr enumerateAttributesInRange:NSMakeRange(0, attr.length) options:0 usingBlock:^(NSDictionary<NSAttributedStringKey,id> *attrs, NSRange range, BOOL *stop) {
        [attrRuns addObject:@{ @"range": [NSValue valueWithRange:range],
                               @"attrs": attrs ?: @{} }];
    }];
    
    // 1) 清洗 + 构建旧->新索引映射
    JKRTextSanitizeStat stPlain = {0};
    NSMutableArray<NSNumber *> *map = nil;
    NSString *san = JKRSanitizePlainStringWithMap(attr.string, &stPlain, &map);
    // 2) 基于清洗后的文本“新建”可变富文本（避免 setString 导致的旧区间漂移/合并）
    NSMutableAttributedString *m = [[NSMutableAttributedString alloc] initWithString:san ?: @""];

    if (st) {
        st->hadCtrl |= stPlain.hadCtrl;
        st->hadSur |= stPlain.hadSur;
        st->hadMoreZero |= stPlain.hadMoreZero;
        st->hadMoreBidi |= stPlain.hadMoreBidi;
        st->hadMoreComb |= stPlain.hadMoreComb;
        st->len0 = stPlain.len0;
        st->len1 = stPlain.len1;
    }
    
    // 3) 全属性“重放”：对每段 attrs 做容错修复后，映射到新串区间并 addAttributes
    for (NSDictionary *run in attrRuns) {
        NSRange oldR = [run[@"range"] rangeValue];
        NSDictionary *oldAttrs = run[@"attrs"] ?: @{};
        NSRange newR;
        if (!JKRMapRangeSafely(oldR, map, m.length, &newR)) continue;
        
        // 修复容错（字体/颜色/kerning/段落等）
        BOOL fFix=NO, kFix=NO, bFix=NO, cFix=NO, sFix=NO, pFix=NO;
        NSDictionary *safeAttrs = jkr_localFixAttributes(oldAttrs, &fFix, &kFix, &bFix, &cFix, &sFix, &pFix);
        if (st) {
            if (fFix) st->fontFix = YES;
            if (kFix) st->kernFix = YES;
            if (bFix) st->baseFix = YES;
            if (cFix) st->colorFix = YES;
            if (sFix) st->strokeWidthFix = YES;
            if (pFix) st->paraFix = YES;
        }
        if (safeAttrs.count > 0) {
            [m addAttributes:safeAttrs range:newR];
        }
    }
    
    NSAttributedString *res = [m copy];
    res.jkr_isSafeString = YES;
    return res;
}

NSAttributedString * JKRSanitizeAttributedStringEasy(NSAttributedString *attr) {
    JKRTextSanitizeStat st = {0};
    return JKRSanitizeAttributedString(attr, &st);
}

BOOL jkr_isSafe(JKRTextSanitizeStat st) {
    if (st.len0 != st.len1 || st.hadCtrl || st.hadSur || st.hadMoreZero || st.hadMoreBidi || st.hadMoreComb || st.fontFix || st.kernFix || st.baseFix || st.colorFix || st.strokeWidthFix || st.paraFix) {
        JKRTextSafetyLog(@"[CTS] 文本清洗检测到不安全字符串:\n");
        if (st.hadCtrl) {
            JKRTextSafetyLog(@"[CTS] 包含控制字符\n");
        }
        if (st.hadSur) {
            JKRTextSafetyLog(@"[CTS] 包含孤立代理项\n");
        }
        if (st.hadMoreZero) {
            JKRTextSafetyLog(@"[CTS] 包含多余零宽字符\n");
        }
        if (st.hadMoreBidi) {
            JKRTextSafetyLog(@"[CTS] 包含多余或不规范的方向控制\n");
        }
        if (st.hadMoreComb) {
            JKRTextSafetyLog(@"[CTS] 包含多余组合记号\n");
        }
        if (st.fontFix) {
            JKRTextSafetyLog(@"[CTS] 包含非法字体\n");
        }
        if (st.kernFix) {
            JKRTextSafetyLog(@"[CTS] 包含非法字距\n");
        }
        if (st.baseFix) {
            JKRTextSafetyLog(@"[CTS] 包含非法基线偏移\n");
        }
        if (st.colorFix) {
            JKRTextSafetyLog(@"[CTS] 包含非法颜色\n");
        }
        if (st.strokeWidthFix) {
            JKRTextSafetyLog(@"[CTS] 包含非法描边\n");
        }
        if (st.paraFix) {
            JKRTextSafetyLog(@"[CTS] 包含非法段落样式\n");
        }
        if (st.len0 != st.len1) {
            JKRTextSafetyLog(@"[CTS] 修正长度对比 %lu - %lu\n", (unsigned long)st.len0, st.len1);
        }
        return NO;
    }
    return YES;
}

CGSize JKRFixMeasureSize(CGSize sz){
    CGFloat w = (jkrFinite(sz.width)  && sz.width  > 0) ? MIN(sz.width,  100000.0) : 100000.0;
    CGFloat h = (jkrFinite(sz.height) && sz.height > 0) ? MIN(sz.height, 100000.0) : 100000.0;
    return (CGSize){w,h};
}


@implementation NSString (JKRSafeCheck)

- (BOOL)jkr_isSafeString {
    return [objc_getAssociatedObject(self, _cmd) boolValue];
}

- (void)setJkr_isSafeString:(BOOL)jkr_isSafeString {
    SEL key = @selector(jkr_isSafeString);
    objc_setAssociatedObject(self, key, @(jkr_isSafeString), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end


@implementation NSAttributedString (JKRSafeCheck)

- (BOOL)jkr_isSafeString {
    return [objc_getAssociatedObject(self, _cmd) boolValue];
}

- (void)setJkr_isSafeString:(BOOL)jkr_isSafeString {
    SEL key = @selector(jkr_isSafeString);
    objc_setAssociatedObject(self, key, @(jkr_isSafeString), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
