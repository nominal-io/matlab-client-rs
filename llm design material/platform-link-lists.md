# The system-library lists in build.m

A Rust `staticlib` does not record its own dependencies the way a shared
library does, so `platformSettings()` in `matlab/build.m` has to name them for
the MEX link. Three hand-maintained lists, one per platform.

**Getting the authoritative list — run on the host in question:**

```
just native-libs
```

That is `cargo rustc --release -p nominal-ffi --crate-type staticlib -- --print
native-static-libs`. No `--target`, deliberately: it reports for the host.

Re-run it after any dependency bump, and whenever a link reports an unresolved
symbol.

## Linux x86-64

`native-libs` on Fedora 44 / rustc 1.98.1 (2026-09-09) reports:

```
-lgcc_s -lutil -lrt -lpthread -lm -ldl -lc
```

`build.m` carries all of these **except `-lc`**, which the compiler driver links
last on its own; naming it explicitly only risks disturbing that ordering.

The list before this was a guess — `-ldl -lpthread -lm -lrt` — missing
`-lgcc_s` (unwind tables) and `-lutil` (`forkpty`, reached through
`std::process`). It would have failed the link. It never had, because nobody had
run the Linux MEX link before.

## macOS arm64

Frameworks cannot be passed as `-l`; they go through `LDFLAGS`. Current list is
`Security`, `CoreFoundation`, `SystemConfiguration`, `-liconv`, `-lc++`, minus
the `-lSystem/-lc/-lm` that clang links itself.

Also needs `MACOSX_DEPLOYMENT_TARGET` pinned (see `macos_target` in the
justfile) so cargo builds the static library against the same floor `mex` links
the gateway with. Otherwise the gateway advertises the old version in its
`LC_BUILD_VERSION` while containing objects built against a much newer SDK —
loads on the build machine, undefined anywhere older.

## Windows x86-64

MSVC system libs are named rather than located, since the toolchain has them on
its search path. The `windows-targets` import libraries are the exception and
are found by glob under the cargo registry — see `findWindowsTargetLibs()`.
Version-stamped paths, so a dependency bump changes which are present; passing
extra unused ones is harmless because the linker takes only referenced symbols.

## The trap

These lists are only correct for the dependency graph that produced them. The
2026-09-09 `reqwest` change (see [tls-and-openssl.md](tls-and-openssl.md))
altered the graph on every platform. The macOS list happened to survive —
checked, `security-framework` and `system-configuration` are still present —
but that was luck, not design. After any change to the dependency tree, the
lists are unverified until `native-libs` is re-run on each host.
