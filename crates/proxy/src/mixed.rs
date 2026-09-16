use std::fmt;
use std::io::{self, Read, Write};

use crate::{
    HttpConnectError, ProxyConnectTarget, ProxyCredentialMaterial, ProxyProtocol,
    Socks5SessionError, accept_socks5_connect, parse_http_connect_request,
};

const SOCKS5_DISCRIMINATOR: u8 = 0x05;
const HTTP_CONNECT_DISCRIMINATOR: u8 = b'C';

/// Detects one already-accepted proxy protocol without taking ownership of listener, DNS,
/// network-selection, outbound-connect or relay lifecycle concerns.
///
/// Only the discriminator byte is consumed for protocol selection. It is replayed into the
/// selected protocol owner so the delegated parser observes the original byte stream exactly.
/// HTTP CONNECT headers are then read one byte at a time until the existing HTTP owner accepts
/// the complete bounded header, which prevents consuming tunnel payload beyond `\r\n\r\n`.
pub fn accept_mixed_connect<S: Read + Write>(
    stream: &mut S,
    credentials: &ProxyCredentialMaterial,
) -> Result<(ProxyProtocol, ProxyConnectTarget), MixedConnectError> {
    let first = read_discriminator(stream)?;
    let mut replay = ReplayIo::new(first, stream);

    match first {
        SOCKS5_DISCRIMINATOR => {
            let target = accept_socks5_connect(&mut replay, credentials)?;
            Ok((ProxyProtocol::Socks5, target))
        }
        HTTP_CONNECT_DISCRIMINATOR => {
            let target = accept_http_connect_stream(&mut replay, credentials)?;
            Ok((ProxyProtocol::Http, target))
        }
        _ => Err(MixedConnectError::UnsupportedProtocol),
    }
}

fn read_discriminator<R: Read>(stream: &mut R) -> Result<u8, MixedConnectError> {
    let mut byte = [0_u8; 1];
    loop {
        match stream.read(&mut byte) {
            Ok(0) => return Err(MixedConnectError::EmptyStream),
            Ok(1) => return Ok(byte[0]),
            Ok(_) => unreachable!("one-byte read cannot return more than one byte"),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(MixedConnectError::Io(error)),
        }
    }
}

/// Reads exactly one bounded HTTP CONNECT header from a stream and leaves tunnel bytes unread.
pub fn accept_http_connect_stream<R: Read>(
    stream: &mut R,
    credentials: &ProxyCredentialMaterial,
) -> Result<ProxyConnectTarget, HttpConnectStreamError> {
    let mut request = Vec::new();

    loop {
        let mut byte = [0_u8; 1];
        match stream.read(&mut byte) {
            Ok(0) => {
                return Err(HttpConnectStreamError::Protocol(
                    HttpConnectError::IncompleteHeader,
                ));
            }
            Ok(1) => request.push(byte[0]),
            Ok(_) => unreachable!("one-byte read cannot return more than one byte"),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(HttpConnectStreamError::Io(error)),
        }

        match parse_http_connect_request(&request, credentials) {
            Err(HttpConnectError::IncompleteHeader) => {}
            Ok(target) => return Ok(target),
            Err(error) => return Err(HttpConnectStreamError::Protocol(error)),
        }
    }
}

struct ReplayIo<'a, S> {
    replay: Option<u8>,
    inner: &'a mut S,
}

impl<'a, S> ReplayIo<'a, S> {
    fn new(first: u8, inner: &'a mut S) -> Self {
        Self {
            replay: Some(first),
            inner,
        }
    }
}

impl<S: Read> Read for ReplayIo<'_, S> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        if let Some(byte) = self.replay.take() {
            buffer[0] = byte;
            return Ok(1);
        }
        self.inner.read(buffer)
    }
}

impl<S: Write> Write for ReplayIo<'_, S> {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.inner.write(buffer)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

#[derive(Debug)]
pub enum HttpConnectStreamError {
    Io(io::Error),
    Protocol(HttpConnectError),
}

impl fmt::Display for HttpConnectStreamError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "HTTP CONNECT stream I/O failed: {error}"),
            Self::Protocol(error) => write!(formatter, "HTTP CONNECT protocol failed: {error}"),
        }
    }
}

impl std::error::Error for HttpConnectStreamError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Protocol(error) => Some(error),
        }
    }
}

impl From<io::Error> for HttpConnectStreamError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<HttpConnectError> for HttpConnectStreamError {
    fn from(error: HttpConnectError) -> Self {
        Self::Protocol(error)
    }
}

#[derive(Debug)]
pub enum MixedConnectError {
    EmptyStream,
    UnsupportedProtocol,
    Io(io::Error),
    Http(HttpConnectStreamError),
    Socks5(Socks5SessionError),
}

impl fmt::Display for MixedConnectError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyStream => {
                formatter.write_str("mixed proxy ingress ended before protocol detection")
            }
            Self::UnsupportedProtocol => {
                formatter.write_str("mixed proxy ingress protocol is unsupported")
            }
            Self::Io(error) => write!(formatter, "mixed proxy ingress I/O failed: {error}"),
            Self::Http(error) => write!(formatter, "mixed proxy HTTP CONNECT failed: {error}"),
            Self::Socks5(error) => write!(formatter, "mixed proxy SOCKS5 failed: {error}"),
        }
    }
}

impl std::error::Error for MixedConnectError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Http(error) => Some(error),
            Self::Socks5(error) => Some(error),
            Self::EmptyStream | Self::UnsupportedProtocol => None,
        }
    }
}

impl From<HttpConnectStreamError> for MixedConnectError {
    fn from(error: HttpConnectStreamError) -> Self {
        Self::Http(error)
    }
}

impl From<Socks5SessionError> for MixedConnectError {
    fn from(error: Socks5SessionError) -> Self {
        Self::Socks5(error)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ProxyTargetHost;

    #[derive(Debug)]
    struct TestIo {
        input: io::Cursor<Vec<u8>>,
        output: Vec<u8>,
    }

    impl TestIo {
        fn new(input: Vec<u8>) -> Self {
            Self {
                input: io::Cursor::new(input),
                output: Vec::new(),
            }
        }

        fn remaining(&mut self) -> Vec<u8> {
            let mut remaining = Vec::new();
            self.input
                .read_to_end(&mut remaining)
                .expect("read remaining input");
            remaining
        }
    }

    impl Read for TestIo {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            self.input.read(buffer)
        }
    }

    impl Write for TestIo {
        fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
            self.output.extend_from_slice(buffer);
            Ok(buffer.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    fn credentials() -> ProxyCredentialMaterial {
        ProxyCredentialMaterial::new("user", "password").expect("valid credentials")
    }

    #[test]
    fn http_connect_dispatch_preserves_unresolved_target_and_tunnel_bytes() {
        let mut input = b"CONNECT example.invalid:443 HTTP/1.1\r\nHost: example.invalid:443\r\nProxy-Authorization: Basic dXNlcjpwYXNzd29yZA==\r\n\r\n".to_vec();
        input.extend_from_slice(b"tunnel-bytes");
        let mut io = TestIo::new(input);

        let (protocol, target) =
            accept_mixed_connect(&mut io, &credentials()).expect("HTTP CONNECT accepted");

        assert_eq!(protocol, ProxyProtocol::Http);
        assert_eq!(target.port(), 443);
        assert_eq!(
            target.host(),
            &ProxyTargetHost::Domain("example.invalid".into())
        );
        assert_eq!(target.host().numeric(), None);
        assert_eq!(io.remaining(), b"tunnel-bytes");
        assert!(io.output.is_empty());
    }

    #[test]
    fn socks5_dispatch_replays_discriminator_and_preserves_tunnel_bytes() {
        let mut input = vec![0x05, 1, 0x02, 0x01, 4];
        input.extend_from_slice(b"user");
        input.push(8);
        input.extend_from_slice(b"password");
        input.extend_from_slice(&[0x05, 0x01, 0x00, 0x03, 15]);
        input.extend_from_slice(b"example.invalid");
        input.extend_from_slice(&443_u16.to_be_bytes());
        input.extend_from_slice(b"tunnel-bytes");
        let mut io = TestIo::new(input);

        let (protocol, target) =
            accept_mixed_connect(&mut io, &credentials()).expect("SOCKS5 CONNECT accepted");

        assert_eq!(protocol, ProxyProtocol::Socks5);
        assert_eq!(target.port(), 443);
        assert_eq!(
            target.host(),
            &ProxyTargetHost::Domain("example.invalid".into())
        );
        assert_eq!(target.host().numeric(), None);
        assert_eq!(io.remaining(), b"tunnel-bytes");
        assert_eq!(io.output, vec![0x05, 0x02, 0x01, 0x00]);
    }

    #[test]
    fn unsupported_protocol_fails_after_only_the_discriminator_byte() {
        let mut io = TestIo::new(vec![0x16, 0x03, 0x01, 0x02]);

        assert!(matches!(
            accept_mixed_connect(&mut io, &credentials()),
            Err(MixedConnectError::UnsupportedProtocol)
        ));
        assert_eq!(io.remaining(), vec![0x03, 0x01, 0x02]);
        assert!(io.output.is_empty());
    }

    #[test]
    fn empty_and_incomplete_http_streams_fail_closed() {
        let mut empty = TestIo::new(Vec::new());
        assert!(matches!(
            accept_mixed_connect(&mut empty, &credentials()),
            Err(MixedConnectError::EmptyStream)
        ));

        let mut incomplete = TestIo::new(b"CONNECT example.invalid:443 HTTP/1.1\r\n".to_vec());
        assert!(matches!(
            accept_mixed_connect(&mut incomplete, &credentials()),
            Err(MixedConnectError::Http(HttpConnectStreamError::Protocol(
                HttpConnectError::IncompleteHeader
            )))
        ));
    }
}
