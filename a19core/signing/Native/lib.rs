//! Native iOS static library adapter to the pinned MIT BariStore modules.
//! Profile-only unattended renewal for A19Core and its JIT extension.
//! No binary signing, certificate issuance/revocation or installation functions.
#[macro_export]
macro_rules! logf { ($($arg:tt)*) => {{}}; }
mod apple;
mod device;
mod pairing;
mod der;
mod hash;
mod siphash;
mod srp;
mod state;
mod setup;

use base64::{engine::general_purpose::STANDARD, Engine};
use plist::{Dictionary,Value};
use serde::Deserialize;
use serde_json::json;
use std::{ffi::{CStr,CString,c_char},path::Path, sync::Mutex,time::{Duration,SystemTime,UNIX_EPOCH}};
use apple::{gsa,portal::Portal};
use device::{session::Session,services};
use pairing::record::PairingRecord;
static LOCK: Mutex<()> = Mutex::new(());
static REFRESH_CANCEL: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
#[no_mangle]
pub extern "C" fn clearsign_cancel_refresh(){REFRESH_CANCEL.store(true,std::sync::atomic::Ordering::SeqCst);}
async fn wait_for_refresh_cancel(){
    while !REFRESH_CANCEL.load(std::sync::atomic::Ordering::SeqCst){
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}
static RENEWAL_ONLY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub(crate) fn renewal_only() -> bool { RENEWAL_ONLY.load(std::sync::atomic::Ordering::SeqCst) }
struct RenewalGuard;
impl RenewalGuard {
    fn start() -> Self { RENEWAL_ONLY.store(true,std::sync::atomic::Ordering::SeqCst); Self }
}
impl Drop for RenewalGuard {
    fn drop(&mut self) { RENEWAL_ONLY.store(false,std::sync::atomic::Ordering::SeqCst); }
}
fn portal_failure(stage: &str, error: apple::portal::PortalError) -> String {
    if error.code != 0 { return format!("portal:{stage}:apple_code={}",error.code); }
    let kind = match error.message.as_str() {
        "portal_headers_failed" | "portal_transport_timeout" | "portal_transport_connect" |
        "portal_transport_failed" | "portal_body_failed" | "renewal_identity_missing" |
        "renewal_identity_rejected" => error.message.clone(),
        other => match other.strip_prefix("portal_http_").and_then(|n| n.parse::<u16>().ok()) {
            Some(n) if (100..=599).contains(&n) => format!("http={n}"),
            _ => "invalid_or_refused_response".into(),
        },
    };
    format!("portal:{stage}:{kind}")
}

#[derive(Deserialize)]
struct Input { bundles: Vec<BundleInput>, previousExpiry: u64 }
#[derive(Deserialize)]
struct BundleInput { bundleID: String, profile: String, signingCertificateSHA256: Option<String> }

fn profile(data: &[u8]) -> Result<Dictionary,&'static str> {
    if data.len() > 1_000_000 { return Err("profile_invalid"); }
    let start = data.windows(6).position(|x| x == b"<plist").ok_or("profile_invalid")?;
    let end = data[start..].windows(8).position(|x| x == b"</plist>").ok_or("profile_invalid")? + start + 8;
    plist::from_bytes::<Value>(&data[start..end]).ok().and_then(Value::into_dictionary).ok_or("profile_invalid")
}
fn expiry(d: &Dictionary) -> Option<u64> {
    match d.get("ExpirationDate")? {
        Value::Date(x) => SystemTime::from(*x).duration_since(UNIX_EPOCH).ok().map(|x|x.as_secs()),
        _ => None,
    }
}
fn team(d: &Dictionary) -> Option<&str> {
    d.get("TeamIdentifier")?.as_array()?.first()?.as_string()
}
fn app_id(d: &Dictionary) -> Option<&str> {
    d.get("Entitlements")?.as_dictionary()?.get("application-identifier")?.as_string()
}
fn certs(d: &Dictionary) -> Vec<&[u8]> {
    d.get("DeveloperCertificates").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_data).collect()
}
fn device_allowed(d: &Dictionary,udid: &str) -> bool {
    let norm = |s: &str| s.replace('-', "").to_lowercase();
    !udid.is_empty() && d.get("ProvisionedDevices").and_then(Value::as_array).into_iter().flatten()
        .filter_map(Value::as_string).any(|x|norm(x)==norm(udid))
}
fn verify(old: &Dictionary,new: &Dictionary,udid: &str,previous: u64,now: u64,fingerprint: Option<&str>) -> Result<u64,&'static str> {
    if team(old).is_none() || team(old)!=team(new) || app_id(old).is_none() || app_id(old)!=app_id(new) {
        return Err("profile_identity_mismatch");
    }
    let old_certs=certs(old);let new_certs=certs(new);
    let cert_end=if let Some(fingerprint)=fingerprint {
        use sha2::{Digest,Sha256};
        if fingerprint.len()!=64||!fingerprint.bytes().all(|c|c.is_ascii_hexdigit()){return Err("certificate_changed");}
        let matches:Vec<_>=old_certs.iter().filter(|c|hex::encode(Sha256::digest(c))==fingerprint).collect();
        if matches.len()!=1||!new_certs.contains(matches[0]){return Err("certificate_changed");}
        let cert=der::cert_info(matches[0]).map_err(|_|"certificate_changed")?;
        if cert.not_before>now||cert.not_after<=now+3600{return Err("signing_certificate_expires");}
        cert.not_after
    }else{
        // Imported/legacy installation has no trustworthy leaf stamp.
        if old_certs.is_empty() || !old_certs.iter().all(|c|new_certs.contains(c)) {return Err("certificate_changed");}
        u64::MAX
    };
    if old.get("Entitlements")!=new.get("Entitlements") {return Err("entitlements_changed");}
    if !device_allowed(old,udid) || !device_allowed(new,udid) {return Err("device_mismatch");}
    let e=expiry(new).ok_or("profile_invalid")?.min(cert_end);
    let old_e=expiry(old).ok_or("profile_invalid")?.min(cert_end);
    if cert_end<=old_e.max(previous).saturating_add(60){return Err("signing_certificate_expires");}
    if e <= now+3600 || e <= old_e.max(previous).saturating_add(60) {return Err("profile_not_extended");}
    Ok(e)
}
// Compare complete CMS bytes received back from the device. Never persist other profiles.
async fn readback(session: &Session, expected: &[(&[u8], u64)]) -> Result<u64,String> {
    let mut conn = services::ServiceConn::open(session, services::MISAGENT).await
        .map_err(|_| "profile_readback_unavailable")?;
    let mut request = Dictionary::new();
    request.insert("MessageType".into(), Value::String("CopyAll".into()));
    request.insert("ProfileType".into(), Value::String("Provisioning".into()));
    let reply = conn.request(&request).await.map_err(|_| "profile_readback_unavailable")?;
    if reply.get("Status").and_then(Value::as_unsigned_integer) != Some(0) {
        return Err("profile_readback_refused".into());
    }
    let installed = reply.get("Payload").and_then(Value::as_array).ok_or("profile_readback_invalid")?;
    verified_expiry(expected, installed)
}
fn verified_expiry(expected: &[(&[u8], u64)], installed: &[Value]) -> Result<u64,String> {
    if expected.len() != 2 || expected[0].0 == expected[1].0 { return Err("profile_readback_invalid".into()); }
    let matched = expected.iter().filter(|(bytes,_)| installed.iter().any(|p| p.as_data() == Some(*bytes))).count();
    match matched {
        2 => Ok(expected.iter().map(|(_,e)| *e).min().unwrap()),
        1 => Err("profile_readback_partial".into()),
        _ => Err("profile_readback_missing".into()),
    }
}
#[cfg(test)]
mod readback_tests {
    use super::*;
    #[test] fn both_exact_profiles_required() {
        let app = b"test app cms".as_slice(); let widget = b"test widget cms".as_slice();
        let expected = [(app, 2000), (widget, 1900)];
        let a = Value::Data(app.to_vec()); let w = Value::Data(widget.to_vec());
        assert_eq!(verified_expiry(&expected, &[w.clone(), a.clone()]), Ok(1900));
        assert_eq!(verified_expiry(&expected, &[a.clone()]), Err("profile_readback_partial".into()));
        assert_eq!(verified_expiry(&expected, &[Value::Data(b"other".to_vec())]), Err("profile_readback_missing".into()));
        assert_eq!(verified_expiry(&expected, &[a.clone(), a]), Err("profile_readback_partial".into()));
        assert_eq!(verified_expiry(&[(app, 2000), (app, 2000)], &[w]), Err("profile_readback_invalid".into()));
    }
}
async fn renew(input: Input) -> Result<u64,String> {
    if input.bundles.len()!=2 {return Err("expected_app_and_jit_helper".into());}
    let mut old=Vec::new();
    for b in &input.bundles {
        let p=profile(&STANDARD.decode(&b.profile).map_err(|_|"profile_invalid")?)?;
        let id=app_id(&p).ok_or("profile_invalid")?;
        if !id.split_once('.').map(|(_,rest)|rest==b.bundleID).unwrap_or(false) {return Err("profile_identity_mismatch".into());}
        old.push(p);
    }
    if input.bundles[0].bundleID==input.bundles[1].bundleID {return Err("profile_identity_mismatch".into());}
    let team_id=team(&old[0]).ok_or("profile_invalid")?.to_string();
    if team(&old[1])!=Some(team_id.as_str()) {return Err("profile_identity_mismatch".into());}
    let record=std::fs::read(state::path("pairing.plist")).ok().and_then(|x|PairingRecord::from_bytes(&x)).ok_or("pairing_missing")?;
    let session=Session::open(&record).await.map_err(|_|"vpn_or_pairing_unavailable")?;
    if !old.iter().all(|p|device_allowed(p,&session.udid)) {return Err("device_mismatch".into());}
    // gsa::resume uses the imported session; it never initiates a password login.
    let (gs,account)=gsa::resume().await.map_err(|e| match e.as_str() {
        "renewal_identity_missing" => "renewal_identity_missing",
        "renewal_identity_rejected" => "renewal_identity_rejected",
        _ => "session_unavailable",
    })?;
    let portal=Portal{gs:&gs,account:&account};
    let teams=portal.teams().await.map_err(|e|portal_failure("listTeams",e))?;
    if !teams.iter().any(|t|t.id==team_id) {return Err("portal:team_not_authorized".into());}
    let ids=portal.app_ids(&team_id).await.map_err(|e|portal_failure("listAppIds",e))?;
    let now=SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
    let mut fresh=Vec::new();
    // Preflight both profiles completely before installing either.
    for (b,p) in input.bundles.iter().zip(old.iter()) {
        let app=ids.iter().find(|a|a.identifier==b.bundleID).ok_or("app_id_missing")?;
        let raw=portal.profile(&team_id,app).await.map_err(|e|portal_failure("downloadTeamProvisioningProfile",e))?;
        let candidate=profile(&raw)?;
        let e=verify(p,&candidate,&session.udid,input.previousExpiry,now,b.signingCertificateSHA256.as_deref())?;
        fresh.push((raw,e));
    }
    let mut install_failed=false;
    for (raw,_) in &fresh {
        if services::install_profile(&session,raw).await.is_err() {
            install_failed=true; break;
        }
    }
    let expected: Vec<(&[u8],u64)> = fresh.iter().map(|(raw,e)| (raw.as_slice(),*e)).collect();
    let result=readback(&session,&expected).await;
    match (install_failed,result) {
        (false,result) => result,
        (true,Ok(_)) => Err("device_install_uncertain".into()),
        (true,Err(code)) if code=="profile_readback_partial" => Err(code),
        (true,Err(_)) => Err("device_install_unconfirmed".into()),
    }
}
fn execute(dir:&str,bytes:&[u8])->Result<u64,String>{
    if bytes.len()>3_000_000 || !Path::new(dir).is_absolute(){return Err("input_invalid".into());}
    let _guard=LOCK.try_lock().map_err(|_|"engine_busy")?;
    let _renewal=RenewalGuard::start();
    REFRESH_CANCEL.store(false,std::sync::atomic::Ordering::SeqCst);
    std::env::set_var("BARISTORE_HOME",dir);
    let route=std::fs::read_to_string(state::path("anisette-server")).map_err(|_|"session_unavailable")?;
    if !route.lines().next().map(|x|x.starts_with("https://")).unwrap_or(false){return Err("session_route_invalid".into());}
    let input:Input=serde_json::from_slice(bytes).map_err(|_|"input_invalid")?;
    let rt=tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().map_err(|_|"engine_unavailable")?;
    let r=rt.block_on(async {tokio::select! {
        result=tokio::time::timeout(Duration::from_secs(120),renew(input))=>result.map_err(|_|"timeout")?,
        _=wait_for_refresh_cancel()=>Err("refresh_cancelled".into()),
    }});
    rt.shutdown_timeout(Duration::from_secs(2));
    r
}
// Same conservative profile-only operation for the independent recovery binary.
pub fn recover_profiles(dir:&str,bytes:&[u8])->Result<u64,String>{execute(dir,bytes)}
#[no_mangle]
pub unsafe extern "C" fn clearsign_refresh(dir:*const c_char,data:*const u8,len:usize)->*mut c_char{
    let result=std::panic::catch_unwind(||{
        if dir.is_null()||data.is_null()||len>3_000_000{return Err("input_invalid".into());}
        let path=CStr::from_ptr(dir).to_str().map_err(|_|"input_invalid")?;
        execute(path,std::slice::from_raw_parts(data,len))
    }).unwrap_or(Err("engine_unavailable".into()));
    let response=match result{Ok(e)=>json!({"ok":true,"expiry":e}),Err(code)=>json!({"ok":false,"code":code})};
    CString::new(response.to_string()).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}
#[no_mangle]
pub unsafe extern "C" fn clearsign_free(value:*mut c_char){if !value.is_null(){drop(CString::from_raw(value));}}
