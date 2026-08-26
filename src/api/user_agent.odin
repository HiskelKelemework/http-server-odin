package api

import r "../request"
import request_utils "../request/util"
import router "../router"

handle_user_agent :: proc(request: ^r.Request, response: ^r.Response, _: router.RouterContext) {
	// whatever we get in the user agent header, we return
	user_agent_header, ok := request_utils.find_header(request.headers[:], "user-agent").?
	if !ok {
		response.status_code = 404
		return
	}

	response.status_code = 200
	response.data = transmute([]byte)user_agent_header.value
	append_elem(&response.headers, r.HttpHeader{"Content-Type", "text/plain"})
}
