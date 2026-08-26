package request

HttpHeader :: struct {
	key, value: string,
}

RequestPathParameters :: map[string]string

Request :: struct {
	method, path: string,
	query_params: map[string]string,
	headers:      [dynamic]HttpHeader,
	body:         []byte,
	path_params:  RequestPathParameters,
}

Response :: struct {
	status_code: u16,
	headers:     [dynamic]HttpHeader,
	data:        []byte,
}

request_init :: proc(request: ^Request) {
	request.query_params = make(map[string]string)
	request.headers = make([dynamic]HttpHeader)
	request.path_params = make(map[string]string)
}

request_destroy :: proc(request: Request) {
	delete(request.query_params)
	delete(request.headers)
	delete(request.path_params)
}


response_init :: proc(response: ^Response) {
	// default 404 not found response
	response.status_code = 404
	response.headers = make([dynamic]HttpHeader)
}

response_destroy :: proc(response: Response) {
	delete(response.headers)
}
