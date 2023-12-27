#!/bin/bash

# Ask for the instance name prefix
read -p "Enter the captain_domain for your Lightsail instances: " captain_domain
read -p "Enter the username:password for your chisel Exit nodes: " credentials_for_chisel

# Define common parameters
bundle_id="nano_3_0"  # Example: nano instance plan
blueprint_id="debian_12"  # Example: Debian 12 OS


# Get the first availability zone in the detected region
first_az=$(aws ec2 describe-availability-zones --region $AWS_REGION --query "AvailabilityZones[0].ZoneName" --output text)
if [ -z "$first_az" ]; then
    echo "No availability zone found in region $AWS_REGION. Exiting..."
    exit 1
fi

echo "Detected Region: $AWS_REGION"
echo "Using Availability Zone: $first_az"


read -r -d '' user_data <<EOF
#!/bin/bash
# Install docker

curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh && sudo apt install tmux -y

# Run chisel
sudo docker run -d -p 9090:9090 -p 443:443 -p 80:80 -it jpillora/chisel server --reverse --port=9090 --auth='$credentials_for_chisel'
EOF

## To debug the userdata/launch script just open up a terminal in the vm and cat /var/log/cloud-init-output.log
## ref: https://aws.amazon.com/blogs/compute/create-use-and-troubleshoot-launch-scripts-on-amazon-lightsail/

# Function to create a Lightsail instance
create_instance() {

    local instance_name=$1
    local user_data=$2  # Cloud-init user data script content

    echo "Creating instance $instance_name with cloud-init..."
    aws lightsail create-instances --instance-names "$instance_name" \
                                   --bundle-id "$bundle_id" \
                                   --blueprint-id "$blueprint_id" \
                                   --availability-zone "$first_az" \
                                   --user-data "$user_data"
                                       instance_name=$1
    #aws lightsail create-instances --instance-names "$instance_name" --bundle-id "$bundle_id" --blueprint-id "$blueprint_id" --availability-zone "$first_az"
    echo "Instance $instance_name is being created..."
}

open_firewall() {
    instance_name=$1

    # Open all ports
    aws lightsail open-instance-public-ports --instance-name "$instance_name" --port-info fromPort=0,toPort=65535,protocol=all
    echo "All ports have been opened for the instance $instance_name."
    
}

# Array of instances
suffixes=("exit1" "exit2")

# Loop through each suffix and perform operations
for suffix in "${suffixes[@]}"; do
    create_instance "${captain_domain}-${suffix}" "${user_data}"
done
echo "Waiting 60 seconds before continuining...."
sleep 60

# Loop through each suffix again to configure firewalls
for suffix in "${suffixes[@]}"; do
    open_firewall "${captain_domain}-${suffix}"
done


# Function to get and store the IPv4 address of an instance
declare -A ip_addresses
get_and_store_ipv4() {
    local instance_name=$1
    local ipv4_address=$(aws lightsail get-instance --instance-name "$instance_name" --query "instance.publicIpAddress" --output text)
    ip_addresses[$instance_name]=$ipv4_address
    echo "Instance $instance_name IPv4 Address: $ipv4_address"
}

# Retrieve and store IPv4 addresses for each instance
for suffix in "${suffixes[@]}"; do
    get_and_store_ipv4 "${captain_domain}-${suffix}"
done

# Function to generate Kubernetes manifest

generate_k8s_manifest() {
echo ""
echo ""
echo "Apply this manifest to your development cluster:"
echo ""
echo ""
cat <<EOF
kubectl apply -k https://github.com/FyraLabs/chisel-operator?ref=staging

kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: selfhosted
  namespace: chisel-operator-system
type: Opaque
stringData:
  auth: "$credentials_for_chisel"
---
apiVersion: chisel-operator.io/v1
kind: ExitNode
metadata:
  name: exit1
  namespace: chisel-operator-system
spec:
  host: "${ip_addresses["${captain_domain}-exit1"]}"
  port: 9090
  auth: selfhosted
---
apiVersion: chisel-operator.io/v1
kind: ExitNode
metadata:
  name: exit2
  namespace: chisel-operator-system
spec:
  host: "${ip_addresses["${captain_domain}-exit2"]}"
  port: 9090
  auth: selfhosted
YAML
EOF
echo ""
echo ""
}

# Generate and output the Kubernetes manifest
generate_k8s_manifest