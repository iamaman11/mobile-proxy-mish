use std::fs;
use std::path::Path;

#[test]
fn proxy_serving_source_has_no_default_dns_capability() {
    let source_root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    collect_rust_files(&source_root, &mut files);
    assert!(
        !files.is_empty(),
        "proxy source tree must contain Rust files"
    );

    for file in files {
        let source = fs::read_to_string(&file).expect("proxy source must be readable");
        for forbidden in [
            "ToSocketAddrs",
            "lookup_host(",
            "getaddrinfo",
            "resolve_socket_addrs",
        ] {
            assert!(
                !source.contains(forbidden),
                "Proxy Serving must preserve unresolved targets and cannot own default DNS: {} contains {forbidden:?}",
                file.display(),
            );
        }
    }
}

fn collect_rust_files(directory: &Path, output: &mut Vec<std::path::PathBuf>) {
    for entry in fs::read_dir(directory).expect("proxy source directory must be readable") {
        let entry = entry.expect("proxy source directory entry must be readable");
        let path = entry.path();
        if path.is_dir() {
            collect_rust_files(&path, output);
        } else if path.extension().and_then(|value| value.to_str()) == Some("rs") {
            output.push(path);
        }
    }
}
