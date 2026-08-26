package buffered_reader

import "core:bytes"
import "core:fmt"
import "core:sys/posix"

Buffered_Reader :: struct {
	socket:     posix.FD,
	data:       [dynamic]byte,
	head, tail: int,
}

buffered_reader_init :: proc(reader: ^Buffered_Reader, socket_fd: posix.FD) {
	reader.head = 0
	reader.tail = 0
	reader.socket = socket_fd
	reader.data = make([dynamic]byte)
}

buffered_reader_destroy :: proc(reader: Buffered_Reader) {
	delete(reader.data)
}

buffered_reader_read_line :: proc(reader: ^Buffered_Reader) -> (data: []byte, ok: bool) {
	CRLF := transmute([]byte)string("\r\n")

	index_at := bytes.index(reader.data[reader.head:reader.tail], CRLF)
	read_chunk_size: uint = 4096

	// until we find a match
	for index_at < 0 {
		desired_capacity := reader.tail + int(read_chunk_size)

		if cap(reader.data) <= desired_capacity {
			// need to resize here
			error := resize(&reader.data, desired_capacity)
			if error != nil {
				fmt.eprintln(#procedure, "resize call failed", error)
				return reader.data[reader.head:reader.tail], false
			}
		}

		bytes_read := posix.read(
			reader.socket,
			raw_data(reader.data[reader.tail:]),
			read_chunk_size,
		)

		if bytes_read <= 0 {
			// reading failed (-1) or connection closed (0)
			fmt.println("read bytes :: ", bytes_read)
			return reader.data[reader.head:reader.tail], false
		}

		reader.tail += bytes_read

		// look again for a match
		index_at = bytes.index(reader.data[reader.head:reader.tail], CRLF)
	}

	new_head := reader.head + index_at
	// when we read we should exclude the crlf bytes
	slice_to_return := reader.data[reader.head:new_head]

	// but cursor should advance past the crlf bytes
	reader.head = new_head + len(CRLF)

	return slice_to_return, true
}
