// Adapter only. The actual SRP, 2FA, route selection and token retrieval
// are the pinned upstream BariStore functions, without protocol patches.
fn clear_login_error(e: LoginError) -> &'static str {
    match e {
        LoginError::WrongPassword(_) => "auth_credentials_or_throttled",
        LoginError::IdentityRefused(_) => "auth_identity_refused",
        LoginError::ServiceRefused(_) => "auth_service_refused",
        LoginError::Stop(_) => "auth_security_stop",
        LoginError::Cancelled => "auth_cancelled",
        LoginError::Other(_) => "auth_upstream_failed",
    }
}
pub async fn clearsign_login_once(email:&str,password:&str,server:&str,ask:&CodeAsker,status:&(dyn Fn(String)+Send+Sync))->Result<(), &'static str>{
    if !server.is_empty() && !SERVERS.contains(&server){return Err("auth_route_invalid");}
    // Upstream candidate_servers reads this setting: empty means Auto.
    let settings=serde_json::json!({"anisette":server});
    state::write_private(&state::path("settings.json"),settings.to_string().as_bytes()).map_err(|_|"auth_storage_failed")?;
    let (_gs,account)=login(email,password,ask,status).await.map_err(clear_login_error)?;
    // Exactly as upstream app.rs: persist the returned account.
    account.save().map_err(|_|"auth_storage_failed")?;
    Ok(())
}
#[cfg(test)]
mod clear_login_tests {
    use super::*;
    #[test] fn diagnostics_do_not_leak_payloads() {
        assert_eq!(clear_login_error(LoginError::Other("secret payload".into())),"auth_upstream_failed");
        assert_eq!(clear_login_error(LoginError::WrongPassword("private".into())),"auth_credentials_or_throttled");
        assert_eq!(clear_login_error(LoginError::Stop("private".into())),"auth_security_stop");
    }
}
