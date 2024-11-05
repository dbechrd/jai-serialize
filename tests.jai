serialize_test :: () {
    log("\n--- Serialize ------------------------------------------------------------------\n");
    log("Running tests...\n");
    TEST(test_bitpacker);
    TEST(test_bits_required);
    TEST(test_stream);
    log("Passed!\n");
}

#scope_file

#import "Basic";
#import "Random";
#import "Trivial";
#import "Assertive";

TEST :: (test: (), $call := #caller_code) {
    assert_test(test, ENABLE_LOGGING, call);
    reset_temporary_storage();
}

test_bitpacker :: () {
    BufferSize :: 256;

    buffer: [BufferSize] u8;

    writer: BitWriter;
    bit_writer_init(*writer, buffer);

    assert_equal(cast(*u8) writer.data.data, buffer.data);
    assert_equal(writer.bitsWritten, 0);
    assert_equal(bit_writer_get_bytes_written(*writer), 0);
    assert_equal(writer.numBits - writer.bitsWritten, BufferSize * 8);

    bit_writer_write_bits(*writer, 0, 1);
    bit_writer_write_bits(*writer, 1, 1);
    bit_writer_write_bits(*writer, 10, 8);
    bit_writer_write_bits(*writer, 255, 8);
    bit_writer_write_bits(*writer, 1000, 10);
    bit_writer_write_bits(*writer, 50000, 16);
    bit_writer_write_bits(*writer, 9999999, 32);
    bit_writer_flush_bits(*writer);

    bitsWritten := 1 + 1 + 8 + 8 + 10 + 16 + 32;

    assert_equal(bit_writer_get_bytes_written(*writer), 10);
    assert_equal(writer.bitsWritten, bitsWritten);
    assert_equal(writer.numBits - writer.bitsWritten, BufferSize * 8 - bitsWritten);

    bytesWritten := bit_writer_get_bytes_written(*writer);

    assert_equal(bytesWritten, 10);

    reader: BitReader;
    bit_reader_init(*reader, buffer);

    assert_equal(reader.bitsRead, 0);
    assert_equal(reader.numBits - reader.bitsRead, buffer.count * 8);

    a := bit_reader_read_bits(*reader, 1);
    b := bit_reader_read_bits(*reader, 1);
    c := bit_reader_read_bits(*reader, 8);
    d := bit_reader_read_bits(*reader, 8);
    e := bit_reader_read_bits(*reader, 10);
    f := bit_reader_read_bits(*reader, 16);
    g := bit_reader_read_bits(*reader, 32);

    assert_equal(a, 0);
    assert_equal(b, 1);
    assert_equal(c, 10);
    assert_equal(d, 255);
    assert_equal(e, 1000);
    assert_equal(f, 50000);
    assert_equal(g, 9999999);

    assert_equal(reader.bitsRead, bitsWritten);
    assert_equal(reader.numBits - reader.bitsRead, buffer.count * 8 - bitsWritten);
}

test_bits_required :: () {
    assert_equal(bits_required(0, 0), 1);
    assert_equal(bits_required(0, 1), 1);
    assert_equal(bits_required(0, 2), 2);
    assert_equal(bits_required(0, 3), 2);
    assert_equal(bits_required(0, 4), 3);
    assert_equal(bits_required(0, 5), 3);
    assert_equal(bits_required(0, 6), 3);
    assert_equal(bits_required(0, 7), 3);
    assert_equal(bits_required(0, 8), 4);
    assert_equal(bits_required(0, 0x_FF), 8);
    assert_equal(bits_required(0, 0x_FFFF), 16);
    assert_equal(bits_required(0, 0x_FFFF_FFFF), 32);
    assert_equal(bits_required(0, 0x_1_0000_0000), 33);
    assert_equal(bits_required(0, 0x_FFFF_FFFF_FFFF_FFFF), 64);
}


MaxItems :: 11;

TestData :: struct {
    a                      : s32;
    b                      : s32;
    c                      : s32;
    d                      : u32;
    e                      : u32;
    f                      : u32;
    flag                   : bool;
    v32                    : u32;
    v64                    : u64;
    numItems               : s32;
    items                  : [MaxItems] s32;
    float_value            : float;
    compressed_float_value : float;
    double_value           : float64;
    uint64_value           : u64;
    int_relative           : s32;
    bytes                  : [17] u8;
    str                    : string;
}

test_data_init :: (data: *TestData) {
    data.a = 1;
    data.b = -2;
    data.c = 150;
    data.d = 55;
    data.e = 255;
    data.f = 127;
    data.flag = true;

    data.numItems = MaxItems / 2;
    for 0..data.numItems-1 {
        data.items[it] = cast(s32)(it + 10);
    }

    data.compressed_float_value = 2.13;
    data.float_value = 3.1415926;
    data.double_value = 1 / 3.0;
    data.uint64_value = 0x1234567898765432;
    data.int_relative = 5;

    for 0..data.bytes.count-1 {
        data.bytes[it] = cast(u8) (random_get() % 255);
    }

    data.str = "Hello, Sailor!";
}

test_data_serialize :: (data: *TestData, stream: *Stream) -> bool {
    serialize_int(stream, *data.a, -10, 10);
    serialize_int(stream, *data.b, -10, 10);
    serialize_int(stream, *data.c, -100, 10000);

    serialize_bits(stream, *data.d, 6);
    serialize_bits(stream, *data.e, 8);
    serialize_bits(stream, *data.f, 7);

    serialize_align(stream);

    serialize_bool(stream, *data.flag);

    serialize_int(stream, *data.numItems, 0, MaxItems - 1);
    for 0..data.numItems-1 {
        serialize_bits(stream, *data.items[it], 8);
    }

    serialize_float(stream, *data.float_value);

    serialize_compressed_float(stream, *data.compressed_float_value, 0, 10, 0.01);

    serialize_float64(stream, *data.double_value);

    serialize_bits(stream, *data.uint64_value, 64);

    serialize_int32_relative(stream, data.a, *data.int_relative);

    serialize_bytes(stream, data.bytes);

    serialize_string(stream, *data.str, 256,, temp);

    return true;
}

test_data_compare :: (a: TestData, b: TestData) -> bool {
    return
        a.a == b.a &&
        a.b == b.b &&
        a.c == b.c &&
        a.d == b.d &&
        a.e == b.e &&
        a.f == b.f &&
        a.flag == b.flag &&
        a.v32 == b.v32 &&
        a.v64 == b.v64 &&
        a.numItems == b.numItems &&
        memcmp(a.items.data, b.items.data, b.numItems) == 0 &&
        a.float_value == b.float_value &&
        a.compressed_float_value == b.compressed_float_value &&
        a.double_value == b.double_value &&
        a.uint64_value == b.uint64_value &&
        a.int_relative == b.int_relative &&
        array_equal(a.bytes, b.bytes) &&
        a.str == b.str;
}

test_stream :: () {
    BufferSize :: 1024;

    buffer: [BufferSize] u8;

    writeStream: WriteStream;
    stream_init(*writeStream, buffer);

    writeData: TestData;
    test_data_init(*writeData);
    test_data_serialize(*writeData, *writeStream);
    stream_flush(*writeStream);

    bytesWritten := stream_get_bytes_processed(*writeStream);

    readData: TestData;
    readStream: ReadStream;
    stream_init(*readStream, buffer);
    test_data_serialize(*readData, *readStream);

    assert_equal(readData.a, writeData.a);
    assert_equal(readData.b, writeData.b);
    assert_equal(readData.c, writeData.c);
    assert_equal(readData.d, writeData.d);
    assert_equal(readData.e, writeData.e);
    assert_equal(readData.f, writeData.f);
    assert_equal(readData.flag, writeData.flag);
    assert_equal(readData.v32, writeData.v32);
    assert_equal(readData.v64, writeData.v64);
    assert_equal(readData.numItems, writeData.numItems);
    assert_equal(readData.items, writeData.items);
    assert_equal(readData.float_value, writeData.float_value);
    assert_equal(readData.compressed_float_value, writeData.compressed_float_value);
    assert_equal(readData.double_value, writeData.double_value);
    assert_equal(readData.uint64_value, writeData.uint64_value);
    assert_equal(readData.int_relative, writeData.int_relative);
    assert_equal(readData.bytes, writeData.bytes);
    assert_equal(readData.str, writeData.str);
}
