use super::{linux::*, ResultType};
use crate::client::{
    LOGIN_MSG_DESKTOP_NO_DESKTOP, LOGIN_MSG_DESKTOP_SESSION_ANOTHER_USER,
    LOGIN_MSG_DESKTOP_SESSION_NOT_READY, LOGIN_MSG_DESKTOP_XORG_NOT_FOUND,
    LOGIN_MSG_DESKTOP_XSESSION_FAILED, LOGIN_MSG_PASSWORD_WRONG,
};
use hbb_common::{
    allow_err, bail, log,
    rand::prelude::*,
    tokio::time,
    users::{get_user_by_name, os::unix::UserExt, User},
};
use pam;
use std::{
    collections::HashMap,
    ffi::{CStr, CString},
    os::raw::{c_char, c_int, c_void},
    os::unix::process::CommandExt,
    path::Path,
    process::{Child, Command},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{sync_channel, SyncSender},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

lazy_static::lazy_static! {
    static ref DESKTOP_RUNNING: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
    static ref DESKTOP_MANAGER: Arc<Mutex<Option<DesktopManager>>> = Arc::new(Mutex::new(None));
}

struct PamCredentials {
    username: String,
    password: String,
}

struct PamSession<'a> {
    handle: &'a mut pam::PamHandle,
    _credentials: Box<PamCredentials>,
    is_authenticated: bool,
    has_open_session: bool,
    last_code: pam::PamReturnCode,
}

impl<'a> PamSession<'a> {
    fn with_password(service: &str, username: &str, password: &str) -> pam::PamResult<Self> {
        let mut credentials = Box::new(PamCredentials {
            username: username.to_owned(),
            password: password.to_owned(),
        });
        let conv = pam::ffi::pam_conv {
            conv: Some(pam_converse),
            appdata_ptr: &mut *credentials as *mut PamCredentials as *mut c_void,
        };
        let handle = pam::start(service, None, &conv)?;
        Ok(Self {
            handle,
            _credentials: credentials,
            is_authenticated: false,
            has_open_session: false,
            last_code: pam::PamReturnCode::Success,
        })
    }

    fn authenticate(&mut self) -> pam::PamResult<()> {
        let code = pam::authenticate(self.handle, pam::PamFlag::None);
        self.check(code)?;
        self.is_authenticated = true;
        let code = pam::acct_mgmt(self.handle, pam::PamFlag::None);
        self.check(code).or_else(|_| self.reset())
    }

    fn set_item(&mut self, item_type: pam::PamItemType, item: &str) -> pam::PamResult<()> {
        let item = CString::new(item).map_err(|_| pam::PamError(pam::PamReturnCode::Buf_Err))?;
        let code = unsafe {
            // SAFETY: `item` is a NUL-terminated C string that remains alive for this call.
            // Linux-PAM copies item data for string item types such as PAM_TTY.
            pam::ffi::pam_set_item(
                self.handle,
                item_type as c_int,
                item.as_ptr() as *const c_void,
            )
        }
        .into();
        self.check(code)
    }

    fn open_session(&mut self) -> pam::PamResult<()> {
        if !self.is_authenticated {
            return Err(pam::PamReturnCode::Perm_Denied.into());
        }

        let code = pam::setcred(self.handle, pam::PamFlag::Establish_Cred);
        self.check(code).or_else(|_| self.reset())?;
        let code = pam::open_session(self.handle, false);
        self.check(code).or_else(|_| self.reset())?;
        let code = pam::setcred(self.handle, pam::PamFlag::Reinitialize_Cred);
        self.check(code).or_else(|_| self.reset())?;
        self.has_open_session = true;
        self.initialize_environment()?;
        Ok(())
    }

    fn initialize_environment(&mut self) -> pam::PamResult<()> {
        let username = self.get_user()?;
        let user =
            get_user_by_name(&username).ok_or(pam::PamError(pam::PamReturnCode::User_Unknown))?;
        let name = user
            .name()
            .to_str()
            .ok_or(pam::PamError(pam::PamReturnCode::System_Err))?;
        let home = user
            .home_dir()
            .to_str()
            .ok_or(pam::PamError(pam::PamReturnCode::System_Err))?;
        let shell = user
            .shell()
            .to_str()
            .ok_or(pam::PamError(pam::PamReturnCode::System_Err))?;

        self.set_env("USER", name)?;
        self.set_env("LOGNAME", name)?;
        self.set_env("HOME", home)?;
        self.set_env("PWD", home)?;
        self.set_env("SHELL", shell)?;
        Ok(())
    }

    fn get_user(&mut self) -> pam::PamResult<String> {
        pam::get_item(self.handle, pam::PamItemType::User).and_then(|result| {
            let ptr = result as *const c_void as *const c_char;
            if ptr.is_null() {
                return Err(pam::PamError(pam::PamReturnCode::System_Err));
            }
            let username = unsafe {
                // SAFETY: PAM returns a valid NUL-terminated PAM_USER string for this item.
                CStr::from_ptr(ptr)
            };
            username
                .to_str()
                .map(|username| username.to_owned())
                .map_err(|_| pam::PamError(pam::PamReturnCode::System_Err))
        })
    }

    fn set_env(&mut self, key: &str, value: &str) -> pam::PamResult<()> {
        std::env::set_var(key, value);
        if pam::getenv(self.handle, key).is_ok() {
            pam::putenv(self.handle, &format!("{key}={value}"))
        } else {
            Ok(())
        }
    }

    fn check(&mut self, code: pam::PamReturnCode) -> pam::PamResult<()> {
        self.last_code = code;
        if code == pam::PamReturnCode::Success {
            Ok(())
        } else {
            Err(code.into())
        }
    }

    fn reset(&mut self) -> pam::PamResult<()> {
        pam::setcred(self.handle, pam::PamFlag::Delete_Cred);
        self.is_authenticated = false;
        Err(self.last_code.into())
    }
}

impl Drop for PamSession<'_> {
    fn drop(&mut self) {
        if self.has_open_session {
            pam::close_session(self.handle, false);
        }
        let code = pam::setcred(self.handle, pam::PamFlag::Delete_Cred);
        pam::end(self.handle, code);
    }
}

unsafe extern "C" fn pam_converse(
    num_msg: c_int,
    msg: *mut *const pam::PamMessage,
    out_resp: *mut *mut pam::PamResponse,
    appdata_ptr: *mut c_void,
) -> c_int {
    if num_msg <= 0 || msg.is_null() || out_resp.is_null() || appdata_ptr.is_null() {
        return pam::PamReturnCode::Conv_Err as c_int;
    }

    let resp = unsafe {
        // SAFETY: Allocates a zeroed PAM response array with `num_msg` entries.
        libc::calloc(num_msg as usize, std::mem::size_of::<pam::PamResponse>())
            as *mut pam::PamResponse
    };
    if resp.is_null() {
        return pam::PamReturnCode::Buf_Err as c_int;
    }

    let credentials = unsafe {
        // SAFETY: `appdata_ptr` was created from a live `PamCredentials` box in `with_password`.
        &mut *(appdata_ptr as *mut PamCredentials)
    };
    let mut result = pam::PamReturnCode::Success;

    for i in 0..num_msg as isize {
        let message_ptr = unsafe {
            // SAFETY: PAM supplied an array of `num_msg` message pointers.
            *msg.offset(i)
        };
        if message_ptr.is_null() {
            result = pam::PamReturnCode::Conv_Err;
            break;
        }
        let message = unsafe {
            // SAFETY: Null was checked above and PAM owns this message for the callback duration.
            &*message_ptr
        };
        let response = unsafe {
            // SAFETY: `resp` has `num_msg` entries allocated by `calloc`.
            &mut *resp.offset(i)
        };
        let text = match pam::PamMessageStyle::from(message.msg_style) {
            pam::PamMessageStyle::Prompt_Echo_On => &credentials.username,
            pam::PamMessageStyle::Prompt_Echo_Off => &credentials.password,
            pam::PamMessageStyle::Text_Info => continue,
            pam::PamMessageStyle::Error_Msg => {
                if !message.msg.is_null() {
                    let message = unsafe {
                        // SAFETY: PAM error messages are NUL-terminated strings for this callback.
                        CStr::from_ptr(message.msg)
                    };
                    log::warn!("[PAM ERROR] {}", message.to_string_lossy());
                }
                result = pam::PamReturnCode::Conv_Err;
                break;
            }
        };

        let Ok(text) = CString::new(text.as_str()) else {
            result = pam::PamReturnCode::Buf_Err;
            break;
        };
        response.resp = unsafe {
            // SAFETY: `text` is a valid C string and `strdup` allocates the PAM-owned response.
            libc::strdup(text.as_ptr())
        };
        if response.resp.is_null() {
            result = pam::PamReturnCode::Buf_Err;
            break;
        }
    }

    if result == pam::PamReturnCode::Success {
        unsafe {
            // SAFETY: `out_resp` was checked for null and PAM expects ownership of `resp`.
            *out_resp = resp;
        }
    } else {
        for i in 0..num_msg as isize {
            let response = unsafe {
                // SAFETY: `resp` has `num_msg` entries allocated by `calloc`.
                &mut *resp.offset(i)
            };
            if !response.resp.is_null() {
                unsafe {
                    // SAFETY: response strings were allocated with `strdup` above.
                    libc::free(response.resp as *mut c_void);
                }
            }
        }
        unsafe {
            // SAFETY: `resp` was allocated with `calloc` above and is not returned to PAM.
            libc::free(resp as *mut c_void);
            *out_resp = std::ptr::null_mut();
        }
    }

    result as c_int
}

#[derive(Debug)]
struct DesktopManager {
    seat0_username: String,
    seat0_display_server: String,
    child_username: String,
    child_exit: Arc<AtomicBool>,
    is_child_running: Arc<AtomicBool>,
}

fn check_desktop_manager() {
    let mut desktop_manager = DESKTOP_MANAGER.lock().unwrap();
    if let Some(desktop_manager) = &mut (*desktop_manager) {
        if desktop_manager.is_child_running.load(Ordering::SeqCst) {
            return;
        }
        desktop_manager.child_exit.store(true, Ordering::SeqCst);
    }
}

pub fn start_xdesktop() {
    debug_assert!(crate::is_server());
    std::thread::spawn(|| {
        *DESKTOP_MANAGER.lock().unwrap() = Some(DesktopManager::new());

        let interval = time::Duration::from_millis(super::SERVICE_INTERVAL);
        DESKTOP_RUNNING.store(true, Ordering::SeqCst);
        while DESKTOP_RUNNING.load(Ordering::SeqCst) {
            check_desktop_manager();
            std::thread::sleep(interval);
        }
        log::info!("xdesktop child thread exit");
    });
}

pub fn stop_xdesktop() {
    DESKTOP_RUNNING.store(false, Ordering::SeqCst);
    *DESKTOP_MANAGER.lock().unwrap() = None;
}

fn detect_headless() -> Option<&'static str> {
    match run_cmds(&format!("which {}", DesktopManager::get_xorg())) {
        Ok(output) => {
            if output.trim().is_empty() {
                return Some(LOGIN_MSG_DESKTOP_XORG_NOT_FOUND);
            }
        }
        _ => {
            return Some(LOGIN_MSG_DESKTOP_XORG_NOT_FOUND);
        }
    }

    match run_cmds("ls /usr/share/xsessions/") {
        Ok(output) => {
            if output.trim().is_empty() {
                return Some(LOGIN_MSG_DESKTOP_NO_DESKTOP);
            }
        }
        _ => {
            return Some(LOGIN_MSG_DESKTOP_NO_DESKTOP);
        }
    }

    None
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum XSessionStartErrorKind {
    Auth,
    Env,
}

const XSESSION_AUTH_FAILURE_DETAIL: &str = "authentication failed";

#[derive(Debug)]
struct XSessionStartError {
    kind: XSessionStartErrorKind,
    detail: String,
}

impl XSessionStartError {
    fn auth(detail: String) -> Self {
        Self {
            kind: XSessionStartErrorKind::Auth,
            detail,
        }
    }

    fn env(detail: String) -> Self {
        Self {
            kind: XSessionStartErrorKind::Env,
            detail,
        }
    }
}

impl std::fmt::Display for XSessionStartError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.detail)
    }
}

fn map_xsession_start_error_to_login_msg(kind: XSessionStartErrorKind) -> &'static str {
    match kind {
        XSessionStartErrorKind::Auth => LOGIN_MSG_PASSWORD_WRONG,
        XSessionStartErrorKind::Env => LOGIN_MSG_DESKTOP_XSESSION_FAILED,
    }
}

pub fn try_start_desktop(_username: &str, _passsword: &str) -> String {
    debug_assert!(crate::is_server());
    if _username.is_empty() {
        let username = get_username();
        if username.is_empty() {
            if let Some(msg) = detect_headless() {
                msg
            } else {
                LOGIN_MSG_DESKTOP_SESSION_NOT_READY
            }
        } else {
            ""
        }
        .to_owned()
    } else {
        let username = get_username();
        if username == _username {
            // No need to verify password here.
            return "".to_owned();
        }
        if !username.is_empty() {
            // Another user is logged in. No need to start a new xsession.
            return "".to_owned();
        }

        if let Some(msg) = detect_headless() {
            return msg.to_owned();
        }

        match try_start_x_session(_username, _passsword) {
            Ok((username, x11_ready)) => {
                if x11_ready {
                    if _username != username {
                        LOGIN_MSG_DESKTOP_SESSION_ANOTHER_USER.to_owned()
                    } else {
                        "".to_owned()
                    }
                } else {
                    LOGIN_MSG_DESKTOP_SESSION_NOT_READY.to_owned()
                }
            }
            Err(e) => {
                match e.kind {
                    XSessionStartErrorKind::Auth => {
                        log::warn!("Failed to authenticate xsession user {}", e);
                    }
                    XSessionStartErrorKind::Env => {
                        log::error!("Failed to start xsession {}", e);
                    }
                }
                map_xsession_start_error_to_login_msg(e.kind).to_owned()
            }
        }
    }
}

fn try_start_x_session(
    username: &str,
    password: &str,
) -> Result<(String, bool), XSessionStartError> {
    let mut desktop_manager = DESKTOP_MANAGER.lock().unwrap();
    if let Some(desktop_manager) = &mut (*desktop_manager) {
        if let Some(seat0_username) = desktop_manager.get_supported_display_seat0_username() {
            return Ok((seat0_username, true));
        }

        let _ = desktop_manager.try_start_x_session(username, password)?;
        log::debug!(
            "try_start_x_session, username: {}, {:?}",
            &username,
            &desktop_manager
        );
        Ok((
            desktop_manager.child_username.clone(),
            desktop_manager.is_running(),
        ))
    } else {
        Err(XSessionStartError::env(
            crate::client::LOGIN_MSG_DESKTOP_NOT_INITED.to_owned(),
        ))
    }
}

#[inline]
pub fn is_headless() -> bool {
    DESKTOP_MANAGER
        .lock()
        .unwrap()
        .as_ref()
        .map_or(false, |manager| {
            manager.get_supported_display_seat0_username().is_none()
        })
}

pub fn get_username() -> String {
    match &*DESKTOP_MANAGER.lock().unwrap() {
        Some(manager) => {
            if let Some(seat0_username) = manager.get_supported_display_seat0_username() {
                seat0_username
            } else {
                if manager.is_running() && !manager.child_username.is_empty() {
                    manager.child_username.clone()
                } else {
                    "".to_owned()
                }
            }
        }
        None => "".to_owned(),
    }
}

impl Drop for DesktopManager {
    fn drop(&mut self) {
        self.stop_children();
    }
}

impl DesktopManager {
    fn fatal_exit() {
        std::process::exit(0);
    }

    pub fn new() -> Self {
        let mut seat0_username = "".to_owned();
        let mut seat0_display_server = "".to_owned();
        let seat0_values = get_values_of_seat0(&[0, 2]);
        if !seat0_values[0].is_empty() {
            seat0_username = seat0_values[1].clone();
            seat0_display_server = get_display_server_of_session(&seat0_values[0]);
        }
        Self {
            seat0_username,
            seat0_display_server,
            child_username: "".to_owned(),
            child_exit: Arc::new(AtomicBool::new(true)),
            is_child_running: Arc::new(AtomicBool::new(false)),
        }
    }

    fn get_supported_display_seat0_username(&self) -> Option<String> {
        if is_gdm_user(&self.seat0_username) && self.seat0_display_server == DISPLAY_SERVER_WAYLAND
        {
            None
        } else if self.seat0_username.is_empty() {
            None
        } else {
            Some(self.seat0_username.clone())
        }
    }

    #[inline]
    fn get_xauth() -> String {
        let xauth = get_env_var("XAUTHORITY");
        if xauth.is_empty() {
            "/tmp/.Xauthority".to_owned()
        } else {
            xauth
        }
    }

    #[inline]
    fn is_running(&self) -> bool {
        self.is_child_running.load(Ordering::SeqCst)
    }

    fn try_start_x_session(
        &mut self,
        username: &str,
        password: &str,
    ) -> Result<(), XSessionStartError> {
        match get_user_by_name(username) {
            Some(userinfo) => {
                let mut session =
                    PamSession::with_password(&pam_get_service_name(), username, password)
                        .map_err(|e| {
                            XSessionStartError::env(format!("failed to init pam session, {}", e))
                        })?;
                match session.authenticate() {
                    Ok(_) => {
                        if self.is_running() {
                            return Ok(());
                        }

                        match self.start_x_session(&userinfo, username, password) {
                            Ok(_) => {
                                log::info!("Succeeded to start x11");
                                self.child_username = username.to_string();
                                Ok(())
                            }
                            Err(e) => Err(XSessionStartError::env(format!(
                                "failed to start x session, {}",
                                e
                            ))),
                        }
                    }
                    Err(_e) => Err(XSessionStartError::auth(
                        XSESSION_AUTH_FAILURE_DETAIL.to_owned(),
                    )),
                }
            }
            None => Err(XSessionStartError::auth(
                XSESSION_AUTH_FAILURE_DETAIL.to_owned(),
            )),
        }
    }

    // The logic mainly from https://github.com/neutrinolabs/xrdp/blob/34fe9b60ebaea59e8814bbc3ca5383cabaa1b869/sesman/session.c#L334.
    fn get_avail_display() -> ResultType<u32> {
        let display_range = 0..51;
        for i in display_range.clone() {
            if Self::is_x_server_running(i) {
                continue;
            }
            return Ok(i);
        }
        bail!("No available display found in range {:?}", display_range)
    }

    #[inline]
    fn is_x_server_running(display: u32) -> bool {
        Path::new(&format!("/tmp/.X11-unix/X{}", display)).exists()
            || Path::new(&format!("/tmp/.X{}-lock", display)).exists()
    }

    fn start_x_session(
        &mut self,
        userinfo: &User,
        username: &str,
        password: &str,
    ) -> ResultType<()> {
        self.stop_children();

        let display_num = Self::get_avail_display()?;
        // "xServer_ip:display_num.screen_num"

        let uid = userinfo.uid();
        let gid = userinfo.primary_group_id();
        let envs = HashMap::from([
            ("SHELL", userinfo.shell().to_string_lossy().to_string()),
            ("PATH", "/sbin:/bin:/usr/bin:/usr/local/bin".to_owned()),
            ("USER", username.to_string()),
            ("UID", userinfo.uid().to_string()),
            ("HOME", userinfo.home_dir().to_string_lossy().to_string()),
            (
                "XDG_RUNTIME_DIR",
                format!("/run/user/{}", userinfo.uid().to_string()),
            ),
            // ("DISPLAY", self.display.clone()),
            // ("XAUTHORITY", self.xauth.clone()),
            // (ENV_DESKTOP_PROTOCOL, XProtocol::X11.to_string()),
        ]);
        self.child_exit.store(false, Ordering::SeqCst);
        let is_child_running = self.is_child_running.clone();

        let (tx_res, rx_res) = sync_channel(1);
        let password = password.to_string();
        let username = username.to_string();
        // start x11
        std::thread::spawn(move || {
            match Self::start_x_session_thread(
                tx_res.clone(),
                is_child_running,
                uid,
                gid,
                display_num,
                username,
                password,
                envs,
            ) {
                Ok(_) => {}
                Err(e) => {
                    log::error!("Failed to start x session thread");
                    allow_err!(tx_res.send(format!("Failed to start x session thread, {}", e)));
                }
            }
        });

        // wait x11
        match rx_res.recv_timeout(Duration::from_millis(10_000)) {
            Ok(res) => {
                if res == "" {
                    Ok(())
                } else {
                    bail!(res)
                }
            }
            Err(e) => {
                bail!("Failed to recv x11 result {}", e)
            }
        }
    }

    #[inline]
    fn display_from_num(num: u32) -> String {
        format!(":{num}")
    }

    fn start_x_session_thread(
        tx_res: SyncSender<String>,
        is_child_running: Arc<AtomicBool>,
        uid: u32,
        gid: u32,
        display_num: u32,
        username: String,
        password: String,
        envs: HashMap<&str, String>,
    ) -> ResultType<()> {
        let mut session = PamSession::with_password(&pam_get_service_name(), &username, &password)?;
        session.authenticate()?;
        session.set_item(pam::PamItemType::TTY, &Self::display_from_num(display_num))?;
        session.open_session()?;

        // fixme: FreeBSD kernel needs to login here.
        // see: https://github.com/neutrinolabs/xrdp/blob/a64573b596b5fb07ca3a51590c5308d621f7214e/sesman/session.c#L556

        let (child_xorg, child_wm) = Self::start_x11(uid, gid, username, display_num, &envs)?;
        is_child_running.store(true, Ordering::SeqCst);

        log::info!("Start xorg and wm done, notify and wait xtop x11");
        allow_err!(tx_res.send("".to_owned()));

        Self::wait_stop_x11(child_xorg, child_wm);
        log::info!("Wait x11 stop done");
        Ok(())
    }

    fn wait_xorg_exit(child_xorg: &mut Child) -> ResultType<String> {
        if let Ok(_) = child_xorg.kill() {
            for _ in 0..3 {
                match child_xorg.try_wait() {
                    Ok(Some(status)) => return Ok(format!("Xorg exit with {}", status)),
                    Ok(None) => {}
                    Err(e) => {
                        // fatal error
                        log::error!("Failed to wait xorg process, {}", e);
                        bail!("Failed to wait xorg process, {}", e)
                    }
                }
                std::thread::sleep(std::time::Duration::from_millis(1_000));
            }
            log::error!("Failed to wait xorg process, not exit");
            bail!("Failed to wait xorg process, not exit")
        } else {
            Ok("Xorg is already exited".to_owned())
        }
    }

    fn add_xauth_cookie(
        file: &str,
        display: &str,
        uid: u32,
        gid: u32,
        envs: &HashMap<&str, String>,
    ) -> ResultType<()> {
        let randstr = (0..16)
            .map(|_| format!("{:02x}", random::<u8>()))
            .collect::<String>();
        let output = Command::new("xauth")
            .uid(uid)
            .gid(gid)
            .envs(envs)
            .args(vec!["-q", "-f", file, "add", display, ".", &randstr])
            .output()?;
        // xauth run success, even the following error occurs.
        // Ok(Output { status: ExitStatus(unix_wait_status(0)), stdout: "", stderr: "xauth:  file .Xauthority does not exist\n" })
        let errmsg = String::from_utf8_lossy(&output.stderr).to_string();
        if !errmsg.is_empty() {
            if !errmsg.contains("does not exist") {
                bail!("Failed to launch xauth, {}", errmsg)
            }
        }
        Ok(())
    }

    fn wait_x_server_running(pid: u32, display_num: u32, max_wait_secs: u64) -> ResultType<()> {
        let wait_begin = Instant::now();
        loop {
            if run_cmds(&format!("ls /proc/{}", pid))?.is_empty() {
                bail!("X server exit");
            }

            if Self::is_x_server_running(display_num) {
                return Ok(());
            }
            if wait_begin.elapsed().as_secs() > max_wait_secs {
                bail!("Failed to wait xserver after {} seconds", max_wait_secs);
            }
            std::thread::sleep(Duration::from_millis(300));
        }
    }

    fn start_x11(
        uid: u32,
        gid: u32,
        username: String,
        display_num: u32,
        envs: &HashMap<&str, String>,
    ) -> ResultType<(Child, Child)> {
        log::debug!("envs of user {}: {:?}", &username, &envs);

        let xauth = Self::get_xauth();
        let display = Self::display_from_num(display_num);

        Self::add_xauth_cookie(&xauth, &display, uid, gid, &envs)?;

        // Start Xorg
        let mut child_xorg = Self::start_x_server(&xauth, &display, uid, gid, &envs)?;

        log::info!("xorg started, wait 10 secs to ensuer x server is running");

        let max_wait_secs = 10;
        // wait x server running
        if let Err(e) = Self::wait_x_server_running(child_xorg.id(), display_num, max_wait_secs) {
            match Self::wait_xorg_exit(&mut child_xorg) {
                Ok(msg) => log::info!("{}", msg),
                Err(e) => {
                    log::error!("{}", e);
                    Self::fatal_exit();
                }
            }
            bail!(e)
        }

        log::info!(
            "xorg is running, start x window manager with DISPLAY: {}, XAUTHORITY: {}",
            &display,
            &xauth
        );

        std::env::set_var("DISPLAY", &display);
        std::env::set_var("XAUTHORITY", &xauth);
        // start window manager (startwm.sh)
        let child_wm = match Self::start_x_window_manager(uid, gid, &envs) {
            Ok(c) => c,
            Err(e) => {
                match Self::wait_xorg_exit(&mut child_xorg) {
                    Ok(msg) => log::info!("{}", msg),
                    Err(e) => {
                        log::error!("{}", e);
                        Self::fatal_exit();
                    }
                }
                bail!(e)
            }
        };
        log::info!("x window manager is started");

        Ok((child_xorg, child_wm))
    }

    fn try_wait_x11_child_exit(child_xorg: &mut Child, child_wm: &mut Child) -> bool {
        match child_xorg.try_wait() {
            Ok(Some(status)) => {
                log::info!("Xorg exit with {}", status);
                return true;
            }
            Ok(None) => {}
            Err(e) => log::error!("Failed to wait xorg process, {}", e),
        }

        match child_wm.try_wait() {
            Ok(Some(status)) => {
                // Logout may result "wm exit with signal: 11 (SIGSEGV) (core dumped)"
                log::info!("wm exit with {}", status);
                return true;
            }
            Ok(None) => {}
            Err(e) => log::error!("Failed to wait xorg process, {}", e),
        }
        false
    }

    fn wait_x11_children_exit(child_xorg: &mut Child, child_wm: &mut Child) {
        log::debug!("Try kill child process xorg");
        if let Ok(_) = child_xorg.kill() {
            let mut exited = false;
            for _ in 0..2 {
                match child_xorg.try_wait() {
                    Ok(Some(status)) => {
                        log::info!("Xorg exit with {}", status);
                        exited = true;
                        break;
                    }
                    Ok(None) => {}
                    Err(e) => {
                        log::error!("Failed to wait xorg process, {}", e);
                        Self::fatal_exit();
                    }
                }
                std::thread::sleep(std::time::Duration::from_millis(1_000));
            }
            if !exited {
                log::error!("Failed to wait child xorg, after kill()");
                // try kill -9?
            }
        }
        log::debug!("Try kill child process wm");
        if let Ok(_) = child_wm.kill() {
            let mut exited = false;
            for _ in 0..2 {
                match child_wm.try_wait() {
                    Ok(Some(status)) => {
                        // Logout may result "wm exit with signal: 11 (SIGSEGV) (core dumped)"
                        log::info!("wm exit with {}", status);
                        exited = true;
                    }
                    Ok(None) => {}
                    Err(e) => {
                        log::error!("Failed to wait wm process, {}", e);
                        Self::fatal_exit();
                    }
                }
                std::thread::sleep(std::time::Duration::from_millis(1_000));
            }
            if !exited {
                log::error!("Failed to wait child xorg, after kill()");
                // try kill -9?
            }
        }
    }

    fn try_wait_stop_x11(child_xorg: &mut Child, child_wm: &mut Child) -> bool {
        let mut desktop_manager = DESKTOP_MANAGER.lock().unwrap();
        let mut exited = true;
        if let Some(desktop_manager) = &mut (*desktop_manager) {
            if desktop_manager.child_exit.load(Ordering::SeqCst) {
                exited = true;
            } else {
                exited = Self::try_wait_x11_child_exit(child_xorg, child_wm);
            }
            if exited {
                log::debug!("Wait x11 children exiting");
                Self::wait_x11_children_exit(child_xorg, child_wm);
                desktop_manager
                    .is_child_running
                    .store(false, Ordering::SeqCst);
                desktop_manager.child_exit.store(true, Ordering::SeqCst);
            }
        }
        exited
    }

    fn wait_stop_x11(mut child_xorg: Child, mut child_wm: Child) {
        loop {
            if Self::try_wait_stop_x11(&mut child_xorg, &mut child_wm) {
                break;
            }
            std::thread::sleep(Duration::from_millis(super::SERVICE_INTERVAL));
        }
    }

    fn get_xorg() -> &'static str {
        // Fedora 26 or later
        let xorg = "/usr/libexec/Xorg";
        if Path::new(xorg).is_file() {
            return xorg;
        }
        // Debian 9 or later
        let xorg = "/usr/lib/xorg/Xorg";
        if Path::new(xorg).is_file() {
            return xorg;
        }
        // Ubuntu 16.04 or later
        let xorg = "/usr/lib/xorg/Xorg";
        if Path::new(xorg).is_file() {
            return xorg;
        }
        // Arch Linux
        let xorg = "/usr/lib/xorg-server/Xorg";
        if Path::new(xorg).is_file() {
            return xorg;
        }
        // Arch Linux
        let xorg = "/usr/lib/Xorg";
        if Path::new(xorg).is_file() {
            return xorg;
        }
        // CentOS 7 /usr/bin/Xorg or param=Xorg

        log::warn!("Failed to find xorg, use default Xorg.\n Please add \"allowed_users=anybody\" to \"/etc/X11/Xwrapper.config\".");
        "Xorg"
    }

    fn start_x_server(
        xauth: &str,
        display: &str,
        uid: u32,
        gid: u32,
        envs: &HashMap<&str, String>,
    ) -> ResultType<Child> {
        let xorg = Self::get_xorg();
        log::info!("Use xorg: {}", &xorg);
        let app_name = crate::get_app_name().to_lowercase();
        let conf = format!("/etc/{app_name}/xorg.conf");
        match Command::new(xorg)
            .envs(envs)
            .uid(uid)
            .gid(gid)
            .args(vec![
                "-noreset",
                "+extension",
                "GLX",
                "+extension",
                "RANDR",
                "+extension",
                "RENDER",
                "-config",
                conf.as_ref(),
                "-auth",
                xauth,
                display,
            ])
            .spawn()
        {
            Ok(c) => Ok(c),
            Err(e) => {
                bail!("Failed to start Xorg with display {}, {}", display, e);
            }
        }
    }

    fn start_x_window_manager(
        uid: u32,
        gid: u32,
        envs: &HashMap<&str, String>,
    ) -> ResultType<Child> {
        let app_name = crate::get_app_name().to_lowercase();
        match Command::new(&format!("/etc/{app_name}/startwm.sh"))
            .envs(envs)
            .uid(uid)
            .gid(gid)
            .spawn()
        {
            Ok(c) => Ok(c),
            Err(e) => {
                bail!("Failed to start window manager, {}", e);
            }
        }
    }

    fn stop_children(&mut self) {
        self.child_exit.store(true, Ordering::SeqCst);
        for _i in 1..10 {
            if !self.is_child_running.load(Ordering::SeqCst) {
                break;
            }
            std::thread::sleep(Duration::from_millis(super::SERVICE_INTERVAL));
        }
        if self.is_child_running.load(Ordering::SeqCst) {
            log::warn!("xdesktop child is still running!");
        }
    }
}

fn pam_get_service_name() -> String {
    let app_name = crate::get_app_name().to_lowercase();
    if Path::new(&format!("/etc/pam.d/{app_name}")).is_file() {
        app_name
    } else {
        "gdm".to_owned()
    }
}
