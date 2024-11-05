/*
Native port of Glenn Fielder's serialize library, as of this commit:
https://github.com/mas-bandwidth/serialize/commit/cc75300b1bce50246374709bf1d29baee41f9587

------------------------------------------------------------------------------------------------------------------------
| Original BSD-3 license
------------------------------------------------------------------------------------------------------------------------
    serialize

    Copyright © 2016 - 2024, Mas Bandwidth LLC.

    Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

        1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

        2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer
           in the documentation and/or other materials provided with the distribution.

        3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived
           from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
    INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
    SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
    SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
    WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
    USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
---------------------------------------------------------------------------------------------------------------------
*/

#module_parameters () (ENABLE_LOGGING := false);

#load "tests.jai";

/*
Calculates the log base 2 of an unsigned 32 bit integer.
@param x The input integer value.
@returns The log base 2 of the input.
*/
log2 :: inline (x: u64) -> int {
    a: u64 = x | (x >> 1);
    b: u64 = a | (a >> 2);
    c: u64 = b | (b >> 4);
    d: u64 = c | (c >> 8);
    e: u64 = d | (d >> 16);
    f: u64 = e | (e >> 32);
    g: u64 = f >> 1;
    return popcount(g);
}

/*
Calculates the number of bits required to serialize an integer in range [min,max].
@param min The minimum value.
@param max The maximum value.
@returns The number of bits required to serialize the integer.
*/
bits_required :: inline (min: u64, max: u64) -> int {
    // NOTE(dlb): I changed the min == max case to use 1 bit, instead of 0, because implicitly
    // serializing things seems like a bad idea in practice. It would be very easy for the reader/writer
    // to become desync'd in different versions of the code.
    return ifx min == max then 1 else log2(max - min) + 1;
}

/*
IMPORTANT: Because most machines are little endian, serialize defines "network byte order" to be little endian.
Convert an integer value from host byte order to "network byte order".
@param value The input value in host byte order.
@returns The input value converted to "network byte order".
*/
host_to_le_32 :: inline (value: u32) -> u32 {
    // We don't support big endian
    return value;
}

/*
IMPORTANT: Because most machines are little endian, serialize defines "network byte order" to be little endian.
Convert an integer value from "network byte order" to host byte order.
@param value The input value in "network byte order".
@returns The input value converted to host byte order.
*/
le_to_host_32 :: inline (value: u32) -> u32 {
    // We don't support big endian
    return value;
}

// Not using these right now, but could be useful. Keeps # of bits low for signed values near zero.
//
//   /*
//   Convert a signed integer to an unsigned integer with zig-zag encoding.
//   0,-1,+1,-2,+2... becomes 0,1,2,3,4 ...
//   @param n The input value.
//   @returns The input value converted from signed to unsigned with zig-zag encoding.
//   */
//   signed_to_unsigned :: inline (n: s32) -> u32 {
//       return (n << 1) ^ (n >> 31);
//   }
//
//   /*
//   Convert an unsigned integer to as signed integer with zig-zag encoding.
//   0,1,2,3,4... becomes 0,-1,+1,-2,+2...
//   @param n The input value.
//   @returns The input value converted from unsigned to signed with zig-zag encoding.
//   */
//   unsigned_to_signed :: inline (n: u32) -> s32 {
//       return ( n >> 1 ) ^ ( -cast(s32) ( n & 1 ) );
//   }
//

/*
Bitpacks unsigned integer values to a buffer.
Integer bit values are written to a 64 bit scratch value from right to left.
Once the low 32 bits of the scratch is filled with bits it is flushed to memory as a dword and the scratch value is shifted right by 32.
The bit stream is written to memory in little endian order, which is considered network byte order for this library.
*/
BitWriter :: struct {
    data        : [] u32;  // The buffer we are writing to, as a uint32_t * because we're writing dwords at a time.
    scratch     : u64;     // The scratch value where we write bits to (right to left). 64 bit for overflow. Once # of bits in scratch is >= 32, the low 32 bits are flushed to memory.
    numBits     : int;     // The number of bits in the buffer. This is equivalent to the size of the buffer in bytes multiplied by 8. Note that the buffer size must always be a multiple of 4.
    bitsWritten : int;     // The number of bits written so far.
    wordIndex   : int;     // The current word index. The next word flushed to memory will be at this index in data.
    scratchBits : int;     // The number of bits in scratch. When this is >= 32, the low 32 bits of scratch is flushed to memory as a dword and scratch is shifted right by 32.
}

/*
Bit writer constructor.
Creates a bit writer object to write to the specified buffer.
@param buffer The buffer to fill with bitpacked data. Length must be a multiple of 4, because the bitpacker reads and writes memory as dwords, not bytes.
*/
bit_writer_init :: (using writer: *BitWriter, buffer: [] u8) {
    assert(buffer.count > 0);
    assert(buffer.count % 4 == 0);

    data = .{ buffer.count / 4, cast(*u32) buffer.data };
    numBits = buffer.count * 8;
}

/*
Write bits to the buffer.
Bits are written to the buffer as-is, without padding to nearest byte. Will assert if you try to write past the end of the buffer.
A boolean value writes just 1 bit to the buffer, a value in range [0,31] can be written with just 5 bits and so on.
IMPORTANT: When you have finished writing to your buffer, take care to call bit_writer_flush_bits, otherwise the last dword of data will not get flushed to memory!
@param value The integer value to write to the buffer. Must be in [0,(1<<bits)-1].
@param bits The number of bits to encode in [1,32].
*/
bit_writer_write_bits :: (using writer: *BitWriter, value: u32, bits: int) {
    assert(bits > 0);
    assert(bits <= 32);
    assert(bitsWritten + bits <= numBits);
    assert(cast(u64) value <= (((cast(u64) 1) << bits) - 1));

    scratch |= (cast(u64) value) << scratchBits;
    scratchBits += bits;

    if scratchBits >= 32 {
        assert(wordIndex < data.count);
        data[wordIndex] = host_to_le_32(cast(u32) (scratch & 0xFFFFFFFF));
        scratch >>= 32;
        scratchBits -= 32;
        wordIndex += 1;
    }

    bitsWritten += bits;
}

/*
Write an alignment to the bit stream, padding zeros so the bit index becomes is a multiple of 8.
This is useful if you want to write some data to a packet that should be byte aligned. For example, an array of bytes, or a string.
IMPORTANT: If the current bit index is already a multiple of 8, nothing is written.
*/
bit_writer_align :: (using writer: *BitWriter) {
    remainderBits := writer.bitsWritten % 8;

    if remainderBits != 0 {
        zero: u32 = 0;
        bit_writer_write_bits(writer, zero, 8 - remainderBits);
        assert((bitsWritten % 8) == 0);
    }
}

/*
Write an array of bytes to the bit stream.
Use this when you have to copy a large block of data into your bitstream.
Faster than just writing each byte to the bit stream via bit_writer_write_bits(writer, value, 8), because it aligns to byte index and copies into the buffer without bitpacking.
@param data The byte array data to write to the bit stream.
@param bytes The number of bytes to write.
*/
bit_writer_write_bytes :: (using writer: *BitWriter, bytes: [] u8) {
    assert(bit_writer_get_align_bits(writer) == 0);
    assert(bitsWritten + bytes.count * 8 <= numBits);

    headBytes := (4 - (bitsWritten % 32) / 8) % 4;
    if headBytes > bytes.count {
        headBytes = bytes.count;
    }
    for 0..headBytes-1 {
        bit_writer_write_bits(writer, bytes[it], 8);
    }
    if headBytes == bytes.count {
        return;
    }

    bit_writer_flush_bits(writer);
    assert(bit_writer_get_align_bits(writer) == 0);

    numWords := (bytes.count - headBytes) / 4;
    if numWords > 0 {
        assert((bitsWritten % 32) == 0);

        memcpy(*data[wordIndex], bytes.data + headBytes, numWords * 4);

        bitsWritten += numWords * 32;
        wordIndex += numWords;
        scratch = 0;
    }
    assert(bit_writer_get_align_bits(writer) == 0);

    tailStart := headBytes + numWords * 4;
    tailBytes := bytes.count - tailStart;
    assert(tailBytes >= 0 && tailBytes < 4);
    for 0..tailBytes-1 {
        bit_writer_write_bits(writer, bytes[tailStart + it], 8);
    }
    assert(bit_writer_get_align_bits(writer) == 0);

    assert(headBytes + numWords * 4 + tailBytes == bytes.count);
}

/*
Flush any remaining bits to memory.
Call this once after you've finished writing bits to flush the last dword of scratch to memory!
*/
bit_writer_flush_bits :: (using writer: *BitWriter) {
    if scratchBits != 0 {
        assert(scratchBits <= 32);
        assert(wordIndex < data.count);

        data[wordIndex] = host_to_le_32(cast(u32) (scratch & 0xFFFFFFFF));
        scratch >>= 32;
        scratchBits = 0;
        wordIndex += 1;
    }
}

/*
How many align bits would be written, if we were to write an align right now?
@returns Result in [0,7], where 0 is zero bits required to align (already aligned) and 7 is worst case.
*/
bit_writer_get_align_bits :: (using writer: *BitWriter) -> int {
    return (8 - (bitsWritten % 8)) % 8;
}

/*
The number of bytes flushed to memory.
This is effectively the size of the packet that you should send after you have finished bitpacking values with this class.
The returned value is not always a multiple of 4, even though we flush dwords to memory. You won't miss any data in this case because the order of bits written is designed to work with the little endian memory layout.
IMPORTANT: Make sure you call bit_writer_flush_bits before calling this method, otherwise you risk missing the last dword of data.
*/
bit_writer_get_bytes_written :: (using writer: *BitWriter) -> int {
    return (bitsWritten + 7) / 8;
}

/*
Reads bit packed integer values from a buffer.
Relies on the user reconstructing the exact same set of bit reads as bit writes when the buffer was written. This is an unattributed bitpacked binary stream!
Implementation: 32 bit dwords are read in from memory to the high bits of a scratch value as required. The user reads off bit values from the scratch value from the right, after which the scratch value is shifted by the same number of bits.
*/
BitReader :: struct {
    data        : [] u32;  // The bitpacked data we're reading as a dword array.
    scratch     : u64;     // The scratch value. New data is read in 32 bits at a top to the left of this buffer, and data is read off to the right.
    numBits     : int;     // Number of bits to read in the buffer. Of course, we can't *really* know this so it's actually data.count * 32.
    bitsRead    : int;     // Number of bits read from the buffer so far.
    scratchBits : int;     // Number of bits currently in the scratch value. If the user wants to read more bits than this, we have to go fetch another dword from memory.
    wordIndex   : int;     // Index of the next word to read from memory.
}

/*
Bit reader constructor.
Non-multiples of four buffer sizes are supported, as this naturally tends to occur when packets are read from the network.
However, actual buffer allocated for the packet data must round up at least to the next 4 bytes in memory, because the bit reader reads dwords from memory not bytes.
@param data Pointer to the bitpacked data to read.
@param bytes The number of bytes of bitpacked data to read.
@see BitWriter
*/
bit_reader_init :: (using reader: *BitReader, buffer: [] u8) {
    assert_greater(buffer.count, 0);

    data = .{ (buffer.count + 3) / 4, cast(*u32) buffer.data };
    numBits = buffer.count * 8;
}

/**
Would the bit reader would read past the end of the buffer if it read this many bits?
@param bits The number of bits that would be read.
@returns True if reading the number of bits would read past the end of the buffer.
*/
bit_reader_would_read_past_end :: inline (using reader: *BitReader, bits: int) -> bool {
    return bitsRead + bits > numBits;
}

/*
Read bits from the bit buffer.
This function will assert in debug builds if this read would read past the end of the buffer.
In production situations, the higher level ReadStream takes care of checking all packet data and never calling this function if it would read past the end of the buffer.
@param bits The number of bits to read in [1,32].
@returns The integer value read in range [0,(1<<bits)-1].
@see BitReader::WouldReadPastEnd
@see BitWriter::WriteBits
*/
bit_reader_read_bits :: (using reader: *BitReader, bits: int) -> u32 {
    assert(bits > 0);
    assert(bits <= 32);
    assert(bitsRead + bits <= numBits);

    bitsRead += bits;

    assert(scratchBits >= 0 && scratchBits <= 64);

    if scratchBits < bits {
        scratch |= (cast(u64) le_to_host_32(data[wordIndex])) << scratchBits;
        scratchBits += 32;
        wordIndex += 1;
    }

    assert(scratchBits >= bits);

    value := cast(u32) (scratch & (((cast(u64) 1) << bits) - 1));
    scratch >>= cast(u64) bits;
    scratchBits -= bits;
    return value;
}

/*
Read an align.
Call this on read to correspond to a WriteAlign call when the bitpacked buffer was written.
This makes sure we skip ahead to the next aligned byte index. As a safety check, we verify that the padding to next byte is zero bits and return false if that's not the case.
This will typically abort packet read. Just another safety measure...
@returns True if we successfully read an align and skipped ahead past zero pad, false otherwise (probably means, no align was written to the stream).
@see BitWriter::WriteAlign
*/
bit_reader_align :: (using reader: *BitReader) -> bool {
    remainderBits := bitsRead % 8;
    if remainderBits != 0 {
        value := bit_reader_read_bits(reader, 8 - remainderBits);
        assert(bitsRead % 8 == 0);
        if value != 0 {
            return false;
        }
    }
    return true;
}

/**
Read bytes from the bitpacked data.
@see BitWriter::WriteBytes
*/
bit_reader_read_bytes :: (using reader: *BitReader, bytes: [] u8) {
    assert(bit_reader_get_align_bits(reader) == 0);
    assert(bitsRead + bytes.count * 8 <= numBits);

    headBytes := (4 - (bitsRead % 32) / 8) % 4;
    if headBytes > bytes.count {
        headBytes = bytes.count;
    }
    for 0..headBytes-1 {
        bytes[it] = cast(u8) bit_reader_read_bits(reader, 8);
    }
    if headBytes == bytes.count {
        return;
    }
    assert(bit_reader_get_align_bits(reader) == 0);

    numWords := (bytes.count - headBytes) / 4;
    if numWords > 0 {
        assert((bitsRead % 32) == 0);

        memcpy(bytes.data + headBytes, *data[wordIndex], numWords * 4);

        bitsRead += numWords * 32;
        wordIndex += numWords;
        scratchBits = 0;
    }
    assert(bit_reader_get_align_bits(reader) == 0);

    tailStart := headBytes + numWords * 4;
    tailBytes := bytes.count - tailStart;
    assert(tailBytes >= 0 && tailBytes < 4);
    for 0..tailBytes-1 {
        bytes[tailStart + it] = cast(u8) bit_reader_read_bits(reader, 8);
    }
    assert(bit_reader_get_align_bits(reader) == 0);

    assert(headBytes + numWords * 4 + tailBytes == bytes.count);
}

/*
How many align bits would be read, if we were to read an align right now?
@returns Result in [0,7], where 0 is zero bits required to align (already aligned) and 7 is worst case.
*/
bit_reader_get_align_bits :: (using reader: *BitReader) -> int {
    return (8 - bitsRead % 8) % 8;
}

/*
The number of bytes read from memory.
The returned value is not always a multiple of 4, even though we read dwords from memory.
This is conservative, and will round up when less than 8 bits have been read from the current byte.
*/
bit_reader_get_bytes_read :: (using reader: *BitReader) -> int {
    return (bitsRead + 7) / 8;
}

StreamType :: enum {
    Write;
    Read;
    Measure;
}

Stream :: struct {
    type: StreamType;
    isWriting: bool;
    isReading: bool;
}

// NOTE: You probably want to call serialize_bits() macro rather than this directly.
stream_serialize_bits :: (stream: *Stream, value: *u64, bits: int) -> bool {
    assert(bits > 0);
    assert(bits <= 64);

    lo, hi: u32;
    if stream.isWriting {
        lo = cast(u32) (value.* & 0xFFFFFFFF);
        hi = cast(u32) (value.* >> 32);
    }

    if #complete stream.type == {
        case .Write;
            s := cast(*WriteStream) stream;
            if bits <= 32 {
                bit_writer_write_bits(*s.writer, lo, bits);
            } else {
                bit_writer_write_bits(*s.writer, lo, 32);
                if bits > 32 {
                    bit_writer_write_bits(*s.writer, hi, bits - 32);
                }
            }
        case .Read;
            s := cast(*ReadStream) stream;
            if bit_reader_would_read_past_end(*s.reader, bits) {
                return false;
            }
            if bits <= 32 {
                lo = bit_reader_read_bits(*s.reader, bits);
            } else {
                lo = bit_reader_read_bits(*s.reader, 32);
                if bits > 32 {
                    hi = bit_reader_read_bits(*s.reader, bits - 32);
                }
            }
            value.* = ((cast(u64) hi) << 32) | lo;
        case .Measure;
            s := cast(*MeasureStream) stream;
            s.bitsWritten += bits;
    }

    return true;
}

// NOTE: You probably want to call serialize_bytes() macro rather than this directly.
stream_serialize_bytes :: (stream: *Stream, bytes: [] u8) -> bool {
    assert(bytes.count > 0);

    if #complete stream.type == {
        case .Write;
            s := cast(*WriteStream) stream;
            stream_align(s);
            bit_writer_write_bytes(*s.writer, bytes);
        case .Read;
            s := cast(*ReadStream) stream;
            if !stream_align(s) {
                return false;
            }
            if bit_reader_would_read_past_end(*s.reader, bytes.count * 8) {
                return false;
            }

            bit_reader_read_bytes(*s.reader, bytes);
        case .Measure;
            s := cast(*MeasureStream) stream;
            stream_align(s);
            s.bitsWritten += bytes.count * 8;
    }
    return true;
}

// NOTE: You probably want to call serialize_align() macro rather than this directly.
stream_align :: (stream: *Stream) -> bool {
    if #complete stream.type == {
        case .Write;
            s := cast(*WriteStream) stream;
            bit_writer_align(*s.writer);
        case .Read;
            s := cast(*ReadStream) stream;
            alignBits := bit_reader_get_align_bits(*s.reader);
            if bit_reader_would_read_past_end(*s.reader, alignBits) {
                return false;
            }
            if !bit_reader_align(*s.reader) {
                return false;
            }
        case .Measure;
            s := cast(*MeasureStream) stream;
            alignBits := stream_get_align_bits(s);
            s.bitsWritten += alignBits;
    }
    return true;
}

/*
Get number of bits written/read/measured so far.
*/
stream_get_bits_processed :: inline (using stream: *Stream) -> int {
    if #complete stream.type == {
        case .Write;
            s := cast(*WriteStream) stream;
            return s.writer.bitsWritten;
        case .Read;
            s := cast(*ReadStream) stream;
            return s.reader.bitsRead;
        case .Measure;
            s := cast(*MeasureStream) stream;
            return s.bitsWritten;
    }
}

/*
Get number of bytes written/read/measured so far.
*/
stream_get_bytes_processed :: inline (using stream: *Stream) -> int {
    if #complete stream.type == {
        case .Write;
            s := cast(*WriteStream) stream;
            return bit_writer_get_bytes_written(*s.writer);
        case .Read;
            s := cast(*ReadStream) stream;
            return bit_reader_get_bytes_read(*s.reader);
        case .Measure;
            s := cast(*MeasureStream) stream;
            // conservative; rounds up to the next byte
            return (s.bitsWritten + 7) / 8;
    }
}

/*
Stream class for writing bitpacked data.
This class is a wrapper around the bit writer class. Its purpose is to provide unified interface for reading and writing.
You can determine if you are writing to a stream by calling Stream::IsWriting inside your templated serialize method.
This is evaluated at compile time, letting the compiler generate optimized serialize functions without the hassle of maintaining separate read and write functions.
IMPORTANT: Generally, you don't call methods on this class directly. Use the serialize_* macros instead.
@see BitWriter
*/
WriteStream :: struct {
    using #as base: Stream;
    base.type = .Write;
    base.isWriting = true;
    base.isReading = false;

    writer: BitWriter;  // The bit writer used for all bitpacked write operations.
}

/*
Write stream constructor.
@param buffer The buffer to write to.
@param bytes The number of bytes in the buffer. Must be a multiple of four.
*/
stream_init :: inline (using stream: *WriteStream, buffer: [] u8) {
    bit_writer_init(*writer, buffer);
}

/*
If we were to write an align right now, how many bits would be required?
@returns The number of zero pad bits required to achieve byte alignment in [0,7].
*/
stream_get_align_bits :: inline (using stream: *WriteStream) -> int {
    return bit_writer_get_align_bits(writer);
}

/*
Flush the stream to memory after you finish writing.
Always call this after you finish writing and before you call WriteStream::GetData, or you'll potentially truncate the last dword of data you wrote.
@see BitWriter::FlushBits
*/
stream_flush :: inline (using stream: *WriteStream) {
    bit_writer_flush_bits(*writer);
}

/*
Get a pointer to the data written by the stream.
IMPORTANT: Call WriteStream::Flush before you call this function!
@returns A pointer to the data written by the stream
*/
stream_get_data :: inline (using stream: *WriteStream) -> [] u8 {
    return writer.data;
}

/**
Stream class for reading bitpacked data.
This class is a wrapper around the bit reader class. Its purpose is to provide unified interface for reading and writing.
You can determine if you are reading from a stream by calling Stream::IsReading inside your templated serialize method.
This is evaluated at compile time, letting the compiler generate optimized serialize functions without the hassle of maintaining separate read and write functions.
IMPORTANT: Generally, you don't call methods on this class directly. Use the serialize_* macros instead.
@see BitReader
*/
ReadStream :: struct {
    using #as base: Stream;
    base.type = .Read;
    base.isWriting = false;
    base.isReading = true;

    reader: BitReader;  // The bit reader used for all bitpacked read operations.
}

/*
Read stream constructor.
@param buffer The buffer to read from.
@param bytes The number of bytes in the buffer. May be a non-multiple of four, however if it is, the underlying buffer allocated should be large enough to read the any remainder bytes as a dword.
@param allocator The allocator to use for stream allocations. This lets you dynamically allocate memory as you read and write packets.
*/
stream_init :: inline (using stream: *ReadStream, buffer: [] u8) {
    bit_reader_init(*reader, buffer);
}

/*
If we were to read an align right now, how many bits would we need to read?
@returns The number of zero pad bits required to achieve byte alignment in [0,7].
*/
stream_get_align_bits :: inline (using stream: *ReadStream) -> int {
    return bit_reader_get_align_bits(reader);
}

/*
Stream class for estimating how many bits it would take to serialize something.
This class acts like a bit writer (IsWriting is 1, IsReading is 0), but instead of writing data, it counts how many bits would be written.
Note that when the serialization includes alignment to byte (see MeasureStream::SerializeAlign), this is an estimate and not an exact measurement. The estimate is guaranteed to be conservative.
@see BitWriter
@see BitReader
*/
MeasureStream :: struct {
    using #as base: Stream;
    base.type = .Measure;
    base.isWriting = true;
    base.isReading = false;

    bitsWritten: int;  // Counts the number of bits written.
}

/*
If we were to write an align right now, how many bits would be required?
IMPORTANT: Since the number of bits required for alignment depends on where an object is written in the final bit stream, this measurement is conservative.
@returns Always returns worst case 7 bits.
*/
stream_get_align_bits :: inline (using stream: *MeasureStream) -> int {
    return 7;
}

// TODO(dlb)[cleanup]: I don't think anyone calls this.
//
//   /*
//   Serialize a safety check to the stream (measure).
//   @returns Always returns true. All checking is performed by debug asserts on write.
//   */
//   stream_serialize_check :: (using stream: *MeasureStream) -> bool {
//       #if YOJIMBO_SERIALIZE_CHECKS {
//           stream_align(stream);
//           bitsWritten += 32;
//       }
//       return true;
//   }
//

/*
Serialize integer value (read/write/measure).
This is a helper macro to make writing unified serialize functions easier.
Serialize macros returns false on error so we don't need to use exceptions for error handling on read. This is an important safety measure because packet data comes from the network and may be malicious.
IMPORTANT: This macro must be called inside a function with a bool return value.
@param stream The stream object. May be a read, write or measure stream.
@param value The integer value to serialize in [min,max].
@param min The minimum value.
@param max The maximum value.
*/
serialize_int :: (stream: *Stream, value: *$T, min: T, max: T) #expand {
    assert(size_of(T) <= 8);
    assert(min <= max);

    // .Write or .Measure
    if stream.isWriting {
        assert_greater_or_equal(value.*, min);
        assert_less_or_equal(value.*, max);
    }

    v := cast,no_check(u64) (value.* - min);
    bits := bits_required(cast(u64) min, cast(u64) max);
    if !stream_serialize_bits(stream, *v, bits) {
        `return false;
    }

    if stream.isReading {
        new_value := cast,no_check(T)(v) + min;
        if new_value < min || new_value > max {
            `return false;
        }
        value.* = new_value;
    }
}

/*
Serialize bits to the stream (read/write/measure).
This is a helper macro to make writing unified serialize functions easier.
Serialize macros returns false on error so we don't need to use exceptions for error handling on read. This is an important safety measure because packet data comes from the network and may be malicious.
IMPORTANT: This macro must be called inside a function with a bool return value.
@param stream The stream object. May be a read, write or measure stream.
@param value The unsigned integer value to serialize.
@param bits The number of bits to serialize in [1,32].
*/
serialize_bits :: (stream: *Stream, value: *$T, bits: int) #expand {
    assert(size_of(T) <= 8);
    assert(bits <= size_of(T) * 8);

    v := cast(u64) value.*;
    if !stream_serialize_bits(stream, *v, bits) {
        `return false;
    }
    value.* = cast(T)v;
}

/*
Serialize a boolean value to the stream (read/write/measure).
This is a helper macro to make writing unified serialize functions easier.
Serialize macros returns false on error so we don't need to use exceptions for error handling on read. This is an important safety measure because packet data comes from the network and may be malicious.
IMPORTANT: This macro must be called inside a function with a bool return value.
@param stream The stream object. May be a read, write or measure stream.
@param value The boolean value to serialize.
*/
serialize_bool :: (stream: *Stream, value: *bool) #expand {
    v: u64;
    if stream.isWriting {
        v = ifx value.* then cast(u64) 1 else cast(u64) 0;
    }
    if !stream_serialize_bits(stream, *v, 1) {
        `return false;
    }
    if stream.isReading {
        value.* = ifx v then true else false;
    }
}

/*
Serialize floating point value (read/write/measure).
This is a helper macro to make writing unified serialize functions easier.
Serialize macros returns false on error so we don't need to use exceptions for error handling on read. This is an important safety measure because packet data comes from the network and may be malicious.
IMPORTANT: This macro must be called inside a function with a bool return value.
@param stream The stream object. May be a read, write or measure stream.
@param value The float value to serialize.
*/
serialize_float :: (stream: *Stream, value: *float) #expand {
    v32: u32;
    if stream.isWriting {
        memcpy(*v32, value, 4);
    }

    v := cast(u64) v32;
    if !stream_serialize_bits(stream, *v, 32) {
        `return false;
    }

    if stream.isReading {
        v32 := cast(u32) v;
        memcpy(value, *v32, 4);
    }
}

/*
Serialize compressed floating point value (read/write/measure).
This is a helper macro to make writing unified serialize functions easier.
Serialize macros returns false on error so we don't need to use exceptions for error handling on read. This is an important safety measure because packet data comes from the network and may be malicious.
IMPORTANT: This macro must be called inside a function with a bool return value.
@param stream The stream object. May be a read, write or measure stream.
@param value The float value to serialize.
*/
serialize_compressed_float :: (stream: *Stream, value: *float, min: float, max: float, res: float) #expand {
    delta := max - min;
    values := delta / res;
    maxIntegerValue := cast(u64) Math.ceil(values);

    v: u64;
    if stream.isWriting {
        normalizedValue := clamp((value.* - min) / delta, 0.0, 1.0);
        v = cast(u64) Math.floor(normalizedValue * maxIntegerValue + 0.5);
    }

    bits := bits_required(0, maxIntegerValue);
    if !stream_serialize_bits(stream, *v, bits) {
        `return false;
    }

    if stream.isReading {
        normalizedValue := v / cast(float) maxIntegerValue;
        value.* = normalizedValue * delta + min;
    }
}

/*
Serialize double precision floating point value to the stream (read/write/measure).
This is a helper macro to make writing unified serialize functions easier.
Serialize macros returns false on error so we don't need to use exceptions for error handling on read. This is an important safety measure because packet data comes from the network and may be malicious.
IMPORTANT: This macro must be called inside a function with a bool return value.
@param stream The stream object. May be a read, write or measure stream.
@param value The double precision floating point value to serialize.
*/
serialize_float64 :: (stream: *Stream, value: *float64) #expand {
    v: u64;
    if stream.isWriting {
        memcpy(*v, value, 8);
    }
    if !stream_serialize_bits(stream, *v, 64) {
        `return false;
    }
    if stream.isReading {
        memcpy(value, *v, 8);
    }
}

/*
Serialize an array of bytes to the stream (read/write/measure).
This is a helper macro to make unified serialize functions easier.
Serialize macros returns false on error so we don't need to use exceptions for error handling on read. This is an important safety measure because packet data comes from the network and may be malicious.
IMPORTANT: This macro must be called inside a function with a bool return value.
@param stream The stream object. May be a read, write or measure stream.
@param bytes Array of bytes to be written.
*/
serialize_bytes :: (stream: *Stream, bytes: [] u8) #expand {
    if !stream_serialize_bytes(stream, bytes) {
        `return false;
    }
}

/*
Serialize a string to the stream (read/write/measure).
This is a helper macro to make writing unified serialize functions easier.
Serialize macros returns false on error so we don't need to use exceptions for error handling on read. This is an important safety measure because packet data comes from the network and may be malicious.
IMPORTANT: This macro must be called inside a function with a bool return value.
@param stream The stream object. May be a read, write or measure stream.
@param string The string to serialize write/measure. Pointer to buffer to be filled on read.
@param buffer_size The size of the string buffer. String with terminating null character must fit into this buffer.
*/
serialize_string :: (stream: *Stream, str: *string, max_length: s32) #expand {
    length: s32;
    if stream.isWriting {
        length = cast(s32) str.count;
        assert(length <= max_length);
    }
    serialize_int(stream, *length, 0, max_length);
    if stream.isReading {
        str.* = alloc_string(length);
    }
    serialize_bytes(stream, .{ str.count, str.data });
}

/*
Serialize an alignment to the stream (read/write/measure).
This is a helper macro to make writing unified serialize functions easier.
Serialize macros returns false on error so we don't need to use exceptions for error handling on read. This is an important safety measure because packet data comes from the network and may be malicious.
IMPORTANT: This macro must be called inside a function with a bool return value.
@param stream The stream object. May be a read, write or measure stream.
*/
serialize_align :: (stream: *Stream) #expand {
    if !stream_align(stream) {
        `return false;
    }
}

/*
Serialize a sequence number relative to another (read/write/measure).
@param stream The stream object. May be a read, write or measure stream.
@param sequence1 The first sequence number to serialize relative to.
@param sequence2 The second sequence number to be encoded relative to the first.
*/
serialize_sequence_relative :: (stream: *Stream, sequence1: u16, sequence2: *u16) -> bool {
    if stream.isWriting {
        a: u32 = sequence1;
        b: u32 = sequence2.* + ifx sequence1 > sequence2.* then cast(u32) 65536 else cast(u32) 0;
        serialize_int32_relative(stream, a, *b);
    } else {
        a: u32 = sequence1;
        b: u32 = 0;
        serialize_int32_relative(stream, a, *b);
        if b >= 65536 {
            b -= 65536;
        }
        sequence2.* = cast(u16) b;
    }
    return true;
}

/*
Serialize an integer value relative to another (read/write/measure).
This is a helper macro to make writing unified serialize functions easier.
Serialize macros returns false on error so we don't need to use exceptions for error handling on read. This is an important safety measure because packet data comes from the network and may be malicious.
IMPORTANT: This macro must be called inside a function with a bool return value.
@param stream The stream object. May be a read, write or measure stream.
@param previous The previous integer value.
@param current The current integer value (must be greater than previous).
*/
serialize_int32_relative :: (stream: *Stream, previous: $T, current: *T) #expand {
    if !stream_serialize_int32_relative_internal(stream, previous, current) {
        `return false;
    }
}

#scope_file

stream_serialize_int32_relative_internal :: (stream: *Stream, previous: $T, current: *T) -> bool {
    assert(size_of(T) <= 4);

    difference: T;
    if stream.isWriting {
        assert(previous < current.*);
        difference = current.* - previous;
    }

    oneBit := false;
    if stream.isWriting {
        oneBit = difference == 1;
    }
    serialize_bool(stream, *oneBit);
    if oneBit {
        if stream.isReading {
            current.* = previous + 1;
        }
        return true;
    }

    twoBits := false;
    if stream.isWriting {
        twoBits = difference <= 6;
    }
    serialize_bool(stream, *twoBits);
    if twoBits {
        serialize_int(stream, *difference, 2, 6);
        if stream.isReading {
            current.* = previous + difference;
        }
        return true;
    }

    fourBits := false;
    if stream.isWriting {
        fourBits = difference <= 23;
    }
    serialize_bool(stream, *fourBits);
    if fourBits {
        serialize_int(stream, *difference, 7, 23);
        if stream.isReading {
            current.* = previous + difference;
        }
        return true;
    }

    eightBits := false;
    if stream.isWriting {
        eightBits = difference <= 280;
    }
    serialize_bool(stream, *eightBits);
    if eightBits {
        serialize_int(stream, *difference, 24, 280);
        if stream.isReading {
            current.* = previous + difference;
        }
        return true;
    }

    twelveBits := false;
    if stream.isWriting {
        twelveBits = difference <= 4377;
    }
    serialize_bool(stream, *twelveBits);
    if twelveBits {
        serialize_int(stream, *difference, 281, 4377);
        if stream.isReading {
            current.* = previous + difference;
        }
        return true;
    }

    sixteenBits := false;
    if stream.isWriting {
        sixteenBits = difference <= 69914;
    }
    serialize_bool(stream, *sixteenBits);
    if sixteenBits {
        serialize_int(stream, *difference, 4378, 69914);
        if stream.isReading {
            current.* = previous + difference;
        }
        return true;
    }

    value := cast(u32) current.*;
    serialize_bits(stream, *value, 32);
    if stream.isReading {
        current.* = cast(T) value;
    }

    return true;
}

#import "Basic";
#import "Bit_Operations";
Math :: #import "Math";
#import "Assertive";