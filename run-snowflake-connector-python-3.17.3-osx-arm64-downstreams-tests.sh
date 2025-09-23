#! /bin/bash

set -u

# set -o pipefail is definitely needed because we run:
# test-package | {logger}

set -o pipefail

# This is a standalone function derived from
# cbousseau/bin/test_package.sh and designed to be sourced or included
# in generated scripts

# We're trying to test a package in isolation from all the other
# accumulated junk that conda builds collect.

# Note that we want the success/failure of this script but we also
# want the unwinding of the environment to proceed.  Bash sources do
# mention unwind-protect functionality but, somewhat disappointingly,
# do not expose it as general behaviour.

test-package ()
{
    t0=${SECONDS}

    # Keeping a close similarity for the interface, we'll handle some
    # options
    declare -a opt_channels
    declare -a opt_extras
    declare opt_pkg=
    declare opt_ver=

    OPTIND=1

    while getopts "c:e:hp:v:" opt ; do
	case "${opt}" in
	c)
	    opt_channels+=( -c ${OPTARG} )
	    ;;
	e)
	    opt_extras+=( ${OPTARG} )
	    ;;
	h)
	    cat <<EOU >&2
Runs the tests of an existing package.
The output is a log file of the test run.

Usage: test-package [OPTIONS]

Options:
  -p NAME	Package to test. Example: astropy
  -v VERS	Optional. Package version. Example: 0.1.2
  -c NAME	Optional, may be repeated. Example: cbouss/label/scipy
  -e NAME	Optional, may be repeated. Example: xz>=5.2.5

  -h		This help.

EOU
	    return 0
	    ;;
	p)
	    opt_pkg=${OPTARG}
	    ;;
	v)
	    opt_ver=${OPTARG}
	    ;;
	esac
    done

    shift $(( OPTIND - 1 ))

    if [[ -n "${opt_extras}" ]] ; then
	opt_extras="--extra-deps ${opt_extras[@]}"
    fi

    declare saved_set="$-"

    declare saved_ERR_trap=$(trap -p ERR)
    declare tp_status=0
    trap 'echo test-package: +$(( SECONDS - t0 )): Error at line ${BASH_LINENO}: exit $? >&2; tp_status=1' ERR

    set -xo pipefail

    # package under test
    declare put=${opt_pkg}${opt_ver:+==${opt_ver}}

    declare temp_env=test_${put}

    mkdir -p $temp_env
    pushd $temp_env

    mkdir -p pkgs_cache
    declare temp_cache=$(realpath pkgs_cache)
    temp_cache=${temp_cache/#\~/$HOME}

    conda config --prepend pkgs_dirs ${temp_cache}
    #conda config --set use_only_tar_bz2 True

    # python=3.10 here is to try to prevent this pre-install of
    # conda-build from outright preventing the install of the package
    # under test which might not have recent python variants: I have
    # seen py38-py311 variants in the py313 era.
    #
    # If I don't do this then I'll get a py312 conda-build and
    # there'll be an early bath.
    conda create -q -y -n ${temp_env} python=3.10 conda-build
    source activate ${temp_env}
    declare temp_env_path=null
    if type -p jq >/dev/null 2>&1 ; then
	temp_env_path=$(conda info --json | jq -r .active_prefix)
    fi
    conda install "${opt_channels[@]}" -q -y --download-only ${put}

    # did we download a .tar.bz2 or .conda or both?
    declare tested=
    declare -a downloads
    downloads=( ${temp_cache}/${opt_pkg}-${opt_ver}*.{tar.bz2,conda} )
    for download in ${downloads[*]} ; do
	if [[ -f ${download} ]] ; then
	    tested=1
	    conda build "${opt_channels[@]}" ${opt_extras} -q --test --keep-going ${download}
	    break
	fi
    done

    if [[ ! ${tested} ]] ; then
	tp_status=3
	echo "test-package: +$(( SECONDS - t0 )): Error: nothing tested?" >&2
	echo downloads: ${downloads[*]}
	ls -l ${temp_cache}
    fi

    conda deactivate
    conda config --remove pkgs_dirs ${temp_cache}
    #conda config --set use_only_tar_bz2 False

    popd
    rm -rf ${temp_env}
    case "${temp_env_path}" in
    /*)
	# conda env list
	conda env remove -q -y -p ${temp_env_path} || true
	;;
    esac

    # Here, we definitely set -x and ERR but whatever we recorded as
    # original values will not necessarily have something to (re)set
    # them.  So explicitly unset them then use the saved values to
    # reset them if that's how they were originally.
    set +x
    set -${saved_set}
    trap - ERR
    if [[ -n "${saved_ERR_trap}" ]] ; then
	eval ${saved_ERR_trap}
    fi

    echo "test-package: +$(( SECONDS - t0 )): ${put}: return ${tp_status}"
    return ${tp_status}
}

usage ()
{
    cat <<EOT
usage: ${0} [options]

${0} will test main downstream packages

options include:

  -c CHANNEL	prefix CHANNEL to install/build commands (normally staging channels)

  -h		this message
  -L		list the tests and exit
  -l		add the (current) -c local (please avoid)
  -q		don't tee the logs (the default)
  -S		do not use the STAGING_CHANNEL
  -v		tee the logs to the screen

----

WARNING: The use of -l defeats the point of testing downstreams on the
main channels as you're now testing your own channels.  You might use
it to assess what also needs to be built on the main channels.

EOT
}

opt_channels=()
opt_list=
opt_local=
opt_staging=1
opt_verbose=

while getopts "c:hLlqSv" opt ; do
    case "${opt}" in
    c)
	opt_channels+=( -c ${OPTARG} )
	;;
    h)
	usage
	exit 0
	;;
    L)
	opt_list=1
	;;
    l)
	opt_local=1
	;;
    q)
	opt_verbose=
	;;
    S)
	opt_staging=
	;;
    v)
	opt_verbose=1
	;;
    esac
done

logger="cp /dev/fd/0"
if [[ ${opt_verbose} ]] ; then
    logger=tee
fi

shift $(( OPTIND - 1 ))

PACKAGE_NAME=snowflake-connector-python
PACKAGE_VERSION=3.17.3

# These are used in the expansion of var_tests_format
pkg=${PACKAGE_NAME}
PR=
subdir=osx-arm64

tdn=reviews/${pkg}/${PR}/tests/${subdir}

# maybe we're running multiple variants (Docker) in parallel?
# run-...-downstream-tests.sh -> results-...-downstream-tests
test_dir=results-${0##*/run-}
test_dir=${test_dir%.sh}
if [[ ! -d ${test_dir} ]] ; then
    mkdir ${test_dir}
fi
cd ${test_dir}

if [[ ! -d ${tdn} ]] ; then
    mkdir -p ${tdn}
fi

# we've shifted down a directory so report a different one
utdn=${tdn}
case "${utdn}" in
/*) ;;
*)
    utdn=${test_dir}/${utdn}
    ;;
esac

pkgs=( snowflake.core snowflake-ml-python snowflake-snowpark-python )
vers=( 1.7.0 1.11.0 1.36.0 )
channels=( main main main )
actions=( retest retest update )
constraints=( "snowflake-connector-python" "snowflake-connector-python  >=3.15.0,<4" "snowflake-connector-python  >=3.14.0,<4.0.0" )

npkgs=${#pkgs[*]}

if [[ ${opt_list} ]] ; then
    {
        echo "# name version channel action constraints"
	for ((i=0; i<${npkgs}; i++)) ; do
	    echo $((i+1))/${npkgs}: ${pkgs[i]} ${vers[i]} ${channels[i]} ${actions[i]} ${constraints[i]}
	done
    } | column -t
    exit 0
fi

# We're going to activate a temp_env and then want to deactivate it
# which requires we fall back to something else (base?) to be able to
# remove the temp_env
if [[ ${CONDA_PREFIX:+X} != X ]] ; then
    # the hooks have embedded newlines so quote the string to evaluate
    eval "$(conda shell.bash hook)"
    conda activate
fi

cs_base_cmd=(
    conda search
    --override-channels
    --skip-flexible-search
    --quiet
)

# Having two possible prefix channels puts us on a hiding to nothing
# as it is near impossible to infer a preference.  Here the
# STAGING_CHANNEL is preferred.
prefix_channel=
prefix_channel_build=
if [[ ${opt_local} ]] ; then
    local_prefix=
    if type -p jq >/dev/null 2>&1 ; then
	active_prefix=$(conda info --json | jq -r .active_prefix)
	case "${active_prefix}" in
	/*)
	    local_prefix=file://${active_prefix}/conda-bld
	    ;;
	*)
	    echo "WARNING: conda info active_prefix=${active_prefix}"
	    ;;
	esac
    elif [[ -d /opt/conda/conda-bld/${subdir} ]] ; then
	local_prefix=file:///opt/conda/conda-bld
    fi
    if [[ ${local_prefix} ]] ; then
        prefix_channel=${local_prefix}
	echo Prefixing -c ${local_prefix}
	opt_channels=( -c ${local_prefix} "${opt_channels:+${opt_channels[@]}}" )
	echo Local build channel:
	cmd=(
	    ${cs_base_cmd[@]}
	    -c ${local_prefix}
	)
	echo ${cmd[@]}:
	"${cmd[@]}"

	# stash the package's build so we can confirm we used it
	prefix_channel_build=$(${cs_base_cmd[@]} -c ${prefix_channel} --json ${PACKAGE_NAME}= | jq -r .${PACKAGE_NAME}.[0].build)
    fi
fi

if [[ ${opt_staging} && '' ]] ; then
    echo "Staging channel:"
    cmd=(
	${cs_base_cmd[@]}
	-c 
    )
    echo ${cmd[@]}:
    "${cmd[@]}"

    # stash the package's build so we can confirm we used it
    prefix_channel=
    prefix_channel_build=$(${cs_base_cmd[@]} -c ${prefix_channel} --json ${PACKAGE_NAME}= | jq -r .${PACKAGE_NAME}.[0].build)
fi

case "${prefix_channel_build}" in
null)
    # duh
    echo "NOTICE: ${prefix_channel} has no artifacts, no build constraint will be applied"
    prefix_channel_build=
    ;;
*)
    # We can now get the build_number from prefix_channel_build to ensure
    # that we use this build with -e {pkg}={ver}=*_{num} -- we've
    # tripped over a test build _not_ using the staging channel which
    # is hard to spot
    prefix_channel_build_number=${prefix_channel_build##*_}
    echo "Will check that ${PACKAGE_NAME} ${PACKAGE_VERSION} ${prefix_channel_build} is used"
    ;;
esac

results=()
for ((i=0; i<${npkgs}; i++)) ; do
    tfn=${tdn}/${pkgs[i]}.log
    utfn=${test_dir}/${tfn}

    results[i]=${actions[i]}
    case "${actions[i]}" in
    ignore|rebuild)
        continue
        ;;
    esac

    echo $((i+1))/${npkgs}: +${SECONDS}: testing ${pkgs[i]} ${vers[i]} ${channels[i]} ${constraints[i]} \> ${utfn}
    cmd=(
	test-package
	-p ${pkgs[i]}
	-v ${vers[i]}
	-e ${pkgs[i]}=${vers[i]}
	-e ${PACKAGE_NAME}=${PACKAGE_VERSION}${prefix_channel_build:+=*_${prefix_channel_build_number}}
	
	${opt_channels:+${opt_channels[*]}}
	-c ${channels[i]}
	
    )
    echo "${cmd[@]}"

    "${cmd[@]}" 2>&1 | ${logger} ${tfn}
    if [[ $? -eq 0 ]] ; then
	results[i]=success
	echo $((i+1))/${npkgs}: +${SECONDS}: success

	if [[ ${prefix_channel_build} ]] ; then
            if grep -q ${PACKAGE_NAME}.*${PACKAGE_VERSION}.*${prefix_channel_build} ${tfn} ; then
		echo "Post-test checks: ${PACKAGE_NAME}=${PACKAGE_VERSION}=${prefix_channel_build} was used"
	    else
		echo "Post-test checks: Error: ${PACKAGE_NAME}=${PACKAGE_VERSION}=${prefix_channel_build} was not used?" | tee -a ${tfn}
		results[i]=failure
            fi
	fi
    else
	results[i]=failure
	echo $((i+1))/${npkgs}: +${SECONDS}: failure

	# cleanup test_package.sh detritus
	(
	    tp_dir=test_${pkgs[i]}
	    if [[ -d ${tp_dir} ]] ; then
		set -x
		rm -rf ${tp_dir}
	    fi
	)
    fi

    echo
done

echo "##############################"
echo "summary of errors:"
for ((i=0; i<${npkgs}; i++)) ; do
    tfn=${tdn}/${pkgs[i]}.log
    utfn=${test_dir}/${tfn}
    echo $((i+1))/${npkgs}: ${pkgs[i]} ${vers[i]} ${channels[i]} ${constraints[i]} \> ${utfn}
    if [[ ${results[i]} != failure ]] ; then
	echo $((i+1))/${npkgs}: ${results[i]}
    else
	grep -E '(Error)' ${tfn}
	awk -f - ${tfn} <<EOT
/CondaValueError: prefix already exists: / {print;system(sprintf("set -x; rm -rf %s", \$NF))}
/EnvironmentLocationNotFound: Not a conda environment: / {print;system(sprintf("set -x; rm -rf %s", \$NF))}
/Could not solve for environment specs/,/^$/ {print}
/LibMambaUnsatisfiableError: Encountered problems while solving:/,/^$/ {print}
EOT
	echo $((i+1))/${npkgs}: ${pkgs[i]} ${vers[i]} ${channels[i]} ${constraints[i]} failure
    fi

    echo
done

echo "##############################"
echo "summary of results:"
for ((i=0; i<${#pkgs[*]}; i++)) ; do
    echo $((i+1))/${npkgs}: ${results[i]} ${pkgs[i]} ${vers[i]} ${channels[i]} ${constraints[i]}
done | column -t
