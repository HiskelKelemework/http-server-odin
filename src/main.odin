package main

import "core:bytes"
import "core:compress/gzip"
import "core:fmt"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:thread"

HttpHeader :: struct {
	key, value: string,
}

Request :: struct {
	method, path: string,
	headers:      [dynamic]HttpHeader,
}

Response :: struct {
	status_code: u16,
	headers:     [dynamic]HttpHeader,
	data:        []byte,
}

main :: proc() {
	directory := ""

	directory_flag_index, found := slice.linear_search(os.args[:], "--directory")
	if found {
		directory_index := directory_flag_index + 1
		fmt.println("directory indexl", directory_index, "array size", len(os.args))

		has_directory_value := directory_index < len(os.args)

		if has_directory_value {
			directory = os.args[directory_flag_index + 1]
			fmt.println("directory changed to ", directory)
		}
	}


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

	outer_loop: for {
		// repeatedly accept new connections
		client_socket := posix.accept(sock, cast(^posix.sockaddr)(&client_addr), &client_addr_len)
		if client_socket < 0 {
			fmt.eprintln("failed to accept a client connection")
		}

		thread_data := new(RequestHandlerData)
		thread_data.socket_fd = client_socket
		thread_data.directory = directory

		thread.create_and_start_with_data(thread_data, request_handler, nil, .Normal, true)
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

RequestHandlerData :: struct {
	socket_fd: posix.FD,
	directory: string,
}

request_handler :: proc(data: rawptr) {
	data := (^RequestHandlerData)(data)

	client_socket := data.socket_fd
	defer posix.close(client_socket)

	directory := data.directory

	// here, we need to read the request line
	reader: Buffered_Reader
	buffered_reader_init(&reader, client_socket)
	defer buffered_reader_destroy(reader)

	line, ok := buffered_reader_read_line(&reader)
	if !ok {
		fmt.eprintln("could not read a full line from buffer")
		return
	}

	request_line := string(line)
	parts, split_error := strings.split(request_line, " ")
	defer delete(parts)

	if split_error != nil {
		fmt.eprintln("error during request line split", split_error)
		return
	}

	if len(parts) != 3 {
		fmt.eprintln("request parts must have exactly three parts")
		return
	}

	request := Request{}
	request.method = parts[0]
	request.path = parts[1]
	request.headers = [dynamic]HttpHeader{}

	response := Response{}

	header_loop: for {
		header, ok := buffered_reader_read_line(&reader)
		if !ok {
			fmt.eprintln("error reading header line")
			return
		}

		header_string := string(header)
		if header_string == "" do break header_loop

		header_parts, error := strings.split(header_string, ": ")
		defer delete(header_parts)

		if error != nil {
			fmt.eprintln("error splitting header", error)
			return
		}

		if len(header_parts) == 2 {
			new_header := HttpHeader {
				key   = header_parts[0],
				value = header_parts[1],
			}
			fmt.println("new header", new_header)
			append_elem(&request.headers, new_header)
		}
	}

	if request.path == "/" {
		// return 200 ok
		response.status_code = 200
	} else if strings.starts_with(request.path, "/echo/") {
		// echo route handler
		echo_parts, error := strings.split(request.path, "/echo/")
		defer delete(echo_parts)

		if error != nil {
			fmt.eprintln("error during request line split", split_error)
			return
		}

		string_to_echo := echo_parts[1]

		response.status_code = 200
		append_elem(&response.headers, HttpHeader{key = "Content-Type", value = "text/plain"})
		append_elem(
			&response.headers,
			HttpHeader{key = "Content-Length", value = fmt.tprintf("%d", len(string_to_echo))},
		)
	} else if request.path == "/user-agent" {
		// whatever we get in the user agent header, we return
		index, found := slice.linear_search_proc(
			request.headers[:],
			proc(header: HttpHeader) -> bool {
				return strings.to_lower(header.key) == "user-agent"
			},
		)

		if !found {
			response.status_code = 404
		} else {
			header := request.headers[index]

			response.status_code = 200
			append_elem(&response.headers, HttpHeader{key = "Content-Type", value = "text/plain"})
			append_elem(
				&response.headers,
				HttpHeader{key = "Content-Length", value = fmt.tprintf("%d", len(header.value))},
			)
		}
	} else if request.method == "GET" && strings.starts_with(request.path, "/files/") {
		// we need to get the --directory flag passed
		request_parts, error := strings.split(request.path, "/files/")
		defer delete(request_parts)

		if error != nil || len(request_parts) != 2 {
			fmt.eprintln("could not get filename from path")
			response.status_code = 404
		} else {
			filename := request_parts[1]
			data, found := handle_read_file(filename, directory)
			defer delete(data)

			if !found {
				response.status_code = 404
			} else {
				response.status_code = 200
				append_elem(
					&response.headers,
					HttpHeader{key = "Content-Type", value = "application/octet-stream"},
				)
				append_elem(
					&response.headers,
					HttpHeader{key = "Content-Length", value = fmt.tprintf("%d", len(data))},
				)
			}
		}
	} else if request.method == "POST" && strings.starts_with(request.path, "/files/") {
		// we need to get the --directory flag passed
		request_parts, error := strings.split(request.path, "/files/")
		defer delete(request_parts)

		if error != nil || len(request_parts) != 2 {
			fmt.eprintln("could not get filename from path")
			response.status_code = 404
		} else {
			filename := request_parts[1]
			index, found := slice.linear_search_proc(
				request.headers[:],
				proc(element: HttpHeader) -> bool {
					return strings.to_lower(element.key) == "content-length"
				},
			)

			if !found {
				// we didn't find a content length header, without which we can't figure out how many bytes to read from the socket
				fmt.eprintln("didn't find a content length header")
				response.status_code = 404
			} else {
				contentLengthHeader := request.headers[index]
				length, ok := strconv.parse_int(contentLengthHeader.value)

				if !ok {
					response.status_code = 404
				} else {
					file_data, ok := handle_read_request_body(&reader, length)
					fmt.println("file content as string", string(file_data))

					success := handle_write_file(filename, directory, file_data)
					response.status_code = success ? 201 : 404
				}
			}
		}
	} else {
		// return 404 not found
		response.status_code = 404
	}

	response_as_string := format_http_response(response)

	posix.write(
		client_socket,
		raw_data(transmute([]byte)response_as_string),
		len(response_as_string),
	)
}

handle_read_file :: proc(filename, directory: string) -> (contents: []byte, found: bool) {
	joined_path, join_err := filepath.join({directory, filename}, context.allocator)
	if join_err != nil {
		fmt.eprintln(#procedure, "join failed", join_err)
		return nil, false
	}

	data, error := os.read_entire_file(joined_path, context.allocator)

	if error != nil do return nil, false
	return data, true
}

handle_write_file :: proc(filename, directory: string, data: []byte) -> bool {
	full_file_name, join_error := filepath.join({directory, filename}, context.allocator)
	if join_error != nil {
		fmt.eprintln(#procedure, "join failed", join_error)
		return false
	}

	error := os.write_entire_file_from_bytes(full_file_name, data)
	return error != nil
}


handle_read_request_body :: proc(
	reader: ^Buffered_Reader,
	length: int,
) -> (
	data: []byte,
	ok: bool,
) {
	unused_bytes_from_reader := reader.tail - reader.head
	fmt.println("expected unused bytes", unused_bytes_from_reader)

	if unused_bytes_from_reader >= length {
		fmt.println("returning early because we have the bytes")

		old_head := reader.head
		reader.head += length

		return reader.data[old_head:old_head + length], true
	}

	read_chunk_size: uint = 4096

	// until we find a match
	for {
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
			return reader.data[reader.head:reader.tail], false
		}

		fmt.println("read bytes", bytes_read)

		reader.tail += bytes_read
		unused_bytes_from_reader := reader.tail - reader.head
		fmt.println("inside loop unused bytes", unused_bytes_from_reader)

		if unused_bytes_from_reader >= length {
			fmt.println("about to return")
			old_head := reader.head
			reader.head += length

			return reader.data[old_head:old_head + length], true
		}
	}
}


format_http_response :: proc(response: Response) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	// response line
	fmt.sbprintf(&builder, "HTTP/1.1 %s\r\n", status_code_to_string(response.status_code))

	// http headers
	for header in response.headers {
		fmt.sbprintf(&builder, "%s: %s\r\n", header.key, header.value)
	}

	fmt.sbprint(&builder, "\r\n")

	fmt.sbprintf(&builder, string(response.data))

	return strings.to_string(builder)
}

status_code_to_string :: proc(status_code: u16) -> string {
	if status_code == 200 {
		return "200 OK"
	}

	if status_code == 201 {
		return "201 Created"
	}

	return "404 Not Found"
}
