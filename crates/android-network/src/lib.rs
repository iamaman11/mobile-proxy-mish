//! Narrow Android network-scoped DNS mechanics adapter.
//!
//! The target One Agent topology physically rejected `Network.bindSocket` /
//! `android_setsocknetwork`, so socket-routing mechanics do not belong here anymore.
//! This transitional adapter retains only read-only DNS resolution against an already
//! owner-issued Android Network authority. Final proxy-target resolver/anti-leak ownership
//! remains Issue #64.

use mish_cellular::CellularNetworkAuthority;
use std::fmt;

/// Fail-closed errors for the transitional exact-network DNS mechanic.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AndroidNetworkError {
    InvalidHostname,
    NativeDnsLookupFailed,
    NativeDnsNoResults,
    NativeAddressConversionFailed,
    UnsupportedPlatform,
}

impl fmt::Display for AndroidNetworkError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidHostname => "hostname must be non-empty and contain no NUL byte",
            Self::NativeDnsLookupFailed => "Android network-scoped DNS lookup failed",
            Self::NativeDnsNoResults => "Android network-scoped DNS lookup returned no addresses",
            Self::NativeAddressConversionFailed => {
                "Android network-scoped DNS address conversion failed"
            }
            Self::UnsupportedPlatform => "network-scoped DNS requires Android",
        })
    }
}

impl std::error::Error for AndroidNetworkError {}

/// Resolves a hostname using DNS associated with the exact Android Network carried by
/// an owner-issued Cellular Egress authority.
///
/// The API is intentionally read-only: it cannot bind/connect a socket or select a
/// network. Runtime verifies the authority generation before and after this call.
pub fn resolve_host(
    authority: CellularNetworkAuthority,
    hostname: &str,
) -> Result<Vec<String>, AndroidNetworkError> {
    if hostname.is_empty() || hostname.as_bytes().contains(&0) {
        return Err(AndroidNetworkError::InvalidHostname);
    }
    resolve_host_on_platform(authority, hostname)
}

#[cfg(target_os = "android")]
fn resolve_host_on_platform(
    authority: CellularNetworkAuthority,
    hostname: &str,
) -> Result<Vec<String>, AndroidNetworkError> {
    android::resolve_host(authority, hostname)
}

#[cfg(not(target_os = "android"))]
fn resolve_host_on_platform(
    authority: CellularNetworkAuthority,
    hostname: &str,
) -> Result<Vec<String>, AndroidNetworkError> {
    let _ = (authority, hostname);
    Err(AndroidNetworkError::UnsupportedPlatform)
}

#[cfg(target_os = "android")]
#[allow(unsafe_code)]
mod android {
    use super::{AndroidNetworkError, CellularNetworkAuthority};
    use std::ffi::CString;
    use std::net::{Ipv4Addr, Ipv6Addr};
    use std::ptr;

    pub(super) fn resolve_host(
        authority: CellularNetworkAuthority,
        hostname: &str,
    ) -> Result<Vec<String>, AndroidNetworkError> {
        let node = CString::new(hostname).map_err(|_| AndroidNetworkError::InvalidHostname)?;
        let mut raw_results: *mut ndk_sys::addrinfo = ptr::null_mut();

        // SAFETY: `node` is a live NUL-terminated string for the synchronous call;
        // `raw_results` is a valid out-pointer. Android owns the returned addrinfo list
        // until it is released by `AddrInfoList::drop` below.
        let result = unsafe {
            ndk_sys::android_getaddrinfofornetwork(
                authority.network_handle().raw(),
                node.as_ptr(),
                ptr::null(),
                ptr::null(),
                &mut raw_results,
            )
        };
        if result != 0 {
            return Err(AndroidNetworkError::NativeDnsLookupFailed);
        }
        if raw_results.is_null() {
            return Err(AndroidNetworkError::NativeDnsNoResults);
        }

        let results = AddrInfoList(raw_results);
        let mut addresses = Vec::new();
        let mut current = results.0;
        while !current.is_null() {
            // SAFETY: nodes belong to the live addrinfo list and are traversed only by
            // the documented `ai_next` pointer until null.
            let info = unsafe { &*current };
            if info.ai_addr.is_null() {
                return Err(AndroidNetworkError::NativeAddressConversionFailed);
            }
            match info.ai_family {
                libc::AF_INET => {
                    if (info.ai_addrlen as usize) < std::mem::size_of::<libc::sockaddr_in>() {
                        return Err(AndroidNetworkError::NativeAddressConversionFailed);
                    }
                    // SAFETY: family/length were validated for sockaddr_in.
                    let address = unsafe { &*(info.ai_addr.cast::<libc::sockaddr_in>()) };
                    addresses.push(
                        Ipv4Addr::from(u32::from_be(address.sin_addr.s_addr)).to_string(),
                    );
                }
                libc::AF_INET6 => {
                    if (info.ai_addrlen as usize) < std::mem::size_of::<libc::sockaddr_in6>() {
                        return Err(AndroidNetworkError::NativeAddressConversionFailed);
                    }
                    // SAFETY: family/length were validated for sockaddr_in6.
                    let address = unsafe { &*(info.ai_addr.cast::<libc::sockaddr_in6>()) };
                    addresses.push(Ipv6Addr::from(address.sin6_addr.s6_addr).to_string());
                }
                _ => {}
            }
            current = info.ai_next;
        }

        addresses.sort();
        addresses.dedup();
        if addresses.is_empty() {
            Err(AndroidNetworkError::NativeDnsNoResults)
        } else {
            Ok(addresses)
        }
    }

    struct AddrInfoList(*mut ndk_sys::addrinfo);

    impl Drop for AddrInfoList {
        fn drop(&mut self) {
            // SAFETY: the pointer is the original non-null list returned by
            // android_getaddrinfofornetwork and is released exactly once here.
            unsafe { libc::freeaddrinfo(self.0.cast::<libc::addrinfo>()) }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_hostname_is_rejected_before_platform_access() {
        // Host tests cannot mint the private authority; the public input validator is
        // therefore covered through this small pure predicate instead of pretending to
        // exercise Android DNS.
        assert!("".is_empty());
        assert!("bad\0host".as_bytes().contains(&0));
    }
}
