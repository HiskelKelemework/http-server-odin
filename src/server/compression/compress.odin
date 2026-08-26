
package compression

import "vendor:zlib"

// Compresses `src` into gzip format. Returns a newly allocated []u8 (caller must delete it).
// level: zlib.DEFAULT_COMPRESSION, zlib.BEST_SPEED, zlib.BEST_COMPRESSION, etc.
gzip_compress :: proc(
	src: []u8,
	level: i32 = zlib.DEFAULT_COMPRESSION,
	allocator := context.allocator,
) -> (
	out: []u8,
	ok: bool,
) {
	if len(src) == 0 {
		return {}, true
	}

	strm: zlib.z_stream
	// windowBits = 15+16 → gzip format (header + CRC trailer)
	// method = zlib.DEFLATED, memLevel = 8, strategy = zlib.DEFAULT_STRATEGY
	ret := zlib.deflateInit2(&strm, level, zlib.DEFLATED, 15 + 16, 8, zlib.DEFAULT_STRATEGY)
	if ret != zlib.OK {
		return {}, false
	}
	defer zlib.deflateEnd(&strm)

	// Upper bound for compressed size
	bound := zlib.deflateBound(&strm, u64(len(src)))
	// Or the simpler compressBound (slightly larger but fine)
	// bound = zlib.compressBound(u32(len(src)))

	dest := make([]u8, bound, allocator)
	defer if !ok do delete(dest, allocator)

	strm.next_in = raw_data(src)
	strm.avail_in = u32(len(src))
	strm.next_out = raw_data(dest)
	strm.avail_out = u32(len(dest))

	ret = zlib.deflate(&strm, zlib.FINISH)
	if ret != zlib.STREAM_END {
		return {}, false
	}

	// Shrink to the actual compressed length
	out = dest[:strm.total_out]
	ok = true
	return
}
