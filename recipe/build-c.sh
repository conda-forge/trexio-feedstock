#!/bin/bash
set -ex

declare -a EXTRA_CMAKE_ARGS

# Only execute the MPI short-circuit if we are actively cross-compiling
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" && "${mpi}" != "nompi" ]]; then
  # Blindly force CMake to bypass MPI compiler runtime execution verification
  EXTRA_CMAKE_ARGS+=(
    -DMPI_C_FOUND=TRUE
    -DMPI_Fortran_FOUND=TRUE
    -DMPI_C_INCLUDE_DIRS="${PREFIX}/include"
    -DMPI_Fortran_INCLUDE_DIRS="${PREFIX}/include"
    -DMPI_C_LIBRARIES="${PREFIX}/lib/libmpi${SHLIB_EXT}"
    -DMPI_Fortran_LIBRARIES="${PREFIX}/lib/libmpi_usempif08${SHLIB_EXT};${PREFIX}/lib/libmpi_usempi_ignore_tkr${SHLIB_EXT};${PREFIX}/lib/libmpi_mpifh${SHLIB_EXT};${PREFIX}/lib/libmpi${SHLIB_EXT}"
  )
fi

# Build shared library libtrexio with HDF5 support
cmake -B build -S . \
  ${CMAKE_ARGS} \
  "${EXTRA_CMAKE_ARGS[@]}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="${CC}" \
  -DCMAKE_Fortran_COMPILER="${FC}" \
  -DENABLE_HDF5="ON" \
  -GNinja

cmake --build build --parallel "${CPU_COUNT}"
cmake --install build

# Safely drop downstream testing execution during cross-compilation
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" != "1" || "${CROSSCOMPILING_EMULATOR}" != "" ]]; then
  ctest --test-dir build --output-on-failure -j"${CPU_COUNT}"
fi
