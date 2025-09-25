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
static const NSUInteger kJKRMaxBibiTotal           = 8;   // 全文最大bibi数量
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
        // 可选：把 U+2028/U+2029 也当控制： [m addCharactersInRange:NSMakeRange(0x2028, 2)];
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
                // LRM/RLM + LRE/RLE/LRO/RLO/PDF + LRI/RLI/FSI/PDI
                @"\u200E\u200F\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069"];
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
        [m addCharactersInRange:NSMakeRange(0x0610, 0x0B)];   // 0610–061A
        [m addCharactersInRange:NSMakeRange(0x064B, 0x15)];   // 064B–065F
        [m addCharactersInRange:NSMakeRange(0x0670, 0x01)];   // 0670
        [m addCharactersInRange:NSMakeRange(0x06D6, 0x18)];   // 06D6–06ED
        set = [m copy];
    });
    return set;
}

// 常见零宽字符：ZWSP/ZWNJ/ZWJ/WORD JOINER/BOM
static NSCharacterSet *JKRSetZeroWidth(void) {
    static NSCharacterSet *set; static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSCharacterSet characterSetWithCharactersInString:
               @"\u200B\u200C\u200D\u2060\uFEFF"];
    });
    return set;
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
            if (fontFix) {
                *fontFix = YES;
            }
            changed = YES;
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
    NSCharacterSet *bibi = JKRSetBidi();
    NSCharacterSet *comb = JKRSetCombining();
    NSCharacterSet *zw   = JKRSetZeroWidth();
    
    __block BOOL hadSur = NO;
    __block BOOL hadCtrl = NO;
    __block BOOL hadMoreBibi = NO;
    __block BOOL hadMoreZero = NO;
    
    __block NSUInteger bibiKept = 0;         // 全文保留的bibi数量
    __block NSUInteger combiningRun = 0;     // 当前簇内连续 Mn/Me 计数
    __block BOOL haveBaseInCluster = NO;     // 当前簇是否已有 base
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
            hadCtrl = YES;
            return;
        }
        
        // bibi
        if (sub.length == 1 && [bibi characterIsMember:c0]) {
            if (bibiKept < kJKRMaxBibiTotal) {
                [fixed appendString:sub];
                bibiKept++;
            } else {
                hadMoreBibi = YES;
            }
            return;
        }
        
        // 孤立代理：直接替换为 U+FFFD（不改变簇状态）
        if (sub.length == 1) {
            if (jkrIsHighSur(c0) || jkrIsLowSur(c0)) {
                [fixed appendString:@"\uFFFD"];
                hadSur = YES;
                return;
            }
        }
        
        // 零宽字符：全局限额，超过后丢弃；零宽不改变簇的 base/combining 状态
        if ([zw characterIsMember:c0]) {
            if (zeroWidthKept < kJKRMaxZeroWidthTotal) {
                [fixed appendString:sub];
                zeroWidthKept++;
            } else {
                // 超额丢弃
                hadMoreZero = YES;
            }
            return;
        }
        
        // 组合附加记号（Mn/Me）：必须挂在已有 base 后；簇内限额
        BOOL isComb = (sub.length == 1) && [comb characterIsMember:c0];
        if (isComb) {
            if (!haveBaseInCluster) {
                // 簇首为 Mn/Me：用 U+FFFD 顶一下，避免 CoreText 组合器对无 base 的堆叠失控
                [fixed appendString:@"\uFFFD"];
                hadSur = YES;
                return;
            }
            if (combiningRun < kJKRMaxCombiningPerCluster) {
                [fixed appendString:sub];
                combiningRun++;
            } else {
                // 超额丢弃
                hadMoreZero = YES;
            }
            return;
        }
        
        // 4) 普通字素（含多 code unit 的 emoji 等）：作为新簇 base，重置计数
        [fixed appendString:sub];
        haveBaseInCluster = YES;
        combiningRun = 0;
    }];
    st.hadCtrl = hadCtrl;
    st.hadSur = hadSur;
    st.hadMoreBibi = hadMoreBibi;
    st.hadMoreZero = hadMoreZero;

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
    NSCharacterSet *bibi = JKRSetBidi();
    NSCharacterSet *comb = JKRSetCombining();
    NSCharacterSet *zw   = JKRSetZeroWidth();
    
    __block BOOL hadSur = NO;
    __block BOOL hadCtrl = NO;
    __block BOOL hadMoreBibi = NO;
    __block BOOL hadMoreZero = NO;
    
    __block NSUInteger bibiKept = 0;         // 全文保留的bibi数量
    __block NSUInteger combiningRun = 0;     // 当前簇内连续 Mn/Me 计数
    __block BOOL haveBaseInCluster = NO;     // 当前簇是否已有 base
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
            hadCtrl = YES;
            return;
        }
        
        // bibi
        if (sub.length == 1 && [bibi characterIsMember:c0]) {
            markRangeTo(subRange, newIdx);
            if (bibiKept < kJKRMaxBibiTotal) {
                [fixed appendString:sub];
                bibiKept++;
                newIdx += sub.length;
                // 修正端点映射：将 old 的 end 指到 “追加后”的 newIdx
                NSUInteger end = NSMaxRange(subRange);
                if (end < map.count) map[end] = @(newIdx);
            } else {
                hadMoreBibi = YES;
            }
            return;
        }
        
        // 孤立代理 -> U+FFFD
        if (sub.length == 1 && (jkrIsHighSur(c0) || jkrIsLowSur(c0))) {
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
        // 组合记号
        BOOL isComb = (sub.length == 1) && [comb characterIsMember:c0];
        if (isComb) {
            markRangeTo(subRange, newIdx);
            if (!haveBaseInCluster) {
                // 无 base：顶 U+FFFD
                [fixed appendString:@"\uFFFD"];
                hadSur = YES;
                newIdx += 1;
                // 修正端点映射
                NSUInteger end = NSMaxRange(subRange);
                if (end < map.count) map[end] = @(newIdx);
                return;
            }
            if (combiningRun < kJKRMaxCombiningPerCluster) {
                [fixed appendString:sub];
                combiningRun++;
                newIdx += sub.length;
                // 修正端点映射
                NSUInteger end = NSMaxRange(subRange);
                if (end < map.count) map[end] = @(newIdx);
            } else {
                hadMoreZero = YES;
            }
            return;
        }
        // 普通 base
        markRangeTo(subRange, newIdx);
        [fixed appendString:sub];
        newIdx += sub.length;
        haveBaseInCluster = YES;
        combiningRun = 0;
        // 修正端点映射
        NSUInteger end = NSMaxRange(subRange);
        if (end < map.count) map[end] = @(newIdx);
    }];
    st.hadCtrl = hadCtrl;
    st.hadSur = hadSur;
    st.hadMoreBibi = hadMoreBibi;
    st.hadMoreZero = hadMoreZero;

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
        st->hadMoreBibi |= stPlain.hadMoreBibi;
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
    if (st.len0 != st.len1 || st.hadCtrl || st.hadSur || st.hadMoreZero || st.hadMoreBibi || st.fontFix || st.kernFix || st.baseFix || st.colorFix || st.strokeWidthFix || st.paraFix) {
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
        if (st.hadMoreBibi) {
            JKRTextSafetyLog(@"[CTS] 包含多余方向控制\n");
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
