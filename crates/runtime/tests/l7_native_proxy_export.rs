use mish_runtime::{ProxyServingRuntime, ProxyServingRuntimeError};

#[test]
fn native_proxy_runtime_remains_exported_for_android_cutover() {
    let _ = std::any::TypeId::of::<ProxyServingRuntime>();
    let _ = std::any::TypeId::of::<ProxyServingRuntimeError>();
}
