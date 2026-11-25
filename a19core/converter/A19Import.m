/* Import user-selected local game and keys, in the existing NativeAOT image.
   Never start a guest while conversion owns the service runtime. */
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include "s2a_docs.h"
extern int a19_convert_game(const char*,const char*,const char*,const char*,void(*)(const char*),char*,size_t);
extern int s2a_img_scan(const char*);
extern void s2a_shell_refresh(void);
static _Atomic int converting;
static BOOL attempted;
int a19_import_busy(void){return atomic_load(&converting);}
@interface A19Import:NSObject<UIDocumentPickerDelegate>
@property(nonatomic,weak) UIViewController *presenter;
@property(nonatomic,strong) NSURL *keys;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIViewController *panel;
@property(nonatomic) BOOL keysScoped;
@end
static A19Import *active;
static void progress(const char *s){
    NSString *v=s?@(s):@"";
    dispatch_async(dispatch_get_main_queue(),^{active.status.text=v;});
}
@implementation A19Import
-(void)choose{
    UIDocumentPickerViewController *p=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:NO];p.delegate=self;
    [self.presenter presentViewController:p animated:YES completion:nil];
}
-(void)finish{
    if(self.keysScoped)[self.keys stopAccessingSecurityScopedResource];
    self.keys=nil;self.keysScoped=NO;atomic_store(&converting,0);
    active=nil;s2a_shell_refresh();
}
-(void)documentPickerWasCancelled:(UIDocumentPickerViewController*)c{(void)c;[self finish];}
-(void)documentPicker:(UIDocumentPickerViewController*)c didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls{
    (void)c;NSURL *u=urls.firstObject;if(!u){[self finish];return;}
    if(!self.keys){
        self.keys=u;self.keysScoped=[u startAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(),^{[self choose];});return;
    }
    NSString *ext=u.pathExtension.lowercaseString;
    if(![@[@"nsp",@"xci"] containsObject:ext]){
        UIAlertController*a=[UIAlertController alertControllerWithTitle:@"Archivo no compatible" message:@"Seleccioná un NSP o XCI de tu propiedad." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Cerrar" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction*x){[self finish];}]];
        [self.presenter presentViewController:a animated:YES completion:nil];return;
    }
    BOOL scoped=[u startAccessingSecurityScopedResource];attempted=YES;
    self.panel=[UIViewController new];self.panel.modalPresentationStyle=UIModalPresentationFullScreen;self.panel.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *label=[UILabel new];label.text=@"Preparando conversión…";label.numberOfLines=0;label.textAlignment=NSTextAlignmentCenter;label.translatesAutoresizingMaskIntoConstraints=NO;
    self.status=label;[self.panel.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[[label.leadingAnchor constraintEqualToAnchor:self.panel.view.safeAreaLayoutGuide.leadingAnchor constant:24],[label.trailingAnchor constraintEqualToAnchor:self.panel.view.safeAreaLayoutGuide.trailingAnchor constant:-24],[label.centerYAnchor constraintEqualToAnchor:self.panel.view.centerYAnchor]]];
    BOOL idle=UIApplication.sharedApplication.idleTimerDisabled;UIApplication.sharedApplication.idleTimerDisabled=YES;
    [self.presenter presentViewController:self.panel animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool{
            char docs[1024],out[4096]={0};s2a_container_docs(docs,sizeof docs);
            int rc=a19_convert_game(self.keys.fileSystemRepresentation,u.fileSystemRepresentation,docs,NSBundle.mainBundle.bundlePath.fileSystemRepresentation,progress,out,sizeof out);
            if(scoped)[u stopAccessingSecurityScopedResource];
            NSString *message;
            if(rc==0&&out[0]){
                NSString *src=@(out),*root=[@(docs) stringByAppendingPathComponent:@"Import Here"];
                NSFileManager *fm=NSFileManager.defaultManager;NSError *e=nil;
                NSString *dest=[root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
                if([fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&e]&&[fm moveItemAtPath:src toPath:dest error:&e]){
                    // Atomic directory move on the same volume; no second multi-GB IMG.
                    int n=s2a_img_scan(docs);
                    message=n>0?@"Conversión terminada. Revisá el estado del juego en la biblioteca.":@"Conversión terminada; los archivos quedaron en Import Here. Revisá la importación y la firma.";
                }else message=[NSString stringWithFormat:@"Conversión terminada; archivos conservados en Converted. %@",e.localizedDescription?:@""];
            }else message=@"No se completó la conversión. Consultá last-conversion.log en Archivos. No se modificó el NSP/XCI original.";
            dispatch_async(dispatch_get_main_queue(),^{
                UIApplication.sharedApplication.idleTimerDisabled=idle;
                [self.panel dismissViewControllerAnimated:YES completion:^{
                    UIAlertController*a=[UIAlertController alertControllerWithTitle:@"Importación" message:message preferredStyle:UIAlertControllerStyleAlert];
                    [a addAction:[UIAlertAction actionWithTitle:@"Aceptar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){[self finish];}]];
                    [self.presenter presentViewController:a animated:YES completion:nil];
                }];
            });
        }
    });
}
@end
void a19_import_begin(UIViewController *vc){
    if(attempted){UIAlertController*a=[UIAlertController alertControllerWithTitle:@"Reabrí A19Core" message:@"Por ahora solo se admite una conversión por proceso." preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"Aceptar" style:UIAlertActionStyleCancel handler:nil]];[vc presentViewController:a animated:YES completion:nil];return;}
    if(atomic_exchange(&converting,1))return;
    active=[A19Import new];active.presenter=vc;
    UIAlertController*a=[UIAlertController alertControllerWithTitle:@"Importar juego" message:@"Primero seleccioná tu prod.keys y después el NSP/XCI. La conversión es local y no modifica tus archivos." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction*x){[active finish];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"Seleccionar claves" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){[active choose];}]];
    [vc presentViewController:a animated:YES completion:nil];
}
