package main

import api "./api"
import router "./router"
import "./server"

import "core:fmt"
import "core:os"
import "core:slice"

main :: proc() {
	http_router: router.Router
	router.router_init(&http_router)
	defer router.router_destroy(http_router)

	// this will be used by the /files handlers to change where to look for the files
	directory := parse_directory_flag()
	if dir, ok := directory.?; ok {
		http_router.ctx["directory"] = dir
	}

	router.router_add_route(&http_router, "GET", "/", api.handle_root)
	router.router_add_route(&http_router, "GET", "/echo/:this", api.handle_echo)
	router.router_add_route(&http_router, "GET", "/user-agent", api.handle_user_agent)
	router.router_add_route(&http_router, "GET", "/files/:filename", api.handle_read_file)
	router.router_add_route(&http_router, "POST", "/files/:filename", api.handle_write_file)

	server.init_http_server({port = 4221, router = http_router})
}

parse_directory_flag :: proc() -> Maybe(string) {
	directory_flag_index, found := slice.linear_search(os.args[:], "--directory")
	if found {
		directory_index := directory_flag_index + 1
		fmt.println("directory indexl", directory_index, "array size", len(os.args))

		has_directory_value := directory_index < len(os.args)

		if has_directory_value {
			return os.args[directory_flag_index + 1]
		}
	}

	return nil
}
