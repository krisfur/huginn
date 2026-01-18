package huginn

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"

// Type alias for termios flags
tcflag_t :: posix.tcflag_t

// Terminal constants
STDIN_FD :: 0

// Debounce delay in milliseconds
DEBOUNCE_DELAY :: time.Millisecond * 500

Termios :: posix.termios

Package :: struct {
	source:      string,
	name:        string,
	version:     string,
	description: string,
}

State :: struct {
	packages:        [dynamic]Package,
	search_query:    [256]u8,
	search_len:      int,
	selected_index:  int,
	scroll_offset:   int,
	last_input_time: time.Time,
	needs_search:    bool,
	status_message:  string,
}

main :: proc() {
	// Check if paru is available
	ret := libc.system("which paru > /dev/null 2>&1")
	if ret != 0 {
		fmt.println("Error: paru is not installed. Please install paru first.")
		return
	}

	// Setup terminal first (before state)
	original_termios: Termios
	posix.tcgetattr(STDIN_FD, &original_termios)
	defer posix.tcsetattr(STDIN_FD, posix.TC_Optional_Action.TCSANOW, &original_termios)

	// Initialize state
	state := State {
		packages        = make([dynamic]Package),
		search_query    = {},
		search_len      = 0,
		selected_index  = 0,
		scroll_offset   = 0,
		last_input_time = time.now(),
		needs_search    = false,
		status_message  = "Start typing to search.",
	}
	defer delete(state.packages)
	defer {
		for pkg in state.packages {
			delete(pkg.source)
			delete(pkg.name)
			delete(pkg.version)
			delete(pkg.description)
		}
	}

	// Enable raw mode
	raw_termios := original_termios
	raw_termios.c_lflag &= ~posix.CLocal_Flags{posix.CLocal_Flag_Bits.ICANON}
	raw_termios.c_lflag &= ~posix.CLocal_Flags{posix.CLocal_Flag_Bits.ECHO}
	raw_termios.c_cc[posix.Control_Char.VMIN] = 0
	raw_termios.c_cc[posix.Control_Char.VTIME] = 1
	posix.tcsetattr(STDIN_FD, posix.TC_Optional_Action.TCSANOW, &raw_termios)

	// Hide cursor
	fmt.print("\x1b[?25l")
	defer fmt.print("\x1b[?25h")

	// Main loop
	for {
		draw(&state)

		// Check if we need to perform a debounced search
		if state.needs_search {
			elapsed := time.since(state.last_input_time)
			if elapsed >= DEBOUNCE_DELAY {
				search(&state)
				state.needs_search = false
			} else {
				state.status_message = "Searching..."
			}
		}

		// Read input (non-blocking)
		buf: [1]u8
		bytes_read := posix.read(STDIN_FD, raw_data(buf[:]), 1)

		if bytes_read > 0 {
			key := buf[0]

			switch key {
			case 'q', 'Q':
				fmt.print("\x1b[2J\x1b[H")
				return

			case '\n':
				// Execute installation
				if state.selected_index >= 0 && state.selected_index < len(state.packages) {
					pkg := state.packages[state.selected_index]
					// Restore terminal to normal mode before running paru
					posix.tcsetattr(STDIN_FD, posix.TC_Optional_Action.TCSANOW, &original_termios)
					fmt.print("\x1b[2J\x1b[H")
					fmt.print("\x1b[?25h")
					fmt.printf("Installing %s from %s...\n", pkg.name, pkg.source)
					cmd := fmt.tprintf("paru -S %s", pkg.name)
					libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))
				}
				return

			case 127, 8:
				// Backspace or Ctrl+H
				if state.search_len > 0 {
					state.search_len -= 1
					state.search_query[state.search_len] = 0
					state.selected_index = 0
					state.last_input_time = time.now()
					state.needs_search = true
				}

			case 27:
				// Escape sequence (arrow keys)
				seq: [2]u8
				n := posix.read(STDIN_FD, raw_data(seq[:]), 2)
				if n == 2 && seq[0] == '[' {
					switch seq[1] {
					case 'A':
						// Up arrow - move to higher index (scroll down in reverse display)
						if state.selected_index < len(state.packages) - 1 {
							state.selected_index += 1
							// Update scroll offset to keep selected item in view
							if state.selected_index >= state.scroll_offset + 10 {
								state.scroll_offset = state.selected_index - 9
							}
						}
					case 'B':
						// Down arrow - move to lower index (scroll up in reverse display)
						if state.selected_index > 0 {
							state.selected_index -= 1
							// Update scroll offset to keep selected item in view
							if state.selected_index < state.scroll_offset {
								state.scroll_offset = state.selected_index
							}
						}
					}
				}

			case:
				// Regular printable character
				if key >= 32 && key < 127 && state.search_len < len(state.search_query) - 1 {
					state.search_query[state.search_len] = key
					state.search_len += 1
					state.selected_index = 0
					state.last_input_time = time.now()
					state.needs_search = true
				}
			}
			free_all(context.temp_allocator)
		}
	}
}

draw :: proc(state: ^State) {
	// Clear screen
	fmt.print("\x1b[2J\x1b[H")

	// Show only 10 results at a time, apply scroll offset
	display_count := len(state.packages) - state.scroll_offset
	if display_count > 10 {
		display_count = 10
	}
	if display_count < 0 {
		display_count = 0
	}

	for i := 0; i < display_count; i += 1 {
		// Index 0 appears at bottom, index 9 appears at top
		pkg_idx := state.scroll_offset + display_count - 1 - i
		pkg := state.packages[pkg_idx]

		if pkg_idx == state.selected_index {
			fmt.printf("\x1b[7m[%-6s] > %-24s %-11s\x1b[0m\n", pkg.source, pkg.name, pkg.version)
			fmt.printf("\x1b[7m         %s\x1b[0m\n", truncate_string(pkg.description, 62))
		} else {
			fmt.printf("[%-6s]   %-24s %-11s\n", pkg.source, pkg.name, pkg.version)
			fmt.printf("         %s\n", truncate_string(pkg.description, 62))
		}
	}

	// Draw status message line
	fmt.printf("%s\n", state.status_message)

	// Draw separator
	fmt.print(
		"──────────────────────────────────────────────────────────────────\n",
	)

	fmt.printf(
		"Results: %d  |  ↑↓: navigate  |  Enter: install  |  Q: quit\n",
		len(state.packages),
	)

	// Draw search box at bottom (always visible)
	query_str := string(state.search_query[:state.search_len])
	fmt.printf("Search: %s", query_str)
}

search :: proc(state: ^State) {
	// Clear previous results
	for pkg in state.packages {
		delete(pkg.source)
		delete(pkg.name)
		delete(pkg.version)
		delete(pkg.description)
	}
	clear(&state.packages)

	query_str := string(state.search_query[:state.search_len])
	if len(query_str) == 0 {
		state.status_message = "Start typing to search."
		state.selected_index = 0
		return
	}

	// Run paru search with output limit for speed
	cmd := fmt.tprintf("paru -Ss '%s' 2>&1", query_str)
	cmd_cstr := strings.clone_to_cstring(cmd)
	defer delete(cmd_cstr)

	// Use popen to read command output
	file := posix.popen(cmd_cstr, "r")
	if file == nil {
		state.status_message = "Error running paru!"
		return
	}
	defer posix.pclose(file)

	// Read output into fixed buffer (faster than dynamic allocation)
	buf: [16384]u8
	total_read := 0

	fd := posix.fileno(file)
	for {
		remaining := c.size_t(len(buf) - total_read)
		n := posix.read(fd, raw_data(buf[total_read:]), remaining)
		if n <= 0 {
			break
		}
		total_read += int(n)
		if total_read >= len(buf) - 1 {
			break
		}
	}

	if total_read == 0 {
		state.status_message = "No results found."
		state.selected_index = 0
		return
	}

	// Parse output
	output_str := string(buf[:total_read])

	// Check for paru error messages
	if strings.contains(output_str, "Query arg too small") ||
	   strings.contains(output_str, "Too many package results") {
		state.status_message = "Too many results! Try a more specific search."
		state.selected_index = 0
		return
	}

	lines := strings.split(output_str, "\n")
	defer delete(lines)

	// Parse paru output format:
	// repo/name version
	// description (on next line, indented with spaces)
	i := 0
	for i < len(lines) {
		line := lines[i]
		i += 1

		// Skip empty lines and description lines
		if len(line) == 0 || line[0] == ' ' {
			continue
		}

		// Parse package line: "repo/name version"
		parts := strings.split(line, " ")
		defer delete(parts)

		if len(parts) < 2 {
			continue
		}

		repo_name := parts[0]
		slash_idx := strings.index(repo_name, "/")
		if slash_idx < 0 {
			continue
		}

		source := repo_name[:slash_idx]
		name := repo_name[slash_idx + 1:]
		version := parts[1]
		description := ""

		// Get description from next line if available
		if i < len(lines) && len(lines[i]) > 0 && lines[i][0] == ' ' {
			description = strings.trim_space(lines[i])
			i += 1
		}

		pkg := Package {
			source      = strings.clone(source),
			name        = strings.clone(name),
			version     = strings.clone(version),
			description = strings.clone(description),
		}
		append(&state.packages, pkg)
	}

	// Set status message and selection
	if len(state.packages) == 0 {
		state.status_message = "No results found."
		state.selected_index = 0
		state.scroll_offset = 0
	} else {
		// Start selection at the bottom of visible results
		// Best match (index 0) appears at bottom, so select it
		state.selected_index = 0
		state.scroll_offset = 0
		state.status_message = fmt.tprintf(
			"Found %d result%s.",
			len(state.packages),
			len(state.packages) == 1 ? "" : "s",
		)
	}
}

truncate_string :: proc(s: string, max_len: int) -> string {
	if len(s) <= max_len {
		return s
	}
	return s[:max_len]
}
