#!/usr/bin/env python3
"""Apply only the signing host integration, after the complete 1.3 overlay."""
from pathlib import Path
import plistlib, re, shutil, sys
root, port = map(Path,sys.argv[1:])
host=root/"src/MeloNX/MeloNX"
def once(s,a,b):
    assert s.count(a)==1, (a[:80],s.count(a))
    return s.replace(a,b,1)
dest=host/"Common/A19Signing"
dest.mkdir(parents=True,exist_ok=True)
for p in sorted((port/"App").glob("*.swift")):
    shutil.copy2(p,dest/p.name)
# Preserve all existing permissions, JIT entries, bundle IDs and version strings.
info=host/"Info.plist"
d=plistlib.loads(info.read_bytes())
for key,item in [("BGTaskSchedulerPermittedIdentifiers","com.stossy11.MeloNX.clearsign"),("UIBackgroundModes","processing"),("NSBonjourServices","_remotepairing-pairable-host._tcp")]:
    old=d.setdefault(key,[])
    assert isinstance(old,list)
    if item not in old: old.append(item)
d.setdefault("NSLocalNetworkUsageDescription","A19Core uses local networking for JIT and explicitly authorized signing pairing.")
info.write_bytes(plistlib.dumps(d,sort_keys=False))
p=host/"UI/MeloNXApp.swift"
s=p.read_text()
s=once(s,"    init() {\n        SDL_SetMainReady()", "    init() {\n        if #available(iOS 26.0, *) {\n            ClearSignSetup.purgeAbandonedSetup()\n            ClearSign.shared.register()\n        }\n        SDL_SetMainReady()")
s=once(s,"    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate","    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate\n    @Environment(\\.scenePhase) private var a19SigningScenePhase")
s=once(s,"                .environmentObject(ryujinxController)","                .onChange(of: a19SigningScenePhase) { phase in\n                    if #available(iOS 26.0, *), phase == .active {\n                        Task { @MainActor in\n                            guard A19SigningPolicy.canRenewWhileIdle(engineActive:ryujinxController.isEngineActive,gameRunning:ryujinxController.isRunning.isRunning()) else{return}\n                            _ = await ClearSign.shared.preventiveCheck()\n                        }\n                    }\n                }\n                .environmentObject(ryujinxController)")
p.write_text(s)
p=host/"UI/Main/Settings/SettingsView.swift"
s=p.read_text()
s=once(s,'            Section("JIT & Updates") {','            Section("JIT & Updates") {\n                if #available(iOS 26.0, *) {\n                    NavigationLink { A19SigningScreen() } label: { Label("Renovación de firma", systemImage: "checkmark.shield") }\n                }')
p.write_text(s)
# Append linker flags only to the MeloNX host build configurations; retain existing flags.
p=root/"src/MeloNX/MeloNX.xcodeproj/project.pbxproj"
s=p.read_text()
flags=['"$(SRCROOT)/../../distribution/ios/a19/build/libclearsign.a"','"-framework"','"Security"','"-framework"','"SystemConfiguration"','"-framework"','"CoreFoundation"','"-liconv"','"-lresolv"','"-lz"','"-lc++"']
count=0
def config(m):
    global count
    block=m.group(0)
    if 'INFOPLIST_FILE = MeloNX/Info.plist;' not in block: return block
    count+=1
    block=once(block,"INFOPLIST_FILE = MeloNX/Info.plist;","INFOPLIST_FILE = MeloNX/Info.plist;\n\t\t\t\tLD_GENERATE_MAP_FILE = YES;\n\t\t\t\tLD_MAP_FILE_PATH = \"$(SRCROOT)/../../build/A19Core-host-linkmap.txt\";")
    pat=r'(?m)^([ \t]*)OTHER_LDFLAGS\s*=\s*(\([^;]*\)|[^;]+);'
    hit=re.search(pat,block)
    extra=", ".join(flags)
    if hit:
        old=hit.group(2).strip()
        if old.startswith("("):
            content=old[1:-1].strip().rstrip(",")
        elif old in ('""',''):
            content='"$(inherited)"'
        else:
            raise ValueError("Unexpected host OTHER_LDFLAGS format: "+old)
        new=hit.group(1)+"OTHER_LDFLAGS = ("+(content+", " if content else "")+extra+");"
        return block[:hit.start()]+new+block[hit.end():]
    return once(block,"INFOPLIST_FILE = MeloNX/Info.plist;","INFOPLIST_FILE = MeloNX/Info.plist;\n\t\t\t\tOTHER_LDFLAGS = (\"$(inherited)\", "+extra+");")
s=re.sub(r'buildSettings = \{.*?\n\s*\};',config,s,flags=re.S)
assert count==2,count
p.write_text(s)
print("A19Core signing overlay applied: host app only; JIT helper and entitlements unchanged")
