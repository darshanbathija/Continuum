#ifndef CLAWDMETER_C_LIB_UTIL_SHIM_H
#define CLAWDMETER_C_LIB_UTIL_SHIM_H

// openpty(3) on Linux lives in libutil, not glibc. macOS has it in libc
// (imported via `import Darwin`). PseudoTerminal.swift uses
// `#if canImport(Glibc) import CLibUtil` to get openpty on Linux.
// No pkg-config entry; just `link "util"`.
#include <pty.h>

#endif
