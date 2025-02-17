#!/bin/bash
start_iperf_server(){
	ns="${1}"
	ip="${2}"
	ip netns exec "${ns}" iperf3 -s -B "${ip}" -p 7575 \
	-D --logfile /tmp/iperf3.txt --forceflush
	while ! grep listening /tmp/iperf3.txt >/dev/null;do
		sleep 1
	done
	echo "iperf server is running"
}

start_iperf_client(){
	ns="${1}"
	ip="${2}"
	iperf_duration="${3}"
	if [[ "${iperf_duration}" != "0" ]];then
		ip netns exec "${ns}" iperf3 -c "${ip}" -t 40 -p 7575
	fi
}

filter_file(){
	file="${1}"
	out="${2}"
	skipfiles="${3}"

	cmd="cat ${file}"
	for skip in ${skipfiles};do
		cmd="${cmd} | grep -v ${skip}"
	done
	echo "${cmd}" | bash > "${out}"
}
check_threshold(){
	field=$1
	value1=$2
	value2=$3
	threshold=$4
	retvalue=0

	if [[ "${val1}" != "0" && "${val2}" != "0" ]];then
		diff=$(awk -v v1="${val1}" -v v2="${val2}" \
		'BEGIN{d=(100*(v2-v1)/v1); \
		if (d<0) d=d*(-1);printf("%2.2f\n", d)}')
		if awk "BEGIN {exit !($diff >= $threshold)}"; then
			if [[ ${retvalue} == 0 ]];then
				echo "ERROR: Wrong values for some statistics"
				retvalue=1
			fi
			echo "${field} ${value1} ${value2} ${diff}"
		fi
	else
		if [[ ${retvalue} == 0 ]];then
			echo "ERROR: Wrong values for some statistics"
			retvalue=1
		fi
		echo "${field} ${value1} ${value2}"
	fi
	return $retvalue
}
compare(){
	echo "Checking that openstack-network-exporter statistics are ok"
	file1=$1
	file2=$2
	threshold=$3

	skipstats_conf=$(dirname "$0")/stats_conf.csv
	skipstats=$(grep "skip_field" "${skipstats_conf}" |
	awk -F ',' -v ORS=' ' '{print $1}')
	echo "Filter: $skipstats"

	filter_file "${file1}" "${file1}".tmp1 "${skipstats}"
	filter_file "${file2}" "${file2}".tmp1 "${skipstats}"

	len1=$(wc -l "${file1}".tmp1 | awk '{print $1}')
	len2=$(wc -l "${file2}".tmp1 | awk '{print $1}')

	if [[ "${len1}" != "${len2}" ]];then
		echo "ERROR: Wrong number of statistics, \
		files have different length ${len1} ${len2}"
		diff "${file1}".tmp1 "${file2}".tmp1
		return 1
   	fi

	awk '{print $1}' "${file1}".tmp1 > "${file1}".tmp2
	awk '{print $1}' "${file2}".tmp1 > "${file2}".tmp2

	if ! diff "${file1}".tmp2 "${file2}".tmp2;then
		echo "ERROR: Statistics set is not completed, \
		Files have different fields"
		diff "${file1}".tmp2 "${file2}".tmp2
		return 1
	fi

	retvalue=0
	while read -r -u 4 line1 && read -r -u 5 line2; do
		if [[ "${line1}" == "${line2}" ]];then
			continue
		fi
		field1="${line1% *}"
		field2="${line2% *}"
		val1="${line1#* }"
		val2="${line2#* }"
		if [[ "${field1}" != "${field2}" ]];then
			echo "ERROR: Unexpected error, fields should \
			coincide ${field1} ${field2}"
			retvalue=1
			break
		fi
		field_base=$(echo ${field1} | sed -En 's/([a-zA-Z0-0]+).*/\1/p')
		stat_thr=$(sed -En "s/${field_base}, set_threshold, \
		([0-9]+),.*/\1/p" stats_conf.csv)
		if [[ "${stat_thr}" != "" ]];then
			echo "Set threshold ${stat_thr} for ${field1}"
		else
			stat_thr="${threshold}"
		fi
		check_threshold "${field1}" "${val1}" "${val2}" "${stat_thr}"
		retvalue=$?
	done 4<"${file1}".tmp1 5<"${file2}".tmp1
	return "${retvalue}"
}

get_stats(){
	file1="${1}"
	file2="${2}"
	options="${3}"
	echo "Getting stats"
	curl -o "${file1}" http://localhost:1981/metrics 2>/dev/null
	# shellcheck disable=SC2086
	"$(dirname "$0")"/get_ovs_stats.sh ${options} >"${file2}"
	if [[ ! -f "$file1" || ! -f "$file2" ]];then
		echo "Failed to get statistics"
		ls -ls "$file1" "$file2"
		return 1
	fi
	return 0
}

restart_dataplane_node_exporter(){
	killall -9 openstack-network-exporter
	./openstack-network-exporter &
	sleep 5
}

test(){
	ns="${1}"
	ip="${2}"
	testname="${3}"
	iperf_duration="${4}"
	options="${5}"

	restart_dataplane_node_exporter
	file="${LOGS_DIR}/${testname}"
	start_iperf_client "${ns}" "${ip}" "${iperf_duration}"
	get_stats "${file}_1" "${file}_2" "${options}"
	compare "${file}_1" "${file}_2" "${THRESHOLD}"
	return $?
}

test1(){
	echo "Test1: Get statistics with default configuration"
	rm "${cfg}" 2>/dev/null
	test "$@" "test1" "10"
	return $?
}

test2(){
	echo "Test2: Get statistics with only with some collectors"
	echo "collectors: [interface, memory]" | tee "${ONE_CONFIG}"
	test "$@" "test2" "10" "-c interface:memory"
	return $?
}

test3(){
	echo "Test3: Get statistics with only with some collectors and metricsets"
	echo "collectors: [interface, memory]" | tee "${ONE_CONFIG}"
	echo "metric-sets: [errors, counters]" | tee -a "${ONE_CONFIG}"
	test "$@" "test3" "10" "-c interface:memory -m errors:counters"
	return $?
}

run_tests(){
	ret=0
	ns="${1}"
	ip="${2}"
	for test in ${TESTCASES};do
		$test "${ns}" "${ip}"
		ret_test=$?
		if [[ "${ret_test}" != 0 ]];then
			echo "${test}: Testcase failed"
			ret="${ret_test}"
		else
			echo "${test}: Testcase passed"
		fi
	done
	return "${ret}"
}

get_environment(){
	namespaces=$(ip netns ls | awk '{print $1}')
	for ns in ${namespaces};do
		ip=$(ip netns exec "${ns}" ip a |
		sed -En 's/.*inet ([0-9.]+).*/\1/p')
		echo "${ns} ${ip}"
	done
}

help(){
	echo "Run testcases"
	echo "run_tests.sh [-h | -t testcases ]"
	echo "   -h for this help"
	echo "   -t for testcases list separated by :"
	echo "   -r threshold numeric values in %, default 2"
	echo "Sudo needed"
}

ONE_CONFIG="/etc/openstack-network-exporter.yaml"
LOGS_DIR="test/logs"
mkdir -p "${LOGS_DIR}"

while getopts h?t:r: flag
do
	case "${flag}" in
		t) TESTCASES=${OPTARG//:/ };;
		r) THRESHOLD=${OPTARG};;
		h|\?) help; exit 0;;
		*) help; exit 0;;
	esac
done
TESTCASES=${TESTCASES:-test1 test2 test3}
THRESHOLD=${THRESHOLD:-2}

echo "testcases: ${TESTCASES}"
echo "threshold: ${THRESHOLD}"

ips=$(get_environment | tr '\n' ' ')
echo "ips      : ${ips}"

ns0=$(echo "${ips}" | awk '{print $1}')
ip0=$(echo "${ips}" | awk '{print $2}')
ns1=$(echo "${ips}" | awk '{print $3}')

start_iperf_server "${ns0}" "${ip0}"

run_tests "${ns1}" "${ip0}"
ret_test=$?

killall -9 iperf3 1>&2 2>/dev/null
exit "${ret_test}"