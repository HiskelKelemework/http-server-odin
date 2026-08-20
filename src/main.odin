package main

import "core:bytes"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

main :: proc() {
	sock := posix.socket(posix.AF.INET, posix.Sock.STREAM)
	if sock < 0 {
		fmt.println("Failed to create server socket")
		return
	}

	// Since the tester restarts your program quite often, setting SO_REUSEADDR
	// ensures that we don't run into 'Address already in use' errors
	reuse: i32 = 1
	posix.setsockopt(
		sock,
		i32(posix.SOL_SOCKET),
		posix.Sock_Option.REUSEADDR,
		&reuse,
		posix.socklen_t(size_of(reuse)),
	)

	addr := posix.sockaddr_in {
		sin_family = posix.sa_family_t.INET,
		sin_port   = u16be(4221),
		sin_addr   = {}, // INADDR_ANY
	}
	posix.bind(sock, cast(^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr)))
	posix.listen(sock, 8)
	fmt.println("Listening on port 4221...")

	// You can use print statements as follows for debugging, they'll be visible when running tests.
	fmt.eprintln("Logs from your program will appear here!")

	// TODO: Uncomment the code below to pass the first stage
	client_addr: posix.sockaddr_storage
	client_addr_len := posix.socklen_t(size_of(posix.sockaddr_storage))

	for {
		// repeatedly accept new connections
		client_socket := posix.accept(sock, cast(^posix.sockaddr)(&client_addr), &client_addr_len)
		if client_socket < 0 {
			fmt.eprintln("failed to accept a client connection")
		}

		fmt.println("accepted socket")
		// here, we need to read the request line
		reader: Buffered_Reader
		buffered_reader_init(&reader, client_socket)
		defer buffered_reader_destroy(reader)

		line, ok := buffered_reader_read_line(&reader)
		if !ok {
			fmt.eprintln("could not read a full line from buffer")
			continue
		}

		request_line := string(line)
		parts, split_error := strings.split(request_line, " ")
		if split_error != nil {
			fmt.eprintln("error during request line split", split_error)
			continue
		}

		if len(parts) != 3 {
			fmt.eprintln("request parts must have exactly three parts")
			continue
		}

		method, path, http_version := parts[0], parts[1], parts[2]
		if path == "/" {
			// return 200 ok
			response := "HTTP/1.1 200 OK \r\n\r\n"
			posix.write(client_socket, raw_data(transmute([]byte)response), len(response))
		} else {
			// return 404 not found
			response := "HTTP/1.1 404 Not Found\r\n\r\n"
			posix.write(client_socket, raw_data(transmute([]byte)response), len(response))
		}

		posix.close(client_socket)
	}
}

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
		if cap(reader.data) <= len(data) + int(read_chunk_size) {
			// need to resize here
			resize(&reader.data, len(data) + int(read_chunk_size))
		}

		bytes_read := posix.read(reader.socket, raw_data(reader.data[:]), read_chunk_size)
		fmt.println("read bytes", bytes_read)
		if bytes_read < 0 {
			// reading failed
			return reader.data[reader.head:reader.tail], false
		}

		if bytes_read == 0 {
			// socket closed (gracefully)
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
