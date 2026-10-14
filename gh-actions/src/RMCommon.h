//
//  RMCommon.h
//  EntryMaster — 设置条目改名 / 换图 / 排序 / 恢复
//  目标: iOS 14+（适配 iOS 17.0.2 relaxin 隐根 rootless 越狱）
//

#ifndef RM_COMMON_H
#define RM_COMMON_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 私有 Preferences 框架最小声明（防御式调用）

// PSCellType 常量（仅用到这两个）
#define RM_PSGroupCell  0
#define RM_PSButtonCell 3

@interface PSSpecifier : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, retain) NSDictionary *properties;
- (id)propertyForKey:(NSString *)key;
- (NSString *)cellType;
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(id)detail cell:(int)cell edit:(int)edit;
+ (id)groupSpecifierWithTitle:(NSString *)title;
- (void)setButtonAction:(SEL)action;
- (void)setTargetObject:(id)target;
@end

@interface PSListController : UIViewController
@property (nonatomic, retain) UITableView *table;
@property (nonatomic, copy) NSString *plistName;
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
@end

#pragma mark - 持久化存储

@interface RMStore : NSObject
+ (instancetype)shared;
/// 自定义名称（无则返回 nil）
- (NSString *)customNameForPage:(NSString *)page key:(NSString *)key;
/// name 传 nil 或空串即删除
- (void)setCustomName:(NSString *)name page:(NSString *)page key:(NSString *)key;
/// 本页是否有任意改名记录
- (BOOL)pageHasNames:(NSString *)page;
- (void)clearNamesForPage:(NSString *)page;
- (BOOL)hasIconForPage:(NSString *)page key:(NSString *)key;
- (UIImage *)iconImageForPage:(NSString *)page key:(NSString *)key;
- (void)saveIconImage:(UIImage *)image page:(NSString *)page key:(NSString *)key;
- (void)removeIconForPage:(NSString *)page key:(NSString *)key;
- (BOOL)pageHasIcons:(NSString *)page;
- (void)clearIconsForPage:(NSString *)page;
- (NSArray<NSString *> *)orderForPage:(NSString *)page;
- (void)setOrder:(NSArray<NSString *> *)keys page:(NSString *)page;
- (void)removeOrderForPage:(NSString *)page;
/// 注入确认标记（只提示一次）
- (BOOL)injectedConfirmed;
- (void)setInjectedConfirmed;
@end

#pragma mark - 选图（相册 / 文件）

typedef NS_ENUM(NSInteger, RMPickSource) {
    RMPickSourcePhotos = 0, // 相册
    RMPickSourceFiles  = 1, // 文件
};

@interface RMPickHelper : NSObject
+ (void)presentImagePickerFromVC:(UIViewController *)vc
                            page:(NSString *)page
                             key:(NSString *)key
                          source:(RMPickSource)source;
@end

#pragma mark - 工具函数（跨文件）

/// 黑匣子日志（RM_DEBUG 编译时启用）：写入 /var/mobile/Library/Preferences/entrymaster.log
void RMLog(NSString *fmt, ...);
/// 安装信号崩溃捕获，崩溃时把信号与调用栈写进日志
void RMLogInstallCrashTrap(void);

/// 列表页稳定 key（类名 | plist 名）
NSString *RMPageKey(id listController);
/// 条目稳定 key：优先取锚定阶段写入的 key，其次条目原名
NSString *RMKeyForSpecifier(id specifier);
/// 用 UITableView 的分区结构把 indexPath 折算成 specifiers 扁平数组下标（NSNotFound 表示无法确定）
NSInteger RMFlatIndexOfTable(UITableView *tv, NSIndexPath *ip);
/// 刷新列表页
void RMRefresh(id listController);
/// 把自定义改名 / 自定义图标应用到单元格
void RMApplyToCell(UITableViewCell *cell, id specifier, NSString *pageKey);

#endif /* RM_COMMON_H */
