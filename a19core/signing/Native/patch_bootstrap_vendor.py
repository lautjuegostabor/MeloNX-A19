#!/usr/bin/env python3
"""Patch only the staged vendor portal; keep automatic renewal non-mutating."""
from pathlib import Path
import sys
def replace(s,a,b):
    if s.count(a)!=1: raise ValueError("Vendor anchor mismatch: "+a[:100])
    return s.replace(a,b,1)
def apply(s):
    s=replace(s,'pub const MACHINE_NAME: &str = "BariStore";','pub const MACHINE_NAME: &str = "ClearSign";')
    # Refuse invalid existing keys rather than silently making a replacement.
    s=replace(s,'        let key = load_or_create_key().map_err(err)?;',
              '        let key = load_key().ok_or_else(|| err("bootstrap_key_missing"))?;')
    start=s.index('        let submitted = match self.call("submitDevelopmentCSR"')
    end=s.index('        let request_id =',start)
    s=s[:start]+'''        let submitted = self.call("submitDevelopmentCSR", Some(team), body).await?;
'''+s[end:]
    s=replace(s,'            if matches_id || matches_key {','            if matches_key {')
    s=replace(s,'                    if spki_matches(info.spki, &modulus) {','                    if spki_matches(info.spki, &modulus) && info.not_after > std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()+3600 {')
    # Independent fail-closed backstop: no revocation from this native library.
    s=replace(s,'        let mut body = Dictionary::new();\n        body.insert("serialNumber".into(), Value::String(serial.into()));\n        self.call("revokeDevelopmentCert", Some(team), body).await.map(|_| ())',
              '        let _ = (team, serial);\n        Err(err("certificate_revocation_disabled"))')
    return s
if __name__=="__main__":
    p=Path(sys.argv[1])/"src/apple/portal.rs"
    p.write_text(apply(p.read_text()))
