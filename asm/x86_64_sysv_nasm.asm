section .text

; swap_context(from: ^ThreadContext, to: ^ThreadContext)
;v from = rdi, to = rsi
global cx_swap
cx_swap:
    mov [rdi], rsp
    mov [rdi + 0x08], r15
    mov [rdi + 0x10], r14
    mov [rdi + 0x18], r13
    mov [rdi + 0x20], r12
    mov [rdi + 0x28], rbx
    mov [rdi + 0x30], rbp

    mov rsp, [rsi]
    mov r15, [rsi + 0x08]
    mov r14, [rsi + 0x10]
    mov r13, [rsi + 0x18]
    mov r12, [rsi + 0x20]
    mov rbx, [rsi + 0x28]
    mov rbp, [rsi + 0x30]
    ret

global _align
_align:
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
