import paramiko
import os
import argparse

def ssh_to_bastion(bastion_host, bastion_port, bastion_user, password, command, output_file):
    """
    SSHs into a bastion host, runs a command, and returns the output from a file.

    :param bastion_host: IP or hostname of the bastion host
    :param bastion_port: SSH port of the bastion host (default 22)
    :param bastion_user: Username to SSH into the bastion host
    :param password: Password for SSH authentication
    :param command: The command or script to run on the bastion host
    :param output_file: The file to write the output to on the bastion host
    :return: The output from the command executed
    """
    
    # Initialize SSH client
    ssh_client = paramiko.SSHClient()
    
    # Auto add host key (make sure to use appropriate key checking in production)
    ssh_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    
    try:
        # Connect to the bastion host using password authentication
        ssh_client.connect(bastion_host, bastion_port, bastion_user, password=password)
        
        # Run the command on the bastion host
        stdin, stdout, stderr = ssh_client.exec_command(command)
        
        # Wait for the command to complete
        stdout.channel.recv_exit_status()  # Wait until the command finishes
        
        # Fetch the output file using SFTP
        sftp_client = ssh_client.open_sftp()
        sftp_client.get(output_file, "bastion_output_local.log")  # Download the file locally
        sftp_client.close()

        # Close the SSH connection
        ssh_client.close()

        # Read the output from the local file
        with open("bastion_output_local.log", 'r') as file:
            output = file.read()

        return output
    except Exception as e:
        return f"Connection failed: {e}"

def main():
    # Set up argument parser
    parser = argparse.ArgumentParser(description="SSH to Bastion Host and run a command.")
    parser.add_argument('-H', '--hostname', type=str, required=True, help="Bastion host IP or hostname")
    parser.add_argument('-P', '--password', type=str, required=True, help="Password for SSH authentication")

    # Parse the command-line arguments
    args = parser.parse_args()

    bastion_host = args.hostname
    password = args.password
    bastion_port = 22                      # Default SSH port
    bastion_user = 'lab-user'              # Your username for SSH

    # Path to the output file on the bastion host
    output_folder = "/home/lab-user/tests/"
    output_file = "/home/lab-user/tests/bastion_output.log"

    # Bash commands to run on the bastion host
    command = f"""
    mkdir -p {output_folder}
    touch {output_file}
    sleep 1  # Add sleep to allow previous commands to finish
    echo "Starting script execution..." > {output_file}
    sleep 1  # Add sleep to allow previous commands to finish

    # Check if the Quay URL is available
    curl -I "$QUAY_URL/repository/quayadmin/frontend/"
    if [ $? -eq 0 ]; then
        echo "Module 0 success" >> {output_file}
    else
        echo "Module 0 failed" >> {output_file}
    fi

    # Check if the policy is finished
    curl --insecure -X GET https://${{ROX_CENTRAL_ADDRESS}}/v1/policies \
    -H "Authorization: Bearer ${{ROX_API_TOKEN}}" \
    -H "Content-Type: application/json" | jq '.policies[] | select(.name == "finished-1-policy") | {{id: .id, name: .name}}'
    if [ $? -eq 0 ]; then
        echo "Module 1 success" >> {output_file}
    else
        echo "Module 1 failed" >> {output_file}
    fi

    # Check if the colleciton has been created
    curl --insecure -X GET "https://$ROX_CENTRAL_ADDRESS/v1/collections?name=frontend-collection" \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json"
    if [ $? -eq 0 ]; then
        echo "Module 2 success" >> {output_file}
    else
        echo "Module 2 failed" >> {output_file}
    fi

    # Check if the policy is finished
    curl --insecure -X GET https://$ROX_CENTRAL_ADDRESS/v1/reports \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json"
    if [ $? -eq 0 ]; then
        echo "Module 3 success" >> {output_file}
    else
        echo "Module 3 failed" >> {output_file}
    fi

    # Check if the policy is finished
    curl --insecure -X GET https://${{ROX_CENTRAL_ADDRESS}}/v1/policies \
    -H "Authorization: Bearer ${{ROX_API_TOKEN}}" \
    -H "Content-Type: application/json" | jq '.policies[] | select(.name == "Alpine Linux Package Manager in Image - Enforce Build") | {{id: .id, name: .name}}'
    if [ $? -eq 0 ]; then
        echo "Module 4 success" >> {output_file}
    else
        echo "Module 4 failed" >> {output_file}
    fi


    # Check TaskRun status for succeeded tasks
    taskruns=$(oc get taskrun -n pipeline-demo -o json | jq '.items[] | select(.status.succeeded == true) | .metadata.name')
    # If no succeeded TaskRun found, set eq=1
    if [ -z "$taskruns" ]; then
        eq=1
    else
        eq=0
    fi

    # Check the value of eq and log success/failure
    if [ $eq -eq 0 ]; then
        echo "Module 5 success" >> {output_file}
    else
        echo "Module 5 failed" >> {output_file}
    fi

    # Check if the compliance scan was created
    curl --insecure -X GET "https://$ROX_CENTRAL_ADDRESS/v2/compliance/scan/results" \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json"
    
    if [ $? -eq 0 ]; then
        echo "Module 6 success" >> {output_file}
    else
        echo "Module 6 failed" >> {output_file}
    fi

    # If all commands succeed, print completion
    echo "Completion" >> {output_file}
    """

    # Run the command and capture output
    result = ssh_to_bastion(bastion_host, bastion_port, bastion_user, password, command, output_file)
    
    # Print result to console
    print("Output from bastion host:")
    print(result)

if __name__ == "__main__":
    main()
