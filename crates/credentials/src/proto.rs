pub(crate) const WIRE_VARINT: u8 = 0;
pub(crate) const WIRE_FIXED64: u8 = 1;
pub(crate) const WIRE_LENGTH_DELIMITED: u8 = 2;
pub(crate) const WIRE_FIXED32: u8 = 5;

pub(crate) fn write_varint_field(output: &mut Vec<u8>, field_number: u32, value: u64) {
    write_varint(
        output,
        u64::from((field_number << 3) | u32::from(WIRE_VARINT)),
    );
    write_varint(output, value);
}

pub(crate) fn write_bytes_field(output: &mut Vec<u8>, field_number: u32, value: &[u8]) {
    write_varint(
        output,
        u64::from((field_number << 3) | u32::from(WIRE_LENGTH_DELIMITED)),
    );
    write_varint(output, value.len() as u64);
    output.extend_from_slice(value);
}

fn write_varint(output: &mut Vec<u8>, value: u64) {
    let mut remaining = value;
    while remaining >= 0x80 {
        output.push(((remaining & 0x7f) as u8) | 0x80);
        remaining >>= 7;
    }
    output.push(remaining as u8);
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct ProtoError;

#[derive(Debug, Clone, Copy)]
pub(crate) struct ProtoTag {
    pub(crate) field_number: u32,
    pub(crate) wire_type: u8,
}

pub(crate) struct ProtoReader<'a> {
    input: &'a [u8],
    offset: usize,
}

impl<'a> ProtoReader<'a> {
    pub(crate) const fn new(input: &'a [u8]) -> Self {
        Self { input, offset: 0 }
    }

    pub(crate) fn exhausted(&self) -> bool {
        self.offset == self.input.len()
    }

    pub(crate) fn read_tag(&mut self) -> Result<ProtoTag, ProtoError> {
        let raw = self.read_varint()?;
        if raw == 0 || raw > u64::from(u32::MAX) {
            return Err(ProtoError);
        }
        let field_number = u32::try_from(raw >> 3).map_err(|_| ProtoError)?;
        let wire_type = u8::try_from(raw & 0x07).map_err(|_| ProtoError)?;
        if field_number == 0 {
            return Err(ProtoError);
        }
        Ok(ProtoTag {
            field_number,
            wire_type,
        })
    }

    pub(crate) fn read_varint(&mut self) -> Result<u64, ProtoError> {
        let mut result = 0_u64;
        for index in 0..10 {
            let byte = *self.input.get(self.offset).ok_or(ProtoError)?;
            self.offset += 1;
            if index == 9 && byte & 0xfe != 0 {
                return Err(ProtoError);
            }
            result |= u64::from(byte & 0x7f) << (index * 7);
            if byte & 0x80 == 0 {
                return Ok(result);
            }
        }
        Err(ProtoError)
    }

    pub(crate) fn read_bytes(&mut self) -> Result<&'a [u8], ProtoError> {
        let length = usize::try_from(self.read_varint()?).map_err(|_| ProtoError)?;
        let end = self.offset.checked_add(length).ok_or(ProtoError)?;
        let bytes = self.input.get(self.offset..end).ok_or(ProtoError)?;
        self.offset = end;
        Ok(bytes)
    }

    pub(crate) fn skip(&mut self, wire_type: u8) -> Result<(), ProtoError> {
        match wire_type {
            WIRE_VARINT => {
                self.read_varint()?;
                Ok(())
            }
            WIRE_FIXED64 => self.advance(8),
            WIRE_LENGTH_DELIMITED => {
                let length = usize::try_from(self.read_varint()?).map_err(|_| ProtoError)?;
                self.advance(length)
            }
            WIRE_FIXED32 => self.advance(4),
            _ => Err(ProtoError),
        }
    }

    fn advance(&mut self, count: usize) -> Result<(), ProtoError> {
        let end = self.offset.checked_add(count).ok_or(ProtoError)?;
        if end > self.input.len() {
            return Err(ProtoError);
        }
        self.offset = end;
        Ok(())
    }
}
