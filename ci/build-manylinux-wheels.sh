#!/bin/bash
set -e -u -x

#TODO: check if is a valid call (this is an auxiliary script)

function repair_wheel {
    wheel="$1"
    if ! auditwheel show "$wheel"; then
        echo "Skipping non-platform wheel $wheel"
    else
        dest_dir=/io/wheelhouse/
        auditwheel repair -L /bases/lib --plat "$PLAT" -w "$dest_dir" "$wheel"
    fi
}

# Compile wheels
pushd /io
rm -f wheelhouse/* >/dev/null || true
for PYBIN in /opt/python/cp*/bin; do
    PYTHON="${PYBIN}/python"
    # Copy lib-dynload to bases
    SRCDIR=$($PYTHON -c "import sysconfig; print(sysconfig.get_config_var('DESTSHARED'))")
    DSTDIR=cx_Freeze/bases/lib-dynload
    mkdir -p $DSTDIR && rm -f $DSTDIR/* || true
    cp "${SRCDIR}/*" "${DSTDIR}/"
    # Build wheel
    $PYTHON -m build -o /tmp/wheelhouse/ -x -n .
done

# Bundle external shared libraries into the wheels
for wheel in /tmp/wheelhouse/*.whl; do
    repair_wheel "$wheel"
done
chown -R $USER_ID:$GROUP_ID /io/wheelhouse/
for wheel in /io/wheelhouse/*.whl; do
    unzip -Z -l "$wheel"
done

# Install package
for PYBIN in /opt/python/cp*/bin/; do
    PYTHON="${PYBIN}/python"
    $PYTHON -m pip install --no-deps --no-index -f /io/wheelhouse cx_Freeze
    $PYTHON -m cx_Freeze --version
done
popd
