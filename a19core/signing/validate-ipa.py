#!/usr/bin/env python3
import sys, zipfile, plistlib
from pathlib import Path
with zipfile.ZipFile(sys.argv[1]) as z:
    app="Payload/MeloNX.app/"
    host=plistlib.loads(z.read(app+"Info.plist"))
    helper=plistlib.loads(z.read(app+"PlugIns/MeloNXJITHelper.appex/Info.plist"))
    assert host["CFBundleIdentifier"]=="com.stossy11.MeloNX"
    assert helper["CFBundleIdentifier"]=="com.stossy11.MeloNX.JITHelper"
    assert "com.stossy11.MeloNX.clearsign" in host["BGTaskSchedulerPermittedIdentifiers"]
    assert "processing" in host["UIBackgroundModes"]
    assert "_remotepairing-pairable-host._tcp" in host["NSBonjourServices"]
    assert "MeloNX" in host["CFBundleExecutable"]
    assert host["CFBundleShortVersionString"]=="2.5",host["CFBundleShortVersionString"]
    assert z.testzip() is None
print("IPA host identity, JIT helper, scheduler, Bonjour and ZIP integrity passed")
