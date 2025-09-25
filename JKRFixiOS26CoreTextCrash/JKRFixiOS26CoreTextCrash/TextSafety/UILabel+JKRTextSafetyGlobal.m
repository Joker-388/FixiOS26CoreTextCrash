//
//  UILabel+JKRTextSafetyGlobal.m
//  JKRFixiOS26CoreTextCrash
//
//  Created by 胡怀刈 on 2025/9/18.
//

#import "UILabel+JKRTextSafetyGlobal.h"
#import <objc/runtime.h>
#import <pthread.h>
#import <sys/utsname.h>
#import "JKRTextSafetyShared.h"

static inline BOOL jkr_is_finite(CGFloat v){ return isfinite(v); }
static void jkr_exchange(Class c, SEL a, SEL b){
    Method m1 = class_getInstanceMethod(c, a);
    Method m2 = class_getInstanceMethod(c, b);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

@implementation UILabel (JKRTextSafetyGlobal)

- (void)jkr_setText:(NSString *)text {
    void (^apply)(void) = ^{
        JKRTextSanitizeStat st = {0};
        
        if (text.jkr_isSafeString) {
            [self jkr_setText:text];
            return;
        }
        
        if (!(jkr_is_finite(self.font.pointSize) && self.font.pointSize > 0)) {
            self.font = [UIFont systemFontOfSize:JKRDefaultFontPt];
            st.fontFix = YES;
        }
        if ((self.text == text) || (text && [self.text isEqualToString:text])) {
            [self jkr_setText:text];
            return;
        }

        NSString *safe = JKRSanitizePlainString(text, &st);
        safe.jkr_isSafeString = YES;
        [self jkr_setText:safe];
        // 需要上报的话，这里用 st
        if (jkr_isSafe(st) == NO) {
            JKRTextSafetyLog(@"[CTS] setText修正前:%@", text);
            JKRTextSafetyLog(@"[CTS] setText修正后:%@", safe);
        }
    };
    if (pthread_main_np()) apply(); else dispatch_async(dispatch_get_main_queue(), apply);
}

- (void)jkr_setAttributedText:(NSAttributedString *)attrText {
    void (^apply)(void) = ^{
        JKRTextSanitizeStat st = {0};
        
        if (attrText.jkr_isSafeString) {
            [self jkr_setAttributedText:attrText];
            return;
        }
        
        if (!(jkr_is_finite(self.font.pointSize) && self.font.pointSize > 0)) {
            self.font = [UIFont systemFontOfSize:JKRDefaultFontPt];
            st.fontFix = YES;
        }
        NSAttributedString *safe = JKRSanitizeAttributedString(attrText, &st);
        safe.jkr_isSafeString = YES;
        [self jkr_setAttributedText:safe];
        // 需要上报的话，这里用 st
        if (jkr_isSafe(st) == NO) {
            JKRTextSafetyLog(@"[CTS] setAttributedText修正前:%@", attrText);
            JKRTextSafetyLog(@"[CTS] setAttributedText修正后:%@", safe);
        }
    };
    if (pthread_main_np()) apply(); else dispatch_async(dispatch_get_main_queue(), apply);
}

//- (BOOL)printWithST:(JKRTextSanitizeStat)st {
//    if (st.hadCtrl || st.hadSur || st.hadMoreZero || st.hadMoreBibi || st.fontFix || st.kernFix || st.baseFix || st.colorFix || st.strokeWidthFix || st.paraFix || st.len0 != st.len1) {
//        JKRTextSafetyLog(@"[CTS] 文本设置捕捉到不安全字符串:\n");
//        if (st.hadCtrl) {
//            JKRTextSafetyLog(@"[CTS] 包含控制字符\n");
//        }
//        if (st.hadSur) {
//            JKRTextSafetyLog(@"[CTS] 包含孤立代理项\n");
//        }
//        if (st.hadMoreZero) {
//            JKRTextSafetyLog(@"[CTS] 包含多余零宽字符\n");
//        }
//        if (st.hadMoreBibi) {
//            JKRTextSafetyLog(@"[CTS] 包含多余方向控制\n");
//        }
//        if (st.fontFix) {
//            JKRTextSafetyLog(@"[CTS] 包含非法字体\n");
//        }
//        if (st.kernFix) {
//            JKRTextSafetyLog(@"[CTS] 包含非法字距\n");
//        }
//        if (st.baseFix) {
//            JKRTextSafetyLog(@"[CTS] 包含非法基线偏移\n");
//        }
//        if (st.colorFix) {
//            JKRTextSafetyLog(@"[CTS] 包含非法颜色\n");
//        }
//        if (st.strokeWidthFix) {
//            JKRTextSafetyLog(@"[CTS] 包含非法描边\n");
//        }
//        if (st.paraFix) {
//            JKRTextSafetyLog(@"[CTS] 包含非法段落样式\n");
//        }
//        if (st.len0 != st.len1) {
//            JKRTextSafetyLog(@"[CTS] 修正长度对比 %lu - %lu\n", (unsigned long)st.len0, st.len1);
//        }
//        return YES;
//    }
//    return NO;
//}

@end

void JKRInstallUILabelTextSafety(void){
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = UILabel.class;
        jkr_exchange(cls, @selector(setText:), @selector(jkr_setText:));
        jkr_exchange(cls, @selector(setAttributedText:), @selector(jkr_setAttributedText:));
    });
}
