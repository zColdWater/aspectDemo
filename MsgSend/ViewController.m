#import "ViewController.h"
#import <Aspects/Aspects.h>

@interface ViewController ()
@end

@implementation ViewController

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSLog(@"original viewWillAppear");
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 写在前面
    // 本Demo未加gitignore，不对Pod文件夹做屏蔽，因为我在Pod文件夹里面的源文件增加了自己的注释理解
    // 直接 CMD + 点击你要看的Aspect方法 即可
    // 可以结合文章来看 https://zcoldwater.github.io/blog/article/ios/aspect/
    id<AspectToken> token = [ViewController aspect_hookSelector:@selector(viewWillAppear:) withOptions:AspectPositionAfter usingBlock:^(id<AspectInfo> aspectInfo, BOOL animation) {
        NSLog(@"hook viewWillAppear");
    } error:NULL];
    
    // 移除对目标函数的Hook
    // [token remove];
}

@end
