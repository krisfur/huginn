package huginn

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:os/os2"
import "core:strings"
import "core:sys/posix"
import "core:terminal/ansi"
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

// ANSI color codes for different repository sources
get_source_color :: proc(source: string) -> string {
	switch source {
	case "core":
		return ansi.CSI + ansi.FG_CYAN + ansi.SGR
	case "extra":
		return ansi.CSI + ansi.FG_BRIGHT_GREEN + ansi.SGR
	case "community":
		return ansi.CSI + ansi.FG_BRIGHT_YELLOW + ansi.SGR
	case "aur":
		return ansi.CSI + ansi.FG_BRIGHT_BLUE + ansi.SGR
	case:
		return ansi.CSI + ansi.FG_MAGENTA + ansi.SGR
	}
}

// Color codes for status messages
get_status_color :: proc(status: string) -> string {
	if strings.contains(status, "Found") {
		return ansi.CSI + ansi.FG_GREEN + ansi.SGR
	} else if strings.contains(status, "Searching") {
		return ansi.CSI + ansi.FG_BRIGHT_YELLOW + ansi.SGR
	} else if strings.contains(status, "Error") || strings.contains(status, "Too many") {
		return ansi.CSI + ansi.FG_RED + ansi.SGR
	} else if strings.contains(status, "Start typing") {
		return ansi.CSI + ansi.FG_BRIGHT_BLACK + ansi.SGR
	}
	return ""
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
	_, stdout, stderr, err := os2.process_exec({command = {"which", "paru"}}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	if err != nil {
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
		status_message  = fmt.aprintf("Start typing to search."),
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
	defer delete(state.status_message)

	// Enable raw mode
	raw_termios := original_termios
	raw_termios.c_lflag &= ~posix.CLocal_Flags{posix.CLocal_Flag_Bits.ICANON}
	raw_termios.c_lflag &= ~posix.CLocal_Flags{posix.CLocal_Flag_Bits.ECHO}
	raw_termios.c_cc[posix.Control_Char.VMIN] = 0
	raw_termios.c_cc[posix.Control_Char.VTIME] = 1
	posix.tcsetattr(STDIN_FD, posix.TC_Optional_Action.TCSANOW, &raw_termios)

	// Hide cursor
	fmt.print(ansi.CSI + ansi.DECTCEM_HIDE)
	defer fmt.print(ansi.CSI + ansi.DECTCEM_SHOW)

	// Scroll down to preserve existing terminal content
	for _ in 0 ..< 12 {
		fmt.println()
	}

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
				delete(state.status_message)
				state.status_message = fmt.aprintf("Searching...")
			}
		}

		// Read input (non-blocking)
		buf: [1]u8
		bytes_read := posix.read(STDIN_FD, raw_data(buf[:]), 1)

		if bytes_read > 0 {
			key := buf[0]

			switch key {
			case 'q', 'Q':
				fmt.print(ansi.CSI + ansi.CUP)
				fmt.print(ansi.CSI + ansi.ED)
				fmt.print(ansi.CSI + ansi.DECTCEM_SHOW)
				return

			case '\n':
				// Execute installation
				if state.selected_index >= 0 && state.selected_index < len(state.packages) {
					pkg := state.packages[state.selected_index]
					// Restore terminal to normal mode before running paru
					posix.tcsetattr(STDIN_FD, posix.TC_Optional_Action.TCSANOW, &original_termios)
					fmt.print(ansi.CSI + ansi.CUP)
					fmt.print(ansi.CSI + ansi.ED)
					fmt.print(ansi.CSI + ansi.DECTCEM_SHOW)
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
	fmt.print(ansi.CSI + ansi.ED)
	fmt.print(ansi.CSI + ansi.CUP)

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

		source_color := get_source_color(pkg.source)
		reset := ansi.CSI + ansi.RESET + ansi.SGR

		if pkg_idx == state.selected_index {
			fmt.printf(
				"%s%s[%-6s]%s > %s%s%-24s%s %-11s%s\n",
				ansi.CSI + ansi.INVERT + ansi.SGR,
				source_color,
				pkg.source,
				ansi.CSI + ansi.INVERT + ansi.SGR,
				ansi.CSI + ansi.BOLD + ansi.SGR,
				ansi.CSI + ansi.FG_DEFAULT + ansi.SGR,
				pkg.name,
				reset,
				pkg.version,
				ansi.CSI + ansi.EL,
			)
			fmt.printf(
				"%s         %s%s%s\n",
				ansi.CSI + ansi.INVERT + ansi.SGR,
				truncate_string(pkg.description, 62),
				reset,
				ansi.CSI + ansi.EL,
			)
		} else {
			fmt.printf(
				"%s[%-6s]%s   %s%-24s%s %-11s%s\n",
				source_color,
				pkg.source,
				reset,
				ansi.CSI + ansi.BOLD + ansi.SGR,
				pkg.name,
				reset,
				pkg.version,
				ansi.CSI + ansi.EL,
			)
			fmt.printf("         %s%s\n", truncate_string(pkg.description, 62), ansi.CSI + ansi.EL)
		}
	}

	// Draw status message line with proper clearing
	fmt.print(ansi.CSI + ansi.EL)
	status_color := get_status_color(state.status_message)
	reset := ansi.CSI + ansi.RESET + ansi.SGR
	fmt.printf("%s%s%s\n", status_color, state.status_message, reset)
	fmt.print(ansi.CSI + ansi.EL)

	// Draw separator with proper clearing
	fmt.print(
		"──────────────────────────────────────────────────────────────────",
	)
	fmt.print(ansi.CSI + ansi.EL)
	fmt.println()

	fmt.printf(
		"Results: %d  |  ↑↓: navigate  |  Enter: install  |  Q: quit%s\n",
		len(state.packages),
		ansi.CSI + ansi.EL,
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
		delete(state.status_message)
		state.status_message = fmt.aprintf("Start typing to search.")
		state.selected_index = 0
		return
	}

	// Run paru search with shell to ensure proper environment
	search_cmd := fmt.tprintf("paru -Ss '%s'", query_str)
	_, stdout, stderr, err := os2.process_exec(
		{command = {"sh", "-c", search_cmd}},
		context.allocator,
	)
	defer delete(stdout)
	defer delete(stderr)

	if err != nil {
		delete(state.status_message)
		state.status_message = fmt.aprintf("Error running paru!")
		return
	}

	// Parse output
	output_str := string(stdout)
	stderr_str := string(stderr)

	// Check for paru error messages in stderr first (has priority)
	if strings.contains(stderr_str, "Query arg too small") ||
	   strings.contains(stderr_str, "Too many package results") {
		delete(state.status_message)
		state.status_message = fmt.aprintf("Too many results! Try a more specific search.")
		state.selected_index = 0
		return
	}

	if len(stdout) == 0 {
		delete(state.status_message)
		state.status_message = fmt.aprintf("No results found.")
		state.selected_index = 0
		return
	}

	// Check for paru error messages in stdout
	if strings.contains(output_str, "Query arg too small") ||
	   strings.contains(output_str, "Too many package results") {
		delete(state.status_message)
		state.status_message = fmt.aprintf("Too many results! Try a more specific search.")
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
		delete(state.status_message)
		state.status_message = fmt.aprintf("No results found.")
		state.selected_index = 0
		state.scroll_offset = 0
	} else {
		// Start selection at the bottom of visible results
		// Best match (index 0) appears at bottom, so select it
		state.selected_index = 0
		state.scroll_offset = 0
		delete(state.status_message)
		state.status_message = fmt.aprintf(
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
