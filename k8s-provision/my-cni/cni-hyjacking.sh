#!/bin/bash

set -euo pipefail

INPUT_TEMP=$(mktemp)
OUTPUT_TEMP=$(mktemp)
ENV_TEMP=$(mktemp)

env > "$ENV_TEMP"

tee $INPUT_TEMP | ./my-cni.sh | tee $OUTPUT_TEMP



echo "================input================" >&2
cat $INPUT_TEMP  >&2
echo "================output================" >&2
cat $OUTPUT_TEMP  >&2
echo "================env================" >&2
cat $ENV_TEMP >&2
