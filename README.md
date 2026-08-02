# fldcwchk
A survey program to find out if `fldcw` is a waiting instruction on real x86 processors

## What's this all about?
This little program aims to tease out a confusing implementation detail of Intel's x87 floating-point unit (FPU) spec, which still forms part of the x86 CPU architecture used in virtually all PCs to this day.

Because the FPU and CPU were originally separate chips, floating-point instructions essentially execute asynchronously. Each time an FPU instruction like `fdiv` (floating-point divide) is issued on the CPU, the results are not guaranteed to be there until the next "waiting" FPU instruction is executed. More importantly, floating-point exceptions (such as a divide-by-zero error) are not delivered to the CPU until the next waiting instruction is executed! Most x87 instructions come in waiting / non-waiting pairs, distinguished by an `n` in the mnemonic. For example, we have `fstcw`, "FPU store control word", and its non-waiting equivalent, `fnstcw`. In most cases, the opcode for waiting instructions begins with the byte `9Bh`, and the non-waiting equivalent lacks this byte.

However, the "FPU _load_ control word" instruction, `fldcw`, does **not** have any non-waiting equivalent. That said, Intel's documentation doesn't explicitly state that it is a waiting instruction either[^1], and the lack of a `9Bh` in the opcode would _suggest_ that it is non-waiting. Experience tells quite a different story though, as I have reliably made the FPU deliver CPU exceptions on `fldcw` on several different machines. So, it seems that this is an implementation detail that is not spelled out in the docs. In that case, maybe different CPUs handle the situation differently?

To test this out, I created this little program, which deliberately raises an FPU exception (by trying to calculate 1.0 / 0.0), then attempts to execute the `fldcw` instruction. If the exception gets delivered to the CPU, this is detected and it sets a flag in the program to indicate that `fldcw` is a waiting instruction on the current CPU. To cast the net as wide as possible, I wrote it as a really simple Win32 program in assembly, using only a handful of kernel and user functions. This means it works on everything from Windows 95 to Windows 11, and also on Linux via Wine.

## Why is this important?

It turns out that there is buggy UEFI firmware in the wild that attempts to use `fldcw` on System Management Mode (SMM) entry, to mask all FPU exceptions. The code was written with the assumption that `fldcw` is **non-waiting**, and when executed on CPUs on which it is waiting, will lock up the entire system if SMM is entered with a pending FPU exception! For a first-hand account of how I figured this out, see https://github.com/PluMGMK/vbesvga.drv/issues/108 - it was quite the head-scratcher!

I'm trying to figure out if there are any CPUs on which the firmware developers' assumption was valid. If there were, then we can assume the code was tested on those. If not, then the code obviously wasn't tested in any meaningful way, and is counter-productive - there is no need for SMM code to use any FPU instructions at all, so they could have just left out the `fldcw` and everything would have been absolutely fine.

## How can you help?

Try out the [`fldcwchk.exe` program](https://github.com/PluMGMK/fldcwchk/raw/refs/heads/master/fldcwchk.exe) on as many machines as you can. As I said, you can run it on any version of Windows from 95 to 11, or on Linux via Wine. Please don't use it on Virtual Machines though - these may use emulated CPUs, which may differ in this implementation detail from the real hardware equivalents! The program outputs a file `fldcwchk.txt` - you can post the contents of this file in the [discussion thread](https://github.com/PluMGMK/fldcwchk/discussions/1), and I will add them to `results.csv`.

## Acknowledgement

A heartfelt thanks to @bplaat for the [MIT-licensed `win32asm` project](https://github.com/bplaat/win32asm), which provided me with the tools I needed to get an assembly-written Win32 program up and running quickly!

[^1]: It says that if you change the control word to unmask any _pending_ exceptions, the _next_ waiting instruction will deliver them, but says nothing about whether or not `fldcw` itself can do so.
