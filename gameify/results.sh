#!/bin/bash

# CSV file path
CSV_FILE="bastions.csv"

# Loop through each line in the CSV
while IFS=',' read -r bastion host_password; do
  # Trim leading/trailing spaces (if any)
  bastion=$(echo "$bastion" | xargs)
  host_password=$(echo "$host_password" | xargs)

  # Check if both bastion and host_password are non-empty
  if [[ -n "$bastion" && -n "$host_password" ]]; then
    echo "Connecting to $bastion with key $host_password"

    # Use sshpass to pass the password to ssh
    sshpass -p "$host_password" ssh -t -o PreferredAuthentications=password -o PubkeyAuthentication=no lab-user@"$bastion" \
      "POST_ENDPOINT='https://${ROX_CENTRAL_ADDRESS}/v1/imageintegrations'; \
       curl -k -X GET \"\${POST_ENDPOINT}\" \
         -H \"Authorization: Bearer \${ROX_API_TOKEN}\" \
         -H \"Content-Type: application/json\" \
         | jq; \
       if [ \$? -eq 0 ]; then \
         echo 'Curl command executed successfully'; \
       else \
         echo 'Curl command failed'; \
       fi"

  else
    echo "Skipping invalid line: $bastion, $host_password"
  fi
done < "$CSV_FILE"
