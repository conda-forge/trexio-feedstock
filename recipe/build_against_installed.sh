#!/usr/bin/env bash

# Build the Python binding against an already-installed TREXIO library.
#
# This is intentionally independent of Autoconf, Automake, and setup.py.  It is
# suitable for a conda recipe after the C library has been installed into
# $PREFIX.  It accepts either a generated developer tree or the Python sdist,
# which already contains the SWIG-generated C wrapper and Python proxy.
#
# Optional environment variables:
#   TREXIO_SOURCE_DIR    unpacked TREXIO source (default: $SRC_DIR or script/..)
#   TREXIO_PREFIX        C library installation prefix (default: $PREFIX)
#   TREXIO_INCLUDEDIR    directory containing trexio.h
#   TREXIO_LIBDIR        directory containing libtrexio
#   PYTHON               target Python interpreter (default: python3)
#   SWIG                 SWIG executable (default: swig)
#   CC                   C compiler (default: cc)
#   SP_DIR               installation directory used by conda-build
#   PYTHON_SITE_PACKAGES installation directory when SP_DIR is not set
#   PYTREXIO_BUILD_DIR   retain build products in this directory

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -n ${TREXIO_SOURCE_DIR:-} ]]; then
  source_dir=${TREXIO_SOURCE_DIR}
elif [[ -n ${SRC_DIR:-} ]]; then
  source_dir=${SRC_DIR}
else
  source_dir=$(cd "${script_dir}/.." && pwd)
fi

python_exe=${PYTHON:-python3}
cc_exe=${CC:-cc}

trexio_prefix=${TREXIO_PREFIX:-${PREFIX:-}}
if [[ -z ${trexio_prefix} ]]; then
  echo "Set TREXIO_PREFIX (or PREFIX) to the installed TREXIO prefix." >&2
  exit 2
fi

trexio_includedir=${TREXIO_INCLUDEDIR:-${trexio_prefix}/include}
trexio_libdir=${TREXIO_LIBDIR:-${trexio_prefix}/lib}

if [[ -n ${SP_DIR:-} ]]; then
  site_packages=${SP_DIR}
elif [[ -n ${PYTHON_SITE_PACKAGES:-} ]]; then
  site_packages=${PYTHON_SITE_PACKAGES}
else
  site_packages=$(
    "${python_exe}" -c 'import sysconfig; print(sysconfig.get_path("platlib"))'
  )
fi

if [[ -f ${source_dir}/src/pytrexio.i ]]; then
  source_layout=developer
  trexio_python=${source_dir}/src/trexio.py
  package_source=${source_dir}/python/pytrexio
elif [[ -f ${source_dir}/src/pytrexio_wrap.c ]]; then
  source_layout=python-sdist
  trexio_python=${source_dir}/trexio.py
  package_source=${source_dir}/pytrexio
else
  echo "No SWIG interface or generated wrapper found under ${source_dir}/src" >&2
  exit 2
fi

required_files=(
  "${source_dir}/src/trexio_s.h"
  "${source_dir}/src/trexio_private.h"
  "${trexio_python}"
  "${package_source}/__init__.py"
  "${package_source}/_version.py"
  "${trexio_includedir}/trexio.h"
)
if [[ ${source_layout} == developer ]]; then
  required_files+=("${source_dir}/src/numpy.i")
else
  required_files+=(
    "${source_dir}/src/pytrexio_wrap.c"
    "${package_source}/pytrexio.py"
  )
fi
for required_file in "${required_files[@]}"; do
  if [[ ! -f ${required_file} ]]; then
    echo "Required generated/input file not found: ${required_file}" >&2
    exit 2
  fi
done

if [[ -f ${source_dir}/src/trexio.h ]] &&
   ! cmp -s "${source_dir}/src/trexio.h" "${trexio_includedir}/trexio.h"; then
  echo "Python source and installed TREXIO headers do not match." >&2
  exit 2
fi

if [[ ! -f ${trexio_libdir}/libtrexio.so &&
      ! -f ${trexio_libdir}/libtrexio.dylib &&
      ! -f ${trexio_libdir}/libtrexio.a ]]; then
  echo "No libtrexio library found in ${trexio_libdir}" >&2
  exit 2
fi

if [[ -n ${PYTREXIO_BUILD_DIR:-} ]]; then
  build_dir=${PYTREXIO_BUILD_DIR}
  mkdir -p "${build_dir}"
else
  build_dir=$(mktemp -d "${TMPDIR:-/tmp}/pytrexio-build.XXXXXX")
  trap 'rm -rf -- "${build_dir}"' EXIT
fi
mkdir -p "${build_dir}/pytrexio"

python_include=$(
  "${python_exe}" -c 'import sysconfig; print(sysconfig.get_path("include"))'
)
numpy_include=$(
  "${python_exe}" -c 'import numpy; print(numpy.get_include())'
)
extension_suffix=$(
  "${python_exe}" -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX") or ".so")'
)
python_platform=$("${python_exe}" -c 'import sys; print(sys.platform)')

if [[ ${source_layout} == developer ]]; then
  swig_exe=${SWIG:-swig}
  echo "Generating the SWIG wrapper"
  "${swig_exe}" \
    -python \
    -I"${source_dir}/src" \
    -I"${trexio_includedir}" \
    -outdir "${build_dir}/pytrexio" \
    -o "${build_dir}/pytrexio_wrap.c" \
    "${source_dir}/src/pytrexio.i"
else
  echo "Using the SWIG wrapper generated in the Python sdist"
  cp "${source_dir}/src/pytrexio_wrap.c" "${build_dir}/pytrexio_wrap.c"
  cp "${package_source}/pytrexio.py" "${build_dir}/pytrexio/pytrexio.py"
fi

echo "Compiling the Python extension"
# CPPFLAGS and CFLAGS are intentionally word-split: conda compiler activation
# supplies each as a shell-style list of compiler arguments.
# shellcheck disable=SC2086
${cc_exe} ${CPPFLAGS:-} ${CFLAGS:-} \
  -std=c99 \
  -fPIC \
  -Wno-incompatible-pointer-types \
  -Wno-unused-variable \
  -Wno-unused-but-set-variable \
  -I"${python_include}" \
  -I"${numpy_include}" \
  -I"${source_dir}/src" \
  -I"${trexio_includedir}" \
  -c "${build_dir}/pytrexio_wrap.c" \
  -o "${build_dir}/pytrexio_wrap.o"

case ${python_platform} in
  darwin)
    platform_link_flags=(
      -bundle
      -undefined dynamic_lookup
      "-Wl,-rpath,${trexio_libdir}"
    )
    ;;
  linux*)
    platform_link_flags=(
      -shared
      "-Wl,-rpath,${trexio_libdir}"
    )
    ;;
  *)
    echo "Unsupported Python platform: ${python_platform}" >&2
    exit 2
    ;;
esac

# LDFLAGS and LIBS follow the same conda convention as CPPFLAGS and CFLAGS.
# shellcheck disable=SC2086
${cc_exe} ${LDFLAGS:-} \
  "${platform_link_flags[@]}" \
  -L"${trexio_libdir}" \
  "${build_dir}/pytrexio_wrap.o" \
  -ltrexio \
  ${LIBS:-} \
  -o "${build_dir}/pytrexio/_pytrexio${extension_suffix}"

echo "Installing into ${site_packages}"
install -d "${site_packages}/pytrexio"
install -m 0644 \
  "${trexio_python}" \
  "${site_packages}/trexio.py"
install -m 0644 \
  "${package_source}/__init__.py" \
  "${package_source}/_version.py" \
  "${build_dir}/pytrexio/pytrexio.py" \
  "${build_dir}/pytrexio/_pytrexio${extension_suffix}" \
  "${site_packages}/pytrexio/"

echo "Installed TREXIO Python binding linked against ${trexio_libdir}/libtrexio"
