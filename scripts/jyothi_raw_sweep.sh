#!/usr/bin/env bash
###
### Local reproduction helper for raw TopoBench K values from the Jyothi et al. SC 2016 artifact.
### It keeps the original Java LP generator and writes raw K plus an optional same-equipment
### random-graph normalization baseline.
###

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

NRUNS=${NRUNS:-10}
PORTS=${PORTS:-"6 8 10 12 14 16"}
MODES=${MODES:-"0 1 4"}
TOPOLOGIES=${TOPOLOGIES:-"fat-tree jellyfish hypercube dragonfly"}
HYPERCUBE_DIMS=${HYPERCUBE_DIMS:-"6 7 8 9 10"}
DRAGONFLY_P=${DRAGONFLY_P:-"2 3 4"}
OUTDIR=${OUTDIR:-resultfiles/jyothi_raw}
COMPARE_RANDOM=${COMPARE_RANDOM:-1}

command -v javac >/dev/null || { echo "javac not found" >&2; exit 1; }
command -v java >/dev/null || { echo "java not found" >&2; exit 1; }
command -v highs >/dev/null || { echo "highs not found" >&2; exit 1; }
if printf '%s\n' "$MODES" | grep -qw 4; then
	command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
	python3 -c 'import networkx' >/dev/null 2>&1 || {
		echo "python3 package networkx is required for mode 4 longest matching" >&2
		exit 1
	}
fi

mkdir -p "$OUTDIR" topology/pathlengths
javac -nowarn lpmaker/ProduceLP.java

rows="$OUTDIR/raw_results.csv"
printf 'topology,variant,size_param,mode,run,seed,switches,switchports,servers,raw_k,random_baseline_k,relative_to_random\n' > "$rows"

want_topology() {
	local wanted=$1
	local item
	for item in $TOPOLOGIES; do
		[[ "$item" == "$wanted" ]] && return 0
	done
	return 1
}

target_servers_for_port() {
	local k=$1
	echo $(( k * k * k / 4 ))
}

solve_generated_lp() {
	local lp_name=$1
	local path_name=$2
	local stem=$3
	[[ -s "$lp_name" ]] || { echo "missing LP $lp_name for $stem" >&2; exit 1; }
	mv "$lp_name" "topology/${stem}.lp"
	if [[ -s "$path_name" ]]; then
		mv "$path_name" "topology/pathlengths/${stem}.txt"
	fi
	bash scripts/lpRun.sh "topology/${stem}.lp"
}

run_case() {
	local topology=$1
	local variant=$2
	local size_param=$3
	local mode=$4
	local run=$5
	local seed=$6
	local switches=$7
	local switchports=$8
	local servers=$9
	shift 9
	local raw_args=("$@")
	local raw_k random_k relative stem

	rm -f my.0.lp pl.0 maxWeightMatch.txt lpmaker/serverDist1.txt
	java lpmaker/ProduceLP "${raw_args[@]}" >/dev/null
	stem="${topology}_${variant}_${size_param}_m${mode}_r${run}"
	raw_k=$(solve_generated_lp my.0.lp pl.0 "$stem")
	random_k=""
	relative=""

	if [[ "$COMPARE_RANDOM" == "1" ]]; then
		rm -f my.0.lp pl.0 maxWeightMatch.txt lpmaker/serverDist1.txt
		java lpmaker/ProduceLP 1 0 garbage "$mode" "$switches" "$switchports" 0 0 "$servers" 0.0 0 0 0 0 0 0 0 0 0 1 "$(( seed + 700000000 ))" >/dev/null
		random_k=$(solve_generated_lp my.0.lp pl.0 "${stem}_same_equipment_random")
		relative=$(awk -v a="$raw_k" -v b="$random_k" 'BEGIN { if (b > 0) printf "%.10f", a / b; }')
	fi

	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$topology" "$variant" "$size_param" "$mode" "$run" "$seed" \
		"$switches" "$switchports" "$servers" "$raw_k" "$random_k" "$relative" >> "$rows"
}

for mode in $MODES; do
	for run in $(seq 1 "$NRUNS"); do
		for k in $PORTS; do
			servers=$(target_servers_for_port "$k")
			switches=$(( 5 * k * k / 4 ))

			if want_topology fat-tree; then
				seed=$(( 1000000 + k * 10000 + mode * 100 + run ))
				run_case "Fat-tree" "sigcomm" "k${k}" "$mode" "$run" "$seed" "$switches" "$k" "$servers" \
					1 1 garbage "$mode" 0 "$k" 0 0 0 0.0 0 0 0 0 0 0 0 0 0 1 "$seed"
			fi

			if want_topology jellyfish; then
				seed=$(( 2000000 + k * 10000 + mode * 100 + run ))
				run_case "Jellyfish" "same-equipment-fat-tree" "k${k}" "$mode" "$run" "$seed" "$switches" "$k" "$servers" \
					1 0 garbage "$mode" "$switches" "$k" 0 0 "$servers" 0.0 0 0 0 0 0 0 0 0 0 1 "$seed"
			fi
		done

		if want_topology hypercube; then
			for m in $HYPERCUBE_DIMS; do
				switches=$(( 1 << m ))
				server_ports=1
				switchports=$(( m + server_ports ))
				servers=$(( switches * server_ports ))
				seed=$(( 3000000 + m * 10000 + mode * 100 + run ))
				run_case "Hypercube" "uniform-server" "m${m}" "$mode" "$run" "$seed" "$switches" "$switchports" "$servers" \
					1 15 garbage "$mode" "$switches" "$switchports" "$m" 0 0 0.0 0 0 0 0 0 0 0 0 0 1 "$seed"
			done
		fi

		if want_topology dragonfly; then
			for p in $DRAGONFLY_P; do
				a=$(( 2 * p ))
				h=$p
				z=1
				g=$(( a * h / z + 1 ))
				switches=$(( a * g ))
				switchports=$(( a + h + p - 1 ))
				servers=$switches
				seed=$(( 4000000 + p * 10000 + mode * 100 + run ))
				run_case "Dragonfly" "balanced-original" "p${p}" "$mode" "$run" "$seed" "$switches" "$switchports" "$servers" \
					1 2 garbage "$mode" "$a" "$p" "$h" "$z" 0 0.0 0 0 0 0 0 0 0 0 0 1 "$seed"
			done
		fi
	done
done

summary="$OUTDIR/raw_summary.csv"
{
	printf 'topology,variant,size_param,mode,avg_raw_k,avg_random_baseline_k,avg_relative_to_random,nruns\n'
	awk -F, '
	NR == 1 { next }
	{
		key=$1 "," $2 "," $3 "," $4
		sum_raw[key]+=$10
		if ($11 != "") { sum_rand[key]+=$11; count_rand[key]++ }
		if ($12 != "") { sum_rel[key]+=$12; count_rel[key]++ }
		count[key]++
	}
	END {
		for (key in count) {
			avg_rand = count_rand[key] ? sum_rand[key]/count_rand[key] : ""
			avg_rel = count_rel[key] ? sum_rel[key]/count_rel[key] : ""
			print key "," sum_raw[key]/count[key] "," avg_rand "," avg_rel "," count[key]
		}
	}
	' "$rows" | sort -t, -k1,1 -k3,3 -k4,4n
} > "$summary"

echo "Wrote $rows"
echo "Wrote $summary"
