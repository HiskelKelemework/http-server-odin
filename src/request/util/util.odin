package util

import r "../"
import "core:strings"

find_header :: proc(headers: []r.HttpHeader, key: string) -> Maybe(r.HttpHeader) {
	lower_key := strings.to_lower(key)

	for header in headers {
		if strings.to_lower(header.key) == lower_key do return header
	}

	return nil
}

extract_path_and_query_params :: proc(
	full_path: string,
) -> (
	path: string,
	query_params: map[string]string,
	error: Maybe(string),
) {
	path_parts, split_error := strings.split(full_path, "?", context.temp_allocator)
	if split_error != nil {
		return "", {}, "Split Failed"
	}

	path = strings.clone(path_parts[0])
	query_params = make(map[string]string)

	if len(path_parts) == 1 do return

	whole_query_param := path_parts[1]
	if whole_query_param == "" do return

	query_params_parts, params_split_error := strings.split(
		path_parts[1],
		"&",
		context.temp_allocator,
	)

	if params_split_error != nil || len(query_params_parts) == 0 do return

	for part in query_params_parts {
		key_value, split_error := strings.split(part, "=", context.temp_allocator)
		if split_error != nil do continue

		key := strings.clone(key_value[0])

		if len(key_value) == 1 {
			query_params[key] = ""
			continue
		}

		value := strings.clone(key_value[1])
		query_params[key] = value
	}

	// clean up all the temporary data we created
	free_all(context.temp_allocator)

	return
}
