#!/usr/bin/bash

# The regjoin script
# Needs
# 1. splunk admin password
# 2. cluster friend
# Actions:
# 1. Check to see if a clean has been performed (check for ${SH}/etc/passed)
#  a. No, exit, probably just a reboot -- systemctl should start splunk normally
#  b. Yes... act now
# 2. Stop splunk
# 3. Create user-seed.conf
# 4. Start splunk
# 5. Add cluster member via cluster friend.
#

log () {
    echo "$(date):${0}:${1}"
}

callIMDSv2 () {
    # Call the instance metadata services using a token that will work for v1 or v2 (v2 required for AL3 ASGs)
    if [[ -z ${1} ]]; then
        echo "";
        return
    else
        reqPath=${1}
    fi
    IMDSToken=$(curl --silent  -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 600" "http://169.254.169.254/latest/api/token")
    curl --fail -H "X-aws-ec2-metadata-token: ${IMDSToken}" --max-time 2 --silent "http://169.254.169.254/latest/meta-data/${reqPath}"
    if [[ $? -gt 0 ]]; then
        echo "FAIL"
    fi
}

checkLocalClusterStatus () {
    curl -O /dev/null --fail --silent -k -u admin:${SPLUNK_PASSWORD} https://localhost:8089/services/shcluster/captain/info
    echo $?
}

disableDetention () {
    # Enable detention mode so the captain will stop sending us new searches.
    detentionCmd="/opt/splunk/bin/splunk edit shcluster-config -manual_detention off  -auth admin:'$(aws --region us-west-2  ssm get-parameter --name /passwords/splunk --with-decryption --query 'Parameter.Value' | tr -d \")'"
    su -c "${detentionCmd}" splunk
    sleep 5

    while :; do
        nodeStat=$(curl --fail -s -k -u admin:${SPLUNK_PASSWORD} 'https://localhost:8089/services/shcluster/member/info?output_mode=json' | jq -r '.entry[0].content.status')
        echo "Node Status: ${nodeStat}"
        if [[ ${nodeStat} == "Up" ]]; then
            break
        else
            sleep 30
            su -c "${detentionCmd}" splunk
        fi
    done
}

checkSplunkd () {
    # Returns 0 on success, non-zero on "Splunk not running"
    # Can run as root
    ${SPLUNK_HOME}/bin/splunk status >/dev/null
    echo $?
}

splunkControl () {
    if [[ -z ${1} ]]; then
        return
    else
        log "${1}ing Splunkd.service"
        systemctl ${1} Splunkd.service
    fi
}

joinSHC () {
    log "Joining the cluster via my friend ${1}"
    joinCmd="${SPLUNK_HOME}/bin/splunk add shcluster-member -current_member_uri https://${1}:8089 -auth admin:'${SPLUNK_PASSWORD}'"
    su -c "${joinCmd}" splunk
    return $?
}

instance=$(callIMDSv2 instance-id)
region=$(callIMDSv2 placement/region)
SPLUNK_HOME="/opt/splunk"
SPLUNK_PASSWORD=$(aws ssm get-parameter --name "/passwords/splunk" --region ${region} --with-decryption --query Parameter.Value | tr -d '"')

# Determine this script run vs. systemd starts
if [[ -e ${SPLUNK_HOME}/etc/passwd ]]; then
    # Probably just a reboot... carry  on
    log "Nothing to do... but let's check things anyway."
    while [[ $(checkSplunkd ) -ne 0 ]]; do
        # Loop until Splunkd is ready
        sleep 5
    done
    log "Splunk is ready."
    checkLocalClusterStatus && log "Cluster status seems ok" || log "Getting cluster status failed... please check on me"
    exit 0
fi

# Ok... splunk is ready... let's do some things.
#
asgName=$(aws --region ${region} autoscaling describe-auto-scaling-instances --instance-ids ${instance}  --query "AutoScalingInstances[0].AutoScalingGroupName" --output text)

# Who's a cluster friend that isn't me?
DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-example.com}"
clusterFriend="$(aws --region ${region}  ec2 describe-instances --instance-ids $(aws --region ${region} autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${asgName} --query "AutoScalingGroups[0].Instances[?InstanceId!='${instance}'].InstanceId" --output text) --query "Reservations[0].Instances[0].Tags[?Key=='Name']|[0].Value" --output text).${DOMAIN_SUFFIX}"

log "instance: ${instance}, region: ${region}, asgName: ${asgName}, clusterFriend: ${clusterFriend}"

while [[ $(checkSplunkd ) -ne 0 ]]; do
    # Loop until Splunkd is ready
    sleep 30
done

log "Splunkd is ready to proceed..."
# Splunk is up now... but not in a particularly useful state...
# Because splunk was started without a password file... we need to rectify that.

splunkControl stop
# let it stop
sleep 5

# Part of the clean process removes the admin password... so recreate that.
log "Creating user-seed file"
cat <<EOF > ${SPLUNK_HOME}/etc/system/local/user-seed.conf
[user_info]
USERNAME = admin
PASSWORD = ${SPLUNK_PASSWORD}
EOF

# Now we need splunk to be running, and ready... so let's do this again.
sleep 1
splunkControl start

while [[ $(checkSplunkd ) -ne 0 ]]; do
    # Loop until Splunkd is ready
    sleep 30
done
# Sleep up to 5 minutes before trying to join the cluster to try and spread out a mass event
sleep  $((  RANDOM % 300  ))

# ok... splunk is up (again) and has a password that we know... probably
while :; do
    # Try to join the cluster
    joinSHC ${clusterFriend} && break || log "Joining the cluster failed... will try again"; sleep $(( ( RANDOM % 60 ) + 30 ))
done

# Just in case detention status sticks around...
disableDetention

log "Complete."
