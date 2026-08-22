#!/bin/bash
SLEEP=10s
echo "Waiting for all pods in all namespaces to become healthy."
start_epoch=$(date +%s)
while true; do
	current_epoch=$(date +%s)
	elapsed=$((current_epoch - start_epoch))
	unhealthy=$(kubectl get pods -A 2>/dev/null | \
		grep -Ev '^NAMESPACE| Running | Complete ')
	if (( $? )); then
		echo "Aborting - Fatal error."
		exit 1
	fi
	if [[ -z "$unhealthy" ]]; then
		echo "All pods are healthy. It took $elapsed seconds."
		exit 0
	fi
	echo -e "\n******************\n*** Unhealthy pods discovered: (elapsed:$elapsed seconds):"
	echo "$unhealthy"
	nr_nodes=$(kubectl get nodes 2>/dev/null | grep NotReady)
	if (( $? )); then
		echo "Aborting - Fatal error."
		exit 1
	fi
	if [[ -n "$nr_nodes" ]]; then
		echo -e "\n*** Unhealthy nodes discovered:"
		echo "$nr_nodes"
	fi
	echo "*** Checking again in $SLEEP seconds."
	sleep "$SLEEP"
done