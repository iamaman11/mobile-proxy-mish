#!/usr/bin/env python3
from pathlib import Path

ffi = Path('crates/android-ffi/src/lib.rs')
text = ffi.read_text()
old = '''        if spawn.is_err() {
            if let Ok(mut tracked_clients) = clients.lock() {
                if let Some(stream) = tracked_clients.remove(&session_id) {
                    let _ = stream.shutdown(Shutdown::Both);
                }
            }
            active_sessions.fetch_sub(1, Ordering::AcqRel);
'''
new = '''        if spawn.is_err() {
            if let Ok(mut tracked_clients) = clients.lock()
                && let Some(stream) = tracked_clients.remove(&session_id)
            {
                let _ = stream.shutdown(Shutdown::Both);
            }
            active_sessions.fetch_sub(1, Ordering::AcqRel);
'''
assert old in text
ffi.write_text(text.replace(old, new))

manifest = Path('android/app/src/main/AndroidManifest.xml')
text = manifest.read_text()
old = '        android:extractNativeLibs="true"\n'
assert old in text
manifest.write_text(text.replace(old, ''))

ci = Path('.github/workflows/ci.yml')
text = ci.read_text()
old = '          for symbol in CellularController admissionSnapshot observeNetwork networkLost; do\n'
new = '          for symbol in CellularController admissionSnapshot observeNetwork networkLost startBridge CellularBridgeRuntime renderProxyRuntimeConfig; do\n'
assert old in text
text = text.replace(old, new)
old = '''          NATIVE="android/app/build/generated/rust-jni/$MISH_TARGET_ABI/libmish_android_ffi.so"
          test -f "$APK"
          test -f "$TEST_APK"
          test -f "$NATIVE"
          unzip -l "$APK" | grep -q "lib/$MISH_TARGET_ABI/libmish_android_ffi.so"
          unzip -l "$APK" | grep -q "lib/$MISH_TARGET_ABI/libjnidispatch.so"
          SYMBOLS="$RUNNER_TEMP/mish-android-ffi.symbols"
'''
new = '''          NATIVE="android/app/build/generated/rust-jni/$MISH_TARGET_ABI/libmish_android_ffi.so"
          SING_BOX="android/app/build/generated/sing-box-jni/$MISH_TARGET_ABI/libsingbox.so"
          test -f "$APK"
          test -f "$TEST_APK"
          test -f "$NATIVE"
          test -f "$SING_BOX"
          unzip -l "$APK" | grep -q "lib/$MISH_TARGET_ABI/libmish_android_ffi.so"
          unzip -l "$APK" | grep -q "lib/$MISH_TARGET_ABI/libjnidispatch.so"
          unzip -l "$APK" | grep -q "lib/$MISH_TARGET_ABI/libsingbox.so"
          PACKAGED_SING_BOX="$RUNNER_TEMP/libsingbox.so"
          unzip -p "$APK" "lib/$MISH_TARGET_ABI/libsingbox.so" > "$PACKAGED_SING_BOX"
          cmp "$SING_BOX" "$PACKAGED_SING_BOX"
          test "$(head -c 4 "$PACKAGED_SING_BOX" | od -An -tx1 | tr -d ' \\n')" = '7f454c46'
          SYMBOLS="$RUNNER_TEMP/mish-android-ffi.symbols"
'''
assert old in text
ci.write_text(text.replace(old, new))
