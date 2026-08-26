package api

import r "../request"
import request_utils "../request/util"
import router "../router"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"

handle_write_file :: proc(request: ^r.Request, response: ^r.Response, ctx: router.RouterContext) {
	filename := request.path_params["filename"]

	content_length_header, ok := request_utils.find_header(request.headers[:], "content-length").?
	if !ok {
		// we didn't find a content length header, without which we can't figure out how many bytes to read from the socket
		fmt.eprintln("didn't find a content length header")
		response.status_code = 404
		return
	}

	length, parse_ok := strconv.parse_int(content_length_header.value)
	if !parse_ok {
		response.status_code = 404
		return
	}

	directory := ctx["directory"].(string) or_else ""
	success := write_file_to_disk(filename, directory, request.body)
	response.status_code = success ? 201 : 404
}

write_file_to_disk :: proc(filename, directory: string, data: []byte) -> bool {
	full_file_name, join_error := filepath.join({directory, filename}, context.allocator)
	if join_error != nil {
		fmt.eprintln(#procedure, "join failed", join_error)
		return false
	}

	error := os.write_entire_file_from_bytes(full_file_name, data)
	if error != nil {
		fmt.println(#procedure, "error during file write", error)
		return false
	}

	return true
}
