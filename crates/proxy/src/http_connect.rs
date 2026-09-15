use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use crate::{ProxyConnectTarget, ProxyCredentialMaterial, ProxyTargetError};

const MAX_HTTP_CONNECT_HEADER_BYTES: usize = 16 * 1024;
const BASIC_PREFIX: &str = "Basic ";
const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Parses one bounded authenticated HTTP CONNECT request without resolving its target.
///
/// This is deliberately not a general forward-HTTP proxy parser. Proxy Serving owns only the
/// accepted CONNECT tunnel contract required by PRODUCT. The returned hostname remains unresolved
/// until Cellular Egress acquires an owner-issued cellular network authority.
pub fn parse_http_connect_request(
    request: &[u8],
    credentials: &ProxyCredentialMaterial,
) -> Result<ProxyConnectTarget, HttpConnectError> {
    if request.len() > MAX_HTTP_CONNECT_HEADER_BYTES {
        return Err(HttpConnectError::HeaderTooLarge);
    }
    if !request.ends_with(b"\r\n\r\n") {
        return Err(HttpConnectError::IncompleteHeader);
    }

    let text = std::str::from_utf8(request).map_err(|_| HttpConnectError::MalformedHeader)?;
    let header = &text[..text.len() - 4];
    let mut lines = header.split("\r\n");
    let request_line = lines.next().ok_or(HttpConnectError::MalformedRequestLine)?;
    let mut parts = request_line.split_ascii_whitespace();
    let method = parts.next().ok_or(HttpConnectError::MalformedRequestLine)?;
    let authority = parts.next().ok_or(HttpConnectError::MalformedRequestLine)?;
    let version = parts.next().ok_or(HttpConnectError::MalformedRequestLine)?;
    if parts.next().is_some() {
        return Err(HttpConnectError::MalformedRequestLine);
    }
    if method != "CONNECT" {
        return Err(HttpConnectError::MethodNotAllowed);
    }
    if version != "HTTP/1.1" && version != "HTTP/1.0" {
        return Err(HttpConnectError::UnsupportedHttpVersion);
    }

    let mut proxy_authorization = None;
    for line in lines {
        if line.is_empty() {
            return Err(HttpConnectError::MalformedHeader);
        }
        let (name, value) = line
            .split_once(':')
            .ok_or(HttpConnectError::MalformedHeader)?;
        if name.is_empty() || name.bytes().any(|byte| byte.is_ascii_whitespace()) {
            return Err(HttpConnectError::MalformedHeader);
        }
        if name.eq_ignore_ascii_case("Proxy-Authorization") {
            if proxy_authorization.is_some() {
                return Err(HttpConnectError::DuplicateProxyAuthorization);
            }
            proxy_authorization = Some(value.trim());
        }
    }

    let supplied = proxy_authorization.ok_or(HttpConnectError::ProxyAuthenticationRequired)?;
    let expected = expected_basic_authorization(credentials);
    if !constant_time_eq(expected.as_bytes(), supplied.as_bytes()) {
        return Err(HttpConnectError::ProxyAuthenticationFailed);
    }

    parse_connect_authority(authority)
}

fn parse_connect_authority(authority: &str) -> Result<ProxyConnectTarget, HttpConnectError> {
    if authority.is_empty() || authority.bytes().any(|byte| byte.is_ascii_control()) {
        return Err(HttpConnectError::InvalidTarget);
    }

    if let Some(bracketed) = authority.strip_prefix('[') {
        let (host, rest) = bracketed
            .split_once(']')
            .ok_or(HttpConnectError::InvalidTarget)?;
        let port = rest
            .strip_prefix(':')
            .ok_or(HttpConnectError::InvalidTarget)?;
        if host.is_empty() || port.is_empty() || port.contains(':') {
            return Err(HttpConnectError::InvalidTarget);
        }
        let address = host
            .parse::<Ipv6Addr>()
            .map_err(|_| HttpConnectError::InvalidTarget)?;
        return ProxyConnectTarget::ipv6(address, parse_port(port)?)
            .map_err(HttpConnectError::Target);
    }

    let (host, port) = authority
        .rsplit_once(':')
        .ok_or(HttpConnectError::InvalidTarget)?;
    if host.is_empty()
        || port.is_empty()
        || host.contains(':')
        || host
            .bytes()
            .any(|byte| matches!(byte, b'/' | b'@' | b'#' | b'?'))
    {
        return Err(HttpConnectError::InvalidTarget);
    }
    let port = parse_port(port)?;

    if let Ok(address) = host.parse::<Ipv4Addr>() {
        return ProxyConnectTarget::ipv4(address, port).map_err(HttpConnectError::Target);
    }
    if host.parse::<IpAddr>().is_ok() {
        // IPv6 literals must use bracketed authority form.
        return Err(HttpConnectError::InvalidTarget);
    }
    ProxyConnectTarget::domain(host, port).map_err(HttpConnectError::Target)
}

fn parse_port(raw: &str) -> Result<u16, HttpConnectError> {
    raw.parse::<u16>()
        .ok()
        .filter(|port| *port != 0)
        .ok_or(HttpConnectError::InvalidTarget)
}

fn expected_basic_authorization(credentials: &ProxyCredentialMaterial) -> String {
    let mut material =
        Vec::with_capacity(credentials.username().len() + credentials.password().len() + 1);
    material.extend_from_slice(credentials.username().as_bytes());
    material.push(b':');
    material.extend_from_slice(credentials.password().as_bytes());
    format!("{BASIC_PREFIX}{}", encode_base64(&material))
}

fn encode_base64(input: &[u8]) -> String {
    let mut output = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let first = chunk[0];
        let second = chunk.get(1).copied().unwrap_or(0);
        let third = chunk.get(2).copied().unwrap_or(0);

        output.push(BASE64[usize::from(first >> 2)] as char);
        output.push(BASE64[usize::from(((first & 0x03) << 4) | (second >> 4))] as char);
        if chunk.len() > 1 {
            output.push(BASE64[usize::from(((second & 0x0f) << 2) | (third >> 6))] as char);
        } else {
            output.push('=');
        }
        if chunk.len() > 2 {
            output.push(BASE64[usize::from(third & 0x3f)] as char);
        } else {
            output.push('=');
        }
    }
    output
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpConnectError {
    HeaderTooLarge,
    IncompleteHeader,
    MalformedHeader,
    MalformedRequestLine,
    MethodNotAllowed,
    UnsupportedHttpVersion,
    ProxyAuthenticationRequired,
    DuplicateProxyAuthorization,
    ProxyAuthenticationFailed,
    InvalidTarget,
    Target(ProxyTargetError),
}

impl fmt::Display for HttpConnectError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::HeaderTooLarge => "HTTP CONNECT header exceeds the bounded limit",
            Self::IncompleteHeader => "HTTP CONNECT header is incomplete",
            Self::MalformedHeader => "HTTP CONNECT header is malformed",
            Self::MalformedRequestLine => "HTTP CONNECT request line is malformed",
            Self::MethodNotAllowed => "only HTTP CONNECT is accepted",
            Self::UnsupportedHttpVersion => "HTTP CONNECT version is unsupported",
            Self::ProxyAuthenticationRequired => "proxy authentication is required",
            Self::DuplicateProxyAuthorization => "duplicate proxy authorization is rejected",
            Self::ProxyAuthenticationFailed => "proxy authentication failed",
            Self::InvalidTarget => "HTTP CONNECT target authority is invalid",
            Self::Target(_) => "HTTP CONNECT target is rejected by Proxy Serving policy",
        })
    }
}

impl std::error::Error for HttpConnectError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Target(error) => Some(error),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ProxyTargetHost;

    fn credentials() -> ProxyCredentialMaterial {
        ProxyCredentialMaterial::new("public-user", "public-password").expect("valid credentials")
    }

    fn request(authority: &str, authorization: &str) -> Vec<u8> {
        format!(
            "CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\nProxy-Authorization: {authorization}\r\n\r\n"
        )
        .into_bytes()
    }

    #[test]
    fn authenticated_domain_remains_unresolved() {
        let parsed = parse_http_connect_request(
            &request(
                "example.invalid:443",
                "Basic cHVibGljLXVzZXI6cHVibGljLXBhc3N3b3Jk",
            ),
            &credentials(),
        )
        .expect("CONNECT accepted");
        assert_eq!(parsed.port(), 443);
        assert_eq!(
            parsed.host(),
            &ProxyTargetHost::Domain("example.invalid".into())
        );
        assert_eq!(parsed.host().numeric(), None);
    }

    #[test]
    fn ipv4_and_bracketed_ipv6_are_typed_without_dns() {
        let ipv4 = parse_http_connect_request(
            &request(
                "203.0.113.10:8443",
                "Basic cHVibGljLXVzZXI6cHVibGljLXBhc3N3b3Jk",
            ),
            &credentials(),
        )
        .expect("IPv4 accepted");
        assert_eq!(
            ipv4.host(),
            &ProxyTargetHost::Ipv4(Ipv4Addr::new(203, 0, 113, 10))
        );

        let ipv6 = parse_http_connect_request(
            &request(
                "[2001:db8::1]:443",
                "Basic cHVibGljLXVzZXI6cHVibGljLXBhc3N3b3Jk",
            ),
            &credentials(),
        )
        .expect("IPv6 accepted");
        assert_eq!(
            ipv6.host(),
            &ProxyTargetHost::Ipv6("2001:db8::1".parse().expect("IPv6"))
        );
    }

    #[test]
    fn missing_wrong_or_duplicate_auth_fails_closed() {
        let missing = b"CONNECT example.invalid:443 HTTP/1.1\r\nHost: example.invalid:443\r\n\r\n";
        assert_eq!(
            parse_http_connect_request(missing, &credentials()),
            Err(HttpConnectError::ProxyAuthenticationRequired)
        );
        assert_eq!(
            parse_http_connect_request(
                &request("example.invalid:443", "Basic d3Jvbmc6d3Jvbmc="),
                &credentials(),
            ),
            Err(HttpConnectError::ProxyAuthenticationFailed)
        );

        let duplicate = b"CONNECT example.invalid:443 HTTP/1.1\r\nProxy-Authorization: Basic cHVibGljLXVzZXI6cHVibGljLXBhc3N3b3Jk\r\nProxy-Authorization: Basic cHVibGljLXVzZXI6cHVibGljLXBhc3N3b3Jk\r\n\r\n";
        assert_eq!(
            parse_http_connect_request(duplicate, &credentials()),
            Err(HttpConnectError::DuplicateProxyAuthorization)
        );
    }

    #[test]
    fn non_connect_and_invalid_authority_are_rejected() {
        let get = b"GET http://example.invalid/ HTTP/1.1\r\nProxy-Authorization: Basic cHVibGljLXVzZXI6cHVibGljLXBhc3N3b3Jk\r\n\r\n";
        assert_eq!(
            parse_http_connect_request(get, &credentials()),
            Err(HttpConnectError::MethodNotAllowed)
        );
        assert_eq!(
            parse_http_connect_request(
                &request(
                    "example.invalid:0",
                    "Basic cHVibGljLXVzZXI6cHVibGljLXBhc3N3b3Jk"
                ),
                &credentials(),
            ),
            Err(HttpConnectError::InvalidTarget)
        );
        assert_eq!(
            parse_http_connect_request(
                &request(
                    "2001:db8::1:443",
                    "Basic cHVibGljLXVzZXI6cHVibGljLXBhc3N3b3Jk"
                ),
                &credentials(),
            ),
            Err(HttpConnectError::InvalidTarget)
        );
    }

    #[test]
    fn incomplete_and_oversized_headers_are_rejected() {
        assert_eq!(
            parse_http_connect_request(b"CONNECT example.invalid:443 HTTP/1.1\r\n", &credentials()),
            Err(HttpConnectError::IncompleteHeader)
        );
        let oversized = vec![b'A'; MAX_HTTP_CONNECT_HEADER_BYTES + 1];
        assert_eq!(
            parse_http_connect_request(&oversized, &credentials()),
            Err(HttpConnectError::HeaderTooLarge)
        );
    }

    #[test]
    fn basic_encoder_matches_rfc4648_vectors() {
        assert_eq!(encode_base64(b""), "");
        assert_eq!(encode_base64(b"f"), "Zg==");
        assert_eq!(encode_base64(b"fo"), "Zm8=");
        assert_eq!(encode_base64(b"foo"), "Zm9v");
        assert_eq!(encode_base64(b"foobar"), "Zm9vYmFy");
    }
}
