#!/bin/bash
#
# This script generates a TLS private key and certificate for testing purposes.
#
# After having configured User Certificates auth provider in RHACS, you can test
# the access with:
#
# curl --cert tls.crt --key tls.key $ROX_CENTRAL_ADDRESS/v1/auth/status

# Generate a private key and certificate:
rm -f tls.key tls.crt
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj "/CN=sample-stackrox-monitoring-stack-prometheus.stackrox.svc" \
        -keyout tls.key -out tls.crt

# Create TLS secret in the current namespace:
kubectl delete secret sample-stackrox-prometheus-tls -n stackrox 
kubectl create secret tls sample-stackrox-prometheus-tls --cert=tls.crt --key=tls.key -n stackrox 