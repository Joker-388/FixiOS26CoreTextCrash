//
//  NSString+JKRTextBoundingSafetyGlobal.m
//  JKRFixiOS26CoreTextCrash
//
//  Created by 胡怀刈 on 2025/9/18.
//

#import "NSString+JKRTextBoundingSafetyGlobal.h"
#import "JKRTextSafetyShared.h"
#import <objc/runtime.h>

static void jkr_exchange(Class c, SEL a, SEL b){
    Method m1 = class_getInstanceMethod(c, a);
    Method m2 = class_getInstanceMethod(c, b);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

@implementation NSString (JKRTextBoundingSafetyGlobal)

- (CGRect)jkr_boundingRectWithSize:(CGSize)size
                           options:(NSStringDrawingOptions)opts
                        attributes:(NSDictionary<NSAttributedStringKey,id> *)attrs
                           context:(NSStringDrawingContext *)context {
    CGSize safeSize = JKRFixMeasureSize(size);
    if (self.length == 0) {
        return [self jkr_boundingRectWithSize:size options:opts attributes:attrs context:context];;
    }
    
    if (self.jkr_isSafeString) {
        // 清洗文本 + 修复属性（本地修复函数返回各命中位，若需要上报可在此聚合）
        BOOL fontFix = NO, kernFix = NO, baseFix = NO, colorFix = NO, strokeWidthFix = NO, paraFix = NO;
        NSDictionary *fixedAttrs = jkr_localFixAttributes(attrs, &fontFix, &kernFix, &baseFix, &colorFix, &strokeWidthFix, &paraFix);
        if (fontFix || kernFix || baseFix || colorFix || strokeWidthFix || paraFix) {
            JKRTextSafetyLog(@"[CTS] 计算bound捕捉到不安全字符串");
            return [self jkr_boundingRectWithSize:safeSize options:opts attributes:fixedAttrs context:context];
        } else {
            return [self jkr_boundingRectWithSize:safeSize options:opts attributes:attrs context:context];
        }
    }
    
    // 清洗文本 + 修复属性（本地修复函数返回各命中位，若需要上报可在此聚合）
    BOOL fontFix = NO, kernFix = NO, baseFix = NO, colorFix = NO, strokeWidthFix = NO, paraFix = NO;
    JKRTextSanitizeStat st = {0};
    NSString *san = JKRSanitizePlainString(self, &st);
    NSDictionary *fixedAttrs = jkr_localFixAttributes(attrs, &fontFix, &kernFix, &baseFix, &colorFix, &strokeWidthFix, &paraFix);
    
    st.fontFix |= fontFix;
    st.kernFix |= kernFix;
    st.baseFix |= baseFix;
    st.colorFix |= colorFix;
    st.strokeWidthFix |= strokeWidthFix;
    st.paraFix |= paraFix;
    
    if (jkr_isSafe(st) == NO) {
        JKRTextSafetyLog(@"[CTS] 计算bound: string捕捉到不安全字符串");
        return [san jkr_boundingRectWithSize:safeSize options:opts attributes:fixedAttrs context:context];
    } else {
        return [self jkr_boundingRectWithSize:safeSize options:opts attributes:attrs context:context];
    }
}

- (BOOL)jkr_isSafeString {
    return [objc_getAssociatedObject(self, _cmd) boolValue];
}

- (void)setJkr_isSafeString:(BOOL)jkr_isSafeString {
    SEL key = @selector(jkr_isSafeString);
    objc_setAssociatedObject(self, key, @(jkr_isSafeString), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

@implementation NSAttributedString (JKRTextBoundingSafetyGlobal)

- (CGRect)jkr_boundingRectWithSize:(CGSize)size
                           options:(NSStringDrawingOptions)opts
                           context:(NSStringDrawingContext *)context {
    if (self.length == 0) {
        return [self jkr_boundingRectWithSize:size options:opts context:context];
    }
    
    CGSize safeSize = JKRFixMeasureSize(size);
    
    if (self.jkr_isSafeString) {
        return [self jkr_boundingRectWithSize:safeSize options:opts context:context];
    }

    JKRTextSanitizeStat st = {0};
    NSAttributedString *m = JKRSanitizeAttributedString(self, &st);
    if (jkr_isSafe(st) == NO) {
        JKRTextSafetyLog(@"[CTS] 计算bound: attrstring捕捉到不安全字符串");
        return [m jkr_boundingRectWithSize:safeSize options:opts context:context];
    } else {
        return [self jkr_boundingRectWithSize:safeSize options:opts context:context];;
    }
}

@end

void JKRInstallTextBoundingSafety(void){
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        jkr_exchange(NSString.class,
                     @selector(boundingRectWithSize:options:attributes:context:),
                     @selector(jkr_boundingRectWithSize:options:attributes:context:));
        jkr_exchange(NSAttributedString.class,
                     @selector(boundingRectWithSize:options:context:),
                     @selector(jkr_boundingRectWithSize:options:context:));
    });
}
