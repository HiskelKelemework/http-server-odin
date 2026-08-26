package api

import r "../request"
import router "../router"
import "core:fmt"
import "core:strings"

handle_echo :: proc(request: ^r.Request, response: ^r.Response, _: router.RouterContext) {
	fmt.println(#procedure, "..running")

	// echo route handler
	echo_parts, error := strings.split(request.path, "/echo/")
	defer delete(echo_parts)

	if error != nil {
		fmt.eprintln("error during request line split", error)
		return
	}

	string_to_echo := strings.clone(echo_parts[1])

	response.status_code = 200
	response.data = transmute([]byte)string_to_echo

	fmt.println(#procedure, "after data", string(response.data))

	append_elem(&response.headers, r.HttpHeader{"Content-Type", "text/plain"})
}
