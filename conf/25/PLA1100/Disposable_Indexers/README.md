# tivo-aaa : TiVo Ansible Alert Actions

## PLA1100 Notes
Below is the internal README.md we had for our anisble alert actions action.
However, you're probably here because you attended or watched the PLA1100 talk
at .conf 2025. This alert action is used by Xperi to terminate old, slow indexers.

While the docs below indicate that SSH keys must be kept in the "OI SSM", really
it just needs to be kept an an SSM that the searchhead running the alert action
can access. SSM is AWS Systems Manager parameter store. Note that we have hardcoded
the region to "us-west-2" since that's where we run our infrastructure. 

We track many machine stats, including memory, diskio, uptime, etc. using telegraf
and the searches that we use to determine if an indexer is a candidate for recycling
or not. We also use the [Splunk AWS TA](https://splunkbase.splunk.com/app/1876) to collect metadata about our AWS accounts
to determine the actual launch time of a node, not just the uptime.

Ok, now that we have all the high-level information out of the way, here is the
actual search and anisble play information we use to find and terminate indexer
candidates.

### Search
This search is run nightly for the purposes of locating candidate indexers for
termination. Our indexers our named `ssidxXX`, where `XX` is an index starting at 01.
Our nodes are deployed to AZs A, B, and C, and are deployed in numerical order, so 01 is in A,
02 is in B, 03 is in C, etc.

```
| mstats span=30s fillnull_value="unknown"
    max(mem.dirty) as dirty, sum(diskio.write_bytes) as wb, latest(system.uptime) as uptime
    WHERE (index="telegraf") host="ssidx*" (name="md0" OR NOT name="*")
    BY host
| eval site=tonumber(replace(host,"ssidx",""))%3+1
| streamstats window=1 current=f global=f last(wb) as lwb, last(_time) as lt by host | eval wb=(wb-lwb)/(_time-lt)
| eval wb=round(wb/1024/1024,2)
| eval wb=case(wb>0 AND wb<100*1024*1024*1024,wb)
| eval wb_under_load=case(dirty>10*1024*1024*1024,wb)
| eval uptime=round(uptime/(24*60*60),1)
| stats max(wb*) as wb*, max(uptime) as uptime by host, site
    
``` get the launch times for the current indexers from the aws inventory metadata ```
| append [ search index=aws_info sourcetype=aws:metadata source=*:ec2_instances Tags.Name=ssidx*
           | rename Tags.Name as host | eval host=replace(host,".oip1","")
           | stats last(LaunchTime) as LaunchTime by host
           | eval age=round((now()-strptime(LaunchTime."-0000","%Y-%m-%dT%H:%M:%S.000Z%z"))/(24*60*60),1) ]
| stats last(wb*) as wb*, last(uptime) as uptime, last(age) as age, last(site) as site by host
    
``` group into three populations based on launch time or uptime ```
| eval order_uptime=case(uptime>60,0,uptime>31,1,isnotnull(uptime),2)
| eval order_age=case(age>60,0,age>31,1,isnotnull(age),2)
| eval order=coalesce(order_age,order_uptime,1)
    
``` never take out "young" indexers (aka order==2) ```
| where order<2
``` order by age group then writeback speeds seen ```
| sort 0 order wb_under_load wb
``` pick the top one from each site ```
| streamstats count as tgt_order by site
| where tgt_order<=1
| head 3

``` make fields for the alert actions ```
| eval str="`".host."` (".age." days old)"
| stats values(str) as str, values(hosts) as hosts
| eval str=mvjoin(str,", "), hosts=mvjoin(hosts,",")
```

### AAA Configuration
The search above will return, among other things, a comma seperated list of hosts
that are to be terminated. That information is used by the `tivo-aaa` action, as
well as other actions to send slacks, etc. to perform the actual host termination.

The AAA action is an Ad-Hoc action and has four configuration components:

#### Host(s):
The hosts to terminate, use the result of the search above.
```
$result.hosts$
```

#### SSH Key Name (SSM):
This is the path in the SSM to find an SSH private key capable of logging into
the indexers

#### Play Setup:
Setup the variables, etc. for the ansible play runner. Note this uses a lookup
to get the Splunk admin password from an SSM path.

```
gather_facts: no
strategy: free
vars:
  splunk_admin: "{{ lookup('aws_ssm', '/splunk/passwordPath', decrypt=true, region='us-west-2') }}"
  ansible_python_interpreter: auto_silent
```

#### Task(s):
This is the meat of the ansible play, the actual tasks to run. It first logs into
the host to determine the instance ID (to be used in the call to AWS), it then
runs `bin/splunk offline` to take the indexer offline, also, since sometimes
the indexers try to restart after a offline, it runs a `systemctl stop Splunkd` for
good measure. 

When that is done, it returns control to the searchhead running the action which then
calls AWS to terminate the instance.

```
---
- name: Gather instance info
  ec2_metadata_facts:
- name: Display instance id
  debug: var=ansible_ec2_instance_id

- name: Offline and disable splunkd
  remote_user: splunk
  ignore_errors: true
  ignore_unreachable: true
  block:
    - name: Offline splunk daemon
      command: /opt/splunk/bin/splunk offline -auth 'admin:{{ splunk_admin }}'
      register: splunkd_offline
      ignore_errors: true
    - name: Stop and disable splunk daemon
      command: sudo systemctl stop Splunkd
      register: splunkd_stop
  rescue:
    - name: Log when hitting errors
      debug:
        msg: 'Failed to offline and stop Splunk daemon!'
  always:
    - name: Log offline results
      debug:
        msg:
          - "Offline result:  {{ splunkd_offline }}"
          - "Systemcl result: {{ splunkd_stop }}"

- name: Terminate instance
  connection: local
  ec2_instance:
    state: terminated
    region: us-west-2
    instance_ids: "{{ ansible_ec2_instance_id }}"
  register: result
  retries: 8
  delay: 15
  until: result is succeeded
```

## Introduction
TiVo ansible alert actions will allow you to use either one of the predefined
methods or ad-hoc ansible syntax to perform actions based on a Splunk alert.
The goal is to allow you to have an alert action that has the capability to
remediate an issue, not just report on it.

There are three (3) predefined actions, and one ad-hoc action. The goal of the
predefined actions is to allow you to perform common tasks with very little
knowledge of ansible, as the underlying task executor.

## Predefined Ansible Alert Actions

### REST 
The `Ansible Alert Actions - REST` action is written to allow the
Splunk searchhead that is running the alert action to perform some HTTP based
action on your behalf. This action executes locally and while it does require
network access to the port to perform the REST it does not require, or expect
to SSH to the target host(s).  
#### Inputs
You will be required to provide(either statically or via SPL result tokens)
the following inputs for the action to run:
- **Host(s)**: This is a comma (,) separated list of hosts upon which to run the
  HTTP request against. All hosts in this list will have the same request run
against them.
- **URL**: This is the URL to call on each of the hosts, in its entirety.
  However, you must replace the traditional "hostname" portion of the URL with
the literal `{{ item }}`. For example, instead of `http://host:8088/blah`, you
would use `http://{{ item }}:8088/blah`
- **Username**: The username to use for the HTTP request. If the endpoint
  doesn't require authentication, then this should be left blank(?)
- **Password**: The password to be used for the HTTP request. If you don't
  want the password to be stored/visible in Splunk, you can use a ansible
based `lookup` command and get the password out of SSM.
- **HTTP Verb**: You must choose if this should be a `GET`, `POST`, or
  `DELETE` request.  

### SYSTEMCTL
The `Ansible Alert Actions - SYSTEMCTL` action is written to allow the Splunk
searchhead that is running the alert action to `SSH` into the remote host(s)
and run a  `systemctl` command to insure that a systemd target is in a
known/expected state.
#### Inputs
- **Host(s)**: This is a comma (,) separated list of hosts to `ssh` in to and
  ensure that the systemd target is in the expected state.
- **SSH Key Name (SSM)**: The SSH private key must be stored in the OI SSM
  store, this is the name of the key to get out of the SSM to be used to login
to the hosts. It is expected that the searchhead can login to the target
host(s) with the named private key and a username of `splunk`.
- **systemctl target**: This is the name of the systemd target to act upon
- **systemctl action**: There are three (3) actions that you can choose for
  this action to perform.
    - _restart_: This will always cause the named systemctl target to be
      stopped and then started (restarted.)
    - _stop_: This will cause the named systemctl target to be stopped, if,
      and only if, it is currently running.
    - _start_: This will cause the named systemctl target to be started, if,
      and only if, it is currently stopped.

### REBOOT
The `Ansible Alert Actions - REBOOT` action is written to allow the Splunk
searchhead that is running the alert action to `SSH` into the remote host(s)
and reboot them.
#### Inputs
- **Host(s)**: This is a comma (,) separated list of hosts to `ssh` in to and
  ensure that the systemd target is in the expected state.
- **SSH Key Name (SSM)**: The SSH private key must be stored in the OI SSM store,
  this is the name of the key to get out of the SSM to be used to login to the hosts.
  It is expected that the searchhead can login to the target host(s) with the named
  private key and a username of `splunk`.

## ADHOC Ansible Alert Actions
The `Ansible Alert Actions - ADHOC` action is written to allow you to run any
ansible based tasks that you can construct. While not all inclusive, and not
setup to handle things like roles, etc., there are two (2) sections of the 
"traditional" playbook that you can configure here. There's the `Play Setup`
section and the `Task(s)` section. Both of these sections are expected by the
alert action to be parsed as YAML. More details below.
### Inputs
- **Execution Environment**: Here you can choose where you expect the ansible
  playbook to be executed, there are two (2) choices:
  - _Local_: This means that the plays will be run on the searchhead executing
    the alert, and the `Host(s)` field must be set to `localhost`. There's no
    need to specify an `ssh` key for this execution environment.
  - _Remote_: This means that the searchhead executing the alert will `ssh` into
    host(s) listed in the `Host(s)` field. In this case the searchhead will use the
    ssh key listed in the `SSH Key Name (SSM)` to login to each host in the `Host(s)`
    input as the user `splunk`
- **Host(s)**: This is a comma (,) separated list of hosts to `ssh` in to and
  ensure that the systemd target is in the expected state.
- **SSH Key Name (SSM)**: The SSH private key must be stored in the OI SSM store,
  this is the name of the key to get out of the SSM to be used to login to the hosts.
  It is expected that the searchhead can login to the target host(s) with the named
  private key and a username of `splunk`.
- **Play Setup**: This is a YAML document that will be parsed to setup the execution of
  the tasks that will be listed in the `Task(s)` document. This is a good place to configure
  your ansible environment using keywords such as `gather_facts`,`remote_user`, and to set any
  `vars` that you may use in your tasks.
- **Task(s)**: This is a YAML document that will be parsed and used as the tasks to
  execute either Locally or Remotely according to your execution environment set above.
  The results of the tasks will be output as alert logs that you can view via Splunk.
  