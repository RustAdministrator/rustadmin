use super::*;
use std::{
    collections::HashSet,
    ops::{Deref, DerefMut},
    thread::{self, JoinHandle},
    time,
};

pub trait Service: Send + Sync {
    fn name(&self) -> String;
    fn on_subscribe(&self, sub: ConnInner);
    fn on_unsubscribe(&self, id: i32);
    fn is_subed(&self, id: i32) -> bool;
    fn join(&self);
    fn get_option(&self, opt: &str) -> Option<String>;
    fn set_option(&self, opt: &str, val: &str) -> Option<String>;
    fn ok(&self) -> bool;
}

pub trait Subscriber: Default + Send + Sync + 'static {
    fn id(&self) -> i32;
    fn send(&mut self, msg: Arc<Message>);
}

#[derive(Default)]
pub struct ServiceInner<T: Subscriber + From<ConnInner>> {
    name: String,
    handle: Option<JoinHandle<()>>,
    subscribes: HashMap<i32, T>,
    new_subscribes: HashMap<i32, T>,
    active: bool,
    need_snapshot: bool,
    options: HashMap<String, String>,
}

pub trait Reset {
    fn reset(&mut self);
    fn init(&mut self) {}
}

pub struct ServiceTmpl<T: Subscriber + From<ConnInner>>(Arc<RwLock<ServiceInner<T>>>);
pub struct ServiceSwap<T: Subscriber + From<ConnInner>>(ServiceTmpl<T>);
pub type GenericService = ServiceTmpl<ConnInner>;
pub const HIBERNATE_TIMEOUT: u64 = 30;
pub const MAX_ERROR_TIMEOUT: u64 = 1_000;
pub const SERVICE_OPTION_VALUE_TRUE: &str = "1";
pub const SERVICE_OPTION_VALUE_FALSE: &str = "0";

#[derive(Clone)]
pub struct EmptyExtraFieldService {
    pub sp: GenericService,
}

impl Deref for EmptyExtraFieldService {
    type Target = ServiceTmpl<ConnInner>;

    fn deref(&self) -> &Self::Target {
        &self.sp
    }
}

impl DerefMut for EmptyExtraFieldService {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.sp
    }
}

impl EmptyExtraFieldService {
    pub fn new(name: String, need_snapshot: bool) -> Self {
        Self {
            sp: GenericService::new(name, need_snapshot),
        }
    }
}

impl<T: Subscriber + From<ConnInner>> ServiceInner<T> {
    fn send_new_subscribes(&mut self, msg: Arc<Message>) {
        for s in self.new_subscribes.values_mut() {
            s.send(msg.clone());
        }
    }

    fn swap_new_subscribes(&mut self) {
        for (_, s) in self.new_subscribes.drain() {
            self.subscribes.insert(s.id(), s);
        }
        debug_assert!(self.new_subscribes.is_empty());
    }

    #[inline]
    fn has_subscribes(&self) -> bool {
        self.subscribes.len() > 0 || self.new_subscribes.len() > 0
    }
}

impl<T: Subscriber + From<ConnInner>> Service for ServiceTmpl<T> {
    #[inline]
    fn name(&self) -> String {
        self.0.read().unwrap().name.clone()
    }

    fn is_subed(&self, id: i32) -> bool {
        self.0.read().unwrap().subscribes.get(&id).is_some()
            || self.0.read().unwrap().new_subscribes.get(&id).is_some()
    }

    fn on_subscribe(&self, sub: ConnInner) {
        let mut lock = self.0.write().unwrap();
        if lock.subscribes.get(&sub.id()).is_some() {
            log::info!(
                "diag service subscribe skipped: name={}, conn_id={}, already_subscribed=true",
                &lock.name,
                sub.id()
            );
            return;
        }
        let conn_id = sub.id();
        let deferred = lock.need_snapshot;
        if lock.need_snapshot {
            lock.new_subscribes.insert(sub.id(), sub.into());
        } else {
            lock.subscribes.insert(sub.id(), sub.into());
        }
        log::info!(
            "diag service subscribe: name={}, conn_id={}, deferred={}",
            &lock.name,
            conn_id,
            deferred
        );
    }

    fn on_unsubscribe(&self, id: i32) {
        let mut lock = self.0.write().unwrap();
        let active_removed = lock.subscribes.remove(&id).is_some();
        let deferred_removed = if active_removed {
            false
        } else {
            lock.new_subscribes.remove(&id).is_some()
        };
        log::info!(
            "diag service unsubscribe: name={}, conn_id={}, active_removed={}, deferred_removed={}",
            &lock.name,
            id,
            active_removed,
            deferred_removed
        );
    }

    fn join(&self) {
        self.0.write().unwrap().active = false;
        let handle = self.0.write().unwrap().handle.take();
        if let Some(handle) = handle {
            if let Err(e) = handle.join() {
                log::error!("Failed to join thread for service {}, {:?}", self.name(), e);
            }
        }
    }

    fn get_option(&self, opt: &str) -> Option<String> {
        self.0.read().unwrap().options.get(opt).cloned()
    }

    fn set_option(&self, opt: &str, val: &str) -> Option<String> {
        self.0
            .write()
            .unwrap()
            .options
            .insert(opt.to_string(), val.to_string())
    }

    #[inline]
    fn ok(&self) -> bool {
        let lock = self.0.read().unwrap();
        lock.active && lock.has_subscribes()
    }
}

impl<T: Subscriber + From<ConnInner>> Clone for ServiceTmpl<T> {
    fn clone(&self) -> Self {
        Self(self.0.clone())
    }
}

impl<T: Subscriber + From<ConnInner>> ServiceTmpl<T> {
    pub fn new(name: String, need_snapshot: bool) -> Self {
        Self(Arc::new(RwLock::new(ServiceInner::<T> {
            name,
            active: true,
            need_snapshot,
            ..Default::default()
        })))
    }

    #[inline]
    pub fn is_option_true(&self, opt: &str) -> bool {
        self.get_option(opt)
            .map_or(false, |v| v == SERVICE_OPTION_VALUE_TRUE)
    }

    #[inline]
    pub fn set_option_bool(&self, opt: &str, val: bool) {
        if val {
            self.set_option(opt, SERVICE_OPTION_VALUE_TRUE);
        } else {
            self.set_option(opt, SERVICE_OPTION_VALUE_FALSE);
        }
    }

    #[inline]
    pub fn has_subscribes(&self) -> bool {
        self.0.read().unwrap().has_subscribes()
    }

    pub fn subscriber_ids(&self) -> HashSet<i32> {
        let lock = self.0.read().unwrap();
        let mut ids = HashSet::with_capacity(lock.subscribes.len() + lock.new_subscribes.len());
        ids.extend(lock.subscribes.keys().copied());
        ids.extend(lock.new_subscribes.keys().copied());
        ids
    }

    pub fn has_pending_subscribers(&self) -> bool {
        !self.0.read().unwrap().new_subscribes.is_empty()
    }

    /// Promotion and first reference-frame delivery share the service lock. A
    /// subscriber arriving after this keyframe stays pending for the next one.
    /// `snapshot` cannot provide this guarantee: its Drop promotes even on error.
    pub fn send_video_frame_with_join(
        &self,
        msg: Message,
        starts_with_keyframe: bool,
    ) -> HashSet<i32> {
        let msg = Arc::new(msg);
        let mut lock = self.0.write().unwrap();
        if starts_with_keyframe {
            lock.swap_new_subscribes();
        }
        let mut ids = HashSet::with_capacity(lock.subscribes.len());
        for s in lock.subscribes.values_mut() {
            s.send(msg.clone());
            ids.insert(s.id());
        }
        ids
    }

    pub fn snapshot<F>(&self, callback: F) -> ResultType<()>
    where
        F: FnMut(ServiceSwap<T>) -> ResultType<()>,
    {
        if self.0.read().unwrap().new_subscribes.len() > 0 {
            log::info!("Call snapshot of {} service", self.name());
            let mut callback = callback;
            callback(ServiceSwap::<T>(self.clone()))?;
        }
        Ok(())
    }

    #[inline]
    pub fn send(&self, msg: Message) {
        self.send_shared(Arc::new(msg));
    }

    pub fn send_to(&self, msg: Message, id: i32) {
        if let Some(s) = self.0.write().unwrap().subscribes.get_mut(&id) {
            s.send(Arc::new(msg));
        }
    }

    pub fn send_to_others(&self, msg: Message, id: i32) {
        let msg = Arc::new(msg);
        let mut lock = self.0.write().unwrap();
        for (sid, s) in lock.subscribes.iter_mut() {
            if *sid != id {
                s.send(msg.clone());
            }
        }
    }

    pub fn send_shared(&self, msg: Arc<Message>) {
        let mut lock = self.0.write().unwrap();
        for s in lock.subscribes.values_mut() {
            s.send(msg.clone());
        }
    }

    pub fn send_video_frame(&self, msg: Message) -> HashSet<i32> {
        self.send_video_frame_shared(Arc::new(msg))
    }

    pub fn send_video_frame_shared(&self, msg: Arc<Message>) -> HashSet<i32> {
        let mut conn_ids = HashSet::new();
        let mut lock = self.0.write().unwrap();
        for s in lock.subscribes.values_mut() {
            s.send(msg.clone());
            conn_ids.insert(s.id());
        }
        conn_ids
    }

    pub fn send_without(&self, msg: Message, sub: i32) {
        let mut lock = self.0.write().unwrap();
        let msg = Arc::new(msg);
        for s in lock.subscribes.values_mut() {
            if sub != s.id() {
                s.send(msg.clone());
            }
        }
    }

    pub fn repeat<S, F, Svc>(svc: &Svc, interval_ms: u64, callback: F)
    where
        F: 'static + FnMut(Svc, &mut S) -> ResultType<()> + Send,
        S: 'static + Default + Reset,
        Svc: 'static + Clone + Send + DerefMut<Target = ServiceTmpl<T>>,
    {
        let interval = time::Duration::from_millis(interval_ms);
        let mut callback = callback;
        let sp = svc.clone();
        let thread = thread::spawn(move || {
            let mut state = S::default();
            let mut may_reset = false;
            while sp.active() {
                let now = time::Instant::now();
                if sp.has_subscribes() {
                    if !may_reset {
                        may_reset = true;
                        state.init();
                    }
                    if let Err(err) = callback(sp.clone(), &mut state) {
                        log::error!("Error of {} service: {}", sp.name(), err);
                        thread::sleep(time::Duration::from_millis(MAX_ERROR_TIMEOUT));
                        #[cfg(windows)]
                        crate::platform::windows::try_change_desktop();
                    }
                } else if may_reset {
                    state.reset();
                    may_reset = false;
                }
                let elapsed = now.elapsed();
                if elapsed < interval {
                    thread::sleep(interval - elapsed);
                }
            }
            log::info!("Service {} exit", sp.name());
        });
        svc.0.write().unwrap().handle = Some(thread);
    }

    pub fn run<F, Svc>(svc: &Svc, callback: F)
    where
        F: 'static + FnMut(Svc) -> ResultType<()> + Send,
        Svc: 'static + Clone + Send + DerefMut<Target = ServiceTmpl<T>>,
    {
        let sp = svc.clone();
        let mut callback = callback;
        let thread = thread::spawn(move || {
            let mut error_timeout = HIBERNATE_TIMEOUT;
            while sp.active() {
                if sp.has_subscribes() {
                    log::debug!("Enter {} service inner loop", sp.name());
                    let tm = time::Instant::now();
                    if let Err(err) = callback(sp.clone()) {
                        log::error!("Error of {} service: {}", sp.name(), err);
                        if tm.elapsed() > time::Duration::from_millis(MAX_ERROR_TIMEOUT) {
                            error_timeout = HIBERNATE_TIMEOUT;
                        } else {
                            error_timeout *= 2;
                        }
                        if error_timeout > MAX_ERROR_TIMEOUT {
                            error_timeout = MAX_ERROR_TIMEOUT;
                        }
                        thread::sleep(time::Duration::from_millis(error_timeout));
                        #[cfg(windows)]
                        crate::platform::windows::try_change_desktop();
                    } else {
                        log::debug!("Exit {} service inner loop", sp.name());
                    }
                }
                thread::sleep(time::Duration::from_millis(HIBERNATE_TIMEOUT));
            }
            log::info!("Service {} exit", sp.name());
        });
        svc.0.write().unwrap().handle = Some(thread);
    }

    #[inline]
    pub fn active(&self) -> bool {
        self.0.read().unwrap().active
    }
}

impl<T: Subscriber + From<ConnInner>> ServiceSwap<T> {
    #[inline]
    pub fn send(&self, msg: Message) {
        self.send_shared(Arc::new(msg));
    }

    #[inline]
    pub fn send_shared(&self, msg: Arc<Message>) {
        (self.0).0.write().unwrap().send_new_subscribes(msg);
    }

    #[inline]
    pub fn has_subscribes(&self) -> bool {
        (self.0).0.read().unwrap().subscribes.len() > 0
    }
}

impl<T: Subscriber + From<ConnInner>> Drop for ServiceSwap<T> {
    fn drop(&mut self) {
        (self.0).0.write().unwrap().swap_new_subscribes();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct TestSubscriber {
        id: i32,
        frames: Arc<Mutex<Vec<(u64, u64)>>>,
    }

    impl From<ConnInner> for TestSubscriber {
        fn from(conn: ConnInner) -> Self {
            Self {
                id: conn.id(),
                ..Self::default()
            }
        }
    }

    impl Subscriber for TestSubscriber {
        fn id(&self) -> i32 {
            self.id
        }
        fn send(&mut self, msg: Arc<Message>) {
            if let Some(message::Union::VideoFrame(frame)) = msg.union.as_ref() {
                self.frames
                    .lock()
                    .unwrap()
                    .push((frame.stream_id, frame.frame_id));
            }
        }
    }

    fn frame(id: u64) -> Message {
        let mut msg = Message::new();
        msg.set_video_frame(hbb_common::message_proto::VideoFrame {
            stream_id: 99,
            frame_id: id,
            ..Default::default()
        });
        msg
    }

    #[test]
    fn subscriber_join_delivers_reference_before_delta_without_replacing_stream() {
        let service = ServiceTmpl::<TestSubscriber>::new("join-test".into(), true);
        let a = Arc::new(Mutex::new(Vec::new()));
        let b = Arc::new(Mutex::new(Vec::new()));
        service.0.write().unwrap().new_subscribes.insert(
            1,
            TestSubscriber {
                id: 1,
                frames: a.clone(),
            },
        );
        assert!(service
            .send_video_frame_with_join(frame(1), false)
            .is_empty());
        assert_eq!(
            service.send_video_frame_with_join(frame(2), true),
            HashSet::from([1])
        );
        service.0.write().unwrap().new_subscribes.insert(
            2,
            TestSubscriber {
                id: 2,
                frames: b.clone(),
            },
        );
        assert_eq!(
            service.send_video_frame_with_join(frame(3), false),
            HashSet::from([1])
        );
        assert!(b.lock().unwrap().is_empty());
        assert!(service.has_pending_subscribers());
        assert_eq!(
            service.send_video_frame_with_join(frame(4), true),
            HashSet::from([1, 2])
        );
        service.send_video_frame_with_join(frame(5), false);
        assert!(!service.has_pending_subscribers());
        assert_eq!(*a.lock().unwrap(), [(99, 2), (99, 3), (99, 4), (99, 5)]);
        assert_eq!(*b.lock().unwrap(), [(99, 4), (99, 5)]);
    }

    #[test]
    fn legacy_snapshot_promotes_even_when_callback_requests_switch() {
        let service = ServiceTmpl::<TestSubscriber>::new("snapshot-test".into(), true);
        service.0.write().unwrap().new_subscribes.insert(
            1,
            TestSubscriber {
                id: 1,
                ..Default::default()
            },
        );
        assert!(service.snapshot(|_| bail!("SWITCH")).is_err());
        assert!(!service.has_pending_subscribers());
        // This characterizes why an in-place join must not use snapshot/Drop.
        assert_eq!(
            service.send_video_frame_with_join(frame(1), false),
            HashSet::from([1])
        );
    }
}
