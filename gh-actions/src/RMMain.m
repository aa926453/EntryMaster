//
//  RMMain.m — EntryMaster 主逻辑
//
//  Hook 设置 App（com.apple.Preferences）的 PSListController：
//   · 首页 / 二级页面列表底部自动插入「EntryMaster」分组：改名 / 换图 / 排序 / 恢复
//   · 改名：批量列表逐项编辑，点「保存」立即生效
//   · 换图：批量列表逐项更换（相册 / 文件），支持清除
//   · 排序：进入编辑模式，按住行尾 ☰ 把手拖动，点「完成」保存退出
//   · 恢复：整页恢复改名 / 恢复改图 / 恢复排序
//  所有自定义立即生效并持久保存，重启不丢。首次注入成功弹一次提示。
//

#import "RMCommon.h"

// 分层定位闪退：RM_LEVEL 控制启用哪些功能层
// 1 = 仅 hook -specifiers（应用排序 + 锚定，不追加工具分组）
// 2 = + 底部追加工具分组（改名/换图/排序/恢复按钮）
// 3 = + hook -tableView:cellForRowAtIndexPath:
// 4 = + 动态方法注入（排序编辑模式、按钮动作等）
#ifndef RM_LEVEL
#define RM_LEVEL 9
#endif

#pragma mark - 全局状态

static IMP origSpecifiers = NULL;
static IMP origCellForRow = NULL;
static NSMutableSet<UIImage *> *rmOurIcons;             // 我们应用过的自定义图（用于复用时还原）
static char kRMStashKey;                                 // 锚定 key（挂在 PSSpecifier 上）
static char kRMToolKey;                                  // 工具条目标记（挂在 PSSpecifier 上）
static char kRMAnchoredArrKey;                           // 数组已锚定标记（挂在 NSArray 上）

#pragma mark - 基础工具

static NSString *RMNameOf(id spec) {
    @try {
        NSString *n = [(PSSpecifier *)spec name];
        if ([n isKindOfClass:[NSString class]]) return n;
    } @catch (NSException *e) {}
    return nil;
}

BOOL RMIsGroupSpecifier(id spec) {
    if (!spec) return NO;
    @try {
        NSString *ct = [(PSSpecifier *)spec cellType];
        if ([ct isKindOfClass:[NSString class]] && [ct isEqualToString:@"PSGroupCell"]) return YES;
    } @catch (NSException *e) {}
    @try {
        id v = [(PSSpecifier *)spec propertyForKey:@"cell"];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v isEqualToString:@"PSGroupCell"]) return YES;
    } @catch (NSException *e) {}
    return NO;
}

NSString *RMPageKey(id vc) {
    if (!vc) return @"__page__";
    NSMutableString *k = [NSMutableString stringWithString:NSStringFromClass([vc class])];
    @try {
        if ([vc respondsToSelector:@selector(plistName)]) {
            NSString *pn = [(PSListController *)vc plistName];
            if ([pn isKindOfClass:[NSString class]] && pn.length) [k appendFormat:@"|%@", pn];
        }
    } @catch (NSException *e) {}
    return k;
}

NSString *RMKeyForSpecifier(id spec) {
    NSString *stashed = objc_getAssociatedObject(spec, &kRMStashKey);
    if ([stashed isKindOfClass:[NSString class]] && stashed.length) return stashed;
    NSString *n = RMNameOf(spec);
    return n.length ? n : @"__unnamed__";
}

// 锚定 key：有名字的用名字；无名字的分组/行用出现序号，保证同一默认结构下稳定
static NSArray<NSString *> *RMAnchoredKeys(NSArray *specs) {
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:specs.count];
    NSUInteger gi = 0, ri = 0;
    for (id spec in specs) {
        NSString *n = RMNameOf(spec);
        NSString *k;
        if (n.length) {
            k = n;
        } else if (RMIsGroupSpecifier(spec)) {
            k = [NSString stringWithFormat:@"__group__%lu", (unsigned long)gi++];
        } else {
            k = [NSString stringWithFormat:@"__row__%lu", (unsigned long)ri++];
        }
        objc_setAssociatedObject(spec, &kRMStashKey, k, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [keys addObject:k];
    }
    return keys;
}

// 同一个数组对象只锚定一次，避免排序后重复锚定导致 key 漂移
static void RMAnchorOnce(NSArray *specs) {
    if (!specs.count) return;
    if (objc_getAssociatedObject(specs, &kRMAnchoredArrKey)) return;
    RMAnchoredKeys(specs);
    objc_setAssociatedObject(specs, &kRMAnchoredArrKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

NSInteger RMFlatIndexOfIndexPath(NSArray *specs, NSIndexPath *ip) {
    if (!specs || !ip) return NSNotFound;
    NSInteger group = -1, row = 0;
    for (NSUInteger i = 0; i < specs.count; i++) {
        id spec = specs[i];
        if (RMIsGroupSpecifier(spec)) { group++; row = 0; continue; } // 分组头不算行
        if (group == ip.section && row == ip.row) return (NSInteger)i;
        row++;
    }
    return NSNotFound;
}

static id RMSpecifierAtIndexPath(NSArray *specs, NSIndexPath *ip) {
    NSInteger idx = RMFlatIndexOfIndexPath(specs, ip);
    if (idx == NSNotFound || idx < 0 || (NSUInteger)idx >= specs.count) return nil;
    return specs[idx];
}

static UITableView *RMFindTableView(UIView *v) {
    if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
    for (UIView *sv in v.subviews) {
        UITableView *t = RMFindTableView(sv);
        if (t) return t;
    }
    return nil;
}

static UITableView *RMTableFor(id vc) {
    @try {
        if ([vc respondsToSelector:@selector(table)]) {
            UITableView *t = [(PSListController *)vc table];
            if ([t isKindOfClass:[UITableView class]]) return t;
        }
    } @catch (NSException *e) {}
    @try { return RMFindTableView(((UIViewController *)vc).view); } @catch (NSException *e) {}
    return nil;
}

void RMRefresh(id listController) {
    if (!listController) return;
    @try {
        if ([listController respondsToSelector:@selector(reloadSpecifiers)]) {
            [(PSListController *)listController reloadSpecifiers];
            return;
        }
    } @catch (NSException *e) {}
    UITableView *t = RMTableFor(listController);
    [t reloadData];
}

#pragma mark - 图标处理

static void RMCollectImageViews(UIView *v, NSMutableArray<UIImageView *> *out) {
    for (UIView *sv in v.subviews) {
        if ([sv isKindOfClass:[UIImageView class]]) [out addObject:(UIImageView *)sv];
        RMCollectImageViews(sv, out);
    }
}

static UIImageView *RMFindIconInCell(UITableViewCell *cell) {
    @try {
        id iv = [cell valueForKey:@"_iconImageView"];
        if ([iv isKindOfClass:[UIImageView class]]) return iv;
    } @catch (NSException *e) {}
    @try {
        id iv = [cell valueForKey:@"_iconView"];
        if ([iv isKindOfClass:[UIImageView class]]) return iv;
    } @catch (NSException *e) {}
    NSMutableArray<UIImageView *> *ivs = [NSMutableArray array];
    RMCollectImageViews(cell, ivs);
    UIImageView *withImage = nil;
    for (UIImageView *iv in ivs) {
        if (iv.image && iv.frame.size.width >= 20.0 && iv.frame.size.height >= 20.0) { withImage = iv; break; }
    }
    if (!withImage && ivs.count) withImage = ivs.firstObject;
    return withImage;
}

static UIImage *RMDefaultIconForSpec(id spec) {
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *k = RMKeyForSpecifier(spec);
    if (k.length) {
        UIImage *cached = cache[k];
        if (cached) return cached;
    }
    NSDictionary *props = nil;
    @try { props = [(PSSpecifier *)spec properties]; } @catch (NSException *e) {}
    UIImage *img = nil;
    for (NSString *kk in @[@"icon-image", @"icon", @"iconImage", @"glyph"]) {
        id v = props[kk];
        if ([v isKindOfClass:[UIImage class]]) { img = v; break; }
        if ([v isKindOfClass:[NSString class]]) {
            NSString *s = v;
            if (![s hasPrefix:@"/"]) img = [UIImage systemImageNamed:s];
            if (!img) img = [UIImage imageWithContentsOfFile:s];
            if (img) break;
        }
    }
    if (img && k) cache[k] = img;
    return img;
}

void RMApplyToCell(UITableViewCell *cell, id spec, NSString *pageKey) {
    if (!cell || !spec || !pageKey.length) return;
    RMStore *store = [RMStore shared];
    NSString *key = RMKeyForSpecifier(spec);

    // 改名
    NSString *custom = [store customNameForPage:pageKey key:key];
    if (custom.length) {
        UILabel *lbl = nil;
        @try { lbl = cell.textLabel; } @catch (NSException *e) {}
        if (!lbl) {
            for (UIView *sv in cell.contentView.subviews) {
                if ([sv isKindOfClass:[UILabel class]]) { lbl = (UILabel *)sv; break; }
            }
        }
        if (lbl) lbl.text = custom;
    }

    // 改图
    UIImageView *iv = RMFindIconInCell(cell);
    if (!iv) return;
    UIImage *customImg = [store iconImageForPage:pageKey key:key];
    if (customImg) {
        iv.image = customImg;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [rmOurIcons addObject:customImg];
    } else if (iv.image && [rmOurIcons containsObject:iv.image]) {
        // 单元格复用带出了别的行的自定义图 → 还原默认
        iv.image = RMDefaultIconForSpec(spec);
    }
}

#pragma mark - 工具条目（底部入口分组）

static BOOL RMIsToolSpecifier(id spec) {
    return spec != nil && objc_getAssociatedObject(spec, &kRMToolKey) != nil;
}

static id RMToolButtonSpec(NSString *title, SEL action, id target) {
    if (![PSSpecifier respondsToSelector:@selector(preferenceSpecifierNamed:target:set:get:detail:cell:edit:)])
        return nil;
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title
                                                      target:target
                                                         set:NULL
                                                         get:NULL
                                                      detail:nil
                                                        cell:RM_PSButtonCell
                                                        edit:0];
    if (!spec) return nil;
    [spec setButtonAction:action];
    [spec setTargetObject:target];
    objc_setAssociatedObject(spec, &kRMToolKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return spec;
}

static void RMAnchorPopover(UIAlertController *sheet, UIView *v) {
    if (!sheet.popoverPresentationController) return;
    if (!v) return;
    sheet.popoverPresentationController.sourceView = v;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds), 1, 1);
    sheet.popoverPresentationController.permittedArrowDirections = 0;
}

#pragma mark - Hook: PSListController

// -specifiers：应用保存的排序 + 锚定每条 key + 底部追加工具分组
static NSArray *rm_specifiers(id self, SEL _cmd) {
    NSArray *orig = ((NSArray *(*)(id, SEL))origSpecifiers)(self, _cmd);
    @try {
        if (!orig.count) return orig;

        // PSListController 可能缓存了我们上次追加过工具的数组，直接返回避免重复追加
        __block BOOL hasTool = NO;
        [orig enumerateObjectsUsingBlock:^(id sp, NSUInteger i, BOOL *stop) {
            if (RMIsToolSpecifier(sp)) { hasTool = YES; *stop = YES; }
        }];

        RMAnchorOnce(orig);
        if (hasTool) return orig;

        NSArray *order = [[RMStore shared] orderForPage:RMPageKey(self)];
        NSMutableArray *arr = [NSMutableArray arrayWithArray:orig];
        if (order.count) {
            // 用锚定 key 还原保存的顺序
            NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:orig.count];
            for (id spec in orig) [keys addObject:RMKeyForSpecifier(spec)];
            NSMutableIndexSet *used = [NSMutableIndexSet indexSet];
            NSMutableArray *sorted = [NSMutableArray arrayWithCapacity:orig.count];
            for (NSString *k in order) {
                for (NSUInteger i = 0; i < orig.count; i++) {
                    if ([used containsIndex:i]) continue;
                    if ([keys[i] isEqualToString:k]) {
                        [sorted addObject:orig[i]];
                        [used addIndex:i];
                        break;
                    }
                }
            }
            for (NSUInteger i = 0; i < orig.count; i++)
                if (![used containsIndex:i]) [sorted addObject:orig[i]];
            [arr setArray:sorted];
        }

        // 底部工具分组：所有 PSListController 页面固定追加
        // （不能按导航深度条件增减，否则分区结构与数组不一致会导致越界崩溃）
#if RM_LEVEL >= 2
        {
            PSSpecifier *grp = nil;
            if ([PSSpecifier respondsToSelector:@selector(groupSpecifierWithTitle:)])
                grp = [PSSpecifier groupSpecifierWithTitle:@"EntryMaster"];
            if (!grp &&
                [PSSpecifier respondsToSelector:@selector(preferenceSpecifierNamed:target:set:get:detail:cell:edit:)])
                grp = [PSSpecifier preferenceSpecifierNamed:@"EntryMaster" target:nil set:NULL get:NULL detail:nil cell:RM_PSGroupCell edit:0];
            if (grp) {
                objc_setAssociatedObject(grp, &kRMToolKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [arr addObject:grp];
            }
            PSSpecifier *btn;
            if ((btn = RMToolButtonSpec(@"改名", @selector(rmOpenRename:), self))) [arr addObject:btn];
            if ((btn = RMToolButtonSpec(@"换图", @selector(rmOpenIcons:), self))) [arr addObject:btn];
            if ((btn = RMToolButtonSpec(@"排序", @selector(rmOpenSort:), self))) [arr addObject:btn];
            if ((btn = RMToolButtonSpec(@"恢复", @selector(rmOpenRestore:), self))) [arr addObject:btn];
        }
#endif

        objc_setAssociatedObject(arr, &kRMAnchoredArrKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return arr;
    } @catch (NSException *e) {
        return orig;
    }
}

// -tableView:cellForRowAtIndexPath:：应用改名/改图（仅主线程回调）
static id rm_cellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    id cell = ((id (*)(id, SEL, UITableView *, NSIndexPath *))origCellForRow)(self, _cmd, tv, ip);
    @try {
        NSArray *specs = [(PSListController *)self specifiers];
        id spec = RMSpecifierAtIndexPath(specs, ip);
        if (spec && cell && !RMIsGroupSpecifier(spec) && !RMIsToolSpecifier(spec)) {
            RMApplyToCell(cell, spec, RMPageKey(self));
        }
    } @catch (NSException *e) {}
    return cell;
}

#pragma mark - 排序拖动处理

static void RMHandleMove(id listController, NSIndexPath *fromIP, NSIndexPath *toIP) {
    @try {
        NSArray *specs = [(PSListController *)listController specifiers];

        // 按 section 整理内容行（分组头作为分界）
        NSMutableArray *sections = [NSMutableArray array];
        NSMutableArray *cur = nil;
        for (id sp in specs) {
            if (RMIsGroupSpecifier(sp) || !cur) {
                cur = [NSMutableArray array];
                [sections addObject:cur];
            }
            if (!RMIsGroupSpecifier(sp) && !RMIsToolSpecifier(sp)) [cur addObject:sp];
        }

        NSInteger sf = fromIP.section, rf = fromIP.row;
        NSInteger st = toIP.section,   rt = toIP.row;
        if (sf < 0 || st < 0 || sf >= (NSInteger)sections.count || st >= (NSInteger)sections.count) return;
        NSMutableArray *src = sections[sf];
        if (rf < 0 || rf >= (NSInteger)src.count) return;

        id moved = src[rf];
        [src removeObjectAtIndex:rf];
        NSMutableArray *dst = sections[st];
        NSInteger rt2 = MIN(MAX(rt, 0), (NSInteger)dst.count);
        [dst insertObject:moved atIndex:rt2];

        // 重建平面顺序并持久化（只含内容行）
        NSMutableArray<NSString *> *order = [NSMutableArray array];
        for (NSMutableArray *sec in sections)
            for (id sp in sec) [order addObject:RMKeyForSpecifier(sp)];

        [[RMStore shared] setOrder:order page:RMPageKey(listController)];
        dispatch_async(dispatch_get_main_queue(), ^{ RMRefresh(listController); });
    } @catch (NSException *e) {}
}

#pragma mark - 恢复

static void RMShowRestoreSheet(id listController) {
    UIViewController *vc = (UIViewController *)listController;
    if (!vc || vc.presentedViewController) return;
    NSString *page = RMPageKey(listController);
    RMStore *store = [RMStore shared];

    BOOL hasName  = [store pageHasNames:page];
    BOOL hasIcon  = [store pageHasIcons:page];
    BOOL hasOrder = [store orderForPage:page].count > 0;

    if (!hasName && !hasIcon && !hasOrder) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"恢复"
                                                                   message:@"该页面没有可恢复的自定义内容"
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"恢复"
                                                                   message:@"恢复本页面的全部"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    RMAnchorPopover(sheet, vc.view);
    if (hasName) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"恢复改名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [store clearNamesForPage:page];
            RMRefresh(listController);
        }]];
    }
    if (hasIcon) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"恢复改图" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [store clearIconsForPage:page];
            RMRefresh(listController);
        }]];
    }
    if (hasOrder) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"恢复排序" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [store removeOrderForPage:page];
            RMRefresh(listController);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - RMListEditor（批量改名 / 换图列表）

typedef NS_ENUM(NSInteger, RMEditMode) { RMEditModeRename = 0, RMEditModeIcon = 1 };

@interface RMEditItem : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *defaultName;
@property (nonatomic, strong) id spec;
@property (nonatomic, copy) NSString *inputText; // 改名模式：输入框内容；换图模式：当前自定义名
@end

@implementation RMEditItem
@end

@interface RMListEditor : UITableViewController
@property (nonatomic, weak) PSListController *listController;
@property (nonatomic, assign) RMEditMode mode;
@property (nonatomic, copy) NSString *page;
@property (nonatomic, strong) NSMutableArray<RMEditItem *> *items;
+ (void)openWithListController:(PSListController *)lc mode:(RMEditMode)m;
- (id)initWithListController:(PSListController *)lc mode:(RMEditMode)m;
@end

@implementation RMListEditor

+ (void)openWithListController:(PSListController *)lc mode:(RMEditMode)m {
    if (!lc) return;
    RMListEditor *ed = [[RMListEditor alloc] initWithListController:lc mode:m];
    UINavigationController *nav = ((UIViewController *)lc).navigationController;
    if (nav) {
        [nav pushViewController:ed animated:YES];
    } else {
        [(UIViewController *)lc presentViewController:[[UINavigationController alloc] initWithRootViewController:ed]
                                             animated:YES completion:nil];
    }
}

- (id)initWithListController:(PSListController *)lc mode:(RMEditMode)m {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _listController = lc;
        _mode = m;
        _page = RMPageKey(lc);
        _items = [NSMutableArray array];
        RMStore *store = [RMStore shared];
        @try {
            for (id spec in [lc specifiers]) {
                if (RMIsGroupSpecifier(spec) || RMIsToolSpecifier(spec)) continue;
                RMEditItem *it = [[RMEditItem alloc] init];
                it.spec = spec;
                it.key = RMKeyForSpecifier(spec);
                it.defaultName = RMNameOf(spec) ?: it.key;
                it.inputText = [store customNameForPage:_page key:it.key];
                [_items addObject:it];
            }
        } @catch (NSException *e) {}
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = (self.mode == RMEditModeRename) ? @"改名" : @"换图";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    if (self.mode == RMEditModeRename) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(saveTapped:)];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.view endEditing:YES];
    RMRefresh(self.listController);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.items.count;
}

- (UIImage *)scaledIcon:(UIImage *)img side:(CGFloat)side {
    CGFloat w = MAX(img.size.width, 1.0), h = MAX(img.size.height, 1.0);
    CGFloat k = side / MAX(w, h);
    CGSize nsz = CGSizeMake(MAX(1.0, round(w * k)), MAX(1.0, round(h * k)));
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:nsz];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, nsz.width, nsz.height)];
    }];
}

static NSString *RMPrettyName(RMEditItem *it) {
    if (it.inputText.length) return it.inputText;
    if ([it.defaultName hasPrefix:@"__"]) return @"(未命名条目)";
    return it.defaultName;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"RMEditCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    RMEditItem *it = self.items[ip.row];

    if (self.mode == RMEditModeRename) {
        cell.textLabel.hidden = YES;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessoryView = nil;
        cell.imageView.image = nil;

        UITextField *tf = nil;
        for (UIView *v in cell.contentView.subviews)
            if ([v isKindOfClass:[UITextField class]]) { tf = (UITextField *)v; break; }
        if (!tf) {
            tf = [[UITextField alloc] init];
            tf.font = [UIFont systemFontOfSize:17];
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
            tf.returnKeyType = UIReturnKeyDone;
            tf.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:tf];
            [cell.contentView addConstraint:
                [NSLayoutConstraint constraintWithItem:tf attribute:NSLayoutAttributeLeading
                                       relatedBy:NSLayoutRelationEqual
                                          toItem:cell.contentView attribute:NSLayoutAttributeLeading
                                      multiplier:1.0 constant:16]];
            [cell.contentView addConstraint:
                [NSLayoutConstraint constraintWithItem:tf attribute:NSLayoutAttributeTrailing
                                       relatedBy:NSLayoutRelationEqual
                                          toItem:cell.contentView attribute:NSLayoutAttributeTrailing
                                      multiplier:1.0 constant:-16]];
            [cell.contentView addConstraint:
                [NSLayoutConstraint constraintWithItem:tf attribute:NSLayoutAttributeTop
                                       relatedBy:NSLayoutRelationEqual
                                          toItem:cell.contentView attribute:NSLayoutAttributeTop
                                      multiplier:1.0 constant:7]];
            [cell.contentView addConstraint:
                [NSLayoutConstraint constraintWithItem:tf attribute:NSLayoutAttributeBottom
                                       relatedBy:NSLayoutRelationEqual
                                          toItem:cell.contentView attribute:NSLayoutAttributeBottom
                                      multiplier:1.0 constant:-7]];
            [tf addTarget:self action:@selector(tfChanged:) forControlEvents:UIControlEventEditingChanged];
        }
        tf.tag = ip.row;
        tf.text = it.inputText ?: @"";
        tf.placeholder = [it.defaultName hasPrefix:@"__"] ? @"(未命名条目)" : it.defaultName;
    } else {
        cell.textLabel.hidden = NO;
        cell.textLabel.text = RMPrettyName(it);
        cell.textLabel.numberOfLines = 2;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessoryView = nil;
        UIImage *img = [[RMStore shared] iconImageForPage:self.page key:it.key];
        if (!img) img = RMDefaultIconForSpec(it.spec);
        cell.imageView.image = img ? [self scaledIcon:img side:29] : nil;
    }
    return cell;
}

- (void)tfChanged:(UITextField *)tf {
    if (tf.tag >= 0 && (NSUInteger)tf.tag < self.items.count)
        [self.items[tf.tag] setInputText:tf.text];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.mode != RMEditModeIcon) return;
    RMEditItem *it = self.items[ip.row];
    RMStore *store = [RMStore shared];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:RMPrettyName(it)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    UIView *src = [tv cellForRowAtIndexPath:ip] ?: tv;
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = src;
        sheet.popoverPresentationController.sourceRect = src.bounds;
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"相册" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [RMPickHelper presentImagePickerFromVC:self page:self.page key:it.key source:RMPickSourcePhotos];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"文件" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [RMPickHelper presentImagePickerFromVC:self page:self.page key:it.key source:RMPickSourceFiles];
    }]];
    if ([store hasIconForPage:self.page key:it.key]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"清除图标" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [store removeIconForPage:self.page key:it.key];
            [self.tableView reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)saveTapped:(id)sender {
    [self.view endEditing:YES];
    RMStore *store = [RMStore shared];
    for (RMEditItem *it in self.items) {
        NSString *t = [it.inputText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length && ![t isEqualToString:it.defaultName])
            [store setCustomName:t page:self.page key:it.key];
        else
            [store setCustomName:nil page:self.page key:it.key];
    }
    RMRefresh(self.listController);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - PSListController 动态方法注入

static void RMSetOrAddMethod(Class c, SEL sel, const char *types, IMP imp) {
    Method m = class_getInstanceMethod(c, sel);
    if (m) method_setImplementation(m, imp);
    else class_addMethod(c, sel, imp, types);
}

static void RMInstallDynamicMethods(Class lc) {
    // 入口动作
    class_addMethod(lc, @selector(rmOpenRename:), imp_implementationWithBlock(^(id _self, PSSpecifier *spec) {
        [RMListEditor openWithListController:(PSListController *)_self mode:RMEditModeRename];
    }), "v@:@");

    class_addMethod(lc, @selector(rmOpenIcons:), imp_implementationWithBlock(^(id _self, PSSpecifier *spec) {
        [RMListEditor openWithListController:(PSListController *)_self mode:RMEditModeIcon];
    }), "v@:@");

    class_addMethod(lc, @selector(rmOpenSort:), imp_implementationWithBlock(^(id _self, PSSpecifier *spec) {
        UITableView *tv = RMTableFor(_self);
        if (!tv) return;
        [tv setEditing:YES animated:YES];
        UIViewController *vc = (UIViewController *)_self;
        vc.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:_self action:@selector(rmDoneSort:)];
    }), "v@:@");

    class_addMethod(lc, @selector(rmDoneSort:), imp_implementationWithBlock(^(id _self, id sender) {
        UIViewController *vc = (UIViewController *)_self;
        UITableView *tv = RMTableFor(_self);
        if (tv) [tv setEditing:NO animated:YES];
        vc.navigationItem.rightBarButtonItem = nil;
        RMRefresh(_self);
    }), "v@:@");

    class_addMethod(lc, @selector(rmOpenRestore:), imp_implementationWithBlock(^(id _self, PSSpecifier *spec) {
        RMShowRestoreSheet(_self);
    }), "v@:@");

    // 排序编辑模式的数据源支持
    // editingStyle/shouldIndent: 替换（返回安全默认值，不影响行数）
    RMSetOrAddMethod(lc, @selector(tableView:editingStyleForRowAtIndexPath:), "Q@:@@",
        imp_implementationWithBlock(^UITableViewCellEditingStyle(id _self, UITableView *tv, NSIndexPath *ip) {
            return UITableViewCellEditingStyleNone; // 只要 ☰ 把手，不要删除圆点
        }));

    RMSetOrAddMethod(lc, @selector(tableView:shouldIndentWhileEditingRowAtIndexPath:), "B@:@@",
        imp_implementationWithBlock(^BOOL(id _self, UITableView *tv, NSIndexPath *ip) {
            return NO;
        }));

    // canMove/moveRow: 只新增，不替换（若系统已有实现则保持原样，避免破坏内部逻辑）
    if (![PSListController instancesRespondToSelector:@selector(tableView:canMoveRowAtIndexPath:)]) {
        class_addMethod(lc, @selector(tableView:canMoveRowAtIndexPath:),
            imp_implementationWithBlock(^BOOL(id _self, UITableView *tv, NSIndexPath *ip) {
                @try {
                    NSArray *specs = [(PSListController *)_self specifiers];
                    id spec = RMSpecifierAtIndexPath(specs, ip);
                    return spec && !RMIsGroupSpecifier(spec) && !RMIsToolSpecifier(spec);
                } @catch (NSException *e) { return NO; }
            }), "B@:@@@");
    }
    if (![PSListController instancesRespondToSelector:@selector(tableView:moveRowAtIndexPath:toIndexPath:)]) {
        class_addMethod(lc, @selector(tableView:moveRowAtIndexPath:toIndexPath:),
            imp_implementationWithBlock(^(id _self, UITableView *tv, NSIndexPath *fromIP, NSIndexPath *toIP) {
                RMHandleMove(_self, fromIP, toIP);
            }), "v@:@@@");
    }
}

#pragma mark - 安装 Hook

__attribute__((constructor))
static void RMEntryConstructor(void) {
    @autoreleasepool {
#ifdef RM_PROBE
        // 探针版：完全空操作，仅验证 dylib 能否被注入加载而不崩溃
        return;
#endif
        @try {
            if (!rmOurIcons) rmOurIcons = [NSMutableSet set];
            // 双保险：只处理设置 App
            NSString *bid = [NSBundle mainBundle].bundleIdentifier;
            if (![bid isEqualToString:@"com.apple.Preferences"]) return;

            Class lc = objc_getClass("PSListController");
            if (!lc) return;

            Method m1 = class_getInstanceMethod(lc, @selector(specifiers));
            if (m1) {
                origSpecifiers = method_getImplementation(m1);
                method_setImplementation(m1, (IMP)rm_specifiers);
            }

            if (RM_LEVEL >= 3) {
                Method m2 = class_getInstanceMethod(lc, @selector(tableView:cellForRowAtIndexPath:));
                if (m2) {
                    origCellForRow = method_getImplementation(m2);
                    method_setImplementation(m2, (IMP)rm_cellForRow);
                }
            }

            if (RM_LEVEL >= 4) {
                RMInstallDynamicMethods(lc);
            }
        } @catch (NSException *e) {}
    }
}
