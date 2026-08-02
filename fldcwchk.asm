    ; fldcwchk.asm - An pure 32-bit and 64-bit win32 assembly program to check
    ;                whether or not `fldcw` is a "waiting instruction" on the
    ;                user's machine.
    ; Based on hello.asm by Bastiaan van der Plaat (https://bplaat.nl/)
    ;  nasm -f bin fldcwchk.asm -o fldcwchk.exe && ./fldcwchk

%include "libwindows.inc"

    ; exception-handling structs
    ; cf. https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-exception_pointers
struct EXCEPTION_POINTERS, \
    ExceptionRecord, POINTER_size, \
    ContextRecord, POINTER_size

struct EXCEPTION_RECORD, \
    ExceptionCode, DWORD_size, \
    ExceptionFlags, DWORD_size, \
    ExceptionRecord, POINTER_size, \
    ExceptionAddress, POINTER_size, \
    NumberParameters, DWORD_size, \
    ExceptionInformation, DWORD_size

; https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-wow64_floating_save_area (I hope...)
struct FLOATING_SAVE_AREA, \
    ControlWord, DWORD_size, \
    StatusWord, DWORD_size, \
    TagWord, DWORD_size, \
    ErrorOffset, DWORD_size, \
    ErrorSelector, DWORD_size, \
    DataOffset, DWORD_size, \
    DataSelector, DWORD_size, \
    RegisterArea, 80, \
    Cr0NpxState, DWORD_size

%ifdef WIN64
    %error "fldcwchk can only be compiled for Win32, because the exception context structure is so different in Win64!"
%else
    ; https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-context-r2
struct CONTEXT, \
    ContextFlags, DWORD_size, \
    _Dr0, DWORD_size, \
    _Dr1, DWORD_size, \
    _Dr2, DWORD_size, \
    _Dr3, DWORD_size, \
    _Dr6, DWORD_size, \
    _Dr7, DWORD_size, \
    FloatSave, FLOATING_SAVE_AREA_size, \
    SegGs, DWORD_size, \
    SegFs, DWORD_size, \
    SegEs, DWORD_size, \
    SegDs, DWORD_size, \
    _Edi, DWORD_size, \
    _Esi, DWORD_size, \
    _Ebx, DWORD_size, \
    _Edx, DWORD_size, \
    _Ecx, DWORD_size, \
    _Eax, DWORD_size, \
    _Ebp, DWORD_size, \
    _Eip, DWORD_size, \
    SegCs, DWORD_size, \
    _Eflags, DWORD_size, \
    _Esp, DWORD_size, \
    SegSs, DWORD_size, \
    ExtendedRegisters, BYTE_size
%endif

; http://winapi.freetechsecrets.com/win32/WIN32SYSTEMINFO.htm
struct SYSTEM_INFO, \
    dwOemId, DWORD_size, \
    dwPageSize, DWORD_size, \
    lpMinimumApplicationAddress, POINTER_size, \
    lpMaximumApplicationAddress, POINTER_size, \
    dwActiveProcessorMask, DWORD_size, \
    dwNumberOfProcessors, DWORD_size, \
    dwProcessorType, DWORD_size, \
    dwAllocationGranularity, DWORD_size, \
    wProcessorLevel, WORD_size, \
    wProcessorRevision, WORD_size

header

; exception types
%define EXCEPTION_FLT_DIVIDE_BY_ZERO 0C000008Eh

; return values for exception filter
%define EXCEPTION_EXECUTE_HANDLER    1
%define EXCEPTION_CONTINUE_EXECUTION -1
%define EXCEPTION_CONTINUE_SEARCH    0

; message box bitfields
%define MB_OKCANCEL        01h
%define MB_ICONERROR       10h
%define MB_ICONQUESTION    20h
%define MB_ICONEXCLAMATION 30h
%define MB_ICONINFORMATION 40h
%define IDOK 1

; file creation flags
%define GENERIC_WRITE 40000000h
%define CREATE_ALWAYS 2

%define FORMAT_MESSAGE_ALLOCATE_BUFFER 0100h
%define FORMAT_MESSAGE_FROM_SYSTEM     1000h

%define LANG_DEFAULT_SUBLANG_NEUTRAL   1 << 10

code_section
    function exception_handler, excinfo
        mov     _ax, [excinfo]
        mov     _ax, [_ax + EXCEPTION_POINTERS.ContextRecord]
        cmp     pointer [_ax + CONTEXT._Eip], fldcw_inst
        je      .handle_div0

        ; check if cpuid raised exception (presumably #UD)
        cmp     pointer [_ax + CONTEXT._Eip], cpuid_inst
        je      .handle_cpuid_ud

        return  EXCEPTION_EXECUTE_HANDLER

        .handle_div0:
        ; fldcw raised a CPU exception, so mark our status:
        inc     [status]
        ; skip over the faulting instruction so it hits fninit and execution
        ; can resume:
        mov     pointer [_ax + CONTEXT._Eip], after_fldcw
        ; resume execution after the faulting instruction:
        return  EXCEPTION_CONTINUE_EXECUTION

        ; NOTE: My initial idea was to clear the exception bits in the
        ; FloatSave.StatusWord field of the execution context, so that
        ; execution could continue without skipping the faulting inst -
        ; but this just doesn't seem to work AT ALL on Win11, resulting
        ; in an infinite loop...

        .handle_cpuid_ud:
        ; skip over the instruction and leave EAX zero to indicate it's not supported
        mov     pointer [_ax + CONTEXT._Eip], after_cpuid
        return  EXCEPTION_CONTINUE_EXECUTION

    entrypoint
        frame

        ; Is the FPU even usable?
        smsw    ax
        bt      ax,2    ; CR0.EM
        jnc     .havefpu

        invoke MessageBoxA, HWND_DESKTOP, msgFPU, title, MB_ICONERROR
        invoke ExitProcess, EXIT_FAILURE

        .havefpu:
        invoke MessageBoxA, HWND_DESKTOP, msginfo, title, MB_ICONQUESTION | MB_OKCANCEL
        cmp     _ax,IDOK
        je      .goahead
        invoke ExitProcess, EXIT_FAILURE

        .goahead:
        ; setup exception handler...
        invoke SetUnhandledExceptionFilter, exception_handler

        ; setup the FPU
        fninit
        ; save the initial control word
        fstcw   [ctlwd]
        ; UNmask all FPU exceptions!
        and     byte [ctlwd], 80h
        fldcw   [ctlwd]

        ; Deliberate division by zero to raise an FPU exception
        fld     [one]
        fdiv    [zero]

        ; Now attempt to re-mask all exceptions
        or      byte [ctlwd], 7Fh
        fldcw_inst:
        fldcw   [ctlwd] ; <-- exception will hit HERE if `fldcw` is waiting!
        after_fldcw:

        ; if exception handler fired, go reset the FPU immediately
        cmp     [status],0
        jnz     .resetFPU

        ; if not, it's possible that an IRQ13 came in instead and caused
        ; Win9x to set the TS flag - check for that...
        smsw    ax
        bt      ax,3    ; CR0.TS
        setc    [status]

        .resetFPU:
        ; reset the FPU
        fninit

        ; display the result
        mov     _ax, msgOK
        mov     _bx, MB_ICONINFORMATION
        cmp     [status], 0
        jz      .dispresult
        mov     _ax, msgNG
        mov     _bx, MB_ICONEXCLAMATION
        .dispresult:
        invoke MessageBoxA, HWND_DESKTOP, _ax, title, _bx

        ; Gather some data!
        xor     eax, eax
        cpuid_inst:
        cpuid
        after_cpuid:
        test    eax,eax
        jz      .nocpuid

        ; if CPUID is available, we can use it to fill in all the info
        ; --> start with the vendor string
        mov     [vendor+0],ebx
        mov     [vendor+4],edx
        mov     [vendor+8],ecx

        ; get family / model / stepping
        mov     eax,1
        cpuid
        ; get stepping
        mov     bl,al
        and     bl,0Fh
        mov     [step],bl
        ; get model
        mov     bl,al
        shr     bl,4
        mov     [model],bl
        ; get family
        mov     bl,ah
        and     bl,0Fh
        mov     [family],bl

        ; do we need to mess with extended model/family?
        cmp     bl,6
        je      .extmodel
        cmp     bl,0Fh
        jne     .noextmodfam

        ; for family 0Fh, need extended family
        mov     ebx,eax
        shr     ebx,20
        add     [family],bl

        .extmodel:
        ; for families 6 or 0Fh, need extended model
        mov     ebx,eax
        ; upper four bits of family are at EBX[19:16]
        shr     ebx,16-4
        ; now at BL[7:4], as required
        and     bl,0F0h
        or      [model],bl

        .noextmodfam:
        ; now see if there's a brand string available
        mov     eax,80000000h
        cpuid
        cmp     eax,80000004h
        jb      .infogathered

        ; if 80000002-4h are supported, we can get the brand string
        mov     eax,80000002h
        cpuid
        mov     [brand+00h],eax
        mov     [brand+04h],ebx
        mov     [brand+08h],ecx
        mov     [brand+0Ch],edx
        mov     eax,80000003h
        cpuid
        mov     [brand+10h],eax
        mov     [brand+14h],ebx
        mov     [brand+18h],ecx
        mov     [brand+1Ch],edx
        mov     eax,80000004h
        cpuid
        mov     [brand+20h],eax
        mov     [brand+24h],ebx
        mov     [brand+28h],ecx
        mov     [brand+2Ch],edx
        jmp     .infogathered

        .nocpuid:
        invoke GetSystemInfo
        mov     bx, [_ax + SYSTEM_INFO.wProcessorLevel]
        test    bx, bx
        jz      .nocpuid_win9x
        mov     [family],bl

        mov     cx, [_ax + SYSTEM_INFO.wProcessorRevision]
        cmp     bl, 5
        jb      .ntpre586
        mov     [model], ch
        mov     [step], cl
        jmp     .infogathered

        .ntpre586:
        cmp     ch, 0FFh
        je      .ntpre586_FF
        ; here's where stepping letters come in...
        add     ch, 'A'
        mov     [stepltr], ch
        mov     [step], cl
        jmp     .infogathered

        .ntpre586_FF:
        ; model / stepping packed into CL
        mov     ch, cl
        shr     ch, 4
        sub     ch, 0Ah
        mov     [model], ch
        and     cl, 0Fh
        mov     [step], cl
        jmp     .infogathered

        .nocpuid_win9x:
        ; Win9x doesn't populate wProcessorLevel / Revision,
        ; so we have very limited info available to us
        mov     ebx, [_ax + SYSTEM_INFO.dwProcessorType]
        mov     [family], 3
        cmp     ebx, 386
        je      .infogathered
        mov     [family], 4
        cmp     ebx, 486
        je      .infogathered
        ; this shouldn't happen, but whatever...
        mov     [family], 5

        .infogathered:
        movzx   eax, byte [family]
        movzx   ebx, byte [model]
        movzx   ecx, byte [stepltr]
        movzx   edx, byte [step]
        movzx   esi, byte [status]
        invoke wsprintfA, outstr, outfmt, vendor, _ax, _bx, _cx, _dx, brand, _si
        ; save length of output string
        mov     _si,_ax

        ; print the output to a file
        invoke CreateFileA, resfile, GENERIC_WRITE, 0, 0, CREATE_ALWAYS, 0, 0 
        cmp     _ax,-1
        je      .filefail
        ; use lp_err to store number of bytes written (we don't actually care
        ; how many, but Win95 refuses to write the file if we don't give some
        ; non-NULL pointer for this; Win7 writes the file but then crashes!)
        invoke WriteFile, _ax, outstr, _si, lp_err, 0
        test    eax,eax
        jz      .filefail

        ; Exit successfully
        invoke MessageBoxA, HWND_DESKTOP, msgdone, title, MB_OK
        invoke ExitProcess, EXIT_SUCCESS

        .filefail:
        invoke GetLastError
        invoke FormatMessageA, FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM, 0, _ax, LANG_DEFAULT_SUBLANG_NEUTRAL, lp_err, 0, 0
        invoke MessageBoxA, HWND_DESKTOP, pointer [lp_err], msgfail, MB_ICONERROR
        invoke ExitProcess, EXIT_FAILURE

        end_frame
end_code_section

data_section

    zero    dd 0
    one     dd 3F800000h    ; FPU 1.0

    lp_err  dp 0    ; pointer to error message buffer if needed

    ; CPUID info
    vendor  dd 0,0,0
            db 0    ; terminate the string
    family  db 0
    model   db 0
    step    db 0
    brand   dd 0,0,0,0, 0,0,0,0, 0,0,0,0
            db 0    ; terminate the string

    ; stepping letter for 386/486 processors (leave as space by default)
    stepltr db 20h

    ; Place to stash the control word
    ctlwd   dw 0

    ; Boolean tracking whether or not `fldcw` is a waiting instruction
    status  db 0

    ; Output string
    outstr  times 1024 db 0

    ; String constants
    title   db "fldcw checker", 0
    msgFPU  db "No FPU detected in your system!", 0
    msginfo db "I will now attempt to calculate 1.0/0.0 on the FPU, then execute the fldcw instruction to see if it results in exception delivery to the CPU. Is this OK?", 0
    msgOK   db "fldcw is NOT a waiting instruction on your machine!", 0
    msgNG   db "fldcw IS a waiting instruction on your machine!", 0
    ; CPU vendor, family, model, stepping, brand string, status
    outfmt  db "%s,%X,%X,%c%X,%s,%d", 0Dh, 0Ah, 0
    msgfail db "Unable to create / write " ; string continues on next line
    resfile db "fldcwchk.txt", 0
    msgdone db "Results written to fldcwchk.txt - please post the contents of this file on the GitHub discussion (or somewhere else I can find them) if / when you can! :)", 0

    ; Import Table
    import_table
        library kernel_table, "KERNEL32.DLL", \
            user_table, "USER32.DLL"

        import kernel_table, \
            ExitProcess, "ExitProcess", \
            GetSystemInfo, "GetSystemInfo", \
            CreateFileA, "CreateFileA", \
            WriteFile, "WriteFile", \
            GetLastError, "GetLastError", \
            FormatMessageA, "FormatMessageA", \
            SetUnhandledExceptionFilter, "SetUnhandledExceptionFilter"

        import user_table, \
            MessageBoxA, "MessageBoxA", \
            wsprintfA, "wsprintfA"
    end_import_table
end_data_section

; vim: ft=nasm:expandtab:nospell:ts=4:
