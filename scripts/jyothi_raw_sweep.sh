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
GEN_JOBS=${GEN_JOBS:-4}

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

ROW_DIR="$OUTDIR/rows"
WORK_DIR="$OUTDIR/work"
META_DIR="$OUTDIR/meta"

rm -rf "$ROW_DIR" "$WORK_DIR" "$META_DIR"
mkdir -p "$OUTDIR/logs" "$ROW_DIR" "$WORK_DIR" "$META_DIR" topology/pathlengths
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

write_generated_lp() {
	local workdir=$1
	local stem=$2
	local lp_out=$3
	local path_out=$4
	[[ -s "$workdir/my.0.lp" ]] || { echo "missing LP for $stem" >&2; exit 1; }
	mv "$workdir/my.0.lp" "$lp_out"
	if [[ -s "$workdir/pl.0" ]]; then
		mv "$workdir/pl.0" "$path_out"
	fi
}

generate_case() {
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
	local stem workdir raw_lp raw_path random_lp random_path meta

	stem="${topology}_${variant}_${size_param}_m${mode}_r${run}"
	workdir="$WORK_DIR/$stem"
	raw_lp="topology/${stem}.lp"
	raw_path="topology/pathlengths/${stem}.txt"
	random_lp=""
	random_path=""
	meta="$META_DIR/${stem}.tsv"

	rm -rf "$workdir"
	mkdir -p "$workdir/lpmaker"
	ln -sf "$REPO_ROOT/lpmaker/maxWeight.py" "$workdir/lpmaker/maxWeight.py"

	(
		cd "$workdir"
		java -cp "$REPO_ROOT" lpmaker/ProduceLP "${raw_args[@]}"
	) > "$OUTDIR/logs/${stem}.gen.log" 2>&1
	write_generated_lp "$workdir" "$stem" "$REPO_ROOT/$raw_lp" "$REPO_ROOT/$raw_path"

	if [[ "$COMPARE_RANDOM" == "1" ]]; then
		rm -f "$workdir/my.0.lp" "$workdir/pl.0" "$workdir/maxWeightMatch.txt" "$workdir/lpmaker/serverDist1.txt"
		random_lp="topology/${stem}_same_equipment_random.lp"
		random_path="topology/pathlengths/${stem}_same_equipment_random.txt"
		(
			cd "$workdir"
			java -cp "$REPO_ROOT" lpmaker/ProduceLP 1 0 garbage "$mode" "$switches" "$switchports" 0 0 "$servers" 0.0 0 0 0 0 0 0 0 0 0 1 "$(( seed + 700000000 ))"
		) > "$OUTDIR/logs/${stem}_same_equipment_random.gen.log" 2>&1
		write_generated_lp "$workdir" "${stem}_same_equipment_random" "$REPO_ROOT/$random_lp" "$REPO_ROOT/$random_path"
	fi

	rm -rf "$workdir"
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$topology" "$variant" "$size_param" "$mode" "$run" "$seed" \
		"$switches" "$switchports" "$servers" "$raw_lp" "$random_lp" > "$meta"
}

producer_pids=()
run_case() {
	while [[ $(jobs -rp | wc -l) -ge $GEN_JOBS ]]; do
		wait -n
	done
	generate_case "$@" &
	producer_pids+=("$!")
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

gen_failed=0
for pid in "${producer_pids[@]}"; do
	wait "$pid" || gen_failed=1
done
if (( gen_failed != 0 )); then
	echo "LP generation failed" >&2
	exit 1
fi

shopt -s nullglob
metafiles=("$META_DIR"/*.tsv)
shopt -u nullglob
for meta in "${metafiles[@]}"; do
	IFS=$'\t' read -r topology variant size_param mode run seed switches switchports servers raw_lp random_lp < "$meta"
	raw_k=$(bash scripts/lpRun.sh "$raw_lp")
	random_k=""
	relative=""
	if [[ -n "$random_lp" ]]; then
		random_k=$(bash scripts/lpRun.sh "$random_lp")
		relative=$(awk -v a="$raw_k" -v b="$random_k" 'BEGIN { if (b > 0) printf "%.10f", a / b; }')
	fi
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$topology" "$variant" "$size_param" "$mode" "$run" "$seed" \
		"$switches" "$switchports" "$servers" "$raw_k" "$random_k" "$relative" >> "$rows"
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
