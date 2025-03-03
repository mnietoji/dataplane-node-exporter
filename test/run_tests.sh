#!/bin/bash
start_iperf_server() {
	ns="$1"
	ip="$2"
	ip netns exec "$ns" iperf3 -s -B "$ip" -p 7575 \
		-D --logfile /tmp/iperf3.txt --forceflush
	ip netns exec $ns socat FILE:/dev/null TCP4-CONNECT:$ip:7575,retry=10
	echo "iperf server is running"
}

start_iperf_client() {
	ns="$1"
	ip="$2"
	duration="$3"
	if [[ "$duration" != "0" ]];then
		ip netns exec "$ns" iperf3 -c "$ip" -t "$duration" -p 7575
	fi
}

filter_file() {
	file="$1"
	out="$2"
	skipfiles="$3"

	cmd="cat $file"
	for skip in $skipfiles;do
		cmd="$cmd | grep -v $skip"
	done
	echo "$cmd" | bash > "$out"
}

check_threshold() {
	field=$1
	value1=$2
	value2=$3
	threshold=$4
	retvalue=0

	if [[ "$val1" != "0" && "$val2" != "0" ]];then
		diff=$(awk -v v1="$val1" -v v2="$val2" \
			'BEGIN{d=(100*(v2-v1)/v1); \
			if (d<0) d=d*(-1);printf("%2.2f\n", d)}')
		if awk "BEGIN {exit !($diff >= $threshold)}"; then
			if [[ $retvalue == 0 ]];then
				retvalue=1
			fi
			echo "ERROR: $field $value1 $value2 $diff"
		fi
	else
		if [[ $retvalue == 0 ]];then
			retvalue=1
		fi
		echo "ERROR: $field $value1 $value2"
	fi
	return "$retvalue"
}
compare() {
	echo "Checking that openstack-network-exporter statistics are ok"
	file1=$1
	file2=$2
	threshold=$3

	# Remove statistics that will not be checked
	skipstats=$(grep "skip_field" "$STATS_CONF" |
		awk -F ',' -v ORS=' ' '{print $1}')
	echo "Filter: $skipstats"

	filter_file "$file1" "$file1".filtered "$skipstats"
	filter_file "$file2" "$file2".filtered "$skipstats"

        # Check that same fields have been generated
	awk '{if ($1 != "#") print $1}' "$file1".filtered > "$file1".fields
	awk '{if ($1 != "#") print $1}' "$file2".filtered > "$file2".fields
	if ! diff "$file1".fields "$file2".fields 2;then
		echo "ERROR: Statistics set is not completed, \
		Files have different fields"
		diff "$file1".fields "$file2".fields
		return 1
	fi

	# Check that values are similar (under a defined threshold)
	retvalue=0
	while read -r -u 4 line1 && read -r -u 5 line2; do
		if [[ "$line1" == "$line2" ]];then
			continue
		fi
		field1="${line1% *}"
		field2="${line2% *}"
		val1="${line1#* }"
		val2="${line2#* }"
		if [[ "$field1" != "$field2" ]];then
			echo "ERROR: Unexpected error, fields should \
			coincide $field1 $field2"
			retvalue=1
			break
		fi
		field_base=$(echo "$field1" | awk -F '{' '{print $1}')
		stat_thr=$(awk -F ',' -v f="$field_base" \
		'{ if ($1 == f) printf("%d",$3) }' "$STATS_CONF")
		if [[ "$stat_thr" != "" ]];then
			echo "Set threshold $stat_thr for $field1"
		else
			stat_thr="$threshold"
		fi
		check_threshold "$field1" "$val1" "$val2" "$stat_thr"
                ret=$?
                [[ $retvalue == 0 ]]&&[[ $ret == 1 ]]&&retvalue=1
	done 4<"$file1".filtered 5<"$file2".filtered
	return "$retvalue"
}

get_stats() {
	file1="{1"
	file2="$2"
	options="$3"
	echo "Getting stats"
	curl -o "$file1" http://localhost:1981/metrics 2>/dev/null
	# shellcheck disable=SC2086
	"${TEST_DIR}"/get_ovs_stats.sh $options >"$file2"
	if [[ ! -f "$file1" || ! -f "$file2" ]];then
		echo "Failed to get statistics"
		ls -ls "$file1" "$file2"
		return 1
	fi
	return 0
}

restart_openstack_network_exporter() {
	killall -9 openstack-network-exporter
	"$BASE_DIR"/openstack-network-exporter &
	sleep 5
}

test() {
	ns="$1"
	ip="$2"
	testname="$3"
	iperf_duration="$4"
	options="$5"

	restart_openstack_network_exporter
	testdir="$LOGS_DIR/$testname"
	start_iperf_client "$ns" "$ip" "$iperf_duration"
	get_stats "$testdir/op_net_ex" "$testdir/test" "$options"
	compare "$testdir/op_net_ex" "$testdir/test" "$THRESHOLD"
	return $?
}

test1() {
	echo "Test1: Get statistics with default configuration"
	[ -f "$ONE_CONFIG" ]&&rm "$ONE_CONFIG"
	test "$@" "test1" "10"
	return $?
}

test2() {
	echo "Test2: Get statistics with only with some collectors"
	echo "collectors: [interface, memory]" | tee "$ONE_CONFIG"
	test "$@" "test2" "10" "-c interface:memory"
	return $?
}

test3() {
	echo "Test3: Get statistics with only with \
	some collectors and metricsets"
	echo "collectors: [interface, memory]" | tee "$ONE_CONFIG"
	echo "metric-sets: [errors, counters]" | tee -a "$ONE_CONFIG"
	test "$@" "test3" "10" "-c interface:memory -m errors:counters"
	return $?
}

run_tests() {
	ret=0
	ns="$1"
	ip="$2"
	for test in $TESTCASES;do
		mkdir "$LOGS_DIR/$test"
		$test "$ns" "$ip"
		ret_test=$?
		if [[ "$ret_test" != 0 ]];then
			echo "$test: Testcase failed"
			ret="$ret_test"
		else
			echo "$test: Testcase passed"
		fi
	done
	return "$ret"
}

get_environment() {
	namespaces=$(ip netns ls | awk '{print $1}')
	for ns in $namespaces;do
		ip=$(ip netns exec "$ns" ip a |
		sed -En 's/.*inet ([0-9.]+).*/\1/p')
		echo "$ns $ip"
	done
}

help() {
	cat <<EOF
Run testcases
run_tests.sh [-h | -t testcases ]
   -h for this help
   -t for testcases list separated by :
   -r threshold numeric values in %, default 2
sudo needed
EOF
}

ONE_CONFIG="/etc/openstack-network-exporter.yaml"
LOGS_DIR="$(dirname "$0")/logs"
TEST_DIR="$(dirname "$0")"
BASE_DIR="$TEST_DIR/../"
STATS_CONF="$TEST_DIR"/stats_conf.csv

mkdir -p "$LOGS_DIR"

while getopts h?t:r: flag; do
	case "$flag" in
	t)
		TESTCASES=${OPTARG//:/ }
		;;
	r)
		THRESHOLD=${OPTARG}
		;;
	h|\?)
		help;
		exit 0
		;;
	*)
		help;
		exit 0
		;;
	esac
done
TESTCASES=${TESTCASES:-test1 test2 test3}
THRESHOLD=${THRESHOLD:-2}

echo "testcases: $TESTCASES"
echo "threshold: $THRESHOLD"

ips=$(get_environment | tr '\n' ' ')
echo "ips      : $ips"

ns0=$(echo "$ips" | awk '{print $1}')
ip0=$(echo "$ips" | awk '{print $2}')
ns1=$(echo "$ips" | awk '{print $3}')

start_iperf_server "$ns0" "$ip0"

run_tests "$ns1" "$ip0"
ret_test=$?

killall -9 iperf3 1>&2 2>/dev/null
exit "$ret_test"
