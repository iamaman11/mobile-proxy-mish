//! Android-only wrapper over the supported NDK explicit-network APIs.
//!
//! This module is the single scoped `unsafe` boundary for B2c. It contains no
//! cellular-selection policy: callers pass only a `NetworkHandle` already admitted
//! by the Rust natural owner.

use crate::CellularNetworkOperationError;
use mish_cellular::NetworkHandle;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

const NUMERIC_HOST_BUFFER_LEN: usize = 1025;

pub(super) fn bind_socket(
    network: NetworkHandle,
    socket_fd: i32,
) -> Result<(), CellularNetworkOperationError> {
    // SAFETY: `network` is a non-zero Android Network handle admitted by the owner,
    // and `socket_fd` has been validated by the safe caller as a non-negative fd.
    // The NDK call neither takes ownership of the fd nor retains Rust references.
    let result = unsafe { ndk_sys::android_setsocknetwork(network.raw(), socket_fd) };

    if result == 0 {
        Ok(())
    } else {
        Err(CellularNetworkOperationError::NativeSocketBindFailed)
    }
}

pub(super) fn resolve_host(
    network: NetworkHandle,
    hostname: &str,
) -> Result<Vec<String>, CellularNetworkOperationError> {
    let node = CString::new(hostname)
        .map_err(|_| CellularNetworkOperationError::InvalidHostname)?;
    let mut raw_results: *mut ndk_sys::addrinfo = ptr::null_mut();

    // SAFETY: `node` is a live NUL-terminated C string for the duration of the call;
    // `raw_results` is a valid out-pointer; null service/hints are explicitly allowed
    // by android_getaddrinfofornetwork/getaddrinfo semantics. The returned list is
    // owned by the caller and released below with `freeaddrinfo`.
    let result = unsafe {
        ndk_sys::android_getaddrinfofornetwork(
            network.raw(),
            node.as_ptr(),
            ptr::null(),
            ptr::null(),
            &mut raw_results,
        )
    };

    if result != 0 {
        return Err(CellularNetworkOperationError::NativeDnsLookupFailed);
    }
    if raw_results.is_null() {
        return Err(CellularNetworkOperationError::NativeDnsNoResults);
    }

    let results = AddrInfoList(raw_results);
    numeric_hosts(&results)
}

struct AddrInfoList(*mut ndk_sys::addrinfo);

impl Drop for AddrInfoList {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: `self.0` is the head returned by a successful
            // android_getaddrinfofornetwork call and is released exactly once here.
            unsafe { ndk_sys::freeaddrinfo(self.0) };
        }
    }
}

fn numeric_hosts(
    results: &AddrInfoList,
) -> Result<Vec<String>, CellularNetworkOperationError> {
    let mut addresses = Vec::new();
    let mut current = results.0;

    while !current.is_null() {
        // SAFETY: `current` points into the still-live addrinfo list owned by `results`.
        // We advance only through `ai_next` pointers supplied by that list.
        let info = unsafe { &*current };

        if !info.ai_addr.is_null() {
            let mut host = [0 as c_char; NUMERIC_HOST_BUFFER_LEN];

            // SAFETY: `ai_addr`/`ai_addrlen` come from the live addrinfo node.
            // `host` is a writable buffer of the advertised length; service output is
            // intentionally omitted. NI_NUMERICHOST prevents a second DNS lookup.
            let conversion = unsafe {
                ndk_sys::getnameinfo(
                    info.ai_addr,
                    info.ai_addrlen,
                    host.as_mut_ptr(),
                    host.len() as ndk_sys::socklen_t,
                    ptr::null_mut(),
                    0,
                    ndk_sys::NI_NUMERICHOST as i32,
                )
            };

            if conversion != 0 {
                return Err(CellularNetworkOperationError::NativeAddressConversionFailed);
            }

            // SAFETY: successful getnameinfo writes a NUL-terminated host string into
            // the supplied buffer because the buffer is NI_MAXHOST-sized.
            let address = unsafe { CStr::from_ptr(host.as_ptr()) }
                .to_str()
                .map_err(|_| CellularNetworkOperationError::NativeAddressConversionFailed)?
                .to_owned();

            if !addresses.contains(&address) {
                addresses.push(address);
            }
        }

        current = info.ai_next;
    }

    if addresses.is_empty() {
        Err(CellularNetworkOperationError::NativeDnsNoResults)
    } else {
        Ok(addresses)
    }
}
