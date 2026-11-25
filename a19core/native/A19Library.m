/* Original UIKit control plane. Uses pinned native runtime's real ABI for
 * game import, signing, validation and launch; no Swift S2Arm library UI. */
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <sys/sysctl.h>
#import <os/proc.h>
#include <stdlib.h>
#include <string.h>
#include "s2a_launch_ctx.h"
#include "a19_policy.h"
extern void s2a_shell_library_appeared(void);
extern int s2a_shell_game_install_state(const char*);
extern int s2a_shell_game_sign_state(const char*);
extern int s2a_shell_game_needs_host_update(const char*);
extern void s2a_shell_pick_s2arm(const char*);
extern void s2a_shell_pick_game_data(const char*);
extern void s2a_shell_cert_p12(void);
extern void s2a_shell_export_game(const char*);
extern int s2a_shell_install_game(const char*);
extern int s2a_shell_install_wait(void);
static void (*play_fn)(const char*,void*);
static void *play_context;
static BOOL validID(NSString *s){
    return s.length==16&&[s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFabcdef"] invertedSet]].location==NSNotFound;
}
static BOOL isTarget(void){
    static BOOL ok;static dispatch_once_t once;
    dispatch_once(&once, ^{char m[64]={0};size_t n=sizeof m;ok=!sysctlbyname("hw.machine",m,&n,NULL,0)&&!strcmp(m,"iPhone18,3")&&[MTLCreateSystemDefaultDevice() supportsFamily:MTLGPUFamilyApple10];});
    return ok;
}
@interface A19Library:UIViewController<UITableViewDataSource,UITableViewDelegate>
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) NSArray<NSDictionary*> *games;
@property(nonatomic,strong) UISwitch *adaptive;
@property(nonatomic,strong) NSTimer *timer;
@end
static __weak A19Library *library;
@implementation A19Library
-(void)viewDidLoad{
    [super viewDidLoad];self.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *title=[UILabel new];title.text=@"A19Core";title.font=[UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    self.status=[UILabel new];self.status.numberOfLines=0;self.status.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    UIButton *import=[UIButton buttonWithType:UIButtonTypeSystem];[import setTitle:@"Importar programa (.s2arm)" forState:UIControlStateNormal];[import addTarget:self action:@selector(importProgram) forControlEvents:UIControlEventTouchUpInside];
    UIButton *cert=[UIButton buttonWithType:UIButtonTypeSystem];[cert setTitle:@"Importar certificado .p12" forState:UIControlStateNormal];[cert addTarget:self action:@selector(certificate) forControlEvents:UIControlEventTouchUpInside];
    UILabel *p=[UILabel new];p.text=@"Precalentamiento adaptativo (experimental)";p.numberOfLines=0;p.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.adaptive=[UISwitch new];self.adaptive.on=[NSUserDefaults.standardUserDefaults boolForKey:@"A19AdaptivePrewarm"];self.adaptive.enabled=isTarget();[self.adaptive addTarget:self action:@selector(setting) forControlEvents:UIControlEventValueChanged];
    UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:@[p,self.adaptive]];row.axis=UILayoutConstraintAxisHorizontal;row.alignment=UIStackViewAlignmentCenter;row.spacing=8;
    self.table=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];self.table.dataSource=self;self.table.delegate=self;
    UIStackView *s=[[UIStackView alloc] initWithArrangedSubviews:@[title,self.status,import,cert,row,self.table]];s.axis=UILayoutConstraintAxisVertical;s.spacing=10;s.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:s];
    UILayoutGuide *g=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[s.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],[s.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],[s.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],[s.bottomAnchor constraintEqualToAnchor:g.bottomAnchor]]];
    [self refresh];
}
-(void)viewDidAppear:(BOOL)animated{[super viewDidAppear:animated];s2a_shell_library_appeared();[self.timer invalidate];__weak A19Library*w=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer*t){(void)t;[w refresh];}];}
-(void)viewWillDisappear:(BOOL)animated{[super viewWillDisappear:animated];[self.timer invalidate];self.timer=nil;}
-(void)setting{[NSUserDefaults.standardUserDefaults setBool:self.adaptive.on forKey:@"A19AdaptivePrewarm"];}
-(void)importProgram{s2a_shell_pick_s2arm("");}
-(void)certificate{s2a_shell_cert_p12();}
-(void)refresh{
    char root[1024]={0};NSMutableArray *list=[NSMutableArray new];NSFileManager *fm=NSFileManager.defaultManager;
    if(!s2a_program_games_root(root,sizeof root,getenv("HOME"))){
        NSString *base=@(root);
        for(NSString *gid in [fm contentsOfDirectoryAtPath:base error:nil]){
            if(!validID(gid))continue;
            NSString *p=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/program/catalogue.json",gid]];
            NSData *data=[NSData dataWithContentsOfFile:p];
            id meta=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
            if(![meta isKindOfClass:NSDictionary.class]||![meta[@"title_id"] isEqual:gid])continue;
            NSString *name=[meta[@"name"] isKindOfClass:NSString.class]?meta[@"name"]:gid;
            int st=s2a_shell_game_install_state(gid.UTF8String), sign=s2a_shell_game_sign_state(gid.UTF8String), abi=s2a_shell_game_needs_host_update(gid.UTF8String);
            [list addObject:@{@"gid":gid,@"name":name,@"state":@(st),@"sign":@(sign),@"abi":@(abi)}];
        }
    }
    [list sortUsingComparator:^NSComparisonResult(NSDictionary*a,NSDictionary*b){return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];}];
    self.status.text=[NSString stringWithFormat:@"%@ · margen %.0f MiB\nImportá el programa y colocá su IMG en Archivos > A19Core > Import Here.",isTarget()?@"iPhone 17 / Apple GPU 10":@"Dispositivo no validado",os_proc_available_memory()/1048576.0];
    if(![self.games isEqual:list]){self.games=list;[self.table reloadData];}
}
-(NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s{(void)t;(void)s;return self.games.count;}
-(UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)i{
    NSDictionary *g=self.games[i.row];UITableViewCell *c=[t dequeueReusableCellWithIdentifier:@"game"];if(!c)c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"game"];
    c.textLabel.text=g[@"name"];c.textLabel.numberOfLines=2;
    int st=[g[@"state"] intValue],sg=[g[@"sign"] intValue];c.detailTextLabel.text=[g[@"abi"] boolValue]?@"ABI incompatible":st==2?@"Pendiente de instalar":st!=1?@"Falta IMG o no está listo":sg?@"Revisar firma":@"Listo para abrir";c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return c;
}
-(void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)i{
    [t deselectRowAtIndexPath:i animated:YES];NSDictionary*g=self.games[i.row];NSString *gid=g[@"gid"];
    if(!isTarget()){UIAlertController*a=[UIAlertController alertControllerWithTitle:@"A19 requerido" message:@"Este prototipo está restringido al iPhone 17 base." preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"Cerrar" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];return;}
    if([g[@"abi"] boolValue]){s2a_shell_pick_s2arm(gid.UTF8String);return;}
    int st=[g[@"state"] intValue];if(st==2){s2a_shell_install_game(gid.UTF8String);return;}
    if(st!=1){s2a_shell_pick_game_data(gid.UTF8String);return;}
    if([g[@"sign"] intValue]){s2a_shell_cert_p12();return;}
    if(!play_fn)return;
    if(s2a_shell_install_wait())return;
    setenv("A19CORE_ADAPTIVE",self.adaptive.on?"1":"0",1);
    a19_session_observer_reset(gid.UTF8String);
    play_fn(gid.UTF8String,play_context);
}
@end
void *s2a_shell_library_vc(const char *path){(void)path;A19Library *v=[A19Library new];library=v;return (__bridge_retained void*)v;}
void s2a_shell_set_play_handler(void(*fn)(const char*,void*),void*ctx){play_fn=fn;play_context=ctx;}
void s2a_shell_refresh(void){dispatch_async(dispatch_get_main_queue(),^{[library refresh];});}
