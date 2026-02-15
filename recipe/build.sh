#!/bin/bash

# GCC will suffer build errors if forced to use a particular linker.
unset LD

# Adjust for Conda environment
export CFLAGS="${CFLAGS} -I${PREFIX}/include"
export CPPFLAGS="${CPPFLAGS} -I${PREFIX}/include"
export LDFLAGS="${LDFLAGS} -L${PREFIX}/lib -Wl,-rpath,${PREFIX}/lib"

args=(
    --prefix="${PREFIX}"
    --libdir="${PREFIX}/lib"
    --disable-nls
    --enable-checking=release
    --with-gcc-major-version-only
    --with-gmp="${PREFIX}"
    --with-mpfr="${PREFIX}"
    --with-mpc="${PREFIX}"
    --with-isl="${PREFIX}"
    --with-zstd="${PREFIX}"
    --with-system-zlib
    --enable-languages=jit
    --enable-host-shared
    --disable-bootstrap
    --disable-werror
)

# Help dyld find libraries during build/test
export DYLD_FALLBACK_LIBRARY_PATH="${PREFIX}/lib"

if [[ "${target_platform}" == osx-* ]]; then
    export CXXFLAGS="${CXXFLAGS} -D_LIBCPP_DISABLE_DEPRECATION_WARNINGS -fpermissive -Wno-error"
    export CFLAGS="${CFLAGS} -Wno-error"

    # System headers may not be in /usr/include
    if [[ -n "${CONDA_BUILD_SYSROOT}" ]]; then
        args+=(--with-sysroot="${CONDA_BUILD_SYSROOT}")
    fi

    # Avoid "Error: Failed changing install name"
    export LDFLAGS="${LDFLAGS} -Wl,-headerpad_max_install_names"

    # Use system libiconv (not conda's). Conda's libiconv exports _libiconv
    # (prefixed) while GCC expects _iconv (unprefixed). We explicitly avoid
    # conda's libiconv by not including it in deps and using -DLIBICONV_PLUG
    # to prevent conda's iconv.h from redefining iconv->libiconv.
    export CFLAGS="${CFLAGS} -DLIBICONV_PLUG"
    export CXXFLAGS="${CXXFLAGS} -DLIBICONV_PLUG"

    # Use the build alias provided by Conda
    args+=(--build="${build_alias}")
else
    # Fix Linux error: gnu/stubs-32.h: No such file or directory.
    args+=(--disable-multilib)

    # Change the default directory name for 64-bit libraries to `lib`
    if [[ -f gcc/config/i386/t-linux64 ]]; then
        sed -i 's/m64=..\/lib64/m64=/g' gcc/config/i386/t-linux64
    fi
    if [[ -f gcc/config/aarch64/t-aarch64-linux ]]; then
        sed -i 's/lp64=..\/lib64/lp64=/g' gcc/config/aarch64/t-aarch64-linux
    fi
fi

# Fix safe-ctype.h: Remove poison macros that conflict with C++ standard headers
# These macros like isprint, iscntrl etc. break libc++ headers
sed -i '/^#undef isalpha$/,/^#define tolower.*do_not_use_tolower_with_safe_ctype$/d' include/safe-ctype.h

# Fix system.h: Remove #pragma GCC poison directives that break C++ standard library headers
sed -i '/^[[:space:]]*#pragma GCC poison malloc realloc$/d' gcc/system.h
sed -i '/^[[:space:]]*#pragma GCC poison malloc realloc$/d' libcpp/system.h

# Fix targetm placement: clang + conda's ld64 puts the targetm struct in
# __common (BSS/zero-filled) instead of __data (initialized data).
#
# The targetm struct is defined in aarch64.cc with TARGET_INITIALIZER
# (a large aggregate of function pointers). When compiled with clang,
# the linker places it in __DATA,__common (zero-filled BSS) instead of
# __DATA,__data. This causes a segfault during library load when
# __cxx_global_var_init tries to dereference null function pointers
# from the zeroed targetm struct.
#
# Strategy: two-part constructor workaround.
# Part 1: In aarch64.cc (goes into libbackend.a), define a C-linkage
#          function jit_fixup_targetm() that copies TARGET_INITIALIZER
#          into targetm via memcpy.
# Part 2: In jit-builtins.cc (linked directly as .o), add a constructor
#          with priority 101 (runs before C++ static inits at 65535).
#          The extern "C" reference to jit_fixup_targetm forces the
#          linker to pull aarch64.o from libbackend.a to resolve it.
#          Because jit-builtins.o is linked directly (not from archive),
#          its __mod_init_func / __init_offsets entry survives linking.

# Part 1: define the fixup function in aarch64.cc
cat >> gcc/config/aarch64/aarch64.cc << 'TARGETM_INIT_EOF'

/* ld64 BSS workaround (part 1): copy TARGET_INITIALIZER into targetm.
   Called from a constructor in jit-builtins.cc before C++ static inits.  */
extern "C"
void jit_fixup_targetm(void) {
  struct gcc_target tmp = TARGET_INITIALIZER;
  __builtin_memcpy((void *)&targetm, &tmp, sizeof(targetm));
}
TARGETM_INIT_EOF

# Part 2: add constructor in jit-builtins.cc
cat >> gcc/jit/jit-builtins.cc << 'JIT_FIXUP_REF_EOF'

/* ld64 BSS workaround (part 2): constructor in a directly-linked .o file.
   Priority 101 ensures it runs before C++ static inits (priority 65535).
   The extern reference to jit_fixup_targetm forces the linker to pull
   aarch64.o from libbackend.a to resolve the symbol.  */
extern "C" void jit_fixup_targetm(void);
__attribute__((constructor(101)))
static void jit_init_targetm(void) {
  jit_fixup_targetm();
}
JIT_FIXUP_REF_EOF

# Fix embedded driver library resolution: The embedded driver in libgccjit
# uses argv[0] (GCC_DRIVER_NAME = "arm64-apple-darwin20.0.0-gcc-15") to
# derive library search paths via make_relative_prefix(). Since this is
# a bare name (no path), prefix derivation fails and LIBRARY_PATH is empty,
# causing "library 'emutls_w' not found" errors.
#
# Fix: Patch jit-playback.cc to set GCC_EXEC_PREFIX from the compiled-in
# STANDARD_EXEC_PREFIX before invoking the embedded driver. Also add
# -DSTANDARD_EXEC_PREFIX to the compilation flags for jit-playback.o.

# Patch jit-playback.cc: add GCC_EXEC_PREFIX setup in invoke_embedded_driver.
# We replace the entire function body to avoid fragile multi-line sed inserts.
python3 -c "
import re
with open('gcc/jit/jit-playback.cc', 'r') as f:
    src = f.read()
old = '''invoke_embedded_driver (const vec <char *> *argvec)
{
  JIT_LOG_SCOPE (get_logger ());
  driver d (true, /* can_finalize */
	    false); /* debug */
  int result = d.main (argvec->length (),
		       const_cast <char **> (argvec->address ()));
  d.finalize ();
  if (result)
    add_error (NULL, \"error invoking gcc driver\");
}'''
new = '''invoke_embedded_driver (const vec <char *> *argvec)
{
  JIT_LOG_SCOPE (get_logger ());
  /* Set GCC_EXEC_PREFIX so the embedded driver can find its libraries.
     The embedded driver cannot derive prefix from argv[0] because
     GCC_DRIVER_NAME is a bare name without a path component.
     STANDARD_EXEC_PREFIX is passed via -D from the Makefile.  */
#ifdef STANDARD_EXEC_PREFIX
  if (!getenv (\"GCC_EXEC_PREFIX\"))
    {
      char *val = concat (\"GCC_EXEC_PREFIX=\", STANDARD_EXEC_PREFIX, NULL);
      putenv (val);
      /* val is intentionally leaked: putenv requires it to persist.  */
    }
#endif
  driver d (true, /* can_finalize */
	    false); /* debug */
  int result = d.main (argvec->length (),
		       const_cast <char **> (argvec->address ()));
  d.finalize ();
  if (result)
    add_error (NULL, \"error invoking gcc driver\");
}'''
assert old in src, 'Pattern not found in jit-playback.cc'
src = src.replace(old, new, 1)
with open('gcc/jit/jit-playback.cc', 'w') as f:
    f.write(src)
print('Patched invoke_embedded_driver in jit-playback.cc')
"

mkdir build-jit
cd build-jit

../configure "${args[@]}"

# Run the GCC sub-configure first (generates gcc/Makefile and gcc-driver-name.h)
make configure-gcc

# Add STANDARD_EXEC_PREFIX definition to jit-playback.o compilation.
# The Makefile supports per-object CFLAGS via CFLAGS-<object>.o.
echo 'CFLAGS-jit/jit-playback.o += -DSTANDARD_EXEC_PREFIX=\"$(libdir)/gcc/\"' >> gcc/Makefile

make -j${CPU_COUNT}
make install

# Cleanup: Keep only libgccjit related files and the GCC backend toolchain.
# libgccjit's embedded driver needs:
#   - ${PREFIX}/bin/<triple>-gcc-<version> (driver, for path resolution)
#   - ${PREFIX}/libexec/gcc/<triple>/<version>/cc1 (C compiler backend)
#   - ${PREFIX}/lib/gcc/<triple>/<version>/ (crt objects, libgcc)
# Without these, gcc_jit_context_compile() segfaults (see GCC Bug 87808).

# Remove share (docs, man pages, info, locale)
rm -rf "${PREFIX}/share" || true

# Remove non-libgccjit headers
find "${PREFIX}/include" -type f ! -name "libgccjit*" -delete || true

# Remove non-libgccjit and non-gcc libraries from top-level lib/
# (keep lib/gcc/ subtree intact, keep iconv_shim if present)
find "${PREFIX}/lib" -maxdepth 1 -type f ! -name "libgccjit*" -delete || true
find "${PREFIX}/lib" -maxdepth 1 -type l ! -name "libgccjit*" -delete || true

# Delete empty directories
find "${PREFIX}" -type d -empty -delete || true
