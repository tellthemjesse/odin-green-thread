package gt

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:sys/posix"

foreign import platform "asm/x86_64_sysv_nasm.asm"

foreign platform {
	cx_swap :: proc(from: ^Cx, to: ^Cx) ---
	_align :: proc() ---
}

STACK_SIZE := mem.PAGE_SIZE * 4
MAX_THREADS :: 3 // One base thread + 2 workers.

RUNTIME: ^Runtime

Stack :: struct {
	base: [^]u8,
	len:  uint,
}

stack_init :: proc(s: ^Stack, size: int) {
	guard := mem.PAGE_SIZE
	len := uint(guard + size)

	base: [^]u8 = auto_cast posix.mmap(nil, len, posix.PROT_NONE, {.ANONYMOUS, .PRIVATE}, -1, 0)
	posix.mprotect(base[guard:], uint(size), {.READ, .WRITE})

	s.base = base
	s.len = len
}

stack_top :: proc(s: ^Stack) -> uintptr {
	return auto_cast mem.ptr_offset(s.base, s.len)
}

stack_free_all :: proc(s: ^Stack) {
	posix.munmap(s.base, s.len)
}

Runtime :: struct {
	threads: [dynamic]Thread,
	current: uint,
}

init :: proc() {
	assert(RUNTIME == nil, "Cannot initialize runtime more than once.")

	runtime := new(Runtime)

	runtime.threads = make([dynamic]Thread, MAX_THREADS)

	for &t in runtime.threads {
		s := new(Stack)
		stack_init(s, STACK_SIZE)
		t.stack = s
	}

	runtime.threads[0].state = .Running

	RUNTIME = runtime
}

run :: proc() {
	for _yield() {} 	// Finishes after there's no work left to do

	for t in RUNTIME.threads {
		stack_free_all(t.stack)
		free(t.stack)
	}
	delete(RUNTIME.threads)

	posix.exit(0)
}

_return :: proc() {
	curr := RUNTIME.current
	if curr != 0 {
		RUNTIME.threads[curr].state = .Available
		_yield()
	}
}

_yield :: proc() -> bool {
	pos := RUNTIME.current
	for RUNTIME.threads[pos].state != .Ready {
		pos += 1
		if pos == len(RUNTIME.threads) {
			pos = 0
		}
		if pos == RUNTIME.current {
			return false
		}
	}

	if RUNTIME.threads[RUNTIME.current].state != .Available {
		RUNTIME.threads[RUNTIME.current].state = .Ready
	}

	RUNTIME.threads[pos].state = .Running
	old_pos := RUNTIME.current
	RUNTIME.current = pos

	cx_swap(&RUNTIME.threads[old_pos].cx, &RUNTIME.threads[pos].cx)
	return len(RUNTIME.threads) > 0
}

spawn :: proc(f: proc()) {
	index, found := slice.linear_search_proc(
		RUNTIME.threads[:],
		proc(t: Thread) -> bool {return t.state == .Available},
	)

	assert(found, "No threads available.")

	available := &RUNTIME.threads[index]
	top := mem.align_backward_uintptr(stack_top(available.stack), 16)

	((^uintptr)(top - 16))^ = transmute(uintptr)_return
	((^uintptr)(top - 24))^ = transmute(uintptr)_align
	((^uintptr)(top - 32))^ = transmute(uintptr)f

	available.cx.rsp = top - 32
	available.state = .Ready
}

State :: enum {
	Available,
	Running,
	Ready,
}

Thread :: struct {
	stack: ^Stack,
	cx:    Cx,
	state: State,
}

// Thread Context
Cx :: struct {
	rsp: uintptr,
	r15: uintptr,
	r14: uintptr,
	r13: uintptr,
	r12: uintptr,
	rbx: uintptr,
	rbp: uintptr,
}

main :: proc() {
	init()

	spawn(proc() {
		fmt.println("Starting Thread 1...")
		for i in 0 ..< 10 {
			fmt.printfln("Thread 1: counter = %d", i)
			_yield()
		}
		fmt.println("Finished Thread 1")
	})

	spawn(proc() {
		fmt.println("Starting Thread 2...")
		for i in 0 ..< 7 {
			fmt.printfln("Thread 2: counter = %d", i)
			_yield()
		}
		fmt.println("Finished Thread 2")
	})

	run()
}
