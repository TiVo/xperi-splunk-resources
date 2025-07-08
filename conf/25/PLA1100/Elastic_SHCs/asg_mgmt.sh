#!/usr/bin/bash
# This will be a systemd service that regularly monitors the "target-lifecycle-state" to determine
# if this node is being taken out of service. If it is being taken out of service (due to an ASG action)
# then nicely remove it from the searchhead cluster.
#
# We've seen significant issues with just shutting a node down, the remaining members of the cluster suffer
# timeouts, slowdowns and generalized anger at the world around. Furthermore, it prevents us from shrinking
# the cluster to less than 50% of the nodes, even if we don't need them, due to the fact that the RAFT protocol
# can not come to a consensus as to who can be captain, becuase it requires qurom of the nodes configured in 
# the cluster, not a qurom of the available nodes.

cleanUp () {
    # Cleanup stuff left around
    echo "Cleaning up..."
    rm ${lchScript}
}

checkPid () {
    # Check to see if a PID is running:
    # 0: yes
    # 1: no
    kill -0 ${1} 2>/dev/null
    return $?
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

createHeartbeatScript () {
    # Write out the hearbeat manager
    cat << EOF > ${lchScript}
#!/usr/bin/bash

log () {
    echo "\$(date): \${1}" >> ${lchLog}
}

sendCompletion () {
    aws --region ${region} autoscaling complete-lifecycle-action --lifecycle-hook-name ${lchName} --auto-scaling-group-name ${asgName} --instance-id ${instance} --lifecycle-action-result CONTINUE
    return \$?
}

completeLch () {
    while :; do
        sleep 5
        # It's possible (likely even?) that the wrapper script will complete before we get out of
        # ASG cooldown, so let's seend the lifecycle-hook completion ASAP and not pay for an extra 300s
        \$(sendCompletion) && break || log "Send completion failed... still in cooldown?"
    done
    rm -f ${lchPid}
    sleep 5
    exit
}

# When signaled that things are complete, complete the lifecycle action and exit
log "\${0} Started: \$$"
echo "\$$" > ${lchPid}
trap completeLch USR1

while :; do
    aws --region ${region} autoscaling record-lifecycle-action-heartbeat --lifecycle-hook-name ${lchName} --auto-scaling-group-name ${asgName} --instance-id ${instance}
    if [[ \$? -gt 0 ]]; then
        # probably still in cooldown -- up to 90s to start + 300s of cooldown, this could take us into the 150th second of the 300 second LCH timeout.
        log "Hearbeat action failed: Still in cooldown?"
        sleep 120
    else
        # Every 90 seconds, extend the lifecycle action by 300s
        log "Recorded heartbeat"
        sleep 90
    fi
done
EOF
	chmod 755 ${lchScript}
}

enableDetention () {
    # Enable detention mode so the captain will stop sending us new searches.
    detentionCmd="/opt/splunk/bin/splunk edit shcluster-config -manual_detention on  -auth admin:'$(aws --region us-west-2  ssm get-parameter --name /passwords/splunk --with-decryption --query 'Parameter.Value' | tr -d \")'"
    su -c "${detentionCmd}" splunk
    sleep 5

    while :; do
        nodeStat=$(curl --fail -s -k -u admin:${SPLUNK_PASSWORD} 'https://localhost:8089/services/shcluster/member/info?output_mode=json' | jq -r '.entry[0].content.status')
        echo "Node Status: ${nodeStat}"
        if [[ ${nodeStat} == "ManualDetention" ]]; then
            break
        else
            sleep 10
            su -c "${detentionCmd}" splunk
        fi
    done
}

runningSearchCount () {
    curl --fail -s -k -u admin:${SPLUNK_PASSWORD} 'https://localhost:8089/services/shcluster/member/info?output_mode=json' | jq '.entry[0].content.active_historical_search_count'
}

removeFromCluster () {
    echo "Removing node from cluster"
    # Tell the cluster we're going away : https://docs.splunk.com/Documentation/Splunk/9.1.5/DistSearch/Removeaclustermember#Remove_the_member
    removeCmd="/opt/splunk/bin/splunk remove shcluster-member -auth admin:'$(aws --region us-west-2  ssm get-parameter --name /passwords/splunk --with-decryption --query 'Parameter.Value' | tr -d \")'"
    su -c "${removeCmd}" splunk
}

shutdownSplunk () {
    systemctl stop Splunkd.service
}

cleanSplunk () {
    # Do the 1st step of the re-add here :: https://docs.splunk.com/Documentation/Splunk/9.1.5/DistSearch/Addaclustermember#Add_a_member_that_was_previously_removed_from_the_cluster
    # This allows us to easily see if a node has been just rebooted, or actually removed from the cluster in the rejoin script
    cleanCmd="/opt/splunk/bin/splunk clean all --answer-yes -auth admin:'$(aws --region us-west-2  ssm get-parameter --name /passwords/splunk --with-decryption --query 'Parameter.Value' | tr -d \")'"
    su -c "${cleanCmd}" splunk
}

checkClusterCaptain () {
    # Try to avoid leaving the cluster when the cluster doesn't seem cohesive, e.g. if the current captain scaled down and an election is in process
    echo "Checking cluster consistency"
    curl -o /dev/null --fail -s -k -u admin:${SPLUNK_PASSWORD}  https://localhost:8089/services/shcluster/captain/info
    return $?
}

completeLifecycle () {
    echo "Killing my child (${childPid})"
    kill -USR1 ${childPid}
    # Wait for the heartbeat to shutdown
    while :; do
        sleep 5
        checkPid ${childPid} && echo "Child (${childPid}) still running" || break
    done
    cleanUp
}

# Common metadata
instance=$(callIMDSv2 instance-id)
region=$(callIMDSv2 placement/region)
asgName=$(aws --region ${region} autoscaling describe-auto-scaling-instances --instance-ids ${instance}  --query "AutoScalingInstances[0].AutoScalingGroupName" --output text)
lchName=$(aws --region ${region} autoscaling describe-lifecycle-hooks --auto-scaling-group-name ${asgName} --query LifecycleHooks[0].LifecycleHookName --output text)

SPLUNK_PASSWORD=$(aws ssm get-parameter --name "/passwords/splunk" --region ${region} --with-decryption --query Parameter.Value | tr -d '"')

# Runtime info
lchScript="/tmp/lchMgr.sh"
lchPid="/tmp/lchMgr.pid"
lchLog="/tmp/lchMgr.log"

echo "region: ${region}, instance: ${instance}, asgName: ${asgName}, lchName: ${lchName}"

# https://docs.aws.amazon.com/autoscaling/ec2/userguide/retrieving-target-lifecycle-state-through-imds.html
# The Auto Scaling instance lifecycle has two primary steady states— InService and Terminated —and two side steady states— Detached and Standby. 
# If you use a warm pool, the lifecycle has four additional steady states— Warmed:Hibernated, Warmed:Running, Warmed:Stopped, and Warmed:Terminated.
#
# UNEXPECTED:
# Sometimes the target-lifecycle-state edpoint doesn't exist... until it does :shrug:
# Fri Nov  1 18:54:25 UTC 2024: ILS: on-demand, IA: none, TLS: FAIL
# Fri Nov  1 18:54:55 UTC 2024: ILS: on-demand, IA: none, TLS: Warmed:Stopped

# Sometimes it does exist... until it doesn't :shrug:
# Mon Nov  4 19:03:20 UTC 2024: ILS: on-demand, IA: none, TLS: InService
# Mon Nov  4 19:03:50 UTC 2024: ILS: on-demand, IA: none, TLS: FAIL

while :; do
    curStatus=$(callIMDSv2 autoscaling/target-lifecycle-state)
    # If the target state is InService, or the call failed, sleep and retry again in a bit
    if [[ ${curStatus} == "InService" ]] || [[ ${curStatus} == "FAIL" ]]; then
        echo "nothing to do..."
        sleep 90
    else # One of the other states were returned, let's shutdown nicely. 
        echo "It's action time!"
        createHeartbeatScript
        # Start the lifecycle-hook heartbeat, this will send heartbeat to prevent shutdown until
        # we send the script SIGUSR1
        ${lchScript} &
        sleep 5
        # Store off the child PID to signal later
        childPid=$(cat ${lchPid})
        # Put the node into detention so that the captain stops sending us searches
        enableDetention
        # Take a nap for up to 15 seconds
        sleep $(( (RANDOM % 10 ) + 5 ))

        while :; do 
            X=$(runningSearchCount)
            echo "${X} searches still running"
            if [[ ${X} -ne 0 ]]; then
                sleep 30
            else
                break
            fi
        done
        # Remove the node from the SHC
        while :; do
            checkClusterCaptain
            if [[ $? -ne 0 ]]; then
                echo "Cluster inconsistent... waiting"
                sleep $(( ( RANDOM % 60 ) + 60 ))
            else
                removeFromCluster
                break
            fi
        done
        # Shutdown splunk
        shutdownSplunk
        # Prepare /opt/splunk for being re-added when restarted
        cleanSplunk
        # Signal the child script that we're done so that it can complete the lifecycle action
        completeLifecycle
    fi
done
