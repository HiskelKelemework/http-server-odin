package main

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
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

RequestHandlerData :: struct {
	socket_fd: posix.FD,
	directory: string,
}

request_handler :: proc(data: rawptr) {
	data := (^RequestHandlerData)(data)

	client_socket := data.socket_fd
	directory := data.directory
	fmt.println("in request_handler", client_socket, "directory", directory)

	defer posix.close(client_socket)

	fmt.println("accepted socket")
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

	header_loop: for {
		header, ok := buffered_reader_read_line(&reader)
		if !ok {
			fmt.eprintln("error reading header line")
			return
		}

		header_string := string(header)
		if header_string == "" do break

		header_parts, error := strings.split(header_string, ": ")
		if error != nil {
			fmt.eprintln("error splitting header", error)
			return
		}

		if len(header_parts) != 2 {
			fmt.eprintln("expected 2 parts to header but found", len(header_parts))
			return
		}

		append_elem(&request.headers, HttpHeader{key = header_parts[0], value = header_parts[1]})
	}

	response: string

	if request.path == "/" {
		// return 200 ok
		response = "HTTP/1.1 200 OK\r\n\r\n"
	} else if strings.starts_with(request.path, "/echo/") {
		// echo route handler
		echo_parts, error := strings.split(request.path, "/echo/")
		if error != nil {
			fmt.eprintln("error during request line split", split_error)
			return
		}

		string_to_echo := echo_parts[1]

		response = fmt.tprintf(
			"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n%s",
			len(string_to_echo),
			string_to_echo,
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
			response = "HTTP/1.1 404 Not Found\r\n\r\n"
		} else {
			header := request.headers[index]

			response = fmt.tprintf(
				"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n%s",
				len(header.value),
				header.value,
			)
		}
	} else if strings.starts_with(request.path, "/files/") {
		// we need to get the --directory flag passed
		request_parts, error := strings.split(request.path, "/files/")
		if error != nil || len(request_parts) != 2 {
			fmt.eprintln("could not get filename from path")
			response = "HTTP/1.1 404 Not Found\r\n\r\n"
		} else {
			filename := request_parts[1]
			data, found := handle_read_file(filename, directory)
			defer delete(data)

			if !found {
				response = "HTTP/1.1 404 Not Found\r\n\r\n"
			} else {
				response = fmt.tprintf(
					"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n%s",
					len(data),
					data,
				)
			}
		}
	} else {
		// return 404 not found
		response = "HTTP/1.1 404 Not Found\r\n\r\n"
	}

	posix.write(client_socket, raw_data(transmute([]byte)response), len(response))
}

handle_read_file :: proc(filename, directory: string) -> (contents: []byte, found: bool) {
	full_file_name := fmt.tprintf("%s%s", filename, directory)

	cwd, err := os.get_working_directory(context.allocator)
	if err != nil {
		fmt.eprintln("failed to get cwd", err)
		return nil, false
	}

	joined_path, join_err := filepath.join({cwd, directory, filename})
	if join_err != nil {
		fmt.eprintln("join failed", err)
		return nil, false
	}

	fmt.println("full_file_name", joined_path)
	data, error := os.read_entire_file(joined_path, context.allocator)

	if error != nil do return nil, false
	return data, true
}
