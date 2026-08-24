package main

import "core:fmt"
import "core:text/regex"

main :: proc() {
	reg_exp, error := regex.create("^/files/(.*)$")
	defer regex.destroy_regex(reg_exp)

	if error != nil {
		fmt.eprintln("bad regex", error)
		return
	}

	capture, success := regex.match(reg_exp, "/files/hello/there/myman.txt")
	defer regex.destroy_capture(capture)

	if !success {
		fmt.eprintln("didn't capture anything")
		return
	}

	// first capture group is always the full string used for the match test
	fmt.println(capture.groups)
}
