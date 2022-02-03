#!/bin/bash

export SF_NO_COPY_ARROW_LIB=1
export SF_ARROW_LIBDIR="${PREFIX}/lib"
export ENABLE_EXT_MODULES=true

python -m pip install . --no-deps --use-feature=in-tree-build --no-binary :all: -vvv