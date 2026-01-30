# AWS Flask Application with Auto Scaling - Setup Guide

This guide provides step-by-step instructions to create a custom VPC, EC2 Launch Template, and Auto Scaling Group for a Flask application using AWS CLI.

## Prerequisites

- AWS CLI installed and configured
- Valid AWS credentials with appropriate permissions
- Terminal/Shell access

## Configuration

Set your name as an environment variable (used throughout the setup):

```bash
export YOUR_NAME="sk"
export KEYPAIR_NAME="${YOUR_NAME}-flask-keypair"
```

---

## Step 1: Create Custom VPC

Create a VPC to host your infrastructure:

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${YOUR_NAME}-flask-vpc}]" \
  --query 'Vpc.VpcId' \
  --output text)

echo "VPC ID: $VPC_ID"
```

Enable DNS hostname support:

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id $VPC_ID \
  --enable-dns-hostnames
```

**Expected Output:** VPC ID like `vpc-0abcdef1234567890`

---

## Step 2: Create Internet Gateway

Create and attach an Internet Gateway for public internet access:

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${YOUR_NAME}-flask-igw}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

echo "Internet Gateway ID: $IGW_ID"

# Attach IGW to VPC
aws ec2 attach-internet-gateway \
  --vpc-id $VPC_ID \
  --internet-gateway-id $IGW_ID
```

**Expected Output:** Internet Gateway ID like `igw-0abcdef1234567890`

---

## Step 3: Create Subnets

Create two public subnets in different availability zones for high availability:

```bash
# Get available AZs
AZ1=$(aws ec2 describe-availability-zones \
  --query 'AvailabilityZones[0].ZoneName' \
  --output text)

AZ2=$(aws ec2 describe-availability-zones \
  --query 'AvailabilityZones[1].ZoneName' \
  --output text)

# Create Subnet 1
SUBNET1_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 \
  --availability-zone $AZ1 \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${YOUR_NAME}-flask-subnet-1}]" \
  --query 'Subnet.SubnetId' \
  --output text)

echo "Subnet 1 ID: $SUBNET1_ID (AZ: $AZ1)"

# Create Subnet 2
SUBNET2_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.2.0/24 \
  --availability-zone $AZ2 \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${YOUR_NAME}-flask-subnet-2}]" \
  --query 'Subnet.SubnetId' \
  --output text)

echo "Subnet 2 ID: $SUBNET2_ID (AZ: $AZ2)"

# Enable auto-assign public IP
aws ec2 modify-subnet-attribute \
  --subnet-id $SUBNET1_ID \
  --map-public-ip-on-launch

aws ec2 modify-subnet-attribute \
  --subnet-id $SUBNET2_ID \
  --map-public-ip-on-launch
```

**Expected Output:** Two subnet IDs like `subnet-0abcdef1234567890`

---

## Step 4: Create Route Table

Create a route table and add a route to the Internet Gateway:

```bash
# Create Route Table
ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${YOUR_NAME}-flask-rt}]" \
  --query 'RouteTable.RouteTableId' \
  --output text)

echo "Route Table ID: $ROUTE_TABLE_ID"

# Add route to Internet Gateway
aws ec2 create-route \
  --route-table-id $ROUTE_TABLE_ID \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID

# Associate route table with subnets
aws ec2 associate-route-table \
  --route-table-id $ROUTE_TABLE_ID \
  --subnet-id $SUBNET1_ID

aws ec2 associate-route-table \
  --route-table-id $ROUTE_TABLE_ID \
  --subnet-id $SUBNET2_ID
```

**Expected Output:** Route table ID and association confirmations

---

## Step 5: Create EC2 Key Pair

Create a new keypair and save the private key:

```bash
aws ec2 create-key-pair \
  --key-name "$KEYPAIR_NAME" \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/${KEYPAIR_NAME}.pem
```

Set correct permissions on the private key:

```bash
chmod 400 ~/.ssh/${KEYPAIR_NAME}.pem
```

Verify the keypair was created:

```bash
aws ec2 describe-key-pairs --key-names "$KEYPAIR_NAME"
```

**Expected Output:** Details of your newly created keypair

---

## Step 6: Get Amazon Linux 2023 AMI ID

Retrieve the latest Amazon Linux 2023 AMI ID for your region:

```bash
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" \
  --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" \
  --output text)

echo "AMI ID: $AMI_ID"
```

**Expected Output:** An AMI ID like `ami-0abcdef1234567890`

---

## Step 7: Create Security Group

Create a security group in your custom VPC:

```bash
SG_ID=$(aws ec2 create-security-group \
  --group-name "${YOUR_NAME}-flask-launch-template-sg" \
  --description "Security group for Flask app launch template" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)

echo "Security Group ID: $SG_ID"
```

**Expected Output:** A Security Group ID like `sg-0abcdef1234567890`

---

## Step 8: Add Inbound Rules to Security Group

Add rules to allow SSH (port 22) and Flask app access (port 8080):

```bash
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --ip-permissions \
    IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=0.0.0.0/0,Description="SSH access"}]' \
    IpProtocol=tcp,FromPort=8080,ToPort=8080,IpRanges='[{CidrIp=0.0.0.0/0,Description="Flask app access"}]'
```

**Expected Output:** Details of the added rules

---

## Step 9: Prepare User Data Script

Create and encode the user data script that will run on instance startup:

```bash
USER_DATA=$(cat <<'EOF' | base64
#!/bin/bash
yum update -y
yum install python3-pip git -y
pip3 install flask gunicorn

git clone https://github.com/jaezeu/flask-app.git
cd flask-app
gunicorn -b 0.0.0.0:8080 app:app
EOF
)
```

**What this script does:**

- Updates system packages
- Installs Python3, pip, and git
- Installs Flask and Gunicorn
- Clones the Flask application repository
- Starts the Flask app using Gunicorn on port 8080

---

## Step 10: Create Launch Template

Create the EC2 Launch Template with all configurations:

```bash
aws ec2 create-launch-template \
  --launch-template-name "${YOUR_NAME}-flask-launch-template" \
  --version-description "Flask app launch template with automated setup" \
  --launch-template-data '{
    "ImageId": "'$AMI_ID'",
    "InstanceType": "t2.micro",
    "KeyName": "'$KEYPAIR_NAME'",
    "SecurityGroupIds": ["'$SG_ID'"],
    "UserData": "'$USER_DATA'"
  }'
```

Verify the launch template was created:

```bash
aws ec2 describe-launch-templates \
  --launch-template-names "${YOUR_NAME}-flask-launch-template"
```

**Expected Output:** Details of your launch template

---

## Step 11: Create Auto Scaling Group

Create the Auto Scaling Group with your launch template in your custom subnets:

```bash
SUBNET_IDS="${SUBNET1_ID},${SUBNET2_ID}"

aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "${YOUR_NAME}-flask-asg" \
  --launch-template "LaunchTemplateName=${YOUR_NAME}-flask-launch-template,Version=\$Latest" \
  --min-size 1 \
  --max-size 3 \
  --desired-capacity 2 \
  --vpc-zone-identifier "$SUBNET_IDS" \
  --health-check-type EC2 \
  --health-check-grace-period 300 \
  --tags "Key=Name,Value=${YOUR_NAME}-flask-instance,PropagateAtLaunch=true"
```

**Configuration:**

- **Min Size:** 1 instance
- **Max Size:** 3 instances
- **Desired Capacity:** 2 instances
- **Health Check Grace Period:** 300 seconds (5 minutes)

---

## Step 12: Add Scaling Policy

Add a target tracking scaling policy based on CPU utilization:

```bash
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "${YOUR_NAME}-flask-asg" \
  --policy-name "cpu-target-tracking-policy" \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ASGAverageCPUUtilization"
    },
    "TargetValue": 50.0
  }'
```

This policy will automatically scale your instances to maintain 50% CPU utilization.

**Expected Output:** Details of the created scaling policy

---

## Step 13: Verify Auto Scaling Group

Check that your Auto Scaling Group was created successfully:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${YOUR_NAME}-flask-asg" \
  --query 'AutoScalingGroups[0].[AutoScalingGroupName,MinSize,MaxSize,DesiredCapacity,Instances[*].InstanceId]' \
  --output table
```

**Expected Output:** A table showing your ASG configuration and running instances

---

## Step 14: Get Instance Public IPs

To access your Flask application, get the public IP addresses of your instances:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${YOUR_NAME}-flask-asg" \
  --query 'AutoScalingGroups[0].Instances[*].InstanceId' \
  --output text | xargs -n1 -I {} aws ec2 describe-instances \
  --instance-ids {} \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text
```

**Note:** Wait ~5-10 minutes after creating the ASG for instances to launch and for the user data script to complete.

---

## Testing Your Flask Application

### Test with curl

Once instances are running and healthy, test the Flask application:

```bash
# Get one instance IP
INSTANCE_IP=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${YOUR_NAME}-flask-asg" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' \
  --output text | xargs aws ec2 describe-instances \
  --instance-ids {} \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

# Test the application
curl http://$INSTANCE_IP:8080
```

**Expected Output:** Response from your Flask application

### Access via Web Browser (Optional)

You can also access the application in your browser:

```
http://<instance-public-ip>:8080
```

---

## Part 4: Testing Auto Scaling with Load Test

Since your Auto Scaling group contains a scaling policy based on CPU Utilization > 50%, you can perform a load test to simulate a scale-out event.

### Step 1: SSH into an EC2 Instance

```bash
# Get an instance IP
INSTANCE_IP=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${YOUR_NAME}-flask-asg" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' \
  --output text | xargs aws ec2 describe-instances \
  --instance-ids {} \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

# SSH into the instance
ssh -i ~/.ssh/${KEYPAIR_NAME}.pem ec2-user@$INSTANCE_IP
```

### Step 2: Install and Run Stress Test

Once connected to the instance, run the following commands:

```bash
# Install stress-ng tool
sudo yum install stress-ng -y

# Run stress test: 70% CPU load for 20 minutes
stress-ng --cpu 1 --cpu-load 70 --timeout 1200s
```

**What happens:**

- The command increases your instance's CPU utilization to 70%
- Duration: 20 minutes (1200 seconds)
- CloudWatch metrics take ~5 minutes to reflect the change
- Auto Scaling will trigger when average CPU across instances exceeds 50%
- A new instance will be launched to handle the load

### Step 3: Monitor Scaling Activity

In a new terminal window (while stress test is running), monitor your Auto Scaling Group:

```bash
# Watch the number of instances
watch -n 30 'aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names \"${YOUR_NAME}-flask-asg\" \
  --query \"AutoScalingGroups[0].[DesiredCapacity,Instances[*].[InstanceId,LifecycleState]]\" \
  --output table'
```

**Or check scaling activities:**

```bash
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name "${YOUR_NAME}-flask-asg" \
  --max-records 10 \
  --query 'Activities[*].[StartTime,Description,StatusCode]' \
  --output table
```

**Expected behavior:**

- After ~5 minutes: CloudWatch metrics show increased CPU
- After ~5-10 minutes: ASG triggers scale-out
- Desired capacity increases (e.g., from 2 to 3 instances)
- New instance launches and joins the group
- After stress test ends: CPU drops, ASG may scale back in

---

## Part 5: Simulate Auto-Healing

You can test the auto-healing capability of your Auto Scaling Group by terminating instances manually and observing how ASG automatically replaces them.

### Terminate a Random Instance

```bash
# Get a random instance ID from your ASG
INSTANCE_TO_TERMINATE=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${YOUR_NAME}-flask-asg" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' \
  --output text)

echo "Terminating instance: $INSTANCE_TO_TERMINATE"

# Terminate the instance
aws ec2 terminate-instances --instance-ids $INSTANCE_TO_TERMINATE
```

### Monitor Auto-Healing

Watch as the ASG detects the terminated instance and launches a replacement:

```bash
# Monitor ASG instances and their states
watch -n 10 'aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names \"${YOUR_NAME}-flask-asg\" \
  --query \"AutoScalingGroups[0].[DesiredCapacity,Instances[*].[InstanceId,LifecycleState,HealthStatus]]\" \
  --output table'
```

**Or check recent scaling activities:**

```bash
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name "${YOUR_NAME}-flask-asg" \
  --max-records 5 \
  --output table
```

**Expected behavior:**

1. Instance shows as `Terminating` in the ASG
2. ASG detects the instance count is below desired capacity
3. ASG automatically launches a new instance
4. New instance shows as `Pending` then `InService`
5. Desired capacity remains constant (e.g., 2 instances)

**Key observation:** The ASG maintains the desired capacity by automatically replacing unhealthy or terminated instances, ensuring high availability.

---

## Cleanup

When you're done, clean up resources to avoid charges (delete in reverse order):

### Delete Auto Scaling Group

```bash
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name "${YOUR_NAME}-flask-asg" \
  --force-delete
```

Wait for instances to terminate before proceeding.

### Delete Launch Template

```bash
aws ec2 delete-launch-template \
  --launch-template-name "${YOUR_NAME}-flask-launch-template"
```

### Delete Security Group

```bash
aws ec2 delete-security-group --group-id $SG_ID
```

### Delete Key Pair

```bash
aws ec2 delete-key-pair --key-name "$KEYPAIR_NAME"
rm ~/.ssh/${KEYPAIR_NAME}.pem
```

### Delete Subnets

```bash
aws ec2 delete-subnet --subnet-id $SUBNET1_ID
aws ec2 delete-subnet --subnet-id $SUBNET2_ID
```

### Delete Route Table

```bash
aws ec2 delete-route-table --route-table-id $ROUTE_TABLE_ID
```

### Detach and Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id $IGW_ID \
  --vpc-id $VPC_ID

aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID
```

### Delete VPC

```bash
aws ec2 delete-vpc --vpc-id $VPC_ID
```

---

## Troubleshooting

### Instances not responding on port 8080

- Wait 5-10 minutes for the user data script to complete
- Check instance logs: `ssh` into instance and run `sudo journalctl -u cloud-init-output`
- Verify security group allows inbound traffic on port 8080

### Cannot SSH into instance

- Verify security group allows SSH (port 22) from your IP
- Check that you're using the correct keypair file
- Ensure keypair file has correct permissions (400)
- Verify instance has a public IP address

### Auto Scaling Group not creating instances

- Verify subnet IDs are valid and in the correct VPC
- Check that subnets have routes to the Internet Gateway
- Ensure subnets have auto-assign public IP enabled
- Check that you have available capacity in your AWS account
- Review launch template configuration for errors

### Instances not getting public IPs

- Verify subnets have auto-assign public IP enabled
- Check that route table has a route to Internet Gateway

---

## Summary

You've successfully created:

- **VPC:** `sk-flask-vpc` with CIDR 10.0.0.0/16
- **Internet Gateway:** Attached to your VPC
- **Subnets:** Two public subnets across multiple AZs (10.0.1.0/24, 10.0.2.0/24)
- **Route Table:** With route to Internet Gateway
- **Key Pair:** `sk-flask-keypair` (private key: `~/.ssh/sk-flask-keypair.pem`)
- **Security Group:** Allows SSH (22) and Flask app (8080) access
- **Launch Template:** `sk-flask-launch-template` with Amazon Linux 2023, t2.micro, and automated Flask setup
- **Auto Scaling Group:** `sk-flask-asg` with 1-3 instances (desired: 2)
- **Scaling Policy:** CPU target tracking at 50%

Your Flask application is now running in a custom VPC with auto-scaling and auto-healing capabilities!
