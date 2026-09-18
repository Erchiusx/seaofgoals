#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: &[u8]| {
    let _ = sog_cargo_fuzz_fixture::normalize_segments(input);
});
