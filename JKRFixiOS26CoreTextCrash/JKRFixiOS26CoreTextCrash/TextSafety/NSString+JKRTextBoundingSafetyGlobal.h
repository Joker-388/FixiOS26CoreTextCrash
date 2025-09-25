//
//  NSString+JKRTextBoundingSafetyGlobal.h
//  JKRFixiOS26CoreTextCrash
//
//  Created by 胡怀刈 on 2025/9/18.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 安装全局 NSString / NSAttributedString 安全文本测量兜底（仅在你调用时启用）
/// - swizzle: -[NSString boundingRectWithSize:options:attributes:context:]
///           -[NSAttributedString boundingRectWithSize:options:context:]
void JKRInstallTextBoundingSafety(void);

@interface NSString (JKRTextBoundingSafetyGlobal)

//- (CGRect)jkr_boundingRectWithSize:(CGSize)size
//                           options:(NSStringDrawingOptions)opts
//                        attributes:(nullable NSDictionary<NSAttributedStringKey,id> *)attrs
//                           context:(nullable NSStringDrawingContext *)context;

//@property (nonatomic) BOOL jkr_isSafeString;

@end


@interface NSAttributedString (JKRTextBoundingSafetyGlobal)

//- (CGRect)jkr_boundingRectWithSize:(CGSize)size
//                           options:(NSStringDrawingOptions)opts
//                           context:(nullable NSStringDrawingContext *)context;

//@property (nonatomic) BOOL jkr_isSafeString;

@end


NS_ASSUME_NONNULL_END
