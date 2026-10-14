//
//  RMPickers.m — 从相册（PHPicker）或文件（UIDocumentPicker）选图
//

#import "RMCommon.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static char kRMDelegateRetain;

@interface RMPickerDelegate : NSObject <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, weak) UIViewController *owner;
@property (nonatomic, copy) NSString *page;
@property (nonatomic, copy) NSString *key;
@end

@implementation RMPickerDelegate

- (void)finishWithImage:(UIImage *)image {
    if (!image) return;
    [[RMStore shared] saveIconImage:image page:self.page key:self.key];
    RMRefresh(self.owner);
}

#pragma mark - 相册（PHPicker，无需相册权限）

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *res = results.firstObject;
    if (!res) return;
    NSString *type = [res.itemProvider registeredTypeIdentifiers].firstObject;
    if (!type.length) type = @"public.image";
    __weak typeof(self) wself = self;
    [res.itemProvider loadItemForTypeIdentifier:type
                                        options:nil
                              completionHandler:^(id<NSSecureCoding> _Nullable item, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(wself) sself = wself;
            if (!sself) return;
            id obj = (id)item;
            UIImage *img = nil;
            if ([obj isKindOfClass:[UIImage class]]) {
                img = obj;
            } else if ([obj isKindOfClass:[NSURL class]]) {
                img = [UIImage imageWithContentsOfFile:[(NSURL *)obj path]];
            } else if ([obj isKindOfClass:[NSData class]]) {
                img = [UIImage imageWithData:(NSData *)obj];
            }
            [sself finishWithImage:img];
        });
    }];
}

#pragma mark - 文件（UIDocumentPicker）

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [controller dismissViewControllerAnimated:YES completion:nil];
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    UIImage *img = [UIImage imageWithContentsOfFile:url.path];
    if (scoped) [url stopAccessingSecurityScopedResource];
    [self finishWithImage:img];
}

@end

@implementation RMPickHelper

+ (void)presentImagePickerFromVC:(UIViewController *)vc
                            page:(NSString *)page
                             key:(NSString *)key
                          source:(RMPickSource)source {
    if (!vc || vc.presentedViewController) return;

    RMPickerDelegate *d = [[RMPickerDelegate alloc] init];
    d.owner = vc;
    d.page = page;
    d.key = key;
    // 挂在 VC 上保活，选完即释放
    objc_setAssociatedObject(vc, &kRMDelegateRetain, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIViewController *target = nil;
    if (source == RMPickSourcePhotos) {
        PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
        cfg.filter = [PHPickerFilter imagesFilter];
        cfg.selectionLimit = 1;
        PHPickerViewController *pv = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        pv.delegate = d;
        target = pv;
    } else {
        UTType *imageType = [UTType typeWithIdentifier:@"public.image"];
        UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[imageType]];
        dp.delegate = d;
        target = dp;
    }
    if (target) [vc presentViewController:target animated:YES completion:nil];
}

@end
