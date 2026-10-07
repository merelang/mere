(* v0.1.642: the os and cpu of the machine this compiler was built for, in the
   names `sys_os` / `sys_arch` answer with -- the interpreter's and the LLVM
   backend's answers (C's are the emitted C's own preprocessor's). *)
let host_os () =
  match Platform_config.system with
  | "macosx" -> "darwin"
  | s when String.length s >= 5 && String.sub s 0 5 = "linux" -> "linux"
  | "mingw" | "mingw64" | "win32" | "win64" | "cygwin" -> "windows"
  | "freebsd" | "netbsd" | "openbsd" -> Platform_config.system
  | _ -> "unknown"

let host_arch () =
  match Platform_config.architecture with
  | "arm64" -> "arm64"
  | "amd64" -> "x86_64"
  | "riscv" -> "riscv64"
  | "power" -> "ppc64"
  | "s390x" -> "s390x"
  | a -> a
