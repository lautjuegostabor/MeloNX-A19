//! Local-only, explicitly initiated setup. No credential logging, certificate changes or unattended login.
use std::{ffi::{CStr,CString,c_char},path::Path,sync::{Mutex,atomic::{AtomicBool,Ordering}},time::Duration};
use serde_json::{Value,json};
use rand::Rng;
use crate::{apple::{gsa,anisette},device::session::Session,pairing::{host,record::{HostIdentity,PairingRecord}},state};
static BUSY: AtomicBool = AtomicBool::new(false);
static CANCEL: AtomicBool = AtomicBool::new(false);
static STATE: Mutex<Option<Value>> = Mutex::new(None);
static ANSWER: Mutex<Option<String>> = Mutex::new(None);
fn update(value: Value) { if let Ok(mut v)=STATE.lock(){*v=Some(value);} }
fn response(value:Value)->*mut c_char { CString::new(value.to_string()).map(CString::into_raw).unwrap_or(std::ptr::null_mut()) }
fn fail(code:&str) { update(json!({"phase":"error","code":code})); }
fn cancelled()->bool { CANCEL.load(Ordering::SeqCst) }
async fn wait_cancel(){while !cancelled(){tokio::time::sleep(Duration::from_millis(100)).await;}}
struct Guard;
impl Drop for Guard { fn drop(&mut self){ if let Ok(mut x)=ANSWER.lock(){*x=None;} BUSY.store(false,Ordering::SeqCst); } }
unsafe fn string(p:*const c_char, max:usize)->Option<String>{
    if p.is_null(){return None;}let x=CStr::from_ptr(p).to_str().ok()?;
    if x.len()>max{return None;}Some(x.to_owned())
}
fn start(dir:String,operation:Operation)->bool {
    if !Path::new(&dir).is_absolute(){return false;}
    {
        let Ok(mut state)=STATE.lock() else{return false;};
        if BUSY.swap(true,Ordering::SeqCst){return false;}
        CANCEL.store(false,Ordering::SeqCst);if let Ok(mut a)=ANSWER.lock(){*a=None;}
        *state=Some(json!({"phase":"starting"}));
    }
    let launched=std::thread::Builder::new().name("clearsetup".into()).spawn(move ||{
        let _guard=Guard;
        let result=std::panic::catch_unwind(||{
            let _lock=crate::LOCK.try_lock().map_err(|_|"engine_busy")?;
            std::env::set_var("BARISTORE_HOME",dir);
            let rt=tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().map_err(|_|"engine_unavailable")?;
            let timeout=if matches!(&operation,Operation::Auth{..}) {300} else {150};
            let r=rt.block_on(async {tokio::select! {
                result=tokio::time::timeout(Duration::from_secs(timeout),run(operation))=>result.unwrap_or(Err("timeout")),
                _=wait_cancel()=>Err("cancelled")
            }});
            rt.shutdown_timeout(Duration::from_secs(2));r
        }).unwrap_or(Err("engine_unavailable"));
        // A terminal snapshot must mean BUSY is already released. Holding STATE
        // prevents a new start from overwriting / being overwritten by it.
        if let Ok(mut state)=STATE.lock(){
            drop(_guard);
            *state=Some(match result{Ok(phase)=>json!({"phase":phase}),Err(code)=>json!({"phase":"error","code":code})});
        }
    });
    if launched.is_err(){BUSY.store(false,Ordering::SeqCst);fail("engine_unavailable");return false;}true
}
enum Operation { Pair, Verify, Auth{email:String,password:String,server:String} }
async fn run(op:Operation)->Result<&'static str,&'static str>{
    match op {
        Operation::Pair=>{
            let identity=HostIdentity::generate();
            let listener=tokio::net::TcpListener::bind(("::",0)).await.map_err(|_|"listener_failed")?;
            let port=listener.local_addr().map_err(|_|"listener_failed")?.port();
            let txt:std::collections::BTreeMap<String,String>=host::txt_records(&identity,"A19Core").into_iter().collect();
            update(json!({"phase":"advertise","port":port,"identifier":identity.identifier.clone(),"txt":txt}));
            let (stream,_)=listener.accept().await.map_err(|_|"connection_failed")?;
            // The user must explicitly approve the pairing in iOS Settings; one connection per attempt.
            let log=|_:String|{};
            let peer=host::PairableHost::new(stream,&identity,"A19Core",&log).accept(||async{
                let code=format!("{:06}",rand::thread_rng().gen_range(0..1_000_000));
                update(json!({"phase":"pairCode","code":code}));code
            }).await.map_err(|_|"pairing_rejected")?;
            if peer.udid.is_empty() || peer.public_key.len()!=32 || cancelled(){return Err("incomplete_pairing");}
            let record=PairingRecord{host:identity,peer};
            state::write_private(&state::path("pairing.plist"),&record.to_xml()).map_err(|_|"storage_failed")?;
            Ok("paired")
        },
        Operation::Verify=>{
            let record=std::fs::read(state::path("pairing.plist")).ok().and_then(|x|PairingRecord::from_bytes(&x)).ok_or("pairing_missing")?;
            update(json!({"phase":"verifying"}));
            let session=Session::open(&record).await.map_err(|_|"vpn_or_pairing_unavailable")?;
            if record.peer.udid!=session.udid{return Err("device_mismatch");}
            Ok("verified")
        },
        Operation::Auth{email,password,server}=>{
            if !server.is_empty() && !anisette::SERVERS.contains(&server.as_str()){return Err("server_not_allowed");}
            update(json!({"phase":"authenticating"}));
            let challenge=std::sync::atomic::AtomicUsize::new(0);
            let ask=move |kind:gsa::CodeKind,hint:Option<String>| -> std::pin::Pin<Box<dyn std::future::Future<Output=Option<String>>+Send>> {
                let number=challenge.fetch_add(1,Ordering::SeqCst)+1;
                Box::pin(async move{
                    // No automatic submission: every upstream challenge requires user input.
                    update(json!({"phase":"twoFactor","challenge":number,"retry":hint.is_some(),"kind":if kind==gsa::CodeKind::Sms{"sms"}else{"trustedDevice"}}));
                    loop{if cancelled(){return None;}let answer=ANSWER.lock().ok().and_then(|mut x|x.take());if let Some(code)=answer{update(json!({"phase":"authenticating"}));return Some(code);}tokio::time::sleep(Duration::from_millis(150)).await;}
                })
            };
            let status=|_:String|{update(json!({"phase":"authenticating"}));};
            gsa::clearsign_login_once(&email,&password,&server,&ask,&status).await?;
            Ok("authenticated")
        }
    }
}
#[no_mangle]pub unsafe extern "C" fn clearsign_setup_pair(dir:*const c_char)->bool {string(dir,4096).map(|d|start(d,Operation::Pair)).unwrap_or(false)}
#[no_mangle]pub unsafe extern "C" fn clearsign_setup_verify(dir:*const c_char)->bool {string(dir,4096).map(|d|start(d,Operation::Verify)).unwrap_or(false)}
#[no_mangle]pub unsafe extern "C" fn clearsign_setup_auth(dir:*const c_char,email:*const c_char,password:*const c_char,server:*const c_char)->bool {
    match (string(dir,4096),string(email,320),string(password,1024),string(server,512)) {
        (Some(d),Some(email),Some(password),Some(server)) if !email.is_empty() && !password.is_empty()=>start(d,Operation::Auth{email,password,server}),_=>false
    }
}
#[no_mangle]pub extern "C" fn clearsign_setup_poll()->*mut c_char {response(STATE.lock().ok().and_then(|x|x.clone()).unwrap_or(json!({"phase":"idle"})))}
#[no_mangle]pub unsafe extern "C" fn clearsign_setup_code(code:*const c_char)->bool {
    let Some(code)=string(code,6) else{return false;};
    if code!="sms" && (code.len()!=6 || !code.bytes().all(|b|b.is_ascii_digit())){return false;}
    let Ok(mut state)=STATE.lock() else{return false;};
    if state.as_ref().and_then(|v|v.get("phase")).and_then(Value::as_str)!=Some("twoFactor"){return false;}
    if code=="sms" && state.as_ref().and_then(|v|v.get("kind")).and_then(Value::as_str)!=Some("trustedDevice"){return false;}
    if let Ok(mut a)=ANSWER.lock(){if a.is_none(){*a=Some(code);*state=Some(json!({"phase":"authenticating"}));return true;}}false
}
#[no_mangle]pub extern "C" fn clearsign_setup_cancel(){CANCEL.store(true,Ordering::SeqCst);}
