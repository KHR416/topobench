###
###  Released under the MIT License (MIT) --- see ../LICENSE
###  Copyright (c) 2014 Ankit Singla, Sangeetha Abdu Jyothi, Chi-Yao Hong, Lucian Popa, P. Brighten Godfrey, Alexandra Kolla
###

set -euo pipefail

# USAGE: Input is a file containing a linear program for throughput in CPLEX format.
# Output is the throughput value obtained. This local reproduction copy always uses
# HiGHS PDLP with presolve disabled instead of the original Gurobi command.

infile=$1

logfile=$(mktemp "${TMPDIR:-/tmp}/topobench-highs.XXXXXX")
solver_input=$(mktemp "${TMPDIR:-/tmp}/topobench-highs-lp.XXXXXX.lp")
cleanup() {
	rm -f "$logfile" "$solver_input" "${optfile:-}"
}
trap cleanup EXIT

# The original TopoBench LP writer targeted Gurobi. HiGHS is stricter about
# CPLEX LP files, so keep a temporary solver copy with Gurobi-style comments
# removed and an explicit End marker added when older writers omit it.
awk '
	substr($0, 1, 1) == "\\" { next }
	{
		print
		if ($0 ~ /[^[:space:]]/) last = tolower($0)
	}
	END {
		gsub(/^[[:space:]]+|[[:space:]]+$/, "", last)
		if (last != "end") print "End"
	}
' "$infile" > "$solver_input"

optfile=$(mktemp "${TMPDIR:-/tmp}/topobench-highs-opts.XXXXXX")
printf 'solver = pdlp\npresolve = off\nkkt_tolerance = 1e-6\n' > "$optfile"
highs --options_file "$optfile" "$solver_input" > "$logfile" 2>&1 || highs_status=$?
highs_status=${highs_status:-0}

objective_line=$(grep "Objective value" "$logfile" | tail -1 || true)
objective=""
if [[ -n "$objective_line" ]]; then
	objective_value=${objective_line##* }
	objective=$(awk -v val="$objective_value" 'BEGIN {printf "%.10f", val}')
fi

if [[ -z "$objective" ]]; then
	if [[ ${LP_ALLOW_FAILURE:-0} == "1" ]]; then
		echo "-1"
	else
		echo "Could not find objective value in HiGHS output for $infile" >&2
		sed -n '1,120p' "$logfile" >&2
		exit 1
	fi
else
	echo "$objective"
fi
