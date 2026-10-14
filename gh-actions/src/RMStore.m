//
//  RMStore.m — 自定义数据持久化
//  DB:  /var/mobile/Library/Preferences/com.relaxin.entrymaster.plist
//  图标: /var/mobile/Library/Application Support/RelaxinEntryMaster/icons/
//
//  线程安全：PSListController 可能在后台线程加载 specifiers，
//  所有方法统一 @synchronized(self) 串行化，避免字典并发崩溃。
//

#import "RMCommon.h"

static NSString * const kDBPath  = @"/var/mobile/Library/Preferences/com.relaxin.entrymaster.plist";
static NSString * const kIconDir = @"/var/mobile/Library/Application Support/RelaxinEntryMaster/icons";

static NSMutableDictionary *RMMutDict(id v) {
    if ([v isKindOfClass:[NSMutableDictionary class]]) return v;
    if ([v isKindOfClass:[NSDictionary class]]) return [v mutableCopy];
    return [NSMutableDictionary dictionary];
}

@interface RMStore ()
- (NSMutableDictionary *)unsafeSection:(NSString *)name;
@end

@implementation RMStore {
    NSMutableDictionary *_db; // { names:{page:{key:name}}, icons:{page:{key:file}}, order:{page:[key...]}, meta:{...} }
}

+ (instancetype)shared {
    static RMStore *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[RMStore alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        @synchronized ([RMStore class]) {
            NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kDBPath];
            if (!d) d = [NSMutableDictionary dictionary];
            _db = d;
        }
    }
    return self;
}

- (void)save {
    [_db writeToFile:kDBPath atomically:YES];
}

- (NSMutableDictionary *)section:(NSString *)name {
    @synchronized (self) {
        _db[name] = RMMutDict(_db[name]);
        return _db[name];
    }
}

- (NSMutableDictionary *)pageDictInSection:(NSString *)section page:(NSString *)page {
    @synchronized (self) {
        NSMutableDictionary *sec = [self unsafeSection:section];
        sec[page] = RMMutDict(sec[page]);
        return sec[page];
    }
}

// 无锁版本（调用方已持有锁）
- (NSMutableDictionary *)unsafeSection:(NSString *)name {
    _db[name] = RMMutDict(_db[name]);
    return _db[name];
}

#pragma mark - 改名

- (NSString *)customNameForPage:(NSString *)page key:(NSString *)key {
    if (!page.length || !key.length) return nil;
    @synchronized (self) {
        id v = [self unsafeSection:@"names"][page];
        if ([v isKindOfClass:[NSDictionary class]]) {
            id n = v[key];
            if ([n isKindOfClass:[NSString class]] && ((NSString *)n).length) return n;
        }
        return nil;
    }
}

- (void)setCustomName:(NSString *)name page:(NSString *)page key:(NSString *)key {
    if (!page.length || !key.length) return;
    @synchronized (self) {
        NSMutableDictionary *d = [self unsafeSection:@"names"];
        NSMutableDictionary *pd = RMMutDict(d[page]);
        if (name.length) pd[key] = [name copy]; else [pd removeObjectForKey:key];
        d[page] = pd;
        [self save];
    }
}

- (BOOL)pageHasNames:(NSString *)page {
    if (!page.length) return NO;
    @synchronized (self) {
        id v = [self unsafeSection:@"names"][page];
        return [v isKindOfClass:[NSDictionary class]] && ((NSDictionary *)v).count > 0;
    }
}

- (void)clearNamesForPage:(NSString *)page {
    if (!page.length) return;
    @synchronized (self) {
        [[self unsafeSection:@"names"] removeObjectForKey:page];
        [self save];
    }
}

#pragma mark - 改图

- (NSString *)iconFileForPage:(NSString *)page key:(NSString *)key {
    if (!page.length || !key.length) return nil;
    @synchronized (self) {
        id v = [self unsafeSection:@"icons"][page];
        if ([v isKindOfClass:[NSDictionary class]]) {
            id f = v[key];
            if ([f isKindOfClass:[NSString class]] && ((NSString *)f).length) return f;
        }
        return nil;
    }
}

- (BOOL)hasIconForPage:(NSString *)page key:(NSString *)key {
    return [self iconFileForPage:page key:key] != nil;
}

- (UIImage *)iconImageForPage:(NSString *)page key:(NSString *)key {
    NSString *f = [self iconFileForPage:page key:key];
    if (!f) return nil;
    return [UIImage imageWithContentsOfFile:[kIconDir stringByAppendingPathComponent:f]];
}

- (void)saveIconImage:(UIImage *)image page:(NSString *)page key:(NSString *)key {
    if (!image || !page.length || !key.length) return;

    // 压到最长边 256，够用且省内存
    CGFloat maxSide = 256.0;
    CGSize sz = image.size;
    CGFloat scale = MIN(1.0, maxSide / MAX(MAX(sz.width, sz.height), 1.0));
    CGSize nsz = CGSizeMake(MAX(1.0, round(sz.width * scale)), MAX(1.0, round(sz.height * scale)));

    UIGraphicsImageRendererFormat *fmt = [[UIGraphicsImageRendererFormat alloc] init];
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:nsz format:fmt];
    UIImage *outImg = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, nsz.width, nsz.height)];
    }];

    NSData *png = UIImagePNGRepresentation(outImg);
    if (!png) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:kIconDir withIntermediateDirectories:YES attributes:nil error:nil]) return;

    NSString *fname = [NSString stringWithFormat:@"%@.png", [[NSUUID UUID] UUIDString].lowercaseString];
    if (![fm createFileAtPath:[kIconDir stringByAppendingPathComponent:fname] contents:png attributes:nil]) return;

    @synchronized (self) {
        NSMutableDictionary *d = [self unsafeSection:@"icons"];
        NSMutableDictionary *pd = RMMutDict(d[page]);
        pd[key] = fname;
        d[page] = pd;
        [self save];
    }
}

- (void)removeIconForPage:(NSString *)page key:(NSString *)key {
    NSString *f = nil;
    @synchronized (self) {
        f = [self iconFileForPage:page key:key];
        NSMutableDictionary *d = [self unsafeSection:@"icons"];
        NSMutableDictionary *pd = RMMutDict(d[page]);
        [pd removeObjectForKey:key];
        d[page] = pd;
        [self save];
    }
    if (f) [[NSFileManager defaultManager] removeItemAtPath:[kIconDir stringByAppendingPathComponent:f] error:nil];
}

#pragma mark - 排序

- (NSArray<NSString *> *)orderForPage:(NSString *)page {
    if (!page.length) return nil;
    @synchronized (self) {
        id v = [self unsafeSection:@"order"][page];
        if ([v isKindOfClass:[NSArray class]] && ((NSArray *)v).count) return v;
        return nil;
    }
}

- (void)setOrder:(NSArray<NSString *> *)keys page:(NSString *)page {
    if (!page.length) return;
    @synchronized (self) {
        [self unsafeSection:@"order"][page] = [keys copy];
        [self save];
    }
}

- (void)removeOrderForPage:(NSString *)page {
    if (!page.length) return;
    @synchronized (self) {
        [[self unsafeSection:@"order"] removeObjectForKey:page];
        [self save];
    }
}

#pragma mark - 整页改图清理

- (BOOL)pageHasIcons:(NSString *)page {
    if (!page.length) return NO;
    @synchronized (self) {
        id v = [self unsafeSection:@"icons"][page];
        return [v isKindOfClass:[NSDictionary class]] && ((NSDictionary *)v).count > 0;
    }
}

- (void)clearIconsForPage:(NSString *)page {
    if (!page.length) return;
    @synchronized (self) {
        NSDictionary *d = [self unsafeSection:@"icons"][page];
        if ([d isKindOfClass:[NSDictionary class]]) {
            NSFileManager *fm = [NSFileManager defaultManager];
            for (NSString *f in d.allValues) {
                if ([f isKindOfClass:[NSString class]])
                    [fm removeItemAtPath:[kIconDir stringByAppendingPathComponent:f] error:nil];
            }
        }
        [[self unsafeSection:@"icons"] removeObjectForKey:page];
        [self save];
    }
}

#pragma mark - 注入确认标记

- (BOOL)injectedConfirmed {
    @synchronized (self) {
        id v = [self unsafeSection:@"meta"][@"injected"];
        return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
    }
}

- (void)setInjectedConfirmed {
    @synchronized (self) {
        [self unsafeSection:@"meta"][@"injected"] = @YES;
        [self save];
    }
}

@end
