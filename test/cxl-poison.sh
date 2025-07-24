#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2023 Intel Corporation. All rights reserved.

. "$(dirname "$0")"/common

rc=77

set -ex
[ -d "/sys/kernel/tracing" ] || do_skip "test requires CONFIG_TRACING"

# FIXME: this should be in "kmsg_fail_if_missing" but this test seems to
# work only once. Cleanup/reset issue?
kmsg_no_fail_on+=(
    # Older
    'cxl_mock_mem cxl_mem.*: poison inject dpa:0x'
    'cxl_mock_mem cxl_mem.*: poison clear dpa:0x'
    # Newer
    'cxl_region region.*: Offset .* exceeds region size'
)

trap 'err $LINENO' ERR

check_prereq "jq"

modprobe -r cxl_test
modprobe cxl_test

rc=1

# THEORY OF OPERATION: Exercise cxl-cli and cxl driver ability to
# inject, clear, and get the poison list. Do it by memdev and by region.

find_memdev()
{
	readarray -t capable_mems < <("$CXL" list -b "$CXL_TEST_BUS" -M |
		jq -r ".[] | select(.pmem_size != null) |
		select(.ram_size != null) | .memdev")

	if [ ${#capable_mems[@]} == 0 ]; then
		echo "no memdevs found for test"
		err "$LINENO"
	fi

	memdev=${capable_mems[0]}
}

create_x2_region()
{
	# Find an x2 decoder
	decoder="$($CXL list -b "$CXL_TEST_BUS" -D -d root | jq -r ".[] |
		select(.pmem_capable == true) |
		select(.nr_targets == 2) |
		.decoder")"

	# Find a memdev for each host-bridge interleave position
	port_dev0="$($CXL list -T -d "$decoder" | jq -r ".[] |
		.targets | .[] | select(.position == 0) | .target")"
	port_dev1="$($CXL list -T -d "$decoder" | jq -r ".[] |
		.targets | .[] | select(.position == 1) | .target")"
	mem0="$($CXL list -M -p "$port_dev0" | jq -r ".[0].memdev")"
	mem1="$($CXL list -M -p "$port_dev1" | jq -r ".[0].memdev")"

	region="$($CXL create-region -d "$decoder" -m "$mem0" "$mem1" |
		jq -r ".region")"
	if [[ ! $region ]]; then
		echo "create-region failed for $decoder"
		err "$LINENO"
	fi
	echo "$region"
}

# When cxl-cli support for inject and clear arrives, replace
# the writes to /sys/kernel/debug with the new cxl commands.

_do_poison_sysfs()
{
	local action="$1" dev="$2" addr="$3"
	local expect_fail=${4:-false}

	if "$expect_fail"; then
		if echo "$addr" > "/sys/kernel/debug/cxl/$dev/${action}_poison"; then
			echo "Expected ${action}_poison to fail for $addr"
			err "$LINENO"
		fi
	else
		echo "$addr" > "/sys/kernel/debug/cxl/$dev/${action}_poison"
	fi
}

inject_poison_sysfs()
{
	_do_poison_sysfs 'inject' "$@"
}

clear_poison_sysfs()
{
	_do_poison_sysfs 'clear' "$@"
}

check_trace_entry()
{
	local expected_region="$1"
	local expected_hpa="$2"

	local trace_line
	trace_line=$(grep "cxl_poison" /sys/kernel/tracing/trace | tail -n 1)
	if [[ -z "$trace_line" ]]; then
		echo "No cxl_poison trace event found"
		err "$LINENO"
	fi

	local trace_region trace_hpa
	trace_region=$(echo "$trace_line" | grep -o 'region=[^ ]*' | cut -d= -f2)
	trace_hpa=$(echo "$trace_line" | grep -o 'hpa=0x[0-9a-fA-F]\+' | cut -d= -f2)

	if [[ "$trace_region" != "$expected_region" ]]; then
		echo "Expected region $expected_region not found in trace"
		echo "$trace_line"
		err "$LINENO"
	fi

	if [[ "$trace_hpa" != "$expected_hpa" ]]; then
		echo "Expected HPA $expected_hpa not found in trace"
		echo "$trace_line"
		err "$LINENO"
	fi
}

validate_poison_found()
{
	list_by="$1"
	nr_expect="$2"

	poison_list="$($CXL list "$list_by" --media-errors |
		jq -r '.[].media_errors')"
	if [[ ! $poison_list ]]; then
		nr_found=0
	else
		nr_found=$(jq "length" <<< "$poison_list")
	fi
	if [ "$nr_found" -ne "$nr_expect" ]; then
		echo "$nr_expect poison records expected, $nr_found found"
		err "$LINENO"
	fi
}

test_poison_by_memdev_by_dpa()
{
	find_memdev
	inject_poison_sysfs "$memdev" "0x40000000"
	inject_poison_sysfs "$memdev" "0x40001000"
	inject_poison_sysfs "$memdev" "0x600"
	inject_poison_sysfs "$memdev" "0x0"
	validate_poison_found "-m $memdev" 4

	clear_poison_sysfs "$memdev" "0x40000000"
	clear_poison_sysfs "$memdev" "0x40001000"
	clear_poison_sysfs "$memdev" "0x600"
	clear_poison_sysfs "$memdev" "0x0"
	validate_poison_found "-m $memdev" 0
}

test_poison_by_region_by_dpa()
{
	inject_poison_sysfs "$mem0" "0x40000000"
	inject_poison_sysfs "$mem1" "0x40000000"
	validate_poison_found "-r $region" 2

	clear_poison_sysfs "$mem0" "0x40000000"
	clear_poison_sysfs "$mem1" "0x40000000"
	validate_poison_found "-r $region" 0
}

test_poison_by_region_offset()
{
	local base gran hpa1 hpa2
	base=$(cat /sys/bus/cxl/devices/"$region"/resource)
	gran=$(cat /sys/bus/cxl/devices/"$region"/interleave_granularity)

	# Test two HPA addresses: base and base + granularity
	# This hits the two memdevs in the region interleave.
	hpa1=$(printf "0x%x" $((base)))
	hpa2=$(printf "0x%x" $((base + gran)))

	# Inject at the offset and check result using the hpa
	# ABI takes an offset, but recall the hpa to check trace event

	inject_poison_sysfs "$region" 0
	check_trace_entry "$region" "$hpa1"
	inject_poison_sysfs "$region" "$gran"
	check_trace_entry "$region" "$hpa2"
	validate_poison_found "-r $region" 2

	clear_poison_sysfs "$region" 0
	check_trace_entry "$region" "$hpa1"
	clear_poison_sysfs "$region" "$gran"
	check_trace_entry "$region" "$hpa2"
	validate_poison_found "-r $region" 0
}

test_poison_by_region_offset_negative()
{
	local region_size cache_size cache_offset exceed_offset large_offset
	region_size=$(cat /sys/bus/cxl/devices/"$region"/size)
	cache_size=0

	# This case is a no-op until cxl-test ELC mocking arrives
	# Try to get cache_size if the attribute exists
	if [ -f "/sys/bus/cxl/devices/$region/cache_size" ]; then
		cache_size=$(cat /sys/bus/cxl/devices/"$region"/cache_size)
	fi

	# Offset within extended linear cache (if cache_size > 0)
	if [[ $cache_size -gt 0 ]]; then
		cache_offset=$((cache_size - 1))
		echo "Testing offset within cache: $cache_offset (cache_size: $cache_size)"
		inject_poison_sysfs "$region" "$cache_offset" true
		clear_poison_sysfs "$region" "$cache_offset" true
	else
		echo "Skipping cache test - cache_size is 0"
	fi

	# Offset exceeds region size
	exceed_offset=$((region_size))
	inject_poison_sysfs "$region" "$exceed_offset" true
	clear_poison_sysfs "$region" "$exceed_offset" true

	# Offset exceeds region size by a lot
	large_offset=$((region_size * 2))
	inject_poison_sysfs "$region" "$large_offset" true
	clear_poison_sysfs "$region" "$large_offset" true
}

# Clear old trace events, enable cxl_poison, enable global tracing
echo "" > /sys/kernel/tracing/trace
echo 1 > /sys/kernel/tracing/events/cxl/cxl_poison/enable
echo 1 > /sys/kernel/tracing/tracing_on

test_poison_by_memdev_by_dpa
create_x2_region
test_poison_by_region_by_dpa
[ -f "/sys/kernel/debug/cxl/$region/inject_poison" ] ||
       do_skip "test cases requires inject by region kernel support"
test_poison_by_region_offset
test_poison_by_region_offset_negative

check_dmesg "$LINENO"

modprobe -r cxl-test
