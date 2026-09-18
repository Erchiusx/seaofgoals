//! Small total functions whose independent fuzz targets exercise separate
//! parser-like contracts.  They intentionally have no shared mutable state.

pub fn decode_frame(input: &[u8]) -> Option<Vec<u8>> {
    let (&declared, payload) = input.split_first()?;
    if payload.len() != usize::from(declared) {
        return None;
    }
    Some(payload.iter().map(|byte| byte ^ 0xa5).collect())
}

pub fn normalize_segments(input: &[u8]) -> Option<Vec<u8>> {
    let mut result = Vec::new();
    for segment in input.split(|byte| *byte == b'/') {
        match segment {
            b"" | b"." => {}
            b".." => {
                result.pop()?;
            }
            other if other.contains(&0) => return None,
            other => {
                if !result.is_empty() {
                    result.push(b'/');
                }
                result.extend_from_slice(other);
            }
        }
    }
    Some(result)
}

pub fn decode_runs(input: &[u8]) -> Option<Vec<u8>> {
    let mut output = Vec::new();
    for pair in input.chunks_exact(2) {
        let count = usize::from(pair[0]);
        if output.len().checked_add(count)? > 4096 {
            return None;
        }
        output.extend(std::iter::repeat_n(pair[1], count));
    }
    input.len().is_multiple_of(2).then_some(output)
}
