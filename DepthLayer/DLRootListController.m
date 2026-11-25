#import <Preferences/PSListController.h>

@interface DLRootListController : PSListController
@end

@implementation DLRootListController
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}
@end
