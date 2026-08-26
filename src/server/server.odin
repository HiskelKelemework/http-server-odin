package http_server

import br "../buffered_reader"
import r "../request"
import request_utils "../request/util"
import router "../router"
import "./compression"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:thread"

ServerSetupOptions :: struct {
	port:   u16,
	router: router.Router,
}

HttpServer :: struct {
	client_addr:     posix.sockaddr_storage,
	client_addr_len: posix.socklen_t,
}

@(private)
RequestHandlerData :: struct {
	socket_fd:   posix.FD,
	http_router: router.Router,
}

CreateServerError :: enum {
	FailedToCreateServerSocket,
}

init_http_server :: proc(options: ServerSetupOptions) -> (error: Maybe(CreateServerError)) {
	sock := posix.socket(posix.AF.INET, posix.Sock.STREAM)
	if sock < 0 do return .FailedToCreateServerSocket

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
		sin_port   = u16be(options.port),
		sin_addr   = {}, // INADDR_ANY
	}

	posix.bind(sock, cast(^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr)))
	posix.listen(sock, 8)
	fmt.printfln("Listening on port %d...", options.port)

	client_addr: posix.sockaddr_storage
	client_addr_len := posix.socklen_t(size_of(posix.sockaddr_storage))

	outer_loop: for {
		// repeatedly accept new connections
		client_socket := posix.accept(sock, cast(^posix.sockaddr)(&client_addr), &client_addr_len)
		if client_socket < 0 {
			fmt.eprintln("failed to accept a client connection")
			continue
		}

		thread_data := new(RequestHandlerData)
		thread_data.socket_fd = client_socket
		thread_data.http_router = options.router

		thread.create_and_start_with_data(
			thread_data,
			parse_request_and_handle,
			nil,
			.Normal,
			true,
		)
	}
}

parse_request_and_handle :: proc(data: rawptr) {
	data := (^RequestHandlerData)(data)

	client_socket := data.socket_fd
	http_router := data.http_router
	defer free(data)

	reader: br.Buffered_Reader
	br.buffered_reader_init(&reader, client_socket)
	defer br.buffered_reader_destroy(reader)

	for {
		// here, we need to read the request line
		line, ok := br.buffered_reader_read_line(&reader)
		if !ok {
			fmt.eprintln("could not read a full line from buffer")
			return
		}

		request_line := string(line)

		parts, split_error := strings.split(request_line, " ", context.temp_allocator)
		if split_error != nil {
			fmt.eprintln("error during request line split", split_error)
			return
		}

		if len(parts) != 3 {
			fmt.eprintln("request parts must have exactly three parts")
			return
		}

		request: r.Request
		r.request_init(&request)
		defer r.request_destroy(request)

		path, query_params, path_parsing_error := request_utils.extract_path_and_query_params(
			parts[1],
		)
		if path_parsing_error != nil {
			fmt.eprintln("path parsing failed", path_parsing_error)
			return
		}

		request.method = parts[0]
		request.path = path
		request.query_params = query_params

		response: r.Response
		r.response_init(&response)
		defer r.response_destroy(response)

		header_loop: for {
			header, ok := br.buffered_reader_read_line(&reader)
			if !ok {
				fmt.eprintln("error reading header line")
				return
			}

			header_string := string(header)
			if header_string == "" do break header_loop

			header_parts, error := strings.split(header_string, ": ", context.temp_allocator)
			if error != nil {
				fmt.eprintln("error splitting header", error)
				return
			}

			if len(header_parts) == 2 {
				new_header := r.HttpHeader {
					key   = header_parts[0],
					value = header_parts[1],
				}

				append_elem(&request.headers, new_header)
			}
		}

		// pull request body only if content-length header is defined
		content_length_header := request_utils.find_header(request.headers[:], "content-length")
		if header, ok := content_length_header.?; ok {
			bytes := strconv.parse_int(header.value) or_else 0
			if bytes > 0 {
				if request_body, ok := handle_read_request_body(&reader, bytes); ok {
					request.body = request_body
				}
			}
		}

		// request is handled here, response is modified
		router.router_handle_request(http_router, &request, &response)

		accept_encoding := request_utils.find_header(request.headers[:], "accept-encoding")
		if header, ok := accept_encoding.?; ok {
			if strings.contains(header.value, "gzip") {
				output, ok := compression.gzip_compress(response.data)
				if ok {
					response.data = output
					append_elem(&response.headers, r.HttpHeader{"Content-Encoding", "gzip"})
				}
			}
		}

		append_elem(
			&response.headers,
			r.HttpHeader{"Content-Length", fmt.tprintf("%d", len(response.data))},
		)

		should_close_connection := false

		connection_header := request_utils.find_header(request.headers[:], "connection")
		if header, ok := connection_header.?; ok {
			fmt.println("connection header value", header.value)

			if header.value == "close" {
				append_elem(&response.headers, r.HttpHeader{"Connection", "close"})
				should_close_connection = true
			}
		}

		builder: strings.Builder
		strings.builder_init(&builder)
		defer strings.builder_destroy(&builder)

		response_as_string := format_http_response(&builder, response)

		posix.write(
			client_socket,
			raw_data(transmute([]byte)response_as_string),
			len(response_as_string),
		)

		if should_close_connection {
			posix.close(client_socket)
		}
	}
}

format_http_response :: proc(builder: ^strings.Builder, response: r.Response) -> string {
	// response line
	fmt.sbprintf(builder, "HTTP/1.1 %s\r\n", status_code_to_string(response.status_code))

	// http headers
	for header in response.headers {
		fmt.sbprintf(builder, "%s: %s\r\n", header.key, header.value)
	}

	fmt.sbprint(builder, "\r\n")

	fmt.sbprint(builder, string(response.data))

	return strings.to_string(builder^)
}

status_code_to_string :: proc(status_code: u16) -> string {
	switch status_code {
	case 200:
		return "200 OK"
	case 201:
		return "201 Created"
	case 404:
		return "404 Not Found"
	case:
		return "501 Not Implemented"
	}
}

handle_read_request_body :: proc(
	reader: ^br.Buffered_Reader,
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
