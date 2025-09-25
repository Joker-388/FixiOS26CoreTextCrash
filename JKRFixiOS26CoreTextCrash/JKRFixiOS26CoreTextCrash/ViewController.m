//
//  ViewController.m
//  JKRFixiOS26CoreTextCrash
//
//  Created by 胡怀刈 on 2025/9/25.
//

#import "ViewController.h"
#import "JKRTextSafetyShared.h"

@interface ViewController ()

@property (weak, nonatomic) IBOutlet UISwitch *isSafeCheckSwitch;

@property (weak, nonatomic) IBOutlet UILabel *showLabel;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    
}

- (IBAction)showbuttonClick:(UIButton *)sender {
    NSString *originString = @"©️➦☠️&nbsp;‌▓‌▓‌⚜  ☠‌️🔯🔯🕉️🕉️🌹⃞⃟🌹⃞⃟🌹⃞⃟🌹⃞⃟🌹⃞⃟🌹⃞⃟🌹⃞⃟🌹⃞⃟🌹⃞⃟⃞⃟🌹⃞⃟🌹⃞⃟📴⃞⃟📴⃞⃟📴⃞⃟📴⃞⃟📴⃞⃟📴⃞⃟📴⃞⃟📴⃞⃞👨‍✈️⃞⃟👨‍✈️⃞⃟👨‍✈️⃞⃟👨‍✈️⃞⃟👨‍✈️⃞⃟👨‍✈️⃞⃟👨‍✈️⃞⃟⃞✑ۦ᳗⃛‌᳗⃛⃛⃛⃛⃛❍ۦ᳕⃛❍⃛‌⃛✑✅VIP✅;‌᳕᪺‌✑ۦ᪷᳗⃛⃛❍⃛‌⃛⃛‌ ;᳗⃛❍⃛‌⃛⃛‌ ;‌ۦ᪷‌᳗⃛⃛ۦ❍⃛‌⃛✑``᪺‌;‌᳕᪺‌✑ۦ᪷᳗⃛⃛C✅❍⃛‌⃛⃛‌;‌⃛⃛ۦ᪷᳗⃛⃛⃛ۦۦ᳕⃛‌⃛⃛ۦ᳕⃛❍‌᳗⃛✑``᪺‌@⃙᳕᪺‌✑ۦ᳗⃛‌᳗⃛⃛⃛⃛⃛❍ۦ᳕⃛❍⃛‌⃛✑ⁿ;‌᳕᪺‌✑ۦ᪷᳗⃛⃛❍⃛‌⃛⃛‌ ;᳗⃛❍⃛‌⃛⃛‌ ;‌ۦ᪷‌᳗⃛⃛ۦ᳕لٜٜٜٜٜٜٜٜٜٖٜٜٜٜٜٜٜᬼ‌ٜٜٜٜٜٜٜٜٜٜٜٜٜٜٜٜٜٖᬼ‌ٜٜٜٜٜٜٜٜٜٖی کٜٜٜٜٜٜٜٜٖᬼ‌ٜٜٜٜٜٜٜٜٜٖٜٜٜٜٜٜٜٜٖᬼ‌ٜٜٜٜم✿‌߷ًًًًٍٍٍْْْٖٖٖٓٓٓٓ‌༅࿆༅‌لٜٜٜٜٜٜٜٜٜٖٜٜٜٜٜٜٜٜٖᬼ‌ٜٜٜٜٜٜٜٜٜٜٜٜٜٜٜٜ کٜٜٜٜٜٜٜᬼ‌ٜٜٜٜٜٜٜٜٜٖٜٜٜٜٜٜٜٜٖᬼ‌ٜٜٜٜٜٜٜ ߷ًًًًٍٍٍْْْٖٖٖ༎ྃالٜٜٜٜٜٜٜٜٜٖٜٜٜٜٜٜٜٜٖᬼ‌ٜٜٜٜٜٜٜٜٜٜٜٜٜٜٜٜF҉‌҉‌҉‌҉‌҉ B҉‌҉‌҉‌҉‌҉·҉˚҉™҉༘҉ᬼ‌ٜٜٜٜٜٜٜٜٜکٜٜٜٜٜٜٜᬼ‌ٜٜٜٜٜٜٜٜٜٖٜٜٜٜٜٜٜٜٖᬼ‌ٜٜٜٜٜVIP لام✿‌߷ًًًًٍٍٍْْْٖٖٖٓٓٓٓ‌༎ྃྂ༅‌الٜٜٜٜٜٜٜٜٜٖٜٜٜٜٜٜٜٜٖᬼ‌ٜٜٜٜٜٜٜٜٜٜٜٜٜٜٜٜٜٖᬼ‌ٜٜٜٜٜٜٜٜٜٖF҉‌҉‌҉‌҉‌҉ B҉‌҉‌҉‌҉‌҉·҉˚҉™҉༘҉ VIPکٜٜٜٜٜٜٜٜٖᬼ‌ٜٜٜٜٜٜٜٜٜٖٜٜٜٜٜٜٜٜٖᬼ‌ٜٜٜٜٜٜٜٜی💊⃞⃟💊⃞⃟💊⃞⃟💊⃞⃟💊⃞⃟💊⃞⃟💊⃞⃟💊⃞⃟💊⃞⃟💊⃞⃟A⃞⃟🔏⃞⃟🔏⃞⃟";
    
    if (self.isSafeCheckSwitch.isOn) {
        originString = JKRSanitizePlainStringEasy(originString);
    }
    
    self.showLabel.text = originString;
}

@end
