package api

import r "../request"
import router "../router"

handle_echo :: proc(request: ^r.Request, response: ^r.Response, _: router.RouterContext) {
	string_to_echo := request.path_params["this"] or_else ""

	response.status_code = 200
	response.data = transmute([]byte)string_to_echo

	append_elem(&response.headers, r.HttpHeader{"Content-Type", "text/plain"})
}
