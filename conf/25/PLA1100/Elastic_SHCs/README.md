# Splunk Search Head Cluster Auto Scaling Group Management

This repository contains scripts and services for managing Splunk Search Head Cluster (SHC) nodes within AWS Auto Scaling Groups, ensuring graceful cluster joins and leaves during scaling operations.

Note that this README.md was largely written by Anthropic's "Claude" LLM after uploading the included files and asking it to:
```
Evaluate the attached files and generate a README.md that can be used to describe the files in git
```
I've generally reviewed it for accuracy and added a section about AWS ASG configuration, but as always, you should review the code before running it in your environment.

## Overview

The solution consists of three main components that work together to provide seamless Splunk cluster management in dynamic AWS environments:

1. **Auto-rejoin script** - Handles rejoining nodes to the cluster after clean operations
2. **ASG lifecycle management** - Monitors for scaling events and gracefully removes nodes
3. **Systemd service** - Ensures continuous monitoring of lifecycle state

## Components

### 999-autoRejoin.sh

**Purpose**: Automatically rejoins Splunk nodes to the search head cluster after a clean operation or initial startup.

**Key Features**:
- Detects whether the node needs to rejoin the cluster (checks for existing passwd file)
- Retrieves Splunk admin password from AWS SSM Parameter Store
- Creates necessary user credentials for cluster operations
- Identifies cluster friends within the same Auto Scaling Group
- Handles cluster joining with retry logic and random delays to prevent mass events
- Disables detention mode after successful join

**Execution Flow**:
1. Check if this is a simple reboot (passwd file exists) or requires cluster rejoin
2. If rejoin needed: stop Splunk, create user-seed.conf, restart Splunk
3. Wait for Splunk to be ready, then attempt to join cluster via a peer node
4. Disable detention mode and complete

### asg_mgmt.sh

**Purpose**: Continuously monitors AWS Auto Scaling Group lifecycle state and gracefully removes nodes from the Splunk cluster when they're being terminated.

**Key Features**:
- Monitors `target-lifecycle-state` via AWS Instance Metadata Service (IMDS v2)
- Creates heartbeat scripts to extend lifecycle hook timeouts during graceful shutdown
- Enables detention mode to prevent new search assignments
- Waits for active searches to complete before removal
- Ensures cluster consistency before attempting removal
- Performs Splunk clean operation to prepare for potential future rejoins

**Execution Flow**:
1. Continuously poll lifecycle state every 90 seconds
2. When termination detected: create heartbeat manager to extend shutdown window
3. Enable detention mode and wait for running searches to complete
4. Verify cluster captain availability before attempting removal
5. Remove node from cluster, stop Splunk, clean data, complete lifecycle action

### tivo_asgManager.service

**Purpose**: Systemd service unit that ensures the ASG management script runs continuously.

**Configuration**:
- Starts after Splunkd.service
- Automatically restarts on failure
- Logs to syslog with identifier "splunkAsgManager"

## Prerequisites

### AWS Configuration
- EC2 instances must have IAM roles with permissions for:
  - SSM Parameter Store access (`ssm:GetParameter`)
  - Auto Scaling Group operations (`autoscaling:*`)
  - EC2 instance describe operations (`ec2:DescribeInstances`)
- Lifecycle hooks configured on Auto Scaling Groups
- IMDS v2 enabled on instances

### Splunk Configuration
- Search Head Cluster already established
- Admin password stored in AWS SSM Parameter Store at `/passwords/splunk`
- Splunk installed at `/opt/splunk`

### System Dependencies
- `curl` - For API calls and IMDS access
- `jq` - For JSON parsing
- `aws` CLI - For AWS service interactions
- Proper network connectivity between cluster members

## Installation
The `999-autoRejoin.sh` script can go into the cloud-init per-boot scripts directory so it will be auto-run on boot time

1. **Deploy scripts**:
   ```bash
   sudo cp 999-autoRejoin.sh /var/lib/cloud/scripts/per-boot/
   sudo cp asg_mgmt.sh /usr/local/bin/
   sudo chmod +x /var/lib/cloud/scripts/per-boot/999-autoRejoin.sh
   sudo chmod +x /usr/local/bin/asg_mgmt.sh
   ```

2. **Install systemd service**:
   ```bash
   sudo cp tivo_asgManager.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable tivo_asgManager.service
   ```

## Usage

### ASG Configuration
You'll need to configure your AWS Auto-Scaling Group to have a termination lifecycle hook associated with it so that 
the node can detect that it is being taken out of service. You can read about [AWS Lifecycle Hooks here](https://docs.aws.amazon.com/autoscaling/ec2/userguide/lifecycle-hooks.html)

### Scaling Operations
We're using a warm pool so that nodes scale in a bit faster, but you don't have to. We also use scheduled scaling actions, however
AWS provides a variety of options trigger a scale down or scale up event, you should configure your ASG according to your needs.

**Scale Up**: New instances will automatically join the cluster via the rejoin script.

**Scale Down**: Instances will be gracefully removed through the ASG management service.

## Monitoring and Troubleshooting

### Log Locations
- ASG Manager: `journalctl -u tivo_asgManager.service -f`
- Lifecycle heartbeat: `/tmp/lchMgr.log`
- Splunk logs: `/opt/splunk/var/log/splunk/`

### Common Issues

**Rejoin failures**:
- Verify SSM parameter exists and is accessible
- Check network connectivity between cluster members
- Ensure Splunk service is running and responsive

**Graceful removal timeouts**:
- Check if searches are completing within expected timeframes
- Verify lifecycle hook timeout is sufficient (recommend 900+ seconds)
- Monitor cluster captain elections during removal events

**IMDS failures**:
- Ensure EC2 instances have proper IAM roles
- Verify IMDS v2 is enabled and accessible
- Check for networking issues affecting metadata service

## Security Considerations

- Splunk admin password is retrieved from AWS SSM Parameter Store with encryption
- Scripts use IAM roles rather than hardcoded credentials
- IMDS v2 tokens are used for enhanced security
- Network access between cluster members should be restricted to necessary ports

## Architecture Notes

This solution addresses several challenges with running Splunk SHC in Auto Scaling Groups:

- **Split-brain prevention**: Ensures proper cluster leave before termination
- **Search continuity**: Waits for active searches to complete before removal
- **Rapid scaling**: Handles mass scale events with randomized delays
- **State management**: Properly cleans and prepares nodes for potential rejoining

The scripts are designed to be resilient to AWS API temporary failures and include retry logic with exponential backoff where appropriate.