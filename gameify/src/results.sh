#!/bin/bash

mkdir -p {output_file} touch {output_file}
sleep 2  # Add sleep to allow previous commands to finish
echo "Starting script execution..." > {output_file}
uptime >> {output_file}
df -h >> {output_file}
free -m >> {output_file}
sleep 2  # Add sleep to allow previous commands to finish
curl --insecure -X GET https://${{ROX_CENTRAL_ADDRESS}}/v1/policies \
-H "Authorization: Bearer ${{ROX_API_TOKEN}}" \
-H "Content-Type: application/json" | jq '.policies[] | select(.name == "finished-1-policy") | {{id: .id, name: .name}}' >> {output_file}
sleep 2  # Allow curl to complete before moving to next command
echo "module 1 complete" >> {output_file}