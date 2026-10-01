#!/bin/bash

set -x


# Install Debian dependencies.
# TODO: Support Fedora/CentOS/etc. as well.
if command -v apt &> /dev/null
then
  pkgs='build-essential libc6-dev gperf'
  install=false
  for pkg in $pkgs; do
    status="$(dpkg-query -W --showformat='${db:Status-Status}' "$pkg" 2>&1)"
    if [ ! $? = 0 ] || [ ! "$status" = installed ]; then
      install=true
      break
    fi
  done
  if "$install"; then
    sudo apt install $pkgs
  fi
fi

set -e
set -x

# The dependencies must be outside of the build folder because
# the python build process ends up running a find -delete that
# happens to also delete all the static libraries that we built.
export "PREFIX=$(pwd)/../MonolithPy-Deps"
export "PYTHON_BASE=$(pwd)"
# GCC 14 turned these warnings into errors. The embed layer hands EFILE *
# where stdio expects FILE * (OpenSSL's BIO_new_fp(stderr, ...)), and older
# dependency code relies on the rest, so keep them warnings, as GCC 13 has.
GCC14_COMPAT="-Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=int-conversion"
export "CFLAGS=-I${PREFIX}/include -I${PYTHON_BASE}/Include -fPIC -flto -fuse-linker-plugin -fno-fat-lto-objects ${GCC14_COMPAT}"
export "CXXFLAGS=-I${PREFIX}/include -I${PYTHON_BASE}/Include -fPIC -flto -fuse-linker-plugin -fno-fat-lto-objects"
export "CPPFLAGS=-I${PREFIX}/include -I${PYTHON_BASE}/Include"
# --wrap rewrites references to fopen/fclose/etc into __wrap_NAME, but
# ld only PULLS mp_embed.o from libmp_embed.a if some symbol it defines
# is already unresolved when the archive is scanned. Configure-style test
# programs put their .c source AFTER LDFLAGS, so when ld scans the archive
# nothing references __wrap_* yet and mp_embed.o is dropped; later the
# .c file gets linked and its fopen calls (now renamed to __wrap_fopen)
# are unresolved and the test fails with "cannot run C compiled programs".
# Force the wrap symbols to be considered as referenced via -u.
export "LDFLAGS=-L${PREFIX}/lib -Wl,-u,__wrap_fopen,-u,__wrap_fclose,-u,__wrap_read,-u,__wrap_lseek,-u,__wrap_fstat,-u,__wrap_close -lmp_embed -l:libzstd.a -lm -flto=auto -fuse-linker-plugin -fno-fat-lto-objects -Wl,--wrap=fopen,--wrap=fopen64,--wrap=fclose,--wrap=read,--wrap=lseek,--wrap=lseek64,--wrap=fstat,--wrap=fstat64,--wrap=close"
export "CCexe_LDFLAGS=-L${PREFIX}/lib -Wl,-u,__wrap_fopen,-u,__wrap_fclose,-u,__wrap_read,-u,__wrap_lseek,-u,__wrap_fstat,-u,__wrap_close -lmp_embed -l:libzstd.a -I${PYTHON_BASE}/Include -Wl,--wrap=fopen,--wrap=fopen64,--wrap=fclose,--wrap=read,--wrap=lseek,--wrap=lseek64,--wrap=fstat,--wrap=fstat64,--wrap=close"
export "PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"


# Allow to overload the compiler used via CC environment variable
if [ "$CC" = "" ]
then
  CC=gcc
  CXX=g++
else
  CXX=`echo "$CC" | sed -e 's#cc#++#'`
fi

export CC
export CXX

ELEVATE=
if [ ! -w "$(dirname "$target")" ]
then
  export "ELEVATE=sudo \"CC=$CC\" \"CXX=$CXX\""
  sudo echo
fi

mkdir -p ${PREFIX}/lib
mkdir -p ${PREFIX}/include

cp Include/mp_embed.h ${PREFIX}/include/

mkdir -p dep-build

# zstandard gives mkembeddata a zstd backend when python3 predates 3.14
# (compression.zstd). Install it for the build user and put the user script
# dir on PATH.
if ! python3 -c "import compression.zstd" 2>/dev/null; then
  python3 -m pip install --user --quiet zstandard || python3 -m pip install --user --quiet --break-system-packages zstandard
fi
export PATH="$(python3 -m site --user-base)/bin:$PATH"

download_file() {
  local url="$1"
  local filename="$2"
  # --fail turns HTTP 4xx/5xx into a non-zero exit (otherwise curl happily
  # writes an HTML error body and returns 0, which later makes tar barf
  # with "not in gzip format"). --retry handles transient connection
  # resets / TLS handshake glitches during the request itself. The outer
  # loop adds retries for the case where the request "succeeded" but the
  # response isn't actually a usable archive - e.g. freedesktop.org's CDN
  # intermittently returns a 200 with an error page, or a partial file
  # that hasn't finished uploading yet.
  local i
  for i in 1 2 3 4 5; do
    rm -f "$filename"
    if curl -fL --retry 3 --retry-delay 2 --retry-connrefused \
            --connect-timeout 20 --max-time 300 \
            "$url" -o "$filename"; then
      # Validate the payload: for tarballs, peek the first file. tar
      # recognises .tar/.tar.gz/.tar.xz/.tar.bz2 by magic and exits
      # non-zero if the file isn't a valid archive. For anything else
      # just check the file is non-empty.
      case "$filename" in
        *.tar.*|*.tgz|*.tbz2|*.txz)
          if tar -tf "$filename" >/dev/null 2>&1; then
            return 0
          fi
          echo "download_file: '$filename' downloaded from '$url' is not a valid tar archive (attempt $i/5), retrying."
          ;;
        *)
          if [ -s "$filename" ]; then
            return 0
          fi
          echo "download_file: '$filename' downloaded from '$url' is empty (attempt $i/5), retrying."
          ;;
      esac
    else
      echo "download_file: curl failed for '$url' (attempt $i/5), retrying."
    fi
    sleep 5
  done
  echo "Failed to download '$url' to '$filename' after 5 retries."
  return 1
}

# zstd has to be built BEFORE mp_embed.c compiles - mp_embed.c includes
# <zstd.h> and decompresses each virtual file's zstd frame on fopen. The
# same archive is also linked by the _zstd Python C extension via
# `-l:libzstd.a` in Modules/Setup, so the final binary only contains one
# copy of zstd's code.
(
  cd dep-build
  if [ ! -d zstd-1.5.7 ]; then
    download_file https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz zstd.tar.gz
    tar -xf zstd.tar.gz
  fi
  make -C zstd-1.5.7/lib -j$(nproc --all) libzstd.a CC="$CC"
  cp zstd-1.5.7/lib/libzstd.a ${PREFIX}/lib/
  # _zstd CPython module uses <zstd.h>, <zdict.h>, <zstd_errors.h>; copy all.
  cp zstd-1.5.7/lib/zstd.h zstd-1.5.7/lib/zstd_errors.h zstd-1.5.7/lib/zdict.h ${PREFIX}/include/
)

# Preparing embedded resources
mkdir -p Embedded/embed_data/vfs/ssl
curl -fL --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 20 --max-time 120 https://mkcert.org/generate/ | python3 -c "import sys; [sys.stdout.buffer.write(line.decode('utf-8').encode('ascii', errors='backslashreplace')) for line in sys.stdin.buffer]" > Embedded/embed_data/vfs/ssl/cert.pem
python3 Lib/mkembeddata.py Embedded Embedded/embed_data
# -fPIC is required so that the resulting libmp_embed.a can be linked
# into shared objects (e.g. tcl's itcl4.3.0.so picks up our LDFLAGS's
# -lmp_embed even though we don't need interception there). Without
# -fPIC, GCC emits PC32 relocations against glibc symbols like stderr
# that can't be used in shared objects, and the dep builds fail.
$CC -c -g -DMP_EMBED_USE_WRAP -fPIC -o Embedded/mp_embed.o Embedded/mp_embed.c -IInclude -I${PREFIX}/include
$CC -c -fPIC -o Embedded/mp_embed_data.o Embedded/mp_embed_data.c
ar rcs ${PREFIX}/lib/libmp_embed.a Embedded/mp_embed.o Embedded/mp_embed_data.o

if [ ! -h ${PREFIX}/lib64 ]; then
  ln -s lib ${PREFIX}/lib64
fi

cd dep-build

if [ ! -d ncurses-6.5 ]; then
download_file https://mirrors.kernel.org/gnu/ncurses/ncurses-6.5.tar.gz ncurses.tar.gz
tar -xf ncurses.tar.gz
cd ncurses-6.5
./configure --prefix=${PREFIX} --disable-shared --enable-termcap --enable-widec --enable-getcap --without-cxx-binding
make libs -j$(nproc --all)
make install.libs install.includes
for header in ${PREFIX}/include/ncursesw/*; do
    ln -s ncursesw/$(basename $header) ${PREFIX}/include/;
done
cd ..
fi

if [ ! -d editline-2.1.0 ]; then
download_file https://github.com/troglobit/editline/releases/download/2.1.0/editline-2.1.0.tar.gz editline.tar.gz
tar -xf editline.tar.gz
cd editline-2.1.0
./configure --prefix=${PREFIX} --disable-shared
make -j$(nproc --all)
make install
cd ..
fi

if [ ! -d sqlite-autoconf-3530300 ]; then
download_file https://sqlite.org/2026/sqlite-autoconf-3530300.tar.gz sqlite.tar.gz
tar -xf sqlite.tar.gz
cd sqlite-autoconf-3530300
export "CFLAGS_bak=$CFLAGS"
export "CPPFLAGS_bak=$CPPFLAGS"
export "CFLAGS=$CFLAGS -DSQLITE_ENABLE_COLUMN_METADATA"
export "CPPFLAGS=$CPPFLAGS -DSQLITE_ENABLE_COLUMN_METADATA"
./configure --prefix=${PREFIX} --disable-shared
make -j$(nproc --all)
make install
export "CFLAGS=$CFLAGS_bak"
export "CPPFLAGS=$CPPFLAGS_bak"
cd ..
fi

if [ ! -d openssl-3.5.7 ]; then
download_file https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz openssl.tar.gz
tar -xf openssl.tar.gz
cd openssl-3.5.7
export "CPPINCLUDES=$PYTHON_BASE/Include"
./Configure --prefix=${PREFIX} --libdir=lib linux-x86_64 enable-ec_nistp_64_gcc_128 no-shared no-tests --openssldir=/vfs/ssl
find . \( -iname '*.h.in' -o -iname '*.h' -o -iname '*.c' -o -iname '*.cc' -o -iname '*.cpp' -o -iname '*.cxx' \) | xargs sed -i '1s/^/#include "mp_embed.h"\n\'$'\n/g'
make install_dev -j$(nproc --all)
unset CPPINCLUDES
cd ..
fi

if [ ! -d bzip2-bzip2-1.0.8 ]; then
download_file https://gitlab.com/bzip2/bzip2/-/archive/bzip2-1.0.8/bzip2-bzip2-1.0.8.tar.gz bzip2.tar.gz
tar -xf bzip2.tar.gz
cd bzip2-bzip2-1.0.8
make install "PREFIX=$PREFIX" -j$(nproc --all)
cd ..
fi

if [ ! -d util-linux-2.39 ]; then
download_file https://mirrors.edge.kernel.org/pub/linux/utils/util-linux/v2.39/util-linux-2.39.tar.gz util-linux.tar.gz
tar -xf util-linux.tar.gz
cd util-linux-2.39
./configure --prefix=${PREFIX} --disable-shared --disable-all-programs --enable-libuuid
make -j$(nproc --all)
make install
cp ./libuuid/src/uuid.h ${PREFIX}/include/
cd ..
fi

if [ ! -d xz-5.8.1 ]; then
download_file https://github.com/tukaani-project/xz/releases/download/v5.8.1/xz-5.8.1.tar.gz xz.tar.gz
tar -xf xz.tar.gz
cd xz-5.8.1
./configure --prefix=${PREFIX} --disable-shared
make -j$(nproc --all)
make install
cd ..
fi

if [ ! -d libffi-3.7.1 ]; then
download_file https://github.com/libffi/libffi/releases/download/v3.7.1/libffi-3.7.1.tar.gz libffi.tar.gz
tar -xf libffi.tar.gz
cd libffi-3.7.1
./configure --prefix=${PREFIX} --disable-shared
make -j$(nproc --all)
make install
cd ..
fi

if [ ! -d zlib-latest ]; then
download_file https://www.zlib.net/current/zlib.tar.gz zlib.tar.gz
tar -xf zlib.tar.gz
mv zlib-* zlib-latest
cd zlib-latest
./configure --prefix=${PREFIX} --static
make -j$(nproc --all)
make install
cd ..
fi

if [ ! -d expat-2.8.2 ]; then
download_file https://github.com/libexpat/libexpat/releases/download/R_2_8_2/expat-2.8.2.tar.gz expat.tar.gz
tar -xf expat.tar.gz
cd expat-2.8.2
./configure --prefix=${PREFIX} --disable-shared
make -j$(nproc --all)
make install
cd ..
fi

if [ ! -d mpdecimal-4.0.1 ]; then
download_file https://www.bytereef.org/software/mpdecimal/releases/mpdecimal-4.0.1.tar.gz mpdecimal.tar.gz
tar -xf mpdecimal.tar.gz
cd mpdecimal-4.0.1
./configure --prefix=${PREFIX} --disable-shared
make -j$(nproc --all)
make install
cd ..
fi

if [ ! -d libb2-0.98.1 ]; then
download_file https://github.com/BLAKE2/libb2/releases/download/v0.98.1/libb2-0.98.1.tar.gz libb2.tar.gz
tar -xf libb2.tar.gz
cd libb2-0.98.1
./configure --prefix=${PREFIX} --disable-shared
make -j$(nproc --all)
make install
cd ..
fi

cd ..

long_version=$(git branch --show-current 2>/dev/null || git symbolic-ref --short HEAD)
long_version=$(echo $long_version | sed -e 's#-.*##')
short_version=$(echo $long_version | sed -e 's#\.##')

target=/opt/monolithpy${short_version}

if [ ! -z "$1" ]
then
  target="$1"
fi

export "CFLAGS=-I${PREFIX}/include -fPIC -flto -fuse-linker-plugin -fno-fat-lto-objects ${GCC14_COMPAT}"
export "CXXFLAGS=-I${PREFIX}/include -fPIC -flto -fuse-linker-plugin -fno-fat-lto-objects"
export "CPPFLAGS=-I${PREFIX}/include"

# The UCS4 has best compatibility with wheels on PyPI it seems.
./configure "--prefix=$target" --disable-shared --enable-ipv6 --enable-unicode=ucs4 \
  --enable-optimizations --with-lto --with-computed-gotos --with-fpectl --without-readline \
  --with-system-expat --with-system-libmpdec \
  CC="$CC" \
  CXX="$CXX" \
  CFLAGS="-g $CFLAGS" \
  LDFLAGS="-g -Xlinker -export-dynamic -rdynamic -Bsymbolic-functions -Wl,-z,relro -Wl,-allow-multiple-definition $LDFLAGS" \
  LIBS="-l:libffi.a -l:libbz2.a -l:libuuid.a -l:libsqlite3.a -l:liblzma.a -l:librt.a -l:libmp_embed.a" \
  PROFILE_TASK='-m test --pgo -x test_json ' \
  MODULE_BUILDTYPE=static \
  ax_cv_c_float_words_bigendian=no \
  ac_cv_lib_sqlite3_sqlite3_bind_double=yes ac_cv_lib_sqlite3_sqlite3_column_decltype=yes ac_cv_lib_sqlite3_sqlite3_column_double=yes \
  ac_cv_lib_sqlite3_sqlite3_complete=yes ac_cv_lib_sqlite3_sqlite3_enable_shared_cache=yes ac_cv_lib_sqlite3_sqlite3_progress_handler=yes \
  ac_cv_lib_sqlite3_sqlite3_result_double=yes ac_cv_lib_sqlite3_sqlite3_set_authorizer=yes ac_cv_lib_sqlite3_sqlite3_trace_v2=yes \
  ac_cv_lib_sqlite3_sqlite3_value_double=yes ac_cv_lib_sqlite3_sqlite3_load_extension=yes ac_cv_lib_sqlite3_sqlite3_serialize=yes \
  ___ORIG_DEPS_PREFIX=${PREFIX}___

make -j $(nproc --all) \
        EXTRA_CFLAGS="-flto -fuse-linker-plugin -fno-fat-lto-objects" \
        profile-opt

# Delayed deletion of old installation, to avoid having it not there for testing purposes
# while compiling, which is slow due to PGO beign applied.
# ENSUREPIP=no because make install's built-in ensurepip runs ./python.exe (not
# yet installed); ./python.exe -m ensurepip imports Lib/pip.py (our wrapper)
# which imports __mp__ → wheel, and wheel isn't present yet. We run ensurepip
# ourselves a few lines below against the INSTALLED interpreter with pip.py
# temporarily renamed, which sidesteps the import cycle.
$ELEVATE rm -rf "$target" && $ELEVATE make libinstall install ENSUREPIP=no

rm pybuilddir.txt

# Some things use the existence of this folder as an anchor so lets make sure it exists.
$ELEVATE mkdir -p "$target/lib/python${long_version}/lib-dynload"
$ELEVATE touch "$target/lib/python${long_version}/lib-dynload/.empty"

# Make sure to have pip installed, might even remove it afterwards, Debian
# e.g. doesn't include it.
$ELEVATE mv "$target/lib/python${long_version}/pip.py" "$target/lib/python${long_version}/pip.py.bak" && \
    $ELEVATE "$target/bin/python${long_version}" -m ensurepip && \
    $ELEVATE mv "$target/lib/python${long_version}/pip.py.bak" "$target/lib/python${long_version}/pip.py"

# Copy embedded data
$ELEVATE mv ${PREFIX}/lib/libmp_embed.a "$target/lib/libmp_embed.a"

$ELEVATE cp -v Modules/_hacl/libHacl_Hash_SHA2.a "$target/lib/"
$ELEVATE cp -v Modules/_hacl/libHacl_Hash_BLAKE2.a "$target/lib/"
$ELEVATE cp -v Modules/_hacl/libHacl_HMAC.a "$target/lib/"

$ELEVATE mkdir -p "$target/Embedded"
# The object file usually gets deleted during the build, so make sure to recompile here just in case.
rm -f Embedded/mp_embed.o
$CC -c -g -DMP_EMBED_USE_WRAP -fPIC -o Embedded/mp_embed.o Embedded/mp_embed.c -IInclude -I${PREFIX}/include
$ELEVATE cp -r "Embedded/mp_embed.o" "$target/Embedded/"
$ELEVATE cp -r "Embedded/embed_data" "$target/Embedded/"

$ELEVATE mkdir -p "$target/dependency_libs"
$ELEVATE cp -r "$(pwd)/../MonolithPy-Deps" "$target/dependency_libs/base"

find "$target" \( -iname '*.la' -o -iname '*.pc' -o -iname '__pycache__' -o -iname 'link.json' \) | xargs $ELEVATE rm -rf

$ELEVATE "$target/bin/python${long_version}" -m rebuildpython
