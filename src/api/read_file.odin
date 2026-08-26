package api

import r "../request"
import router "../router"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

handle_read_file :: proc(request: ^r.Request, response: ^r.Response, ctx: router.RouterContext) {
	fmt.println("request params", request.path_params)
	directory := ctx["directory"].(string) or_else ""

	// we need to get the --directory flag passed
	request_parts, error := strings.split(request.path, "/files/")
	defer delete(request_parts)

	if error != nil || len(request_parts) != 2 {
		fmt.eprintln("could not get filename from path")
		response.status_code = 404
		return
	}

	filename := request_parts[1]
	data, found := read_file(filename, directory)

	if !found {
		response.status_code = 404
		return
	}

	response.status_code = 200
	response.data = data

	append_elem(&response.headers, r.HttpHeader{"Content-Type", "application/octet-stream"})
}

read_file :: proc(filename, directory: string) -> (contents: []byte, found: bool) {
	joined_path, join_err := filepath.join({directory, filename}, context.allocator)
	if join_err != nil {
		fmt.eprintln(#procedure, "join failed", join_err)
		return nil, false
	}

	data, error := os.read_entire_file(joined_path, context.allocator)

	if error != nil do return nil, false
	return data, true
}
