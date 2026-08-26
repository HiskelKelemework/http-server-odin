package api

import r "../request"
import router "../router"

handle_root :: proc(request: ^r.Request, response: ^r.Response, _: router.RouterContext) {
	response.status_code = 200
}
