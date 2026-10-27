use std::ptr;

use hbb_common::libc::c_void;

use super::ffi::*;

//TODO: Color space, YCbCr matrix.
pub struct Config {
    /// Whether the cursor is visible.
    pub cursor: bool,
    /// Whether it should letterbox or stretch.
    pub letterbox: bool,
    /// Minimum seconds per frame.
    pub throttle: f64,
    /// How many frames are allocated.
    /// 3 is the recommended value.
    /// 8 is the maximum value.
    pub queue_length: i8,
}

impl Config {
    pub fn for_resource_mode(mode: hbb_common::ResourceMode) -> Self {
        let mut config = Self::default();
        config.throttle = mode
            .active_fps_cap()
            .map_or(0.0, |fps| 1.0 / f64::from(fps));
        config
    }

    /// Don't forget to CFRelease this!
    pub fn build(self) -> CFDictionaryRef {
        unsafe {
            let throttle = CFNumberCreate(
                ptr::null_mut(),
                CFNumberType::Float64,
                &self.throttle as *const _ as *const c_void,
            );
            let queue_length = CFNumberCreate(
                ptr::null_mut(),
                CFNumberType::SInt8,
                &self.queue_length as *const _ as *const c_void,
            );

            let keys: [CFStringRef; 4] = [
                kCGDisplayStreamShowCursor,
                kCGDisplayStreamPreserveAspectRatio,
                kCGDisplayStreamMinimumFrameTime,
                kCGDisplayStreamQueueDepth,
            ];
            let values: [*mut c_void; 4] = [
                cfbool(self.cursor),
                cfbool(self.letterbox),
                throttle,
                queue_length,
            ];

            let res = CFDictionaryCreate(
                ptr::null_mut(),
                keys.as_ptr(),
                values.as_ptr(),
                4,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks,
            );

            CFRelease(throttle);
            CFRelease(queue_length);

            res
        }
    }
}

impl Default for Config {
    fn default() -> Config {
        Config {
            cursor: false,
            letterbox: true,
            throttle: 0.0,
            queue_length: 3,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resource_mode_throttle_is_source_cadence_and_normal_is_uncapped() {
        assert_eq!(
            Config::for_resource_mode(hbb_common::ResourceMode::Normal).throttle,
            0.0
        );
        assert_eq!(
            Config::for_resource_mode(hbb_common::ResourceMode::LowPower).throttle,
            0.1
        );
        assert_eq!(
            Config::for_resource_mode(hbb_common::ResourceMode::MinimizeGpu).throttle,
            0.1
        );
    }
}
