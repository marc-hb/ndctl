#!/bin/bash -Ex
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2024 Intel Corporation. All rights reserved.

. "$(dirname "$0")/common"

rc=77
trap 'err $LINENO' ERR
check_prereq "jq"


do_set_up()
{
	# Set up based on calling environment
	if [[ "$1" == "nfit" ]]; then
		. "$(dirname "$0")/nfit-namespace"
		target=(-b "$NFIT_TEST_BUS0")
	elif [[ "$1" == "cxl" ]]; then
		. "$(dirname "$0")/cxl-namespace"
		target=(--region="$region")
	else
		do_skip "Missing nfit or cxl input parameter"
	fi

	rc=1
}

test_namespace_create()
{
	local mode_list=("raw" "fsdax" "devdax" "sector")

	for ns_mode in "${mode_list[@]}"; do
		local params json
		local dev="x"

		if [[ "$ns_mode" == "devdax" || "$ns_mode" == "fsdax" ]]; then
			params=("${target[@]}" -m "$ns_mode" --map=mem)
		else
			params=("${target[@]}" -m "$ns_mode")
		fi

		json=$($NDCTL create-namespace "${params[@]}")
		eval "$(echo "$json" | json2var)"

		if [[ "$dev" == "x" || "$mode" != "$ns_mode" ]]; then
			err "$LINENO"
		fi

		$NDCTL destroy-namespace -f $dev || err "$LINENO"
	done
}

test_namespace_reconfigure()
{
	# Create a raw pmem namespace then reconfigure it.
	# Based on the original nfit create.sh plus devdax.

	local json mode sector_size
	local dev="x"

	json=$($NDCTL create-namespace "${target[@]}" -t pmem -m raw)
	eval "$(echo "$json" | json2var )"
	[ "$dev" = "x" ] && err "$LINENO"
	[ "$mode" != "raw" ] && err "$LINENO"

	# convert pmem to fsdax mode
	json=$($NDCTL create-namespace -m fsdax -f -e "$dev" --map=mem)
	eval "$(echo "$json" | json2var )"
	[ "$mode" != "fsdax" ] && err "$LINENO"

	# convert pmem to sector mode
	json=$($NDCTL create-namespace -m sector -l 4096 -f -e "$dev")
	eval "$(echo "$json" | json2var )"
	[ "$sector_size" != 4096 ] && err "$LINENO"
	[ "$mode" != "sector" ] && err "$LINENO"

	# convert pmem to devdax mode
	json=$($NDCTL create-namespace -m devdax -f -e "$dev" --map=mem)
	eval "$(echo "$json" | json2var )"
	[ "$mode" != "devdax" ] && err "$LINENO"

	$NDCTL destroy-namespace -f "$dev" || err "$LINENO"
}

do_set_up "$1"
test_namespace_create
test_namespace_reconfigure

check_dmesg "$LINENO"

if [ "$1" = "nfit" ]; then
	_cleanup
elif [ "$1" = "cxl" ]; then
	_cxl_cleanup
fi
