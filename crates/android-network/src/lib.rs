//! Bounded Android exact-network mechanics adapter.
//!
//! This crate owns only supported Android/NDK operations for an already owner-issued
//! cellular authority. It does not select networks, own admission state, or provide
//! fallback/retry policy.

use mish_cellular::CellularNetworkAuthority;
use std::fmt;
use std::net::{SocketAddr, TcpStream};
use std::time::Instant;

/// Fail-closed errors for supported Android exact-network bind/DNS mechanics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AndroidNetworkError {
    InvalidSocketFd,
    InvalidHostname,
    NativeSocketBindFailed,
    NativeDnsLookupFailed,
    NativeDnsNoResults,
    NativeAddressConversionFailed,
    UnsupportedPlatform,
}

impl fmt::Display for AndroidNetworkError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidSocketFd => "socket file descriptor must be non-negative",
            Self::InvalidHostname => "hostname must be non-empty and contain no NUL byte",
            Self::NativeSocketBindFailed => "Android explicit-network socket binding failed",
            Self::NativeDnsLookupFailed => "Android explicit-network DNS lookup failed",
            Self::NativeDnsNoResults => "Android explicit-network DNS lookup returned no addresses",
            Self::NativeAddressConversionFailed => {
                "Android explicit-network DNS address conversion failed"
            }
            Self::UnsupportedPlatform => "explicit-network operation requires Android",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for AndroidNetworkError {}

/// Fail-closed errors for the deadline-bounded Android TCP connect mechanic.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AndroidConnectError {
    DeadlineExceeded,
    NativeSocketCreateFailed,
    NativeSocketBindFailed,
    NativeConnectFailed,
    NativeSocketModeFailed,
    UnsupportedPlatform,
}

impl fmt::Display for AndroidConnectError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::DeadlineExceeded => "Android exact-network TCP connect deadline exceeded",
            Self::NativeSocketCreateFailed => "Android TCP socket creation failed",
            Self::NativeSocketBindFailed => "Android explicit-network socket binding failed",
            Self::NativeConnectFailed => "Android exact-network TCP connect failed",
            Self::NativeSocketModeFailed => "Android TCP socket blocking-mode transition failed",
            Self::UnsupportedPlatform => "exact-network TCP connect requires Android",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for AndroidConnectError {}

/// Binds an existing socket to the exact Android Network carried by an owner-issued
/// cellular authority.
pub fn bind_socket(
    authority: CellularNetworkAuthority,
    socket_fd: i32,
) -> Result<(), AndroidNetworkError> {
    if socket_fd < 0 {
        return Err(AndroidNetworkError::InvalidSocketFd);
    }

    bind_socket_on_platform(authority, socket_fd)
}

/// Resolves a hostname using DNS associated with the exact Android Network carried by
/// an owner-issued cellular authority.
///
/// The call preserves Android's native `getAllByName`/getaddrinfo semantics, including
/// platform address ordering and resolver behavior. Runtime Lifecycle places this
/// blocking platform operation behind one bounded resolver worker so it cannot extend a
/// public CONNECT operation past its owner-defined deadline.
pub fn resolve_host(
    authority: CellularNetworkAuthority,
    hostname: &str,
) -> Result<Vec<String>, AndroidNetworkError> {
    if hostname.is_empty() || hostname.as_bytes().contains(&0) {
        return Err(AndroidNetworkError::InvalidHostname);
    }

    resolve_host_on_platform(authority, hostname)
}

/// Creates one nonblocking TCP socket, binds it to the exact Android Network, and then
/// performs exactly one deadline-bounded `connect(2)` attempt for a numeric target.
///
/// DNS is deliberately absent from this API. Domain resolution remains a separate
/// exact-network operation using the same owner-issued authority.
pub fn connect_tcp_until(
    authority: CellularNetworkAuthority,
    address: SocketAddr,
    deadline: Instant,
) -> Result<TcpStream, AndroidConnectError> {
    ensure_before_deadline(deadline)?;
    connect_tcp_until_on_platform(authority, address, deadline)
}

fn ensure_before_deadline(deadline: Instant) -> Result<(), AndroidConnectError> {
    if Instant::now() < deadline {
        Ok(())
    } else {
        Err(AndroidConnectError::DeadlineExceeded)
    }
}

#[cfg(target_os = "android")]
fn bind_socket_on_platform(
    authority: CellularNetworkAuthority,
    socket_fd: i32,
) -> Result<(), AndroidNetworkError> {
    android::bind_socket(authority, socket_fd)
}

#[cfg(not(target_os = "android"))]
fn bind_socket_on_platform(
    authority: CellularNetworkAuthority,
    socket_fd: i32,
) -> Result<(), AndroidNetworkError> {
    let _ = (authority, socket_fd);
    Err(AndroidNetworkError::UnsupportedPlatform)
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
fn connect_tcp_until_on_platform(
    authority: CellularNetworkAuthority,
    address: SocketAddr,
    deadline: Instant,
) -> Result<TcpStream, AndroidConnectError> {
    android::connect_tcp_until(authority, address, deadline)
}

#[cfg(not(target_os = "android"))]
fn connect_tcp_until_on_platform(
    authority: CellularNetworkAuthority,
    address: SocketAddr,
    deadline: Instant,
) -> Result<TcpStream, AndroidConnectError> {
    let _ = (authority, address, deadline);
    Err(AndroidConnectError::UnsupportedPlatform)
}

#[cfg(target_os = "android")]
#[allow(unsafe_code)]
mod android {
    use super::{
        AndroidConnectError, AndroidNetworkError, CellularNetworkAuthority, Instant, SocketAddr,
        TcpStream,
    };
    use std::ffi::{CStr, CString};
    use std::mem;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::raw::{c_char, c_int, c_void};
    use std::ptr;

    const NUMERIC_HOST_BUFFER_LEN: usize = 1025;

    pub(super) fn bind_socket(
        authority: CellularNetworkAuthority,
        socket_fd: i32,
    ) -> Result<(), AndroidNetworkError> {
        if bind_socket_fd_raw(authority, socket_fd) {
            Ok(())
        } else {
            Err(AndroidNetworkError::NativeSocketBindFailed)
        }
    }

    pub(super) fn resolve_host(
        authority: CellularNetworkAuthority,
        hostname: &str,
    ) -> Result<Vec<String>, AndroidNetworkError> {
        let node = CString::new(hostname).map_err(|_| AndroidNetworkError::InvalidHostname)?;
        let mut raw_results: *mut ndk_sys::addrinfo = ptr::null_mut();
        let network = authority.network_handle();

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
            return Err(AndroidNetworkError::NativeDnsLookupFailed);
        }
        if raw_results.is_null() {
            return Err(AndroidNetworkError::NativeDnsNoResults);
        }

        let results = AddrInfoList(raw_results);
        numeric_hosts(&results)
    }

    pub(super) fn connect_tcp_until(
        authority: CellularNetworkAuthority,
        address: SocketAddr,
        deadline: Instant,
    ) -> Result<TcpStream, AndroidConnectError> {
        let socket = create_socket(address)?;
        if !bind_socket_fd_raw(authority, socket.as_raw_fd()) {
            return Err(AndroidConnectError::NativeSocketBindFailed);
        }
        connect_socket_until(socket.as_raw_fd(), address, deadline)?;
        restore_blocking(socket.as_raw_fd())?;
        Ok(TcpStream::from(socket))
    }

    fn bind_socket_fd_raw(authority: CellularNetworkAuthority, socket_fd: i32) -> bool {
        let network = authority.network_handle();

        // SAFETY: `network` is captured in an owner-issued opaque authority token and
        // `socket_fd` has been validated/created by the safe caller. The NDK call neither
        // takes ownership of the fd nor retains Rust references.
        unsafe { ndk_sys::android_setsocknetwork(network.raw(), socket_fd) == 0 }
    }

    fn create_socket(address: SocketAddr) -> Result<OwnedFd, AndroidConnectError> {
        let domain = match address {
            SocketAddr::V4(_) => libc::AF_INET,
            SocketAddr::V6(_) => libc::AF_INET6,
        };

        // SAFETY: `socket` has no pointer arguments. On success it returns one owned fd;
        // that ownership is immediately transferred into `OwnedFd` exactly once.
        let raw_fd = unsafe {
            libc::socket(
                domain,
                libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
                libc::IPPROTO_TCP,
            )
        };
        if raw_fd < 0 {
            return Err(AndroidConnectError::NativeSocketCreateFailed);
        }

        // SAFETY: `raw_fd` is a fresh successful result from `socket(2)` and has not
        // been wrapped or closed elsewhere. `OwnedFd` closes it on every later failure.
        Ok(unsafe { OwnedFd::from_raw_fd(raw_fd) })
    }

    fn connect_socket_until(
        socket_fd: c_int,
        address: SocketAddr,
        deadline: Instant,
    ) -> Result<(), AndroidConnectError> {
        super::ensure_before_deadline(deadline)?;
        let result = raw_connect(socket_fd, address);
        if result == 0 {
            return Ok(());
        }

        let error = std::io::Error::last_os_error().raw_os_error();
        if error != Some(libc::EINPROGRESS) && error != Some(libc::EALREADY) {
            return Err(AndroidConnectError::NativeConnectFailed);
        }

        poll_writable_until(socket_fd, deadline)?;

        let mut socket_error: c_int = 0;
        let mut length = mem::size_of::<c_int>() as libc::socklen_t;
        // SAFETY: `socket_error` and `length` are valid writable buffers for SO_ERROR.
        let result = unsafe {
            libc::getsockopt(
                socket_fd,
                libc::SOL_SOCKET,
                libc::SO_ERROR,
                (&mut socket_error as *mut c_int).cast::<c_void>(),
                &mut length,
            )
        };
        if result != 0 || socket_error != 0 {
            return Err(AndroidConnectError::NativeConnectFailed);
        }

        Ok(())
    }

    fn raw_connect(socket_fd: c_int, address: SocketAddr) -> c_int {
        match address {
            SocketAddr::V4(address) => {
                let raw = libc::sockaddr_in {
                    sin_family: libc::AF_INET as libc::sa_family_t,
                    sin_port: address.port().to_be(),
                    sin_addr: libc::in_addr {
                        s_addr: u32::from_ne_bytes(address.ip().octets()),
                    },
                    sin_zero: [0; 8],
                };

                // SAFETY: `raw` is a fully initialized IPv4 sockaddr whose pointer and
                // exact length remain valid for the duration of the synchronous call.
                unsafe {
                    libc::connect(
                        socket_fd,
                        (&raw as *const libc::sockaddr_in).cast::<libc::sockaddr>(),
                        mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
                    )
                }
            }
            SocketAddr::V6(address) => {
                let raw = libc::sockaddr_in6 {
                    sin6_family: libc::AF_INET6 as libc::sa_family_t,
                    sin6_port: address.port().to_be(),
                    sin6_flowinfo: address.flowinfo().to_be(),
                    sin6_addr: libc::in6_addr {
                        s6_addr: address.ip().octets(),
                    },
                    sin6_scope_id: address.scope_id(),
                };

                // SAFETY: `raw` is a fully initialized IPv6 sockaddr whose pointer and
                // exact length remain valid for the duration of the synchronous call.
                unsafe {
                    libc::connect(
                        socket_fd,
                        (&raw as *const libc::sockaddr_in6).cast::<libc::sockaddr>(),
                        mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t,
                    )
                }
            }
        }
    }

    fn poll_writable_until(
        socket_fd: c_int,
        deadline: Instant,
    ) -> Result<(), AndroidConnectError> {
        loop {
            let timeout = poll_timeout_ms(deadline)?;
            let mut poll_fd = libc::pollfd {
                fd: socket_fd,
                events: libc::POLLOUT,
                revents: 0,
            };

            // SAFETY: `poll_fd` points to one initialized pollfd and remains valid for
            // the duration of this synchronous call.
            let result = unsafe { libc::poll(&mut poll_fd, 1, timeout) };
            if result > 0 {
                return Ok(());
            }
            if result == 0 {
                return Err(AndroidConnectError::DeadlineExceeded);
            }
            if std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
                return Err(AndroidConnectError::NativeConnectFailed);
            }
        }
    }

    fn poll_timeout_ms(deadline: Instant) -> Result<c_int, AndroidConnectError> {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or(AndroidConnectError::DeadlineExceeded)?;
        let millis = remaining.as_millis();
        if millis == 0 {
            return Ok(1);
        }
        Ok(millis.min(i32::MAX as u128) as c_int)
    }

    fn restore_blocking(socket_fd: c_int) -> Result<(), AndroidConnectError> {
        // SAFETY: fcntl operates on the live socket fd and uses integer flags only.
        let flags = unsafe { libc::fcntl(socket_fd, libc::F_GETFL) };
        if flags < 0 {
            return Err(AndroidConnectError::NativeSocketModeFailed);
        }

        // SAFETY: same live fd; clearing O_NONBLOCK preserves all unrelated flags.
        let result = unsafe { libc::fcntl(socket_fd, libc::F_SETFL, flags & !libc::O_NONBLOCK) };
        if result < 0 {
            return Err(AndroidConnectError::NativeSocketModeFailed);
        }
        Ok(())
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

    fn numeric_hosts(results: &AddrInfoList) -> Result<Vec<String>, AndroidNetworkError> {
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
                        host.len(),
                        ptr::null_mut(),
                        0,
                        ndk_sys::NI_NUMERICHOST as i32,
                    )
                };

                if conversion != 0 {
                    return Err(AndroidNetworkError::NativeAddressConversionFailed);
                }

                // SAFETY: successful getnameinfo writes a NUL-terminated host string into
                // the supplied buffer because the buffer is NI_MAXHOST-sized.
                let address = unsafe { CStr::from_ptr(host.as_ptr()) }
                    .to_str()
                    .map_err(|_| AndroidNetworkError::NativeAddressConversionFailed)?
                    .to_owned();

                if !addresses.contains(&address) {
                    addresses.push(address);
                }
            }

            current = info.ai_next;
        }

        if addresses.is_empty() {
            Err(AndroidNetworkError::NativeDnsNoResults)
        } else {
            Ok(addresses)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_cellular::{NetworkHandle, NetworkObservation, ObservationSequence};
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
    use std::time::Duration;

    fn authority() -> CellularNetworkAuthority {
        let mut owner = mish_cellular::CellularEgress::new();
        owner.observe(NetworkObservation::new(
            ObservationSequence::new(1).expect("test sequence"),
            NetworkHandle::new(42).expect("test network"),
            true,
            true,
            true,
        ));
        owner
            .admitted_network_authority()
            .expect("admitted authority")
    }

    #[test]
    fn invalid_inputs_fail_before_platform_access() {
        let authority = authority();

        assert_eq!(
            bind_socket(authority, -1),
            Err(AndroidNetworkError::InvalidSocketFd)
        );
        assert_eq!(
            resolve_host(authority, ""),
            Err(AndroidNetworkError::InvalidHostname)
        );
        assert_eq!(
            resolve_host(authority, "bad\0host"),
            Err(AndroidNetworkError::InvalidHostname)
        );
    }

    #[test]
    fn expired_connect_deadline_fails_before_platform_access() {
        let authority = authority();
        let expired = Instant::now() - Duration::from_millis(1);
        let address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 443);

        assert_eq!(
            connect_tcp_until(authority, address, expired),
            Err(AndroidConnectError::DeadlineExceeded)
        );
    }

    #[cfg(not(target_os = "android"))]
    #[test]
    fn supported_operations_fail_closed_off_android() {
        let authority = authority();
        let deadline = Instant::now() + Duration::from_secs(1);
        let address = SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), 443);

        assert_eq!(
            bind_socket(authority, 5),
            Err(AndroidNetworkError::UnsupportedPlatform)
        );
        assert_eq!(
            resolve_host(authority, "example.com"),
            Err(AndroidNetworkError::UnsupportedPlatform)
        );
        assert!(matches!(
            connect_tcp_until(authority, address, deadline),
            Err(AndroidConnectError::UnsupportedPlatform)
        ));
    }
}
