//! A single protocol-auth seam: the accepted primary plus at most one optional secondary grant.
//! Credentials owns whether the temporary grant is valid. This module checks that verdict at
//! the moment of each HTTP/SOCKS authentication; it never owns a clock, store or timer.

use crate::{ProxyCredentialMaterial, ProxyPolicyError};
use std::fmt;
use std::sync::Arc;

/// Identity is private to the authenticated relay. It never changes the original primary grant.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyPrincipal {
    Primary,
    Temporary,
}

/// Proxy-owned wire authentication policy. Called once for every newly admitted connection.
/// Implemented directly by the existing primary material to preserve the shipping path.
pub trait ProxyAuthenticator: Send + Sync {
    fn matches_http_basic(&self, supplied: &str) -> bool;
    fn matches_username_password(&self, username: &[u8], password: &[u8]) -> bool;

    /// Default is legacy primary-only; dual-auth policy overrides it without changing the wire
    /// protocol parser. A runtime session-local adapter records the result once per handshake.
    fn classify_http_basic(&self, supplied: &str) -> Option<ProxyPrincipal> {
        self.matches_http_basic(supplied)
            .then_some(ProxyPrincipal::Primary)
    }

    fn classify_username_password(
        &self,
        username: &[u8],
        password: &[u8],
    ) -> Option<ProxyPrincipal> {
        self.matches_username_password(username, password)
            .then_some(ProxyPrincipal::Primary)
    }

    /// Per-relay liveness decision called only for authenticated temporary sessions.
    fn temporary_session_available(&self) -> bool {
        false
    }

    fn socks_compatible(&self) -> bool;
}

impl ProxyAuthenticator for ProxyCredentialMaterial {
    fn matches_http_basic(&self, supplied: &str) -> bool {
        constant_time_eq(
            self.basic_authorization_value().as_bytes(),
            supplied.as_bytes(),
        )
    }

    fn matches_username_password(&self, username: &[u8], password: &[u8]) -> bool {
        constant_time_eq(self.username().as_bytes(), username)
            & constant_time_eq(self.password().as_bytes(), password)
    }

    fn socks_compatible(&self) -> bool {
        valid_socks_pair(self)
    }
}

/// Stateless proxy view of exactly one optional additional credential.
///
/// The availability callback belongs to the Credentials/composition owner, which must make a
/// fresh, fail-closed, persist-before-admit lease decision. This object cannot issue a grant or
/// extend its deadline; the primary credential is never changed by temporary admission checks.
#[derive(Clone)]
pub struct ProxyCredentialAdmission {
    primary: ProxyCredentialMaterial,
    temporary: Option<ProxyCredentialMaterial>,
    temporary_available: Option<Arc<dyn Fn() -> bool + Send + Sync>>,
}

impl ProxyCredentialAdmission {
    pub fn primary_only(primary: ProxyCredentialMaterial) -> Self {
        Self {
            primary,
            temporary: None,
            temporary_available: None,
        }
    }

    pub fn with_temporary(
        primary: ProxyCredentialMaterial,
        temporary: ProxyCredentialMaterial,
        available: impl Fn() -> bool + Send + Sync + 'static,
    ) -> Result<Self, ProxyPolicyError> {
        if primary.username() == temporary.username() {
            return Err(ProxyPolicyError::DuplicateCredentialUsername);
        }
        if !valid_socks_pair(&temporary) {
            return Err(ProxyPolicyError::InvalidTemporarySocks5Credential);
        }
        Ok(Self {
            primary,
            temporary: Some(temporary),
            temporary_available: Some(Arc::new(available)),
        })
    }

    pub fn primary(&self) -> &ProxyCredentialMaterial {
        &self.primary
    }
}

impl ProxyAuthenticator for ProxyCredentialAdmission {
    fn matches_http_basic(&self, supplied: &str) -> bool {
        let primary_ok = self.primary.matches_http_basic(supplied);
        let temporary_matches = self
            .temporary
            .as_ref()
            .is_some_and(|temp| temp.matches_http_basic(supplied));
        let temporary_ok = temporary_matches
            && self
                .temporary_available
                .as_ref()
                .is_some_and(|available| available());
        primary_ok | temporary_ok
    }

    fn matches_username_password(&self, username: &[u8], password: &[u8]) -> bool {
        let primary_ok = self.primary.matches_username_password(username, password);
        let temporary_matches = self
            .temporary
            .as_ref()
            .is_some_and(|temp| temp.matches_username_password(username, password));
        let temporary_ok = temporary_matches
            && self
                .temporary_available
                .as_ref()
                .is_some_and(|available| available());
        primary_ok | temporary_ok
    }

    fn classify_http_basic(&self, supplied: &str) -> Option<ProxyPrincipal> {
        if self.primary.matches_http_basic(supplied) {
            return Some(ProxyPrincipal::Primary);
        }
        let secondary_matches = self
            .temporary
            .as_ref()
            .is_some_and(|temp| temp.matches_http_basic(supplied));
        if secondary_matches && self.temporary_session_available() {
            Some(ProxyPrincipal::Temporary)
        } else {
            None
        }
    }

    fn classify_username_password(
        &self,
        username: &[u8],
        password: &[u8],
    ) -> Option<ProxyPrincipal> {
        if self.primary.matches_username_password(username, password) {
            return Some(ProxyPrincipal::Primary);
        }
        let secondary_matches = self
            .temporary
            .as_ref()
            .is_some_and(|temp| temp.matches_username_password(username, password));
        if secondary_matches && self.temporary_session_available() {
            Some(ProxyPrincipal::Temporary)
        } else {
            None
        }
    }

    fn temporary_session_available(&self) -> bool {
        self.temporary.is_some()
            && self
                .temporary_available
                .as_ref()
                .is_some_and(|available| available())
    }

    fn socks_compatible(&self) -> bool {
        self.primary.socks_compatible() && self.temporary.as_ref().is_none_or(valid_socks_pair)
    }
}

impl fmt::Debug for ProxyCredentialAdmission {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ProxyCredentialAdmission")
            .field("primary", &"<redacted>")
            .field("temporary", &self.temporary.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

fn valid_socks_pair(pair: &ProxyCredentialMaterial) -> bool {
    (1..=255).contains(&pair.username().len()) && (1..=255).contains(&pair.password().len())
}

fn constant_time_eq(expected: &[u8], supplied: &[u8]) -> bool {
    let mut difference = expected.len() ^ supplied.len();
    let max_len = expected.len().max(supplied.len());
    for index in 0..max_len {
        let left = expected.get(index).copied().unwrap_or(0);
        let right = supplied.get(index).copied().unwrap_or(0);
        difference |= usize::from(left ^ right);
    }
    difference == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        HttpConnectError, MixedConnectError, ProxyProtocol, Socks5ProtocolError,
        Socks5SessionError, accept_mixed_connect, accept_socks5_connect,
        parse_http_connect_request,
    };
    use std::io::{Cursor, Read, Write};
    use std::sync::atomic::{AtomicBool, Ordering};

    fn pair(u: &str, p: &str) -> ProxyCredentialMaterial {
        ProxyCredentialMaterial::new(u, p).expect("credentials")
    }

    fn http_request(pair: &ProxyCredentialMaterial) -> Vec<u8> {
        format!(
            "CONNECT example.invalid:443 HTTP/1.1\r\nProxy-Authorization: {}\r\n\r\n",
            pair.basic_authorization_value()
        )
        .into_bytes()
    }

    #[derive(Default)]
    struct MemoryIo {
        input: Cursor<Vec<u8>>,
        output: Vec<u8>,
    }

    impl MemoryIo {
        fn from_input(input: Vec<u8>) -> Self {
            Self {
                input: Cursor::new(input),
                output: Vec::new(),
            }
        }
    }

    impl Read for MemoryIo {
        fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
            self.input.read(bytes)
        }
    }

    impl Write for MemoryIo {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.output.extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn socks_request(pair: &ProxyCredentialMaterial) -> Vec<u8> {
        let mut request = vec![0x05, 0x01, 0x02, 0x01, pair.username().len() as u8];
        request.extend_from_slice(pair.username().as_bytes());
        request.push(pair.password().len() as u8);
        request.extend_from_slice(pair.password().as_bytes());
        request.extend_from_slice(&[0x05, 0x01, 0, 0x03, 15]);
        request.extend_from_slice(b"example.invalid");
        request.extend_from_slice(&443_u16.to_be_bytes());
        request
    }

    #[test]
    fn authenticated_principals_have_independent_liveness() {
        let primary = pair("owner", "owner-secret");
        let temporary = pair("guest", "guest-secret");
        let active = Arc::new(AtomicBool::new(true));
        let flag = Arc::clone(&active);
        let admission = ProxyCredentialAdmission::with_temporary(
            primary.clone(),
            temporary.clone(),
            move || flag.load(Ordering::SeqCst),
        )
        .expect("distinct principals");

        assert_eq!(
            admission.classify_http_basic(&primary.basic_authorization_value()),
            Some(ProxyPrincipal::Primary)
        );
        assert_eq!(
            admission.classify_http_basic(&temporary.basic_authorization_value()),
            Some(ProxyPrincipal::Temporary)
        );
        assert_eq!(
            admission.classify_username_password(b"guest", b"guest-secret"),
            Some(ProxyPrincipal::Temporary)
        );
        active.store(false, Ordering::SeqCst);
        assert!(!admission.temporary_session_available());
        assert_eq!(
            admission.classify_username_password(b"guest", b"guest-secret"),
            None
        );
        assert_eq!(
            admission.classify_username_password(b"owner", b"owner-secret"),
            Some(ProxyPrincipal::Primary)
        );
    }

    #[test]
    fn both_protocols_accept_primary_and_available_temporary() {
        let primary = pair("owner", "owner-secret");
        let temporary = pair("guest", "guest-secret");
        let admission =
            ProxyCredentialAdmission::with_temporary(primary.clone(), temporary.clone(), || true)
                .expect("two distinct accounts");

        for credential in [&primary, &temporary] {
            let target = parse_http_connect_request(&http_request(credential), &admission)
                .expect("HTTP allowed");
            assert_eq!(target.port(), 443);
            let mut socks = MemoryIo::from_input(socks_request(credential));
            let target = accept_socks5_connect(&mut socks, &admission).expect("SOCKS allowed");
            assert_eq!(target.port(), 443);
            assert_eq!(&socks.output[..4], &[0x05, 0x02, 0x01, 0x00]);

            let mut mixed = MemoryIo::from_input(socks_request(credential));
            let (protocol, _) =
                accept_mixed_connect(&mut mixed, &admission).expect("mixed socks allowed");
            assert_eq!(protocol, ProxyProtocol::Socks5);
            let mut mixed = MemoryIo::from_input(http_request(credential));
            let (protocol, _) =
                accept_mixed_connect(&mut mixed, &admission).expect("mixed http allowed");
            assert_eq!(protocol, ProxyProtocol::Http);
        }
    }

    #[test]
    fn revoke_or_expire_only_temporary_and_primary_continues_to_work() {
        let primary = pair("owner", "owner-secret");
        let temporary = pair("guest", "guest-secret");
        let active = Arc::new(AtomicBool::new(true));
        let flag = Arc::clone(&active);
        let admission = ProxyCredentialAdmission::with_temporary(
            primary.clone(),
            temporary.clone(),
            move || flag.load(Ordering::SeqCst),
        )
        .expect("two credentials");

        assert!(parse_http_connect_request(&http_request(&temporary), &admission).is_ok());
        active.store(false, Ordering::SeqCst);
        assert_eq!(
            parse_http_connect_request(&http_request(&temporary), &admission),
            Err(HttpConnectError::ProxyAuthenticationFailed)
        );
        assert!(parse_http_connect_request(&http_request(&primary), &admission).is_ok());

        let mut rejected = MemoryIo::from_input(socks_request(&temporary));
        assert!(matches!(
            accept_socks5_connect(&mut rejected, &admission),
            Err(Socks5SessionError::Protocol(
                Socks5ProtocolError::AuthenticationFailed
            ))
        ));
        let mut accepted = MemoryIo::from_input(socks_request(&primary));
        assert!(accept_socks5_connect(&mut accepted, &admission).is_ok());
        let mut mixed = MemoryIo::from_input(http_request(&temporary));
        assert!(matches!(
            accept_mixed_connect(&mut mixed, &admission),
            Err(MixedConnectError::Http(_))
        ));
    }

    #[test]
    fn wrong_password_and_duplicate_username_are_denied() {
        let primary = pair("owner", "owner-secret");
        let temporary = pair("guest", "guest-secret");
        let admission =
            ProxyCredentialAdmission::with_temporary(primary.clone(), temporary, || true)
                .expect("two accounts");
        let wrong = pair("guest", "wrong-secret");
        assert_eq!(
            parse_http_connect_request(&http_request(&wrong), &admission),
            Err(HttpConnectError::ProxyAuthenticationFailed)
        );
        let mut socks = MemoryIo::from_input(socks_request(&wrong));
        assert!(accept_socks5_connect(&mut socks, &admission).is_err());
        assert_eq!(
            ProxyCredentialAdmission::with_temporary(
                primary.clone(),
                pair("owner", "guest"),
                || true
            )
            .err(),
            Some(ProxyPolicyError::DuplicateCredentialUsername)
        );
        assert!(
            ProxyCredentialAdmission::with_temporary(
                primary,
                pair("guest", &"x".repeat(256)),
                || true
            )
            .is_err()
        );
    }

    #[test]
    fn no_temporary_grant_does_not_change_shipped_primary_behavior() {
        let primary = pair("owner", "owner-secret");
        let admission = ProxyCredentialAdmission::primary_only(primary.clone());
        assert!(parse_http_connect_request(&http_request(&primary), &admission).is_ok());
        let mut socks = MemoryIo::from_input(socks_request(&primary));
        assert!(accept_socks5_connect(&mut socks, &admission).is_ok());
        let report = format!("{admission:?}");
        assert!(!report.contains("owner-secret"));
        assert!(!report.contains("owner"));
    }
}
