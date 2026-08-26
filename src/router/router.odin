package router

import r "../request"
import "core:fmt"
import "core:slice"
import "core:strings"

RouterContext :: map[string]any

RouteHandler :: proc(request: ^r.Request, response: ^r.Response, ctx: RouterContext)

RequestPathLiteral :: struct {
	value: string,
}

RequestPathParameter :: struct {
	name: string,
}


RequestPathPart :: union {
	RequestPathLiteral,
	RequestPathParameter,
}


Route :: struct {
	method:     string,
	path:       string,
	path_parts: []RequestPathPart,
	hander:     RouteHandler,
}

Router :: struct {
	handlers: [dynamic]Route,
	ctx:      RouterContext,
}

router_init :: proc(router: ^Router) {
	router.handlers = make([dynamic]Route)
	router.ctx = make(map[string]any)
}

router_destroy :: proc(router: Router) {
	delete(router.handlers)
	delete(router.ctx)
}

router_add_route :: proc(
	router: ^Router,
	method, path: string,
	handler: RouteHandler,
) -> (
	success: bool,
) {
	path_parts, ok := break_path_into_parts(path)
	if !ok do return false

	append_elem(&router.handlers, Route{method, path, path_parts, handler})
	return true
}

router_handle_request :: proc(router: Router, request: ^r.Request, response: ^r.Response) {
	fmt.println(#procedure, "handling request, path:", request.path)

	for handler in router.handlers {
		if request.method != handler.method do continue

		ok := match_route(request.path, handler.path_parts, &request.path_params)
		if !ok do continue

		handler.hander(request, response, router.ctx)
	}
}

match_route :: proc(
	path: string,
	match_parts: []RequestPathPart,
	path_params: ^r.RequestPathParameters,
) -> bool {
	path_parts, error := strings.split(path, "/")
	if error != nil do return false

	if len(path_parts) != len(match_parts) do return false

	compare_loop: for path, index in path_parts {
		match_part := match_parts[index]

		switch match in match_part {
		case RequestPathLiteral:
			if path != match.value do return false
		case RequestPathParameter:
			path_params[match.name] = path
		}
	}

	return true
}

break_path_into_parts :: proc(path: string) -> ([]RequestPathPart, bool) {
	parts, error := strings.split(path, "/")
	if error != nil do return {}, false

	mapped_parts, mapper_error := slice.mapper(parts, proc(part: string) -> RequestPathPart {
		trimmed := strings.trim_space(part)
		if trimmed == "" {
			return RequestPathLiteral{""}
		}

		if !strings.starts_with(trimmed, ":") {
			return RequestPathLiteral{trimmed}
		}

		return RequestPathParameter{trimmed[1:]}
	})

	if mapper_error != nil do return {}, false

	return mapped_parts, true
}
