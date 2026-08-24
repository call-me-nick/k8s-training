#!/bin/bash
SLEEP=10s
# User may want to sleep for a bit before checking. 
if [[ -n "$1" ]]; then sleep "$1" ; fi
echo "Waiting for all pods in all namespaces to become healthy."
start_epoch=$(date +%s)
while true; do
	current_epoch=$(date +%s)
	elapsed=$((current_epoch - start_epoch))
	unhealthy=$(kubectl get pods -A 2>/dev/null | \
		grep -Ev '^NAMESPACE| Running | Complete ')
	if [[ -z "$unhealthy" ]]; then
		echo "All pods are healthy. It took $elapsed seconds."
		exit 0
	fi
	echo -e "\n******************\n*** Unhealthy pods discovered: (elapsed:$elapsed seconds):"
	echo "$unhealthy"
	nr_nodes=$(kubectl get nodes 2>/dev/null | grep NotReady)
	[[ -z "$nr_nodes" ]] && nr_nodes='0'
	if [[ -n "$nr_nodes" ]]; then
		echo -e "\n*** Unhealthy nodes discovered:"
		echo "$nr_nodes"
	fi
	echo "*** NOT READY - Checking again in $SLEEP seconds."
	sleep "$SLEEP"
done