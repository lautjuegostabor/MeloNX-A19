#!/usr/bin/env python3
"""Modify only the staged, byte-verified vendor copy."""
from pathlib import Path
import sys
def replace(s, old, new):
    if s.count(old) != 1:
        raise ValueError('Unexpected vendor anchor: ' + old[:100])
    return s.replace(old,new,1)
def portal(s):
    old = '''        let resp = self.gs.http.post(&url).headers(self.headers().await?)
            .body(crate::pairing::record::plist_xml(&body)).send().await
            .map_err(|e| err(format!("developer services: {e}")))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| err(e.to_string()))?;
        let reply: Dictionary = plist::from_bytes(text.as_bytes())
            .map_err(|_| err(format!("developer services answered HTTP {status}: {}", text.chars().take(160).collect::<String>())))?;'''
    new = '''        let headers = self.headers().await.map_err(|e| {
            if e.code != 0 { e }
            else if e.message == "renewal_identity_missing" || e.message == "renewal_identity_rejected" { e }
            else { err("portal_headers_failed") }
        })?;
        let resp = self.gs.http.post(&url).headers(headers)
            .body(crate::pairing::record::plist_xml(&body)).send().await
            .map_err(|e| err(if e.is_timeout() { "portal_transport_timeout" } else if e.is_connect() { "portal_transport_connect" } else { "portal_transport_failed" }))?;
        let status = resp.status();
        let bytes = resp.bytes().await.map_err(|_| err("portal_body_failed"))?;
        let reply: Dictionary = plist::from_bytes(&bytes)
            .map_err(|_| err(format!("portal_http_{}", status.as_u16())))?;'''
    s=replace(s,old,new)
    return replace(s,'''        Ok(reply)
    }

    pub async fn teams''','''        if !status.is_success() { return Err(err(format!("portal_http_{}", status.as_u16()))); }
        Ok(reply)
    }

    pub async fn teams''')
def anisette(s):
    s=replace(s,'''            if self.adi_pb.is_none() {
                self.provision(gs).await?;
            }''','''            if self.adi_pb.is_none() {
                if crate::renewal_only() { return Err("renewal_identity_missing".into()); }
                self.provision(gs).await?;
            }''')
    return replace(s,'''                    if message.contains("-45061") {
                        self.forget();''','''                    if message.contains("-45061") {
                        if crate::renewal_only() { return Err("renewal_identity_rejected".into()); }
                        self.forget();''')
def main(root):
    p=Path(root)/'src/apple/portal.rs'; q=Path(root)/'src/apple/anisette.rs'
    a,b=portal(p.read_text()),anisette(q.read_text())
    p.write_text(a); q.write_text(b)
if __name__=='__main__': main(sys.argv[1])
