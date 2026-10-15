package fibers

import "core:mem"
import "core:slice"
import "core:sys/posix"
import "core:testing"

foreign import platform "x86_64_sysv_nasm.asm"

foreign platform {
	// Swaps the thread context
	cx_swap :: proc(from: ^Cx, to: ^Cx) ---
	// Assembly ret instruction to handle the gap when we return from task,
	// so that t_return proc will get called on a 16-byte boundary
	t_skip :: proc() ---
}

STACK_SIZE := mem.PAGE_SIZE * 4
MAX_THREADS :: #config(MAX_THREADS, 3) // The default value is one base thread + 2 workers
RUNTIME: ^Runtime // Global runtime

// Each Thread has a Stack
Stack :: struct {
	base: [^]u8, // Backing buffer with a guard page
	len:  uint,
}

// Initializes the stack. Underlying buffer is created via mmap. It also comes with a guard page
stack_init :: proc(s: ^Stack, size: int) {
	assert(s != nil, "Expected a stack pointer.")

	guard := mem.PAGE_SIZE
	len := uint(guard + size)

	base: [^]u8 = auto_cast posix.mmap(nil, len, posix.PROT_NONE, {.ANONYMOUS, .PRIVATE}, -1, 0)
	posix.mprotect(base[guard:], uint(size), {.READ, .WRITE})

	s.base = base
	s.len = len
}

// Returns a pointer to the top of the stack
stack_top :: proc(s: ^Stack) -> uintptr {
	assert(s != nil, "Expected a stack pointer.")

	return auto_cast mem.ptr_offset(s.base, s.len)
}

// Unmaps the underlying buffer
stack_free_all :: proc(s: ^Stack) {
	assert(s != nil, "Expected a stack pointer.")

	posix.munmap(s.base, s.len)
}

Runtime :: struct {
	threads: [dynamic]Thread,
	current: uint,
}

// Initializes the runtime
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
	assert(RUNTIME != nil, "Runtime is not initialized.")

	for t_yield() {} 	// Finishes after there's no work left to do

	for t in RUNTIME.threads {
		stack_free_all(t.stack)
		free(t.stack)
	}
	delete(RUNTIME.threads)
	free(RUNTIME)
}

// Task return guard
t_return :: proc() {
	curr := RUNTIME.current
	if curr != 0 {
		RUNTIME.threads[curr].state = .Available
		t_yield()
	}
}

// Yields control back to the runtime
t_yield :: proc() -> bool {
	// Round-robin scheduler

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

// Spawns a task
spawn :: proc(func: proc()) -> (ok: bool) {
	assert(RUNTIME != nil, "Runtime is not initialized.")

	index := slice.linear_search_proc(
		RUNTIME.threads[:],
		proc(t: Thread) -> bool {return t.state == .Available},
	) or_return

	available := &RUNTIME.threads[index]
	ptr := mem.align_backward_uintptr(stack_top(available.stack), 16)

	((^uintptr)(ptr - 16))^ = transmute(uintptr)t_return
	((^uintptr)(ptr - 24))^ = transmute(uintptr)t_skip
	((^uintptr)(ptr - 32))^ = transmute(uintptr)func

	available.cx.rsp = ptr - 32
	available.state = .Ready

	return true
}

// Thread state
State :: enum {
	Available,
	Running,
	Ready,
}

// Green thread
Thread :: struct {
	stack: ^Stack,
	cx:    Cx,
	state: State,
}

// Thread context
Cx :: struct {
	rsp: uintptr,
	r15: uintptr,
	r14: uintptr,
	r13: uintptr,
	r12: uintptr,
	rbx: uintptr,
	rbp: uintptr,
}

@(test)
spawn_tasks :: proc(t: ^testing.T) {
	init()

	ok := spawn(proc() {}) 	// 1/2 threads
	testing.expect(t, ok)

	ok = spawn(proc() {}) 	// 2/2 threads
	testing.expect(t, ok)

	ok = spawn(proc() {}) 	// All threads are busy
	testing.expect(t, ok == false)

	run()
}
