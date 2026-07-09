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
    progress_file = "/home/lab-user/.acs-roadshow/progress"

    # Bash commands to run on the bastion host
    command = f"""
    mkdir -p {output_folder}
    touch {output_file}
    sleep 1
    echo "Starting script execution..." > {output_file}
    sleep 1

    progress="{progress_file}"
    if [ ! -f "$progress" ]; then
        echo "Progress file not found: $progress" >> {output_file}
    fi

    for mod in 00 01 02 03 04 05 06 07 08 09 10; do
        mod_num=$(echo "$mod" | sed 's/^0*//')
        [ -z "$mod_num" ] && mod_num=0
        if grep -q "^MODULE=${{mod}} COMPLETE" "$progress" 2>/dev/null; then
            echo "Module $mod_num success" >> {output_file}
        else
            echo "Module $mod_num failed" >> {output_file}
        fi
    done

    echo "Completion" >> {output_file}
    """

    # Run the command and capture output
    result = ssh_to_bastion(bastion_host, bastion_port, bastion_user, password, command, output_file)
    
    # Print result to console
    print("Output from bastion host:")
    print(result)

if __name__ == "__main__":
    main()
